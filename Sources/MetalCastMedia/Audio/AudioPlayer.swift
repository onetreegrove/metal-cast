import Foundation
import AudioToolbox

public final class AudioPlayer: @unchecked Sendable {
    private var audioQueue: AudioQueueRef?
    private var isRunning = false
    private let lock = NSLock()
    private var bufferPool: [AudioQueueBufferRef] = []
    private let bufferSize: UInt32 = 32768 // 32KB per buffer
    public var isMuted: Bool = false {
        didSet {
            updateVolume()
        }
    }
    public var volume: Float = 1.0 {
        didSet {
            updateVolume()
        }
    }

    public init() {
        setupAudioQueue()
    }

    deinit {
        stop()
    }

    private func setupAudioQueue() {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let callback: AudioQueueOutputCallback = { userData, inAQ, inBuffer in
            guard let userData = userData else { return }
            let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()
            player.handleBufferCompleted(buffer: inBuffer)
        }

        let status = AudioQueueNewOutput(
            &format,
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &audioQueue
        )

        guard status == noErr, let queue = audioQueue else {
            print("❌ [AudioPlayer] 初始化 AudioQueue 失败: \(status)")
            return
        }

        // Pre-allocate 6 buffers in pool
        for _ in 0..<6 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, bufferSize, &buffer) == noErr, let buf = buffer {
                bufferPool.append(buf)
            }
        }
    }

    private func handleBufferCompleted(buffer: AudioQueueBufferRef) {
        lock.lock()
        defer { lock.unlock() }

        if bufferPool.count < 12 {
            bufferPool.append(buffer)
        } else if let queue = audioQueue {
            AudioQueueFreeBuffer(queue, buffer)
        }
    }

    private func updateVolume() {
        guard let queue = audioQueue else { return }
        let effectiveVol: Float = isMuted ? 0.0 : max(0.0, min(1.0, volume))
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, effectiveVol)
    }

    public func enqueue(data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let queue = audioQueue else { return }

        let buffer: AudioQueueBufferRef
        if let pooled = bufferPool.popLast() {
            buffer = pooled
        } else {
            var dynamicBuffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, max(bufferSize, UInt32(data.count)), &dynamicBuffer)
            guard allocStatus == noErr, let buf = dynamicBuffer else { return }
            buffer = buf
        }

        let copyLength = min(Int(buffer.pointee.mAudioDataBytesCapacity), data.count)
        data.withUnsafeBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            memcpy(buffer.pointee.mAudioData, baseAddress, copyLength)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(copyLength)

        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if status != noErr {
            print("⚠️ [AudioPlayer] AudioQueueEnqueueBuffer 失败: \(status)")
            bufferPool.append(buffer)
            return
        }

        if !isRunning {
            let startStatus = AudioQueueStart(queue, nil)
            if startStatus == noErr {
                isRunning = true
                print("🔊 [AudioPlayer] 音频输出队列已启动 (48kHz Stereo)")
            }
        }
    }

    public func start() {
        guard let queue = audioQueue, !isRunning else { return }
        AudioQueueStart(queue, nil)
        isRunning = true
    }

    public func pause() {
        guard let queue = audioQueue, isRunning else { return }
        AudioQueuePause(queue)
        isRunning = false
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        bufferPool.removeAll()
        isRunning = false
    }
}
