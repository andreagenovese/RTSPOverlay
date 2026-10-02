import AVFoundation
import CoreMedia

/// Trasforma gli access unit in CMSampleBuffer e li passa al display layer,
/// che decodifica in hardware (VideoToolbox) e li mostra subito.
final class VideoRenderer {
    private enum NALKind { case parameterSet, keyframe, frame, other }

    /// Chiamate sul main thread.
    var onVideoSize: ((CGSize) -> Void)?
    var onFirstFrame: (() -> Void)?

    private(set) var formatDescription: CMVideoFormatDescription?
    private let renderer: AVSampleBufferVideoRenderer?
    private var codec: VideoCodec = .h264
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var waitingForKeyframe = true
    private var hasRendered = false
    private var videoSize = CGSize.zero

    init(layer: AVSampleBufferDisplayLayer?) {
        renderer = layer?.sampleBufferRenderer
    }

    func reset(codec: VideoCodec, parameterSets: [[UInt8]]) {
        self.codec = codec
        vps = nil
        sps = nil
        pps = nil
        formatDescription = nil
        waitingForKeyframe = true
        hasRendered = false
        for set in parameterSets where !set.isEmpty { _ = store(parameterSet: set) }
        renderer?.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    func render(_ nals: [[UInt8]], complete: Bool) {
        guard let renderer else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            waitingForKeyframe = true
        }
        guard let sample = makeSampleBuffer(nals, complete: complete) else { return }
        renderer.enqueue(sample)
        if !hasRendered {
            hasRendered = true
            let callback = onFirstFrame
            DispatchQueue.main.async { callback?() }
        }
    }

    /// Restituisce nil finché non arriva un fotogramma chiave dopo un errore o un reset.
    func makeSampleBuffer(_ nals: [[UInt8]], complete: Bool) -> CMSampleBuffer? {
        guard complete else {
            waitingForKeyframe = true
            return nil
        }
        var slices: [[UInt8]] = []
        var keyframe = false
        var changed = false
        for nal in nals where !nal.isEmpty {
            switch kind(of: nal) {
            case .parameterSet: if store(parameterSet: nal) { changed = true }
            case .keyframe: keyframe = true; slices.append(nal)
            case .frame: slices.append(nal)
            case .other: break
            }
        }
        if changed || formatDescription == nil { rebuildFormat() }
        guard let format = formatDescription, !slices.isEmpty else { return nil }
        if waitingForKeyframe {
            guard keyframe else { return nil }
            waitingForKeyframe = false
        }

        // Formato AVCC/HVCC: ogni NAL preceduta dalla lunghezza a 4 byte big-endian
        let total = slices.reduce(0) { $0 + 4 + $1.count }
        var data = [UInt8]()
        data.reserveCapacity(total)
        for s in slices {
            let n = UInt32(s.count)
            data += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            data += s
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: total,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                   offsetIntoDestination: 0, dataLength: total) }) == kCMBlockBufferNoErr
        else { return nil }

        var sample: CMSampleBuffer?
        var size = total
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let yes = Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque()
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), yes)
            if !keyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), yes)
            }
        }
        return sample
    }

    private func kind(of nal: [UInt8]) -> NALKind {
        switch codec {
        case .h264:
            switch nal[0] & 0x1F {
            case 7, 8: return .parameterSet
            case 5: return .keyframe
            case 1...4: return .frame
            default: return .other
            }
        case .h265:
            guard nal.count >= 2 else { return .other }
            switch (nal[0] >> 1) & 0x3F {
            case 32...34: return .parameterSet
            case 16...21: return .keyframe
            case 0...9: return .frame
            default: return .other
            }
        }
    }

    private func store(parameterSet nal: [UInt8]) -> Bool {
        switch codec {
        case .h264:
            switch nal[0] & 0x1F {
            case 7 where sps != nal: sps = nal; return true
            case 8 where pps != nal: pps = nal; return true
            default: return false
            }
        case .h265:
            switch (nal[0] >> 1) & 0x3F {
            case 32 where vps != nal: vps = nal; return true
            case 33 where sps != nal: sps = nal; return true
            case 34 where pps != nal: pps = nal; return true
            default: return false
            }
        }
    }

    private func rebuildFormat() {
        let sets: [[UInt8]]
        switch codec {
        case .h264:
            guard let sps, let pps else { return }
            sets = [sps, pps]
        case .h265:
            guard let vps, let sps, let pps else { return }
            sets = [vps, sps, pps]
        }
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { return }
        formatDescription = format

        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        if size != videoSize, size.width > 0, size.height > 0 {
            videoSize = size
            let callback = onVideoSize
            DispatchQueue.main.async { callback?(size) }
        }
    }
}
