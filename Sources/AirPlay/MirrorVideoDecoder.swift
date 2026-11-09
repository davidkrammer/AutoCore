import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct MirrorDecodedFrame {
    let sampleBuffer: CMSampleBuffer
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime
}

final class MirrorVideoDecoder {
    private let queue = DispatchQueue(label: "AirRecorder.VideoDecoder", qos: .userInitiated)
    private let outputHandler: (MirrorDecodedFrame) -> Void

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var loggedMissingConfiguration = false
    private var lastSubmittedDecodeError: OSStatus?
    private let outputErrorLock = NSLock()
    private var lastOutputError: OSStatus?

    init(outputHandler: @escaping (MirrorDecodedFrame) -> Void) {
        self.outputHandler = outputHandler
    }

    deinit {
        reset()
    }

    func submitParameterSets(sps: Data, pps: Data) {
        queue.async { [weak self] in
            self?.configureDecoder(sps: sps, pps: pps)
        }
    }

    func submitFrame(_ frame: Data, ptsMicroseconds: UInt64) {
        queue.async { [weak self] in
            self?.decode(frame: frame, ptsMicroseconds: ptsMicroseconds)
        }
    }

    func flush() {
        queue.async { [weak self] in
            guard let session = self?.decompressionSession else { return }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    func reset() {
        queue.sync {
            invalidateDecoder()
        }
    }

    private func configureDecoder(sps: Data, pps: Data) {
        invalidateDecoder()
        loggedMissingConfiguration = false
        lastSubmittedDecodeError = nil

        let spsBytes = Array(sps)
        let ppsBytes = Array(pps)
        let sizes = [spsBytes.count, ppsBytes.count]
        var createdFormatDescription: CMFormatDescription?

        let formatStatus = spsBytes.withUnsafeBufferPointer { spsBuffer in
            ppsBytes.withUnsafeBufferPointer { ppsBuffer in
                guard
                    let spsBaseAddress = spsBuffer.baseAddress,
                    let ppsBaseAddress = ppsBuffer.baseAddress
                else {
                    return OSStatus(-50)
                }

                var parameterSetPointers = [spsBaseAddress, ppsBaseAddress]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &createdFormatDescription
                )
            }
        }

        guard formatStatus == noErr, let formatDescription = createdFormatDescription else {
            NSLog("AirPlay: invalid H.264 parameter sets (status=%d, SPS=%lu, PPS=%lu, types=%u/%u)",
                  formatStatus, sps.count, pps.count,
                  UInt32(sps.first ?? 0) & 0x1f, UInt32(pps.first ?? 0) & 0x1f)
            return
        }

        self.formatDescription = formatDescription

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: mirrorDecompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard sessionStatus == noErr, let session else {
            NSLog("AirPlay: VideoToolbox session creation failed (status=%d)", sessionStatus)
            self.formatDescription = nil
            return
        }

        decompressionSession = session
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    private func decode(frame: Data, ptsMicroseconds: UInt64) {
        guard let formatDescription, let decompressionSession else {
            if !loggedMissingConfiguration {
                NSLog("AirPlay: video frames arrived before a usable H.264 configuration")
                loggedMissingConfiguration = true
            }
            return
        }
        guard
            let avccFrame = Self.annexBToAVCC(frame),
            !avccFrame.isEmpty
        else {
            return
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccFrame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccFrame.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return
        }

        let replaceStatus = avccFrame.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccFrame.count
            )
        }

        guard replaceStatus == kCMBlockBufferNoErr else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccFrame.count
        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            return
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if decodeStatus != noErr, decodeStatus != lastSubmittedDecodeError {
            NSLog("AirPlay: VideoToolbox rejected frame (status=%d)", decodeStatus)
            lastSubmittedDecodeError = decodeStatus
        }
    }

    fileprivate func noteOutputError(_ status: OSStatus) {
        outputErrorLock.lock()
        let isNewError = lastOutputError != status
        lastOutputError = status
        outputErrorLock.unlock()
        if isNewError {
            NSLog("AirPlay: VideoToolbox output failed (status=%d)", status)
        }
    }

    fileprivate func consumeDecodedImageBuffer(_ imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime) {
        let pixelBuffer = imageBuffer

        var videoFormatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &videoFormatDescription
        )

        guard formatStatus == noErr, let videoFormatDescription else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        outputHandler(
            MirrorDecodedFrame(
                sampleBuffer: sampleBuffer,
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp
            )
        )
    }

    private func invalidateDecoder() {
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }

        decompressionSession = nil
        formatDescription = nil
    }

    private static func annexBToAVCC(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }

        var output = Data()
        var index = 0

        while index < bytes.count {
            let codeLength = startCodeLength(bytes, at: index)
            if codeLength == 0 {
                index += 1
                continue
            }

            let naluStart = index + codeLength
            var naluEnd = naluStart

            while naluEnd < bytes.count, startCodeLength(bytes, at: naluEnd) == 0 {
                naluEnd += 1
            }

            let naluLength = naluEnd - naluStart
            if naluLength > 0 {
                var bigEndianLength = UInt32(naluLength).bigEndian
                withUnsafeBytes(of: &bigEndianLength) { output.append(contentsOf: $0) }
                output.append(contentsOf: bytes[naluStart..<naluEnd])
            }

            index = naluEnd
        }

        return output.isEmpty ? nil : output
    }

    private static func startCodeLength(_ bytes: [UInt8], at index: Int) -> Int {
        guard index < bytes.count else { return 0 }

        if index + 3 < bytes.count,
           bytes[index] == 0,
           bytes[index + 1] == 0,
           bytes[index + 2] == 0,
           bytes[index + 3] == 1 {
            return 4
        }

        if index + 2 < bytes.count,
           bytes[index] == 0,
           bytes[index + 1] == 0,
           bytes[index + 2] == 1 {
            return 3
        }

        return 0
    }
}

private func mirrorDecompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    let _ = sourceFrameRefCon
    let _ = infoFlags
    let _ = presentationDuration

    guard let decompressionOutputRefCon else {
        return
    }

    let decoder = Unmanaged<MirrorVideoDecoder>.fromOpaque(decompressionOutputRefCon).takeUnretainedValue()
    guard status == noErr, let imageBuffer else {
        decoder.noteOutputError(status)
        return
    }
    decoder.consumeDecodedImageBuffer(imageBuffer, presentationTimeStamp: presentationTimeStamp)
}
