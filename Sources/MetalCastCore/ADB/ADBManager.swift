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
