import Foundation

public actor ADBManager {
    public static let shared = ADBManager()

    private let runner: ADBProcessRunner

    public init(runner: ADBProcessRunner = .shared) {
        self.runner = runner
    }

    /// Queries connected ADB devices with detailed properties
    public func getDevices() async throws -> [ADBDevice] {
        let result = try await runner.run(args: ["devices", "-l"])
        guard result.exitCode == 0 else {
            throw ADBError.commandFailed(result.stderr)
        }

        let lines = result.stdout.components(separatedBy: .newlines)
        return lines.compactMap { ADBDevice.parse(deviceLine: $0) }
    }

    /// Pushes a local file to the remote Android device
    public func push(serial: String, localPath: String, remotePath: String) async throws {
        let result = try await runner.run(args: ["-s", serial, "push", localPath, remotePath])
        guard result.exitCode == 0 else {
            throw ADBError.pushFailed(result.stderr)
        }
    }

    /// Sets up adb reverse tunnel (e.g. localabstract:scrcpy -> tcp:27183)
    public func reverse(serial: String, remoteSocket: String, localPort: UInt16) async throws {
        let result = try await runner.run(args: [
            "-s", serial, "reverse",
            "localabstract:\(remoteSocket)",
            "tcp:\(localPort)"
        ])
        guard result.exitCode == 0 else {
            throw ADBError.reverseFailed(result.stderr)
        }
    }

    /// Removes adb reverse tunnel
    public func removeReverse(serial: String, remoteSocket: String) async throws {
        _ = try await runner.run(args: [
            "-s", serial, "reverse", "--remove",
            "localabstract:\(remoteSocket)"
        ])
    }

    /// Sets up adb forward tunnel
    public func forward(serial: String, localPort: UInt16, remoteSocket: String) async throws {
        let result = try await runner.run(args: [
            "-s", serial, "forward",
            "tcp:\(localPort)",
            "localabstract:\(remoteSocket)"
        ])
        guard result.exitCode == 0 else {
            throw ADBError.forwardFailed(result.stderr)
        }
    }

    /// Removes adb forward tunnel
    public func removeForward(serial: String, localPort: UInt16) async throws {
        _ = try await runner.run(args: [
            "-s", serial, "forward", "--remove",
            "tcp:\(localPort)"
        ])
    }

    /// Connects to a device via Wi-Fi IP and Port
    public func connectWifi(ip: String, port: Int = 5555) async throws -> Bool {
        let target = "\(ip):\(port)"
        let result = try await runner.run(args: ["connect", target])
        return result.exitCode == 0 && result.stdout.contains("connected")
    }

    /// Disconnects a Wi-Fi device
    public func disconnectWifi(ip: String, port: Int = 5555) async throws {
        let target = "\(ip):\(port)"
        _ = try await runner.run(args: ["disconnect", target])
    }

    /// Discovers nearby wireless ADB devices via mDNS services
    public func getMdnsServices() async throws -> [DiscoveredWirelessDevice] {
        let result = try await runner.run(args: ["mdns", "services"])
        guard result.exitCode == 0 else { return [] }

        var list: [DiscoveredWirelessDevice] = []
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("List of discovered") {
                continue
            }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 3 else { continue }
            let name = parts[0]
            let type = parts[1]
            let addr = parts[2]
            let device = DiscoveredWirelessDevice(
                id: "\(name)_\(addr)",
                name: name,
                serviceType: type,
                address: addr
            )
            list.append(device)
        }
        return list
    }

    /// Pairs with an Android 11+ wireless debugging device using a 6-digit code
    public func pairDevice(address: String, code: String) async throws -> (success: Bool, message: String) {
        let result = try await runner.run(args: ["pair", address, code])
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let isSuccess = result.exitCode == 0 && output.contains("Successfully paired")
        return (isSuccess, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Enables TCP/IP debugging on a currently connected USB device
    public func enableTcpip(serial: String, port: Int = 5555) async throws -> Bool {
        let result = try await runner.run(args: ["-s", serial, "tcpip", "\(port)"])
        return result.exitCode == 0
    }

    /// Retrieves the device's local Wi-Fi IPv4 address
    public func getDeviceWifiIP(serial: String) async throws -> String? {
        // Try method 1: ip -f inet addr show wlan0
        let res1 = try await runner.run(args: ["-s", serial, "shell", "ip -f inet addr show wlan0"])
        if res1.exitCode == 0 {
            let pattern = #"inet\s+(\d+\.\d+\.\d+\.\d+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: res1.stdout, range: NSRange(res1.stdout.startIndex..., in: res1.stdout)),
               let range = Range(match.range(at: 1), in: res1.stdout) {
                return String(res1.stdout[range])
            }
        }

        // Try method 2: getprop dhcp.wlan0.ipaddress
        let res2 = try await runner.run(args: ["-s", serial, "shell", "getprop dhcp.wlan0.ipaddress"])
        let ip2 = res2.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip2.isEmpty && ip2.contains(".") {
            return ip2
        }

        // Try method 3: ip route
        let res3 = try await runner.run(args: ["-s", serial, "shell", "ip route"])
        let pattern3 = #"src\s+(\d+\.\d+\.\d+\.\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern3),
           let match = regex.firstMatch(in: res3.stdout, range: NSRange(res3.stdout.startIndex..., in: res3.stdout)),
           let range = Range(match.range(at: 1), in: res3.stdout) {
            return String(res3.stdout[range])
        }

        return nil
    }

    /// One-click helper: switches a USB device to Wi-Fi connection seamlessly
    public func switchToWireless(serial: String, port: Int = 5555) async throws -> String {
        guard let ip = try await getDeviceWifiIP(serial: serial) else {
            throw NSError(domain: "MetalCast", code: -1, userInfo: [NSLocalizedDescriptionKey: "未能获取手机当前 Wi-Fi IP 地址，请确认手机已连入与 Mac 相同的 Wi-Fi 局域网"])
        }

        let tcpipSuccess = try await enableTcpip(serial: serial, port: port)
        guard tcpipSuccess else {
            throw NSError(domain: "MetalCast", code: -2, userInfo: [NSLocalizedDescriptionKey: "执行 adb tcpip \(port) 失败，请确保 USB 调试已授权"])
        }

        // Wait for ADB daemon on device to restart in TCP mode (with retry)
        var connected = false
        for attempt in 1...3 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if (try? await connectWifi(ip: ip, port: port)) == true {
                connected = true
                break
            }
            print("🔄 [ADBManager] 尝试连接无线设备 \(ip):\(port) (第 \(attempt)/3 次)...")
        }

        guard connected else {
            throw NSError(domain: "MetalCast", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法连接无线设备 \(ip):\(port)，请检查手机是否与 Mac 处于同一 Wi-Fi 子网并允许无线访问"])
        }

        return ip
    }

    /// Installs an APK silently
    public func installApk(serial: String, apkPath: String) async throws {
        let result = try await runner.run(args: ["-s", serial, "install", "-r", apkPath])
        guard result.exitCode == 0 && result.stdout.contains("Success") else {
            throw ADBError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Launches the scrcpy-server on device using app_process
    public func executeServer(
        serial: String,
        serverRemotePath: String = "/data/local/tmp/scrcpy-server.jar",
        version: String = "4.1",
        maxSize: UInt16 = 0,
        bitRate: UInt32 = 16_000_000,
        maxFps: UInt16 = 120,
        tunnelForward: Bool = false,
        control: Bool = true,
        audio: Bool = true,
        audioCodec: String = "raw",
        videoCodec: String = "h264",
        scid: UInt32? = nil,
        onLog: (@Sendable (String) -> Void)? = nil
    ) throws -> Process {
        var args = [
            "-s", serial, "shell",
            "CLASSPATH=\(serverRemotePath)",
            "app_process", "/",
            "com.genymobile.scrcpy.Server",
            version,
            "video_bit_rate=\(bitRate)",
            "video_codec=\(videoCodec)",
            "audio=\(audio)",
            "control=\(control)",
            "stay_awake=true",
            "log_level=debug"
        ]

        if audio {
            args.append("audio_codec=\(audioCodec)")
        }

        if let scid = scid {
            let hexScid = String(format: "%08x", scid)
            args.append("scid=\(hexScid)")
        }

        if maxSize > 0 {
            args.append("max_size=\(maxSize)")
        }
        if maxFps > 0 {
            args.append("max_fps=\(maxFps)")
        }
        if tunnelForward {
            args.append("tunnel_forward=true")
        }

        return try runner.spawn(args: args, onOutput: onLog)
    }
}

public enum ADBError: LocalizedError, Sendable {
    case commandFailed(String)
    case pushFailed(String)
    case reverseFailed(String)
    case forwardFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "ADB 命令执行失败: \(msg)"
        case .pushFailed(let msg): return "ADB 推送文件失败: \(msg)"
        case .reverseFailed(let msg): return "ADB 反向代理失败: \(msg)"
        case .forwardFailed(let msg): return "ADB 端口转发失败: \(msg)"
        }
    }
}
