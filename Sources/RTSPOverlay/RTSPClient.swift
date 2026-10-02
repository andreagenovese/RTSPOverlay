import Foundation
import Network
import CryptoKit

enum VideoCodec: String {
    case h264 = "H.264"
    case h265 = "H.265"
}

struct RTSPError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct RTSPResponse {
    let status: Int
    let reason: String
    let headers: [(name: String, value: String)]
    let body: [UInt8]

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func allHeaders(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

/// Client RTSP minimale: RTP interleaved su TCP, autenticazione Digest/Basic, solo traccia video H.264/H.265.
/// Ogni istanza gestisce una sola connessione; tutte le callback arrivano sulla `queue` passata.
final class RTSPClient {
    enum State {
        case connecting
        case playing
        case failed(String)
    }

    var onState: ((State) -> Void)?
    var onStreamStart: ((VideoCodec, [[UInt8]]) -> Void)?
    /// NAL unit di un access unit (senza start code) e `false` se sono andati persi pacchetti.
    var onAccessUnit: (([[UInt8]], Bool) -> Void)?

    private enum Auth {
        case basic
        case digest(realm: String, nonce: String, qop: String?, opaque: String?, algorithm: String?)
    }

    private struct VideoTrack {
        let codec: VideoCodec
        let control: String
        let parameterSets: [[UInt8]]
    }

    private let url: String
    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var buf: [UInt8] = []
    private var pos = 0
    private var cseq = 0
    private var pending: [Int: (RTSPResponse) -> Void] = [:]
    private var auth: Auth?
    private var nonceCount = 0
    private var session: String?
    private var sessionTimeout = 60
    private var baseURL = ""
    private var videoChannel: UInt8 = 0
    private var depacketizer: RTPDepacketizer?
    private var keepAliveMethod = "GET_PARAMETER"
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var lastData = Date()
    private var lastKeepAlive = Date()
    private var playing = false
    private var finished = false

    init?(url: String, username: String, password: String, queue: DispatchQueue) {
        guard var comps = URLComponents(string: url), comps.scheme?.lowercased() == "rtsp",
              let host = comps.host, !host.isEmpty else { return nil }
        let port = comps.port ?? 554
        guard (1...65535).contains(port) else { return nil }
        comps.user = nil
        comps.password = nil
        self.url = comps.string ?? url
        self.host = host
        self.port = UInt16(port)
        self.username = username
        self.password = password
        self.queue = queue
        self.baseURL = self.url
    }

    deinit { connection?.cancel() }

    func start() {
        queue.async { [self] in
            guard connection == nil, !finished else { return }
            onState?(.connecting)
            startedAt = Date()
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                    using: NWParameters(tls: nil, tcp: tcp))
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, !self.finished else { return }
                switch state {
                case .ready:
                    self.lastData = Date()
                    self.startTimer()
                    self.receive()
                    self.sendOptions()
                case .waiting(let error):
                    self.fail(String(localized: "Device unreachable (\(error.localizedDescription))"))
                case .failed(let error):
                    self.fail(String(localized: "Connection error: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            startTimer()
        }
    }

    func stop() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            timer?.cancel()
            timer = nil
            pending.removeAll()
            guard let conn = connection else { return }
            connection = nil
            if playing, session != nil {
                let teardown = buildRequest("TEARDOWN", baseURL, headers: [])
                conn.send(content: teardown, completion: .contentProcessed { _ in conn.cancel() })
            } else {
                conn.cancel()
            }
        }
    }

    // MARK: - Sequenza RTSP

    private func sendOptions() {
        request("OPTIONS", url) { [self] resp in
            if let methods = resp.header("Public"), !methods.uppercased().contains("GET_PARAMETER") {
                keepAliveMethod = "OPTIONS"
            }
            describe()
        }
    }

    private func describe() {
        request("DESCRIBE", url, headers: [("Accept", "application/sdp")]) { [self] resp in
            guard resp.status == 200 else { return fail(errorMessage(resp, "DESCRIBE")) }
            baseURL = normalize(resp.header("Content-Base") ?? resp.header("Content-Location") ?? url)
            do {
                let track = try Self.parseVideoTrack(String(decoding: resp.body, as: UTF8.self))
                let depacketizer = RTPDepacketizer(codec: track.codec)
                depacketizer.onAccessUnit = { [weak self] nals, complete in self?.onAccessUnit?(nals, complete) }
                self.depacketizer = depacketizer
                onStreamStart?(track.codec, track.parameterSets)
                setup(controlURL: resolve(track.control))
            } catch let error as RTSPError {
                fail(error.message)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func setup(controlURL: String) {
        request("SETUP", controlURL, headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")]) { [self] resp in
            guard resp.status == 200 else { return fail(errorMessage(resp, "SETUP")) }
            guard let sessionHeader = resp.header("Session") else { return fail(String(localized: "The device did not return a session")) }
            let parts = sessionHeader.split(separator: ";")
            session = parts.first.map { $0.trimmed }
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0].trimmed.lowercased() == "timeout", let t = Int(kv[1].trimmed), t > 0 {
                    sessionTimeout = t
                }
            }
            if let transport = resp.header("Transport"),
               let inter = transport.split(separator: ";").first(where: { $0.trimmed.lowercased().hasPrefix("interleaved=") }),
               let ch = UInt8(inter.trimmed.dropFirst("interleaved=".count).split(separator: "-").first ?? "") {
                videoChannel = ch
            }
            play()
        }
    }

    private func play() {
        request("PLAY", baseURL, headers: [("Range", "npt=0.000-")]) { [self] resp in
            guard resp.status == 200 else { return fail(errorMessage(resp, "PLAY")) }
            playing = true
            lastData = Date()
            lastKeepAlive = Date()
            onState?(.playing)
        }
    }

    private func sendKeepAlive() {
        lastKeepAlive = Date()
        request(keepAliveMethod, baseURL) { [self] resp in
            if resp.status != 200, keepAliveMethod == "GET_PARAMETER" { keepAliveMethod = "OPTIONS" }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let now = Date()
            if !self.playing {
                if now.timeIntervalSince(self.startedAt) > 15 { self.fail(String(localized: "Timeout while connecting")) }
                return
            }
            if now.timeIntervalSince(self.lastData) > 10 { return self.fail(String(localized: "No data received from the device")) }
            let interval = Double(max(5, min(30, self.sessionTimeout / 2)))
            if now.timeIntervalSince(self.lastKeepAlive) > interval { self.sendKeepAlive() }
        }
        t.resume()
        timer = t
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        pending.removeAll()
        connection?.cancel()
        connection = nil
        onState?(.failed(message))
    }

    private func errorMessage(_ resp: RTSPResponse, _ step: String) -> String {
        switch resp.status {
        case 401: return String(localized: "Invalid username or password (401)")
        case 403: return String(localized: "Access denied (403)")
        case 404: return String(localized: "Stream not found (404): check channel or path")
        case 453: return String(localized: "Not enough bandwidth or too many clients connected (453)")
        case 454: return String(localized: "Session not found (454)")
        default: return String(localized: "\(step) refused: \(resp.status) \(resp.reason)")
        }
    }

    // MARK: - Richieste e autenticazione

    private func buildRequest(_ method: String, _ uri: String, headers: [(String, String)]) -> Data {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: RTSPOverlay/1.0"]
        if let authorization = authorizationHeader(method: method, uri: uri) { lines.append("Authorization: \(authorization)") }
        if let session { lines.append("Session: \(session)") }
        for (k, v) in headers { lines.append("\(k): \(v)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func request(_ method: String, _ uri: String, headers: [(String, String)] = [],
                         retryAuth: Bool = true, completion: @escaping (RTSPResponse) -> Void) {
        guard let conn = connection, !finished else { return }
        let data = buildRequest(method, uri, headers: headers)
        pending[cseq] = { [weak self] resp in
            guard let self else { return }
            if resp.status == 401, retryAuth {
                guard self.configureAuth(from: resp) else { return self.fail(String(localized: "Unsupported authentication method")) }
                self.request(method, uri, headers: headers, retryAuth: false, completion: completion)
                return
            }
            completion(resp)
        }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(String(localized: "Send failed: \(error.localizedDescription)")) }
        })
    }

    private func configureAuth(from resp: RTSPResponse) -> Bool {
        let challenges = resp.allHeaders("WWW-Authenticate")
        if let digest = challenges.first(where: { $0.lowercased().hasPrefix("digest") }) {
            let params = Self.parseAuthParams(String(digest.dropFirst(6)))
            guard let realm = params["realm"], let nonce = params["nonce"] else { return false }
            auth = .digest(realm: realm, nonce: nonce, qop: params["qop"], opaque: params["opaque"], algorithm: params["algorithm"])
            nonceCount = 0
            return true
        }
        if challenges.contains(where: { $0.lowercased().hasPrefix("basic") }) {
            auth = .basic
            return true
        }
        return false
    }

    private func authorizationHeader(method: String, uri: String) -> String? {
        switch auth {
        case nil:
            return nil
        case .basic:
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case let .digest(realm, nonce, qop, opaque, algorithm):
            let ha1 = Self.md5("\(username):\(realm):\(password)")
            let ha2 = Self.md5("\(method):\(uri)")
            var parts = ["username=\"\(username)\"", "realm=\"\(realm)\"", "nonce=\"\(nonce)\"", "uri=\"\(uri)\""]
            if let qop, qop.split(separator: ",").map({ $0.trimmed }).contains("auth") {
                nonceCount += 1
                let nc = String(format: "%08x", nonceCount)
                let cnonce = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                parts.append("response=\"\(Self.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)"))\"")
                parts += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
            } else {
                parts.append("response=\"\(Self.md5("\(ha1):\(nonce):\(ha2)"))\"")
            }
            if let opaque { parts.append("opaque=\"\(opaque)\"") }
            if let algorithm { parts.append("algorithm=\(algorithm)") }
            return "Digest " + parts.joined(separator: ", ")
        }
    }

    // MARK: - Ricezione

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.lastData = Date()
                self.buf.append(contentsOf: data)
                self.parse()
            }
            if let error {
                self.fail(String(localized: "Connection lost: \(error.localizedDescription)"))
            } else if isComplete {
                self.fail(String(localized: "Connection closed by the device"))
            } else {
                self.receive()
            }
        }
    }

    private func parse() {
        while !finished {
            let available = buf.count - pos
            guard available > 0 else { break }
            if buf[pos] == 0x24 { // '$' = pacchetto RTP/RTCP interleaved
                guard available >= 4 else { break }
                let channel = buf[pos + 1]
                let length = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3])
                guard available >= 4 + length else { break }
                if channel == videoChannel { handleRTP(Array(buf[(pos + 4)..<(pos + 4 + length)])) }
                pos += 4 + length
            } else if buf[pos] == 0x52 { // 'R' di "RTSP/1.0"
                guard available >= 5 else { break }
                guard buf[pos..<(pos + 5)].elementsEqual("RTSP/".utf8) else { pos += 1; continue }
                guard let headerEnd = findHeaderEnd(from: pos) else {
                    if available > 65536 { fail(String(localized: "Invalid RTSP response")) }
                    break
                }
                guard let consumed = parseResponse(headerEnd: headerEnd) else { break }
                pos = consumed
            } else {
                pos += 1 // dati inattesi: risincronizzazione
            }
        }
        if pos > 0 {
            buf.removeSubrange(0..<min(pos, buf.count))
            pos = 0
        }
    }

    private func findHeaderEnd(from start: Int) -> Int? {
        var i = start
        while i + 3 < buf.count {
            if buf[i] == 13, buf[i + 1] == 10, buf[i + 2] == 13, buf[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// Restituisce la posizione dopo la risposta, o nil se il corpo non è ancora arrivato.
    private func parseResponse(headerEnd: Int) -> Int? {
        var lines = String(decoding: buf[pos..<headerEnd], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((line[..<colon].trimmed, line[line.index(after: colon)...].trimmed))
        }
        let contentLength = headers.first { $0.name.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        let bodyStart = headerEnd + 4
        guard buf.count >= bodyStart + contentLength else { return nil }
        let response = RTSPResponse(
            status: statusParts.count > 1 ? Int(statusParts[1]) ?? 0 : 0,
            reason: statusParts.count > 2 ? String(statusParts[2]) : "",
            headers: headers,
            body: Array(buf[bodyStart..<(bodyStart + contentLength)]))
        if let cseq = response.header("CSeq").flatMap({ Int($0.trimmed) }), let handler = pending.removeValue(forKey: cseq) {
            handler(response)
        }
        return bodyStart + contentLength
    }

    private func handleRTP(_ p: [UInt8]) {
        guard let depacketizer, p.count >= 12, p[0] >> 6 == 2 else { return }
        var offset = 12 + 4 * Int(p[0] & 0x0F)
        if p[0] & 0x10 != 0 { // header extension
            guard p.count >= offset + 4 else { return }
            offset += 4 + 4 * (Int(p[offset + 2]) << 8 | Int(p[offset + 3]))
        }
        var end = p.count
        if p[0] & 0x20 != 0 { end -= Int(p[end - 1]) } // padding
        guard offset < end else { return }
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let timestamp = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        depacketizer.push(Array(p[offset..<end]), seq: seq, timestamp: timestamp, marker: p[1] & 0x80 != 0)
    }

    // MARK: - Utilità

    /// Gli URL restituiti dal dispositivo possono contenere il suo IP interno (es. dietro NAT):
    /// li riscriviamo con host e porta effettivamente usati.
    private func normalize(_ value: String) -> String {
        guard var comps = URLComponents(string: value.trimmed), comps.scheme?.lowercased() == "rtsp" else { return value }
        comps.host = host
        comps.port = Int(port)
        comps.user = nil
        comps.password = nil
        return comps.string ?? value
    }

    private func resolve(_ control: String) -> String {
        let c = control.trimmed
        if c.isEmpty || c == "*" { return baseURL }
        if c.lowercased().hasPrefix("rtsp://") { return normalize(c) }
        return baseURL.hasSuffix("/") ? baseURL + c : baseURL + "/" + c
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parseAuthParams(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 }
            var key = ""
            while i < chars.count, chars[i] != "=", chars[i] != "," { key.append(chars[i]); i += 1 }
            guard i < chars.count, chars[i] == "=" else { continue }
            i += 1
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i])
                    i += 1
                }
                i += 1
            } else {
                while i < chars.count, chars[i] != "," { value.append(chars[i]); i += 1 }
            }
            result[key.trimmed.lowercased()] = value.trimmed
        }
        return result
    }

    private static func parseVideoTrack(_ sdp: String) throws -> VideoTrack {
        var inVideo = false, found = false
        var payloadType = "", encoding = "", control = ""
        var fmtp: [String: String] = [:]
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.hasPrefix("m=") {
                if found { break }
                inVideo = line.hasPrefix("m=video")
                if inVideo {
                    found = true
                    let parts = line.split(separator: " ")
                    payloadType = parts.count > 3 ? String(parts[3]) : ""
                }
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let parts = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[0] == payloadType {
                    encoding = String(parts[1].split(separator: "/").first ?? "").uppercased()
                }
            } else if line.hasPrefix("a=fmtp:") {
                let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[0] == payloadType {
                    for item in parts[1].split(separator: ";") {
                        let kv = item.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 { fmtp[kv[0].trimmed.lowercased()] = kv[1].trimmed }
                    }
                }
            } else if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10))
            }
        }
        guard found else { throw RTSPError(String(localized: "No video track in the stream")) }
        switch encoding {
        case "H264":
            let sets = (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").compactMap(base64)
            return VideoTrack(codec: .h264, control: control, parameterSets: sets)
        case "H265", "HEVC":
            let sets = ["sprop-vps", "sprop-sps", "sprop-pps"].compactMap { fmtp[$0] }
                .flatMap { $0.split(separator: ",") }.compactMap(base64)
            return VideoTrack(codec: .h265, control: control, parameterSets: sets)
        default:
            let name = encoding.isEmpty ? String(localized: "unknown") : encoding
            throw RTSPError(String(localized: "Unsupported video codec: \(name). Set H.264 or H.265 on the camera"))
        }
    }

    private static func base64(_ s: Substring) -> [UInt8]? {
        var str = s.trimmed
        while str.count % 4 != 0 { str += "=" }
        guard let data = Data(base64Encoded: str), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
