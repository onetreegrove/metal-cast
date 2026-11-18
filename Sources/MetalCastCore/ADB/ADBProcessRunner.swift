import Foundation

public final class ADBProcessRunner: @unchecked Sendable {
    public static let shared = ADBProcessRunner()

    private let lock = NSLock()
    private var customAdbPath: String?

    public init(customAdbPath: String? = nil) {
        self.customAdbPath = customAdbPath
    }

    public func setCustomAdbPath(_ path: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.customAdbPath = path
    }

    /// Resolves the most appropriate ADB executable path
    public func resolveAdbPath() -> String {
        lock.lock()
        let custom = customAdbPath
        lock.unlock()

        if let custom = custom, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }

        // 1. Check local Resources directory relative to executable or current bundle
        let possibleLocalPaths = [
            Bundle.main.resourcePath.map { "\($0)/adb" },
            Bundle.module?.resourcePath.map { "\($0)/adb" },
            // Development path relative to workspace
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/adb").path
        ].compactMap { $0 }

        for path in possibleLocalPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Common macOS installation paths
        let systemCandidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        ]

        for path in systemCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 3. Fallback to PATH lookup
        return "adb"
    }

    private final class BufferBox: @unchecked Sendable {
        var data = Data()
        let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        func extract() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Executes an ADB command and returns (exitCode, stdout, stderr)
    @discardableResult
    public func run(args: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let adbPath = resolveAdbPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = BufferBox()
        let errBox = BufferBox()

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        // Asynchronous non-blocking streaming read
        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                outBox.append(chunk)
            }
        }

        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                errBox.append(chunk)
            }
        }

        try process.run()
        process.waitUntilExit()

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        // Flush remaining data
        let remainingOut = outHandle.readDataToEndOfFile()
        if !remainingOut.isEmpty { outBox.append(remainingOut) }

        let remainingErr = errHandle.readDataToEndOfFile()
        if !remainingErr.isEmpty { errBox.append(remainingErr) }

        let outStr = String(data: outBox.extract(), encoding: .utf8) ?? ""
        let errStr = String(data: errBox.extract(), encoding: .utf8) ?? ""

        return (process.terminationStatus, outStr, errStr)
    }

    /// Spawns a long-running ADB background process (e.g. scrcpy-server)
    public func spawn(args: [String], onOutput: (@Sendable (String) -> Void)? = nil) throws -> Process {
        let adbPath = resolveAdbPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        let handle = outPipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                onOutput?(str)
            }
        }

        try process.run()
        return process
    }
}

private extension Bundle {
    static var module: Bundle? {
        Bundle(for: ADBProcessRunnerBox.self)
    }
}

private class ADBProcessRunnerBox {}
