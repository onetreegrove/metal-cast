import AppKit
import CoreMedia
import MetalCastCore
import MetalCastMedia

@MainActor
public final class SessionManager: ObservableObject {
    public static let shared = SessionManager()

    @Published public var devices: [ADBDevice] = []
    @Published public var selectedDevice: ADBDevice?
    @Published public var discoveredWirelessDevices: [DiscoveredWirelessDevice] = []
    @Published public var isScanningWireless = false
    @Published public var isRunning = false
    @Published public var statusMessage = "就绪"

    @Published public var selectedResolution: UInt16 = 0 // 0 = 原生
    @Published public var selectedFps: UInt16 = 0        // 0 = 自适应
    @Published public var selectedBitrate: UInt32 = 16_000_000
    @Published public var selectedCodec: String = "h264" // "h264" 或 "h265"
    @Published public var isAudioEnabled: Bool = true    // 低延迟音频转发开关
    @Published public var screenOffOnStart: Bool = false

    private var activeConnection: ScrcpyConnection?
    private var activeProcess: Process?
    private var mirrorWindowController: MirrorWindowController?
    private var currentSocketName: String?
    private var currentSerial: String?
    private var currentParser: AnnexBParser?
    private var currentDecoder: VTDecoder?
    private var audioPlayer: AudioPlayer?

    public init() {}

    private func resolveServerPath() -> String? {
        let candidates: [String?] = [
            Bundle.main.resourcePath.map { "\($0)/scrcpy-server" },
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scrcpy-server").path,
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/scrcpy-server").path
        ]

        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func refreshDevices() async {
        do {
            let list = try await ADBManager.shared.getDevices()
            self.devices = list
            if selectedDevice == nil || !list.contains(where: { $0.serial == selectedDevice?.serial }) {
                self.selectedDevice = list.first(where: { $0.state == .device })
            }
            self.statusMessage = "扫描完成: 发现 \(list.count) 台设备"
        } catch {
            self.statusMessage = "扫描设备失败: \(error.localizedDescription)"
        }
        await scanWirelessDevices()
    }

    public func scanWirelessDevices() async {
        guard !isScanningWireless else { return }
        isScanningWireless = true
        defer { isScanningWireless = false }

        do {
            let list = try await ADBManager.shared.getMdnsServices()
            self.discoveredWirelessDevices = list
        } catch {
            print("⚠️ [Session] 扫描无线设备失败: \(error.localizedDescription)")
        }
    }

    public func connectWifi(ip: String, port: Int = 5555) async {
        do {
            statusMessage = "正在通过 Wi-Fi 连接 \(ip):\(port) ..."
            let success = try await ADBManager.shared.connectWifi(ip: ip, port: port)
            if success {
                statusMessage = "Wi-Fi 连接成功: \(ip):\(port)"
                await refreshDevices()
            } else {
                statusMessage = "Wi-Fi 连接未响应，请检查手机 IP 与端口"
            }
        } catch {
            statusMessage = "Wi-Fi 连接失败: \(error.localizedDescription)"
        }
    }

    public func pairWirelessDevice(address: String, code: String) async -> Bool {
        statusMessage = "正在配对设备 \(address) ..."
        do {
            let res = try await ADBManager.shared.pairDevice(address: address, code: code)
            if res.success {
                statusMessage = "🎉 配对成功: \(address)"
                await refreshDevices()
                return true
            } else {
                statusMessage = "配对失败: \(res.message)"
                return false
            }
        } catch {
            statusMessage = "配对异常: \(error.localizedDescription)"
            return false
        }
    }

    public func connectDiscoveredWirelessDevice(_ device: DiscoveredWirelessDevice) async {
        await connectWifi(ip: device.ip, port: device.port)
    }

    public func switchSelectedDeviceToWireless() async {
        guard let device = selectedDevice, !device.isWifi else { return }
        statusMessage = "正在为 \(device.model ?? device.serial) 切换无线免插线模式..."
        do {
            let ip = try await ADBManager.shared.switchToWireless(serial: device.serial)
            statusMessage = "🎉 成功切换为无线投屏模式 (\(ip):5555)！现在可以拔下 USB 数据线。"
            await refreshDevices()
        } catch {
            statusMessage = "切换无线模式失败: \(error.localizedDescription)"
        }
    }

    public func setAudioMuted(_ isMuted: Bool) {
        audioPlayer?.isMuted = isMuted
    }

    public func startMirroring() async {
        guard let device = selectedDevice, device.state == .device else {
            statusMessage = "请先选择已连接且授权的 Android 设备"
            return
        }

        guard !isRunning else { return }
        isRunning = true
        currentSerial = device.serial
        statusMessage = "正在初始化推流服务..."

        do {
            // 1. 推送 scrcpy-server.jar
            guard let serverLocalPath = resolveServerPath() else {
                statusMessage = "未找到 scrcpy-server 资源文件"
                isRunning = false
                return
            }

            let serverRemotePath = "/data/local/tmp/scrcpy-server.jar"
            try await ADBManager.shared.push(serial: device.serial, localPath: serverLocalPath, remotePath: serverRemotePath)

            // 2. 建立隧道
            let scid = UInt32.random(in: 0x10000000...0x7FFFFFFF)
            let socketName = String(format: "scrcpy_%08x", scid)
            currentSocketName = socketName
            let localPort: UInt16 = UInt16.random(in: 27200...28000)

            try await ADBManager.shared.reverse(serial: device.serial, remoteSocket: socketName, localPort: localPort)

            // 3. 构建解码流水线与音频输出
            let targetVideoCodec: VideoCodec = (selectedCodec == "h265") ? .h265 : .h264
            let parser = AnnexBParser(codec: targetVideoCodec)
            let decoder = VTDecoder()
            self.currentParser = parser
            self.currentDecoder = decoder

            var localAudioPlayer: AudioPlayer?
            if isAudioEnabled {
                let player = AudioPlayer()
                self.audioPlayer = player
                localAudioPlayer = player
            }

            let winController = MirrorWindowController(serial: device.serial, deviceName: device.model ?? "Android")
            self.mirrorWindowController = winController

            winController.onClose = { [weak self] in
                Task { @MainActor in
                    self?.stopMirroring()
                }
            }

            decoder.onPixelBuffer = { [weak winController] pixelBuffer in
                winController?.renderFrame(pixelBuffer)
            }

            parser.onFormatDescription = { [weak winController, weak decoder] formatDesc in
                let dim = CMVideoFormatDescriptionGetDimensions(formatDesc)
                print("📐 [Session] 提取到视频格式描述: \(dim.width)x\(dim.height)")
                decoder?.updateFormatDescription(formatDesc)
                DispatchQueue.main.async {
                    winController?.updateResolution(width: Int(dim.width), height: Int(dim.height))
                }
            }

            parser.onSampleBuffer = { [weak decoder] sample in
                decoder?.decode(sampleBuffer: sample)
            }

            // 4. 建立 TCP 服务
            let connection = ScrcpyConnection(port: localPort, audioEnabled: isAudioEnabled)
            self.activeConnection = connection
            winController.attachConnection(connection)

            connection.onDeviceName = { [weak winController] name, codec, w, h in
                print("🎉 [Session] 成功握手设备: \(name) (\(codec), \(w)x\(h))")
                DispatchQueue.main.async {
                    winController?.updateResolution(width: w, height: h)
                }
            }

            connection.onVideoData = { chunk in
                parser.parse(chunk: chunk)
            }

            if let audioP = localAudioPlayer {
                connection.onAudioData = { chunk in
                    audioP.enqueue(data: chunk)
                }
            }

            connection.onDeviceMessage = { msg in
                if case .clipboard(let text) = msg {
                    Task { @MainActor in
                        ClipboardManager.shared.handleDeviceClipboard(text)
                    }
                }
            }

            connection.onDisconnected = { [weak self] in
                print("🛑 [Session] 收到设备连接中断通知")
                Task { @MainActor in
                    self?.statusMessage = "连接已中断"
                    self?.stopMirroring()
                }
            }

            try await connection.startListening()

            // 5. 启动 Android 端 Server
            let proc = try await ADBManager.shared.executeServer(
                serial: device.serial,
                serverRemotePath: serverRemotePath,
                maxSize: selectedResolution,
                bitRate: selectedBitrate,
                maxFps: selectedFps,
                control: true,
                audio: isAudioEnabled,
                audioCodec: "raw",
                videoCodec: selectedCodec,
                scid: scid,
                onLog: { log in
                    let clean = log.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        print("📱 [Server Log] \(clean)")
                    }
                }
            )
            self.activeProcess = proc

            // 6. 激活剪贴板监控
            ClipboardManager.shared.startMonitoring(connection: connection)

            // 7. 熄屏参数处理
            if screenOffOnStart {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                connection.sendControlMessage(.setScreenPower(on: false))
            }

            winController.showWindow(nil)
            winController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            statusMessage = "投屏运行中 (音频: \(isAudioEnabled ? "开启" : "关闭"), 编码: \(selectedCodec.uppercased()))"

        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
            stopMirroring()
        }
    }

    public func stopMirroring() {
        guard isRunning else { return }
        print("🛑 [Session] 正在停止投屏会话...")

        audioPlayer?.stop()
        audioPlayer = nil

        ClipboardManager.shared.stopMonitoring()
        activeConnection?.stop()
        activeConnection = nil

        activeProcess?.terminate()
        activeProcess = nil

        if let serial = currentSerial, let socket = currentSocketName {
            Task {
                try? await ADBManager.shared.removeReverse(serial: serial, remoteSocket: socket)
            }
        }

        mirrorWindowController?.close()
        mirrorWindowController = nil
        currentParser = nil
        currentDecoder = nil

        isRunning = false
        statusMessage = "已断开连接"
    }
}
