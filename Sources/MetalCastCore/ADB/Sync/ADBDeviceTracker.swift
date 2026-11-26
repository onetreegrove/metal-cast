import Foundation

public enum ADBDeviceTrackingEvent: Sendable, Equatable {
    case snapshot(generation: UInt64, devices: [ADBDevice], usedFallbackTrack: Bool)
    case disconnected(generation: UInt64, reason: String)
}

/// Maintains a persistent `host:track-devices-l` stream (falling back to `host:track-devices` + `host:devices-l`)
/// and monotonically increments `serverGeneration` on initial connect, reconnect, or `start-server`.
public actor ADBDeviceTracker {
    public let endpoint: ADBServerEndpoint
    private let starter: ADBServerStarter
    private let handshakeTimeout: TimeInterval
    private let reconnectDelayNanoseconds: UInt64

    private var serverGeneration: UInt64 = 0
    private var latestDevices: [ADBDevice] = []
    private var hasConnectedSnapshot = false
    private var trackTask: Task<Void, Never>?
    private var activeConnection: ADBSocketConnection?
    private var continuations: [UUID: AsyncStream<ADBDeviceTrackingEvent>.Continuation] = [:]
    private var initialWaiters: [UUID: CheckedContinuation<(generation: UInt64, devices: [ADBDevice]), Error>] = [:]

    public init(
        endpoint: ADBServerEndpoint,
        starter: ADBServerStarter = .shared,
        handshakeTimeout: TimeInterval = ADBSocketConnection.defaultHandshakeTimeout,
        reconnectDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.endpoint = endpoint
        self.starter = starter
        self.handshakeTimeout = handshakeTimeout
        self.reconnectDelayNanoseconds = reconnectDelayNanoseconds
    }

    public var currentGeneration: UInt64 {
        serverGeneration
    }

    public var currentDevices: [ADBDevice] {
        latestDevices
    }

    /// Evaluates whether an existing bound file session remains valid against the current generation and device list.
    public func isSessionValid(_ sessionId: ADBFileSessionID) -> Bool {
        guard sessionId.endpoint == endpoint,
              sessionId.serverGeneration == serverGeneration else {
            return false
        }
        return latestDevices.contains { device in
            device.state == .device &&
            device.transportId == sessionId.transportId &&
            device.serial == sessionId.serial
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        var continuation: AsyncStream<ADBDeviceTrackingEvent>.Continuation?
    }

    public func events() -> AsyncStream<ADBDeviceTrackingEvent> {
        let box = ContinuationBox()
        let stream = AsyncStream<ADBDeviceTrackingEvent> { continuation in
            box.continuation = continuation
        }
        let id = UUID()
        if let continuation = box.continuation {
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(id: id)
                }
            }
        }
        return stream
    }

    public func start() {
        guard trackTask == nil else { return }
        trackTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        trackTask?.cancel()
        trackTask = nil
        activeConnection?.close()
        activeConnection = nil
        hasConnectedSnapshot = false
        failAllInitialWaiters(error: CancellationError())
    }

    /// Waits for the tracking loop's first device snapshot so `openSession` binds against the live
    /// tracker generation instead of racing `refreshOnce()` with `runLoop()`'s initial increment.
    public func waitForInitialSnapshot(
        timeout: TimeInterval = ADBSocketConnection.defaultHandshakeTimeout
    ) async throws -> (generation: UInt64, devices: [ADBDevice]) {
        if hasConnectedSnapshot {
            return (serverGeneration, latestDevices)
        }
        start()

        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if hasConnectedSnapshot {
                    continuation.resume(returning: (serverGeneration, latestDevices))
                    return
                }
                initialWaiters[waiterId] = continuation

                Task { [weak self] in
                    let ns = UInt64(max(0.05, timeout) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: ns)
                    await self?.failInitialWaiter(
                        id: waiterId,
                        error: ADBFileError.protocolError(stage: "track-devices", detail: "等待设备跟踪初始化超时")
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failInitialWaiter(id: waiterId, error: CancellationError())
            }
        }
    }

    private func resolveInitialWaiters(generation: UInt64, devices: [ADBDevice]) {
        hasConnectedSnapshot = true
        guard !initialWaiters.isEmpty else { return }
        let waiters = Array(initialWaiters.values)
        initialWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: (generation, devices))
        }
    }

    private func failInitialWaiter(id: UUID, error: Error) {
        if let waiter = initialWaiters.removeValue(forKey: id) {
            waiter.resume(throwing: error)
        }
    }

    private func failAllInitialWaiters(error: Error) {
        guard !initialWaiters.isEmpty else { return }
        let waiters = Array(initialWaiters.values)
        initialWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    /// Performs a one-shot `host:devices-l` refresh using an independent Host Socket.
    public func refreshOnce() async throws -> (generation: UInt64, devices: [ADBDevice]) {
        let (conn, didStart) = try await ADBSocketConnection.connectWithAutoStart(
            endpoint: endpoint,
            starter: starter,
            timeout: handshakeTimeout
        )
        defer { conn.close() }
        if didStart || (serverGeneration == 0 && trackTask == nil) {
            serverGeneration += 1
        }
        let devices = try await conn.listDevicesLong(timeout: handshakeTimeout)
        latestDevices = devices
        return (serverGeneration, devices)
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: ADBDeviceTrackingEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            var connectedGeneration: UInt64?
            do {
                let (conn, _) = try await ADBSocketConnection.connectWithAutoStart(
                    endpoint: endpoint,
                    starter: starter,
                    timeout: handshakeTimeout
                )
                activeConnection = conn

                // Every fresh track connection establishes a new generation.
                serverGeneration += 1
                let gen = serverGeneration
                connectedGeneration = gen

                let status = try await conn.sendHostRequest(
                    "host:track-devices-l",
                    timeout: handshakeTimeout,
                    stage: "track-devices-l"
                )

                switch status {
                case .okay:
                    try await readTrackLongLoop(connection: conn, generation: gen)
                case .fail:
                    conn.close()
                    activeConnection = nil
                    try await runFallbackTrackLoop(generation: gen)
                }
            } catch is CancellationError {
                activeConnection?.close()
                activeConnection = nil
                return
            } catch {
                activeConnection?.close()
                activeConnection = nil
                latestDevices = []
                let hadSnapshot = hasConnectedSnapshot
                hasConnectedSnapshot = false
                if !hadSnapshot {
                    failAllInitialWaiters(error: error)
                }
                if let gen = connectedGeneration {
                    broadcast(.disconnected(generation: gen, reason: error.localizedDescription))
                } else {
                    broadcast(.disconnected(generation: serverGeneration, reason: error.localizedDescription))
                }
            }

            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds)
        }
    }

    private func readTrackLongLoop(connection: ADBSocketConnection, generation: UInt64) async throws {
        while !Task.isCancelled {
            // Long-lived track-devices-l stream has no idle timeout (Plan §2.2).
            let payloadData = try await connection.readHostPayload(
                maxBytes: ADBSocketConnection.maxTrackPayloadBytes,
                timeout: nil,
                stage: "track-devices-l"
            )
            guard let text = String(data: payloadData, encoding: .utf8) else {
                throw ADBFileError.protocolError(stage: "track-devices-l", detail: "设备清单非有效 UTF-8")
            }
            let devices = ADBSocketConnection.parseDeviceListPayload(text)
            latestDevices = devices
            resolveInitialWaiters(generation: generation, devices: devices)
            broadcast(.snapshot(generation: generation, devices: devices, usedFallbackTrack: false))
        }
    }

    private func runFallbackTrackLoop(generation: UInt64) async throws {
        let conn = ADBSocketConnection(endpoint: endpoint)
        activeConnection = conn
        defer {
            conn.close()
            if activeConnection === conn {
                activeConnection = nil
            }
        }

        try await conn.connect(timeout: handshakeTimeout)
        try await conn.sendHostRequestExpectingOkay(
            "host:track-devices",
            timeout: handshakeTimeout,
            stage: "track-devices"
        )

        while !Task.isCancelled {
            _ = try await conn.readHostPayload(
                maxBytes: ADBSocketConnection.maxTrackPayloadBytes,
                timeout: nil,
                stage: "track-devices"
            )
            // Fetch detailed transport_id / model properties via independent host:devices-l socket.
            let detailConn = ADBSocketConnection(endpoint: endpoint)
            defer { detailConn.close() }
            try await detailConn.connect(timeout: handshakeTimeout)
            let devices = try await detailConn.listDevicesLong(timeout: handshakeTimeout)
            latestDevices = devices
            resolveInitialWaiters(generation: generation, devices: devices)
            broadcast(.snapshot(generation: generation, devices: devices, usedFallbackTrack: true))
        }
    }
}
