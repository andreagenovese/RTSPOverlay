import Foundation

/// Ricompone le NAL unit H.264 (RFC 6184) / H.265 (RFC 7798) dai pacchetti RTP
/// e le raggruppa in access unit (un fotogramma).
final class RTPDepacketizer {
    let codec: VideoCodec
    var onAccessUnit: (([[UInt8]], Bool) -> Void)?

    private var nals: [[UInt8]] = []
    private var fragment: [UInt8]?
    private var lastSeq: UInt16?
    private var timestamp: UInt32?
    private var damaged = false

    init(codec: VideoCodec) { self.codec = codec }

    func push(_ payload: [UInt8], seq: UInt16, timestamp ts: UInt32, marker: Bool) {
        if let last = lastSeq, seq != last &+ 1 {
            fragment = nil
            damaged = true
        }
        lastSeq = seq
        if let current = timestamp, current != ts, !nals.isEmpty { flush() } // marker perso
        timestamp = ts

        switch codec {
        case .h264: pushH264(payload)
        case .h265: pushH265(payload)
        }
        if marker { flush() }
    }

    private func flush() {
        if !nals.isEmpty { onAccessUnit?(nals, !damaged) }
        nals = []
        damaged = false
    }

    private func pushH264(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        switch p[0] & 0x1F {
        case 1...23:
            nals.append(p)
        case 24: // STAP-A
            appendAggregated(p, from: 1)
        case 28: // FU-A
            guard p.count > 2 else { return }
            let start = p[1] & 0x80 != 0, end = p[1] & 0x40 != 0
            if start {
                fragment = [(p[0] & 0xE0) | (p[1] & 0x1F)] + p[2...]
            } else if fragment != nil {
                fragment!.append(contentsOf: p[2...])
            } else {
                damaged = true
            }
            if end, let f = fragment {
                nals.append(f)
                fragment = nil
            }
        default:
            break
        }
    }

    private func pushH265(_ p: [UInt8]) {
        guard p.count > 2 else { return }
        switch (p[0] >> 1) & 0x3F {
        case 48: // Aggregation packet
            appendAggregated(p, from: 2)
        case 49: // Fragmentation unit
            guard p.count > 3 else { return }
            let header = p[2]
            let start = header & 0x80 != 0, end = header & 0x40 != 0
            if start {
                fragment = [(p[0] & 0x81) | ((header & 0x3F) << 1), p[1]] + p[3...]
            } else if fragment != nil {
                fragment!.append(contentsOf: p[3...])
            } else {
                damaged = true
            }
            if end, let f = fragment {
                nals.append(f)
                fragment = nil
            }
        case 50: // PACI: non supportato
            break
        default:
            nals.append(p)
        }
    }

    private func appendAggregated(_ p: [UInt8], from start: Int) {
        var i = start
        while i + 2 <= p.count {
            let size = Int(p[i]) << 8 | Int(p[i + 1])
            i += 2
            guard size > 0, i + size <= p.count else { break }
            nals.append(Array(p[i..<(i + size)]))
            i += size
        }
    }
}
