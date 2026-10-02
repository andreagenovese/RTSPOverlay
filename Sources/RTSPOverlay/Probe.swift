import Foundation
import CoreMedia
import VideoToolbox

/// Diagnostica da terminale: `RTSPOverlay --probe rtsp://user:password@host:554/Streaming/Channels/102`
/// Si collega, decodifica ~5 secondi di video con VideoToolbox e stampa un riepilogo.
enum Probe {
    static func run(_ args: [String]) -> Never {
        guard let raw = args.first, var comps = URLComponents(string: raw) else {
            print("Usage: RTSPOverlay --probe rtsp://user:password@host:554/Streaming/Channels/102")
            exit(2)
        }
        let user = comps.user ?? ""
        let password = comps.password ?? ""
        comps.user = nil
        comps.password = nil
        let queue = DispatchQueue(label: "probe")
        guard let url = comps.string,
              let client = RTSPClient(url: url, username: user, password: password, queue: queue) else {
            print("Invalid URL")
            exit(2)
        }

        let renderer = VideoRenderer(layer: nil)
        let decoder = ProbeDecoder()
        var units = 0
        var bytes = 0
        var started = Date()

        renderer.onVideoSize = { print("Resolution: \(Int($0.width))×\(Int($0.height))") }
        client.onState = { state in
            switch state {
            case .connecting: print("Connecting to \(url)…")
            case .playing: print("PLAY ok, receiving video…"); started = Date()
            case .failed(let message): print("ERROR: \(message)"); exit(1)
            }
        }
        client.onStreamStart = { codec, sets in
            print("Codec: \(codec.rawValue) (parameter sets in SDP: \(sets.count))")
            renderer.reset(codec: codec, parameterSets: sets)
        }
        client.onAccessUnit = { nals, complete in
            units += 1
            bytes += nals.reduce(0) { $0 + $1.count }
            if let sample = renderer.makeSampleBuffer(nals, complete: complete) { decoder.decode(sample) }
            if units >= 125 {
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "Frames received: %d in %.1f s (%.1f fps, %.0f kbit/s)",
                             units, elapsed, Double(units) / elapsed, Double(bytes) * 8 / elapsed / 1000))
                print("Decoded: \(decoder.decoded), errors: \(decoder.errors), image: \(decoder.imageSize)")
                exit(decoder.decoded > 0 && decoder.errors == 0 ? 0 : 1)
            }
        }
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            print("Timeout (frames received: \(units))")
            exit(1)
        }
        dispatchMain()
    }
}

private final class ProbeDecoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private(set) var decoded = 0
    private(set) var errors = 0
    private(set) var imageSize = "-"

    func decode(_ sample: CMSampleBuffer) {
        guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: sampleFormat) }) == true {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            VTDecompressionSessionCreate(allocator: nil, formatDescription: sampleFormat, decoderSpecification: nil,
                                         imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
            format = sampleFormat
        }
        guard let session else { errors += 1; return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image {
                self.decoded += 1
                self.imageSize = "\(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image))"
            } else {
                self.errors += 1
            }
        }
        if status != noErr { errors += 1 }
    }
}
