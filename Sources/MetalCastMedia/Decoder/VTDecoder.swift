import Foundation
import VideoToolbox
import CoreMedia

public final class VTDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var decompressionSession: VTDecompressionSession?
    private var isInvalidated = false
    public var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    public init() {}

    deinit {
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        isInvalidated = true
        let session = decompressionSession
        decompressionSession = nil
        onPixelBuffer = nil
        lock.unlock()

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Invalidates the decoder off the caller's thread so UI teardown never blocks waiting for async frames.
    public func invalidateAsync() {
        lock.lock()
        isInvalidated = true
        let session = decompressionSession
        decompressionSession = nil
        onPixelBuffer = nil
        lock.unlock()

        guard let session else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            _ = self
        }
    }

    /// Configures or resets the decompression session when resolution/format changes
    public func updateFormatDescription(_ formatDesc: CMVideoFormatDescription) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        let oldSession = decompressionSession
        decompressionSession = nil
        lock.unlock()

        if let oldSession {
            VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
            VTDecompressionSessionInvalidate(oldSession)
        }

        let destinationImageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferOpenGLCompatibilityKey: false
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, _, status, _, imageBuffer, _, _) in
                guard let refCon = decompressionOutputRefCon, status == noErr, let buffer = imageBuffer else { return }
                let decoder = Unmanaged<VTDecoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.lock.lock()
                let handler = decoder.isInvalidated ? nil : decoder.onPixelBuffer
                decoder.lock.unlock()
                handler?(buffer)
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

        if status == noErr, let created = session {
            lock.lock()
            if isInvalidated {
                lock.unlock()
                VTDecompressionSessionInvalidate(created)
            } else {
                self.decompressionSession = created
                lock.unlock()
            }
        } else {
            print("[VTDecoder] Failed to create decompression session: \(status)")
        }
    }

    /// Pushes a CMSampleBuffer to hardware decoder
    public func decode(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let session = isInvalidated ? nil : decompressionSession
        lock.unlock()
        guard let session else { return }

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
