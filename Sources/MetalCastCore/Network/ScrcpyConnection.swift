import Foundation
import Network

public final class ScrcpyConnection: @unchecked Sendable {
    public let port: UInt16
    public let audioEnabled: Bool

    private var listener: NWListener?
    private var videoConnection: NWConnection?
    private var audioConnection: NWConnection?
    private var controlConnection: NWConnection?

    private let queue = DispatchQueue(label: "com.macscrcpy.connection", qos: .userInteractive)

    public var onDeviceName: (@Sendable (_ name: String, _ codec: String, _ width: Int, _ height: Int) -> Void)?
    public var onVideoData: (@Sendable (Data) -> Void)?
    public var onAudioData: (@Sendable (Data) -> Void)?
    public var onDeviceMessage: (@Sendable (DeviceMessage) -> Void)?
    public var onDisconnected: (@Sendable () -> Void)?

    private var incomingConnections: [NWConnection] = []
    private var videoBuffer = Data()
    private var audioBuffer = Data()
    private var controlBuffer = Data()
    private var isHeaderReceived = false
    private var isAudioHeaderReceived = false
    private var hasDisconnected = false

    public init(port: UInt16 = 27183, audioEnabled: Bool = true) {
        self.port = port
        self.audioEnabled = audioEnabled
    }

    /// Starts listening for incoming connections from scrcpy-server
    public func startListening() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "MetalCast", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        let newListener = try NWListener(using: parameters, on: nwPort)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[ScrcpyConnection] 正在端口 \(nwPort) 监听连接 (Audio: \(self.audioEnabled ? "开启" : "关闭"))")
            case .failed(let error):
                print("[ScrcpyConnection] 监听器失败: \(error)")
            default:
                break
            }
        }

        newListener.start(queue: queue)
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.incomingConnections.append(connection)
            let index = self.incomingConnections.count
            print("[ScrcpyConnection] 建立新 Socket 连接 #\(index)")
            connection.start(queue: self.queue)

            if index == 1 {
                self.videoConnection = connection
                self.readVideoStream(connection)
            } else if self.audioEnabled && index == 2 {
                self.audioConnection = connection
                self.readAudioStream(connection)
            } else if (!self.audioEnabled && index == 2) || (self.audioEnabled && index == 3) {
                self.controlConnection = connection
                self.readControlStream(connection)
            }
        }
    }

    private func readVideoStream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.videoBuffer.append(data)
                self.parseVideoBuffer()
            }

            if isComplete || error != nil {
                print("[Video Socket #1] 连接关闭或出错: \(String(describing: error))")
                self.handleDisconnect()
            } else {
                self.readVideoStream(connection)
            }
        }
    }

    private func parseVideoBuffer() {
        // 1. Initial 80-byte header: 64B DeviceName + 4B CodecID + 4B Flags + 4B Width + 4B Height
        if !isHeaderReceived {
            guard videoBuffer.count >= 80 else { return }

            let nameData = videoBuffer.subdata(in: 0..<64)
            let deviceName = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(["\0", " "])) ?? "Android Device"

            let codecData = videoBuffer.subdata(in: 64..<68)
            let codecStr = String(data: codecData, encoding: .ascii)?.trimmingCharacters(in: CharacterSet(["\0", " "])) ?? "h264"

            let width = Int(videoBuffer.subdata(in: 72..<76).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let height = Int(videoBuffer.subdata(in: 76..<80).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

            videoBuffer.removeSubrange(0..<80)
            isHeaderReceived = true
            print("📱 [ScrcpyConnection] 设备: \(deviceName), 编码: \(codecStr), 尺寸: \(width)x\(height)")
            onDeviceName?(deviceName, codecStr, width, height)
        }

        // 2. Framed video packets: 12B Header (8B PTS/flags + 4B Length) + Payload
        while videoBuffer.count >= 12 {
            let (ptsFlags, packetLen): (UInt64, Int) = videoBuffer.withUnsafeBytes { rawPtr in
                let pts = rawPtr.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian
                let len = Int(rawPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian)
                return (pts, len)
            }

            // Session metadata packet (flag 1<<63): 12 bytes total, no extra payload
            if (ptsFlags & (UInt64(1) << 63)) != 0 {
                videoBuffer.removeSubrange(0..<12)
                print("[ScrcpyConnection] 收到会话尺寸更新包 (Session Metadata)")
                continue
            }

            guard videoBuffer.count >= 12 + packetLen else {
                // Incomplete packet payload, wait for next socket read
                break
            }

            let payload = videoBuffer.subdata(in: 12..<(12 + packetLen))
            videoBuffer.removeSubrange(0..<(12 + packetLen))
            onVideoData?(payload)
        }
    }

    private func readAudioStream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.audioBuffer.append(data)
                self.parseAudioBuffer()
            }

            if isComplete || error != nil {
                print("[Audio Socket] 连接关闭: \(String(describing: error))")
            } else {
                self.readAudioStream(connection)
            }
        }
    }

    private func parseAudioBuffer() {
        // 1. Initial 4-byte header: Codec ID (raw / aac / opus / 0x00000000)
        if !isAudioHeaderReceived {
            guard audioBuffer.count >= 4 else { return }
            let codecRaw = audioBuffer.subdata(in: 0..<4)
            audioBuffer.removeSubrange(0..<4)
            isAudioHeaderReceived = true

            let codecStr = String(data: codecRaw, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            print("🎵 [ScrcpyConnection] 接收到音频流 Codec 标识: '\(codecStr)'")

            if codecStr.allSatisfy({ $0 == "\0" }) {
                print("⚠️ [ScrcpyConnection] 设备端显式禁用了音频流 (系统低于 Android 11 或捕获失败)")
                return
            }
        }

        // 2. Framed audio packets: 12B Header (8B PTS/flags + 4B Length) + Payload
        while audioBuffer.count >= 12 {
            let (ptsFlags, packetLen): (UInt64, Int) = audioBuffer.withUnsafeBytes { rawPtr in
                let pts = rawPtr.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian
                let len = Int(rawPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian)
                return (pts, len)
            }

            // Check config packet flag (bit 1 of 8-byte header: 1 << 62)
            let isConfig = (ptsFlags & (UInt64(1) << 62)) != 0
            if isConfig {
                if audioBuffer.count >= 12 + packetLen {
                    audioBuffer.removeSubrange(0..<(12 + packetLen))
                    continue
                } else {
                    break
                }
            }

            guard audioBuffer.count >= 12 + packetLen else {
                break
            }

            let payload = audioBuffer.subdata(in: 12..<(12 + packetLen))
            audioBuffer.removeSubrange(0..<(12 + packetLen))
            onAudioData?(payload)
        }
    }

    private func readControlStream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.controlBuffer.append(data)
                self.parseControlBuffer()
            }

            if isComplete || error != nil {
                self.handleDisconnect()
            } else {
                self.readControlStream(connection)
            }
        }
    }

    private func parseControlBuffer() {
        while true {
            let result = DeviceMessage.parse(from: controlBuffer)
            guard let msg = result.message, result.bytesConsumed > 0 else { break }
            controlBuffer.removeSubrange(0..<result.bytesConsumed)
            onDeviceMessage?(msg)
        }
    }

    /// Sends a control message to the Android device
    public func sendControlMessage(_ message: ControlMessage) {
        let data = message.serialize()
        queue.async { [weak self] in
            self?.controlConnection?.send(content: data, completion: .contentProcessed { error in
                if let err = error {
                    print("[ScrcpyConnection] Send failed: \(err)")
                }
            })
        }
    }

    private func handleDisconnect() {
        guard !hasDisconnected else { return }
        hasDisconnected = true
        onDisconnected?()
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.videoConnection?.cancel()
            self?.videoConnection = nil
            self?.audioConnection?.cancel()
            self?.audioConnection = nil
            self?.controlConnection?.cancel()
            self?.controlConnection = nil
            self?.incomingConnections.forEach { $0.cancel() }
            self?.incomingConnections.removeAll()
            self?.videoBuffer.removeAll()
            self?.audioBuffer.removeAll()
            self?.controlBuffer.removeAll()
            self?.isHeaderReceived = false
            self?.isAudioHeaderReceived = false
            self?.hasDisconnected = false
        }
    }
}
