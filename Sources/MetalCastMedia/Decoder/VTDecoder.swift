import Foundation
import VideoToolbox
import CoreMedia

public final class VTDecoder: @unchecked Sendable {
    private var decompressionSession: VTDecompressionSession?
    public var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    public init() {}

    deinit {
        invalidate()
    }

    public func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    /// Configures or resets the decompression session when resolution/format changes
    public func updateFormatDescription(_ formatDesc: CMVideoFormatDescription) {
        invalidate()

        let destinationImageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferOpenGLCompatibilityKey: false
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, _, status, _, imageBuffer, _, _) in
                guard status == noErr, let buffer = imageBuffer else { return }
                let decoder = Unmanaged<VTDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
                decoder.onPixelBuffer?(buffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        if status == noErr {
            self.decompressionSession = session
        } else {
            print("[VTDecoder] Failed to create decompression session: \(status)")
        }
    }

    /// Pushes a CMSampleBuffer to hardware decoder
    public func decode(sampleBuffer: CMSampleBuffer) {
        guard let session = decompressionSession else { return }

        let flags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
            ._1xRealTimePlayback
        ]

        var flagOut: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: &flagOut
        )
    }
}
