import Foundation
import AudioToolbox

public final class AudioPlayer: @unchecked Sendable {
    private var audioQueue: AudioQueueRef?
    private var isRunning = false
    private let lock = NSLock()
    private var bufferPool: [AudioQueueBufferRef] = []
    private let bufferSize: UInt32 = 4096 * 4 // ~16KB chunks
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

        // Pre-allocate 4 buffers in pool
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, bufferSize, &buffer) == noErr, let buf = buffer {
                bufferPool.append(buf)
            }
        }
    }

    private func handleBufferCompleted(buffer: AudioQueueBufferRef) {
        lock.lock()
        bufferPool.append(buffer)
        lock.unlock()
    }

    private func updateVolume() {
        guard let queue = audioQueue else { return }
        let effectiveVol: Float = isMuted ? 0.0 : max(0.0, min(1.0, volume))
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, effectiveVol)
    }

    public func enqueue(data: Data) {
        guard let queue = audioQueue, !data.isEmpty else { return }

        lock.lock()
        guard let buffer = bufferPool.popLast() else {
            lock.unlock()
            // Buffer pool exhausted; allocate a dynamic buffer if needed
            var dynamicBuffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, UInt32(data.count), &dynamicBuffer)
            guard allocStatus == noErr, let buf = dynamicBuffer else { return }
            fillAndEnqueue(buffer: buf, with: data, queue: queue)
            return
        }
        lock.unlock()

        fillAndEnqueue(buffer: buffer, with: data, queue: queue)
    }

    private func fillAndEnqueue(buffer: AudioQueueBufferRef, with data: Data, queue: AudioQueueRef) {
        let copyLength = min(Int(buffer.pointee.mAudioDataBytesCapacity), data.count)
        data.withUnsafeBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            memcpy(buffer.pointee.mAudioData, baseAddress, copyLength)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(copyLength)

        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if status != noErr {
            print("⚠️ [AudioPlayer] AudioQueueEnqueueBuffer 失败: \(status)")
            lock.lock()
            bufferPool.append(buffer)
            lock.unlock()
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
