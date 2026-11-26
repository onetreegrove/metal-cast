import Darwin
import Foundation
import Network

/// Coalesces concurrent `adb start-server` requests per endpoint when `ECONNREFUSED` occurs.
public actor ADBServerStarter {
    public static let shared = ADBServerStarter()

    public typealias StartServerHandler = @Sendable (ADBServerEndpoint) async throws -> Void

    private var inFlightTasks: [ADBServerEndpoint: Task<Void, Error>] = [:]
    private let startHandler: StartServerHandler

    public init(runner: ADBProcessRunner = .shared) {
        self.startHandler = { endpoint in
            let result = try await runner.run(
                args: ["start-server"],
                endpoint: endpoint,
                timeout: 10.0,
                maxOutputBytes: 256 * 1024
            )
            guard result.exitCode == 0 else {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                throw ADBFileError.adbServerStartFailed(
                    detail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    public init(startHandler: @escaping StartServerHandler) {
        self.startHandler = startHandler
    }

    /// Runs or awaits a single in-flight `start-server` operation for the given endpoint.
    public func ensureServerStarted(endpoint: ADBServerEndpoint) async throws {
        if let existing = inFlightTasks[endpoint] {
            return try await existing.value
        }

        let handler = self.startHandler
        let task = Task<Void, Error> {
            try await handler(endpoint)
        }
        inFlightTasks[endpoint] = task
        defer { inFlightTasks.removeValue(forKey: endpoint) }
        return try await task.value
    }
}

/// Low-level `NWConnection` wrapper implementing ADB Host protocol framing, exact cross-packet reads,
/// per-phase timeouts, idempotent cancellation, and single-retry `ECONNREFUSED` auto-start.
public final class ADBSocketConnection: @unchecked Sendable {
    public enum HostStatus: Sendable, Equatable {
        case okay
        case fail(String)
    }

    public static let defaultHandshakeTimeout: TimeInterval = 5.0
    public static let maxHostFailBytes = 64 * 1024
    public static let maxFeaturesBytes = 64 * 1024
    public static let maxTrackPayloadBytes = 1024 * 1024

    public let endpoint: ADBServerEndpoint
    private let queue = DispatchQueue(label: "com.metalcast.adb.socket")

    private var connection: NWConnection?
    private var readBuffer = Data()
    private var isEOF = false
    private var terminalError: Error?
    private var isReceiving = false
    private var isClosed = false
    private var closedByCancellation = false

    private var pendingConnect: PendingOperation<Void>?
    private var pendingRead: PendingReadOperation?
    private var pendingWrites: [PendingOperation<Void>] = []

    private final class PendingOperation<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var didFinish = false
        private var timer: DispatchSourceTimer?

        init(continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func installTimer(timeout: TimeInterval?, queue: DispatchQueue, onTimeout: @escaping @Sendable () -> Void) {
            guard let timeout, timeout > 0 else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler(handler: onTimeout)
            lock.lock()
            if didFinish {
                lock.unlock()
                timer.cancel()
                timer.resume()
                return
            }
            self.timer = timer
            lock.unlock()
            timer.resume()
        }

        @discardableResult
        func succeed(_ value: T) -> Bool {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return false
            }
            didFinish = true
            let cont = continuation
            continuation = nil
            timer?.cancel()
            timer = nil
            lock.unlock()
            cont?.resume(returning: value)
            return true
        }

        @discardableResult
        func fail(_ error: Error) -> Bool {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return false
            }
            didFinish = true
            let cont = continuation
            continuation = nil
            timer?.cancel()
            timer = nil
            lock.unlock()
            cont?.resume(throwing: error)
            return true
        }
    }

    private struct PendingReadOperation {
        let needed: Int
        let allowCleanEOF: Bool
        let stage: String
        let op: PendingOperation<Data?>
    }

    public init(endpoint: ADBServerEndpoint) {
        self.endpoint = endpoint
    }

    deinit {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    /// Connects to `endpoint`, automatically coalescing `adb start-server` and retrying once on `ECONNREFUSED`.
    public static func connectWithAutoStart(
        endpoint: ADBServerEndpoint,
        starter: ADBServerStarter = .shared,
        timeout: TimeInterval = defaultHandshakeTimeout
    ) async throws -> (connection: ADBSocketConnection, didStartServer: Bool) {
        let first = ADBSocketConnection(endpoint: endpoint)
        do {
            try await first.connect(timeout: timeout)
            return (first, false)
        } catch let error as POSIXError where error.code == .ECONNREFUSED {
            first.close()
            try await starter.ensureServerStarted(endpoint: endpoint)
            let second = ADBSocketConnection(endpoint: endpoint)
            do {
                try await second.connect(timeout: timeout)
                return (second, true)
            } catch {
                second.close()
                throw error
            }
        } catch {
            first.close()
            throw error
        }
    }

    public func connect(timeout: TimeInterval = defaultHandshakeTimeout) async throws {
        try Task.checkCancellation()

        guard let nwPort = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw ADBFileError.incompatibleEndpoint("无效端口号: \(endpoint.port)")
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: nwPort,
            using: .tcp
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let op = PendingOperation<Void>(continuation: continuation)

                queue.async { [weak self] in
                    guard let self else {
                        op.fail(CancellationError())
                        return
                    }
                    guard !self.isClosed else {
                        op.fail(CancellationError())
                        return
                    }

                    self.connection = conn
                    self.pendingConnect = op

                    op.installTimer(timeout: timeout, queue: self.queue) { [weak self] in
                        guard let self else { return }
                        if op.fail(ADBFileError.protocolError(stage: "connect", detail: "连接 ADB Server 超时")) {
                            self.pendingConnect = nil
                            self.closeLocked()
                        }
                    }

                    conn.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let pending = self.pendingConnect {
                                self.pendingConnect = nil
                                pending.succeed(())
                            }
                        case .waiting(let nwError):
                            if Self.isConnectionRefused(nwError) {
                                if let pending = self.pendingConnect {
                                    self.pendingConnect = nil
                                    pending.fail(POSIXError(.ECONNREFUSED))
                                }
                                self.closeLocked()
                            }
                        case .failed(let nwError):
                            let mapped: Error = Self.isConnectionRefused(nwError)
                                ? POSIXError(.ECONNREFUSED)
                                : ADBFileError.protocolError(stage: "connect", detail: nwError.localizedDescription)
                            self.terminalError = mapped
                            if let pending = self.pendingConnect {
                                self.pendingConnect = nil
                                pending.fail(mapped)
                            }
                            if let pendingR = self.pendingRead {
                                self.pendingRead = nil
                                pendingR.op.fail(mapped)
                            }
                            if !self.pendingWrites.isEmpty {
                                let writes = self.pendingWrites
                                self.pendingWrites.removeAll()
                                for w in writes {
                                    w.fail(mapped)
                                }
                            }
                            self.isClosed = true
                            self.connection?.stateUpdateHandler = nil
                            self.connection?.cancel()
                            self.connection = nil
                        case .cancelled:
                            if let pending = self.pendingConnect {
                                self.pendingConnect = nil
                                pending.fail(CancellationError())
                            }
                        default:
                            break
                        }
                    }

                    conn.start(queue: self.queue)
                }
            }
        } onCancel: {
            queue.async { [weak self] in
                guard let self else { return }
                if let pending = self.pendingConnect {
                    self.pendingConnect = nil
                    pending.fail(CancellationError())
                }
                self.closeLocked(cancelled: true)
            }
        }
    }

    public func close() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    private func closeLocked(cancelled: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        if cancelled {
            closedByCancellation = true
        }

        if let pending = pendingConnect {
            pendingConnect = nil
            pending.fail(CancellationError())
        }
        if let pendingR = pendingRead {
            pendingRead = nil
            pendingR.op.fail(CancellationError())
        }
        if !pendingWrites.isEmpty {
            let writes = pendingWrites
            pendingWrites.removeAll()
            for w in writes {
                w.fail(CancellationError())
            }
        }

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    public func writeAll(
        _ data: Data,
        timeout: TimeInterval? = defaultHandshakeTimeout,
        stage: String = "write"
    ) async throws {
        try Task.checkCancellation()
        if data.isEmpty { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let op = PendingOperation<Void>(continuation: continuation)

                queue.async { [weak self] in
                    guard let self else {
                        op.fail(CancellationError())
                        return
                    }
                    guard !self.isClosed, let conn = self.connection else {
                        let err: Error = self.closedByCancellation
                            ? CancellationError()
                            : ADBFileError.protocolError(stage: stage, detail: "Socket 已关闭")
                        op.fail(err)
                        return
                    }

                    self.pendingWrites.append(op)
                    op.installTimer(timeout: timeout, queue: self.queue) { [weak self] in
                        guard let self else { return }
                        if op.fail(ADBFileError.protocolError(stage: stage, detail: "写入超时")) {
                            self.closeLocked()
                        }
                    }

                    conn.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        self.pendingWrites.removeAll { $0 === op }
                        if let error {
                            let mapped = ADBFileError.protocolError(stage: stage, detail: error.localizedDescription)
                            op.fail(mapped)
                            self.closeLocked()
                        } else {
                            op.succeed(())
                        }
                    })
                }
            }
        } onCancel: {
            queue.async { [weak self] in
                guard let self else { return }
                let writes = self.pendingWrites
                self.pendingWrites.removeAll()
                for w in writes {
                    w.fail(CancellationError())
                }
                self.closeLocked(cancelled: true)
            }
        }
    }

    public func readExact(
        _ count: Int,
        timeout: TimeInterval? = defaultHandshakeTimeout,
        stage: String = "read"
    ) async throws -> Data {
        guard let data = try await readExactInternal(count, allowCleanEOF: false, timeout: timeout, stage: stage) else {
            throw ADBFileError.protocolError(stage: stage, detail: "连接提前断开")
        }
        return data
    }

    /// Reads `count` bytes or returns `nil` if the stream hits clean EOF with 0 buffered bytes remaining.
    /// Partial EOF (`0 < buffered < count`) still throws `ADBFileError.protocolError`.
    public func readExactOrEOF(
        _ count: Int,
        timeout: TimeInterval? = defaultHandshakeTimeout,
        stage: String = "read"
    ) async throws -> Data? {
        try await readExactInternal(count, allowCleanEOF: true, timeout: timeout, stage: stage)
    }

    private func readExactInternal(
        _ count: Int,
        allowCleanEOF: Bool,
        timeout: TimeInterval?,
        stage: String
    ) async throws -> Data? {
        try Task.checkCancellation()
        guard count >= 0 else {
            throw ADBFileError.protocolError(stage: stage, detail: "非法读取长度: \(count)")
        }
        if count == 0 { return Data() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let op = PendingOperation<Data?>(continuation: continuation)

                queue.async { [weak self] in
                    guard let self else {
                        op.fail(CancellationError())
                        return
                    }
                    if self.closedByCancellation {
                        op.fail(CancellationError())
                        return
                    }
                    if self.readBuffer.count >= count {
                        let out = Data(self.readBuffer.prefix(count))
                        self.readBuffer.removeFirst(count)
                        op.succeed(out)
                        return
                    }
                    if let terminalError = self.terminalError {
                        op.fail(terminalError)
                        return
                    }
                    if self.isEOF {
                        if allowCleanEOF && self.readBuffer.isEmpty {
                            op.succeed(nil)
                        } else {
                            op.fail(ADBFileError.protocolError(
                                stage: stage,
                                detail: "连接提前断开（期望 \(count) 字节，实际仅收到 \(self.readBuffer.count) 字节）"
                            ))
                        }
                        return
                    }
                    guard !self.isClosed, self.connection != nil else {
                        let err: Error = self.closedByCancellation
                            ? CancellationError()
                            : ADBFileError.protocolError(stage: stage, detail: "Socket 已关闭")
                        op.fail(err)
                        return
                    }
                    guard self.pendingRead == nil else {
                        op.fail(ADBFileError.protocolError(stage: stage, detail: "禁止并发读同一 ADB Socket"))
                        return
                    }

                    self.pendingRead = PendingReadOperation(
                        needed: count,
                        allowCleanEOF: allowCleanEOF,
                        stage: stage,
                        op: op
                    )
                    op.installTimer(timeout: timeout, queue: self.queue) { [weak self] in
                        guard let self else { return }
                        if op.fail(ADBFileError.protocolError(stage: stage, detail: "读取超时")) {
                            self.pendingRead = nil
                            self.closeLocked()
                        }
                    }

                    self.pumpReceiveLocked()
                }
            }
        } onCancel: {
            queue.async { [weak self] in
                guard let self else { return }
                if let pendingR = self.pendingRead {
                    self.pendingRead = nil
                    pendingR.op.fail(CancellationError())
                }
                self.closeLocked(cancelled: true)
            }
        }
    }

    private func pumpReceiveLocked() {
        guard !isClosed, !isReceiving, !isEOF, terminalError == nil, let conn = connection else {
            return
        }
        isReceiving = true
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.isReceiving = false

            if let content, !content.isEmpty {
                self.readBuffer.append(content)
            }
            if let error {
                self.terminalError = Self.isConnectionRefused(error)
                    ? POSIXError(.ECONNREFUSED)
                    : ADBFileError.protocolError(
                        stage: self.pendingRead?.stage ?? "read",
                        detail: error.localizedDescription
                    )
            }
            if isComplete {
                self.isEOF = true
            }

            self.resolvePendingReadLocked()
        }
    }

    private func resolvePendingReadLocked() {
        guard let pending = pendingRead else { return }

        if readBuffer.count >= pending.needed {
            let out = Data(readBuffer.prefix(pending.needed))
            readBuffer.removeFirst(pending.needed)
            pendingRead = nil
            pending.op.succeed(out)
            return
        }

        if let terminalError {
            pendingRead = nil
            pending.op.fail(terminalError)
            return
        }

        if isEOF {
            pendingRead = nil
            if pending.allowCleanEOF && readBuffer.isEmpty {
                pending.op.succeed(nil)
            } else {
                pending.op.fail(ADBFileError.protocolError(
                    stage: pending.stage,
                    detail: "连接意外关闭（期望 \(pending.needed) 字节，实际仅收到 \(readBuffer.count) 字节）"
                ))
            }
            return
        }

        pumpReceiveLocked()
    }

    // MARK: - ADB Host Protocol Helpers

    public func sendHostFrame(
        _ payload: String,
        timeout: TimeInterval = defaultHandshakeTimeout,
        stage: String
    ) async throws {
        guard let utf8 = payload.data(using: .utf8), utf8.count <= 0xFFFF else {
            throw ADBFileError.protocolError(stage: stage, detail: "Host 请求长度超出 4 位 hex 上限")
        }
        let header = String(format: "%04x", utf8.count).data(using: .ascii)!
        var frame = Data(capacity: 4 + utf8.count)
        frame.append(header)
        frame.append(utf8)
        try await writeAll(frame, timeout: timeout, stage: stage)
    }

    public func readHostStatus(
        timeout: TimeInterval = defaultHandshakeTimeout,
        stage: String
    ) async throws -> HostStatus {
        let statusBytes = try await readExact(4, timeout: timeout, stage: stage)
        guard let tag = String(data: statusBytes, encoding: .ascii) else {
            throw ADBFileError.protocolError(stage: stage, detail: "非法 Host 状态标签")
        }
        switch tag {
        case "OKAY":
            return .okay
        case "FAIL":
            let messageData = try await readHostPayload(
                maxBytes: Self.maxHostFailBytes,
                timeout: timeout,
                stage: stage
            )
            let message = String(data: messageData, encoding: .utf8) ?? "<non-utf8>"
            return .fail(message)
        default:
            throw ADBFileError.protocolError(stage: stage, detail: "未知 Host 状态标签: \(tag)")
        }
    }

    @discardableResult
    public func sendHostRequest(
        _ payload: String,
        timeout: TimeInterval = defaultHandshakeTimeout,
        stage: String
    ) async throws -> HostStatus {
        try await sendHostFrame(payload, timeout: timeout, stage: stage)
        return try await readHostStatus(timeout: timeout, stage: stage)
    }

    public func sendHostRequestExpectingOkay(
        _ payload: String,
        timeout: TimeInterval = defaultHandshakeTimeout,
        stage: String
    ) async throws {
        let status = try await sendHostRequest(payload, timeout: timeout, stage: stage)
        if case .fail(let message) = status {
            throw ADBFileError.protocolError(stage: stage, detail: message)
        }
    }

    public func readHostPayload(
        maxBytes: Int,
        timeout: TimeInterval? = defaultHandshakeTimeout,
        stage: String
    ) async throws -> Data {
        let lenBytes = try await readExact(4, timeout: timeout, stage: stage)
        guard let hexString = String(data: lenBytes, encoding: .ascii),
              hexString.count == 4,
              let length = Int(hexString, radix: 16),
              length >= 0 else {
            throw ADBFileError.protocolError(stage: stage, detail: "非法 4 位 hex 长度前缀")
        }
        guard length <= maxBytes else {
            throw ADBFileError.protocolError(
                stage: stage,
                detail: "Host 载荷长度 \(length) 字节超过上限 \(maxBytes) 字节"
            )
        }
        return try await readExact(length, timeout: timeout, stage: stage)
    }

    // MARK: - High-Level Host Services

    public func selectTransport(transportId: String, timeout: TimeInterval = defaultHandshakeTimeout) async throws {
        try await sendHostRequestExpectingOkay(
            "host:transport-id:\(transportId)",
            timeout: timeout,
            stage: "transport-id"
        )
    }

    /// Binds this socket to `transportId` and switches it into a device sub-service such as `sync:` or `shell,v2,raw:...`.
    public func openDeviceService(
        transportId: String,
        service: String,
        timeout: TimeInterval = defaultHandshakeTimeout,
        stage: String? = nil
    ) async throws {
        try await selectTransport(transportId: transportId, timeout: timeout)
        try await sendHostRequestExpectingOkay(
            service,
            timeout: timeout,
            stage: stage ?? service
        )
    }

    public func queryFeatures(
        transportId: String,
        timeout: TimeInterval = defaultHandshakeTimeout
    ) async throws -> Set<String> {
        let stage = "features"
        try await sendHostRequestExpectingOkay(
            "host-transport-id:\(transportId):features",
            timeout: timeout,
            stage: stage
        )
        let data = try await readHostPayload(maxBytes: Self.maxFeaturesBytes, timeout: timeout, stage: stage)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let parts = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    public func listDevicesLong(timeout: TimeInterval = defaultHandshakeTimeout) async throws -> [ADBDevice] {
        let stage = "devices-l"
        try await sendHostRequestExpectingOkay("host:devices-l", timeout: timeout, stage: stage)
        let data = try await readHostPayload(maxBytes: Self.maxTrackPayloadBytes, timeout: timeout, stage: stage)
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.parseDeviceListPayload(text)
    }

    public static func parseDeviceListPayload(_ text: String) -> [ADBDevice] {
        text.components(separatedBy: .newlines).compactMap { ADBDevice.parse(deviceLine: $0) }
    }

    private static func isConnectionRefused(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ECONNREFUSED
        }
        return false
    }
}
