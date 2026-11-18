import Foundation
import Network

public final class ScrcpyConnection: @unchecked Sendable {
    public let port: UInt16
    private var listener: NWListener?
    private var videoConnection: NWConnection?
    private var controlConnection: NWConnection?

    private let queue = DispatchQueue(label: "com.macscrcpy.connection", qos: .userInteractive)

    public var onDeviceName: (@Sendable (String, Int, Int) -> Void)?
    public var onVideoData: (@Sendable (Data) -> Void)?
    public var onDeviceMessage: (@Sendable (DeviceMessage) -> Void)?
    public var onDisconnected: (@Sendable () -> Void)?

    private var incomingConnections: [NWConnection] = []
    private var videoBuffer = Data()
    private var controlBuffer = Data()
    private var isHeaderReceived = false

    public init(port: UInt16 = 27183) {
        self.port = port
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
                print("[ScrcpyConnection] Listening on port \(nwPort)")
            case .failed(let error):
                print("[ScrcpyConnection] Listener failed: \(error)")
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
            } else if index == 2 {
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
                print("[Socket #1] 连接关闭或出错: \(String(describing: error))")
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

            let width = Int(videoBuffer.subdata(in: 72..<76).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let height = Int(videoBuffer.subdata(in: 76..<80).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

            videoBuffer.removeSubrange(0..<80)
            isHeaderReceived = true
            onDeviceName?(deviceName, width, height)
        }

        // 2. Framed video packets: 12B Header (8B PTS/flags + 4B Length) + Payload
        while videoBuffer.count >= 12 {
            let ptsFlags = videoBuffer.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            let packetLen = Int(videoBuffer.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

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
        onDisconnected?()
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.videoConnection?.cancel()
            self?.videoConnection = nil
            self?.controlConnection?.cancel()
            self?.controlConnection = nil
            self?.incomingConnections.removeAll()
            self?.videoBuffer.removeAll()
            self?.controlBuffer.removeAll()
            self?.isHeaderReceived = false
        }
    }
}
