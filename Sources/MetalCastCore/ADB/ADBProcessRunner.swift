import Darwin
import Foundation

public final class ADBProcessRunner: @unchecked Sendable {
    public static let shared = ADBProcessRunner()

    private let lock = NSLock()
    private var customAdbPath: String?
    private let explicitEndpoint: ADBServerEndpoint?
    private let environmentProvider: @Sendable () -> [String: String]

    public init(
        customAdbPath: String? = nil,
        explicitEndpoint: ADBServerEndpoint? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.customAdbPath = customAdbPath
        self.explicitEndpoint = explicitEndpoint
        self.environmentProvider = environmentProvider
    }

    public func setCustomAdbPath(_ path: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.customAdbPath = path
    }

    /// Resolves the most appropriate ADB executable path (falls back to `"adb"` for display/legacy callers).
    public func resolveAdbPath() -> String {
        (try? resolveExecutableAdbURL(environment: environmentProvider()).path) ?? "adb"
    }

    /// Resolves an executable `adb` URL or throws `ADBFileError.adbServerStartFailed`.
    public func resolveExecutableAdbURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        lock.lock()
        let custom = customAdbPath
        lock.unlock()

        if let custom, FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }

        // 1. Check local Resources directory relative to executable or current bundle
        let possibleLocalPaths = [
            Bundle.main.resourcePath.map { "\($0)/adb" },
            Bundle.module?.resourcePath.map { "\($0)/adb" },
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/adb").path
        ].compactMap { $0 }

        for path in possibleLocalPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // 2. Common macOS installation paths
        let systemCandidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        ]

        for path in systemCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // 3. Search PATH entries explicitly so we never pass bare "adb" to URL(fileURLWithPath:)
        if let pathEnv = environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("adb").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        throw ADBFileError.adbServerStartFailed("未在应用内置资源、系统目录或 PATH 中找到可执行 adb")
    }

    /// Builds sanitized process arguments (`-L tcp:<host>:<port>` prepended) and cleaned environment.
    public func prepareProcessConfiguration(
        args: [String],
        endpoint: ADBServerEndpoint? = nil
    ) throws -> (executableURL: URL, arguments: [String], environment: [String: String]) {
        let env = environmentProvider()
        let resolvedEndpoint = try ADBServerEndpoint.resolve(explicit: endpoint ?? explicitEndpoint, environment: env)
        let executableURL = try resolveExecutableAdbURL(environment: env)
        let finalArgs = resolvedEndpoint.cliArguments(prependedTo: args)
        let cleanedEnv = ADBServerEndpoint.sanitizedEnvironment(from: env)
        return (executableURL, finalArgs, cleanedEnv)
    }

    private final class BufferBox: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        private let maxBytes: Int?

        init(maxBytes: Int? = nil) {
            self.maxBytes = maxBytes
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            if let maxBytes {
                let remaining = maxBytes - data.count
                guard remaining > 0 else { return }
                data.append(chunk.prefix(remaining))
            } else {
                data.append(chunk)
            }
        }

        func extract() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(exitCode: Int32, stdout: String, stderr: String), Error>?
        private var didFinish = false
        private var isCancelled = false
        private var pipesCleaned = false
        private var timeoutTimer: DispatchSourceTimer?

        func attach(
            continuation: CheckedContinuation<(exitCode: Int32, stdout: String, stderr: String), Error>
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isCancelled || didFinish {
                didFinish = true
                return false
            }
            self.continuation = continuation
            return true
        }

        func setTimer(_ timer: DispatchSourceTimer) {
            lock.lock()
            defer { lock.unlock() }
            if didFinish {
                timer.cancel()
            } else {
                self.timeoutTimer = timer
            }
        }

        func complete() -> CheckedContinuation<(exitCode: Int32, stdout: String, stderr: String), Error>? {
            lock.lock()
            defer { lock.unlock() }
            guard !didFinish else { return nil }
            didFinish = true
            timeoutTimer?.cancel()
            timeoutTimer = nil
            let cont = continuation
            continuation = nil
            return cont
        }

        func markCancelled() -> CheckedContinuation<(exitCode: Int32, stdout: String, stderr: String), Error>? {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            guard !didFinish else { return nil }
            didFinish = true
            timeoutTimer?.cancel()
            timeoutTimer = nil
            let cont = continuation
            continuation = nil
            return cont
        }

        func claimPipeCleanup() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !pipesCleaned else { return false }
            pipesCleaned = true
            return true
        }
    }

    /// Executes an ADB command asynchronously without blocking Swift concurrency threads.
    @discardableResult
    public func run(args: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await run(args: args, endpoint: nil, timeout: nil, maxOutputBytes: nil)
    }

    /// Executes an ADB command asynchronously with unified endpoint `-L`, env sanitization, timeout, and cancellation.
    @discardableResult
    public func run(
        args: [String],
        endpoint: ADBServerEndpoint? = nil,
        timeout: TimeInterval? = nil,
        maxOutputBytes: Int? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try Task.checkCancellation()

        let config = try prepareProcessConfiguration(args: args, endpoint: endpoint)
        let process = Process()
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        process.environment = config.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = BufferBox(maxBytes: maxOutputBytes)
        let errBox = BufferBox(maxBytes: maxOutputBytes)

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let state = RunState()

        @Sendable func detachHandlersOnce() {
            if state.claimPipeCleanup() {
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.attach(continuation: continuation) else {
                    detachHandlersOnce()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                outHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        outBox.append(chunk)
                    } else {
                        handle.readabilityHandler = nil
                    }
                }

                errHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        errBox.append(chunk)
                    } else {
                        handle.readabilityHandler = nil
                    }
                }

                process.terminationHandler = { terminatedProcess in
                    guard let cont = state.complete() else {
                        detachHandlersOnce()
                        return
                    }
                    detachHandlersOnce()
                    Self.drainNonBlocking(outHandle, into: outBox)
                    Self.drainNonBlocking(errHandle, into: errBox)

                    let outStr = String(data: outBox.extract(), encoding: .utf8) ?? ""
                    let errStr = String(data: errBox.extract(), encoding: .utf8) ?? ""
                    let value = (terminatedProcess.terminationStatus, outStr, errStr)
                    cont.resume(returning: value)
                }

                if let timeout, timeout > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler {
                        guard let cont = state.complete() else { return }
                        if process.isRunning {
                            process.terminate()
                        }
                        detachHandlersOnce()
                        let formatted = String(format: "%.2g", timeout)
                        cont.resume(throwing: ADBFileError.adbServerStartFailed("adb 命令执行超时（\(formatted) 秒）"))
                    }
                    state.setTimer(timer)
                    timer.resume()
                }

                do {
                    try process.run()
                } catch {
                    detachHandlersOnce()
                    if let cont = state.complete() {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if let cont = state.markCancelled() {
                if process.isRunning {
                    process.terminate()
                }
                detachHandlersOnce()
                cont.resume(throwing: CancellationError())
            } else if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Spawns a long-running ADB background process (e.g. scrcpy-server) with unified endpoint & sanitized environment.
    public func spawn(
        args: [String],
        endpoint: ADBServerEndpoint? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> Process {
        let config = try prepareProcessConfiguration(args: args, endpoint: endpoint)
        let process = Process()
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        process.environment = config.environment

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        let handle = outPipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8) {
                onOutput?(str)
            }
        }

        try process.run()
        return process
    }

    private static func drainNonBlocking(_ handle: FileHandle, into box: BufferBox) {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                box.append(Data(buffer[0..<bytesRead]))
            } else {
                break
            }
        }
    }
}

private extension Bundle {
    static var module: Bundle? {
        Bundle(for: ADBProcessRunnerBox.self)
    }
}

private class ADBProcessRunnerBox {}
