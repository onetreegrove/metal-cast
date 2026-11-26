import Foundation

/// Coordinates directory listing over `sync:` with `200`-entry / `50 ms` batched delivery,
/// automatic empty-directory Shell probing, and `(sessionId, requestId)` cancellation/filtering.
public final class ADBDirectoryBrowser: @unchecked Sendable {
    private let syncClient: ADBSyncClient
    private let shellClient: ADBShellClient
    private let lock = NSLock()
    private var activeRequestIds: [ADBFileSessionID: UUID] = [:]
    private var activeTasks: [ADBFileSessionID: Task<Void, Never>] = [:]

    public init(syncClient: ADBSyncClient = ADBSyncClient(), shellClient: ADBShellClient = ADBShellClient()) {
        self.syncClient = syncClient
        self.shellClient = shellClient
    }

    /// Registers `requestId` as the latest active directory request for `sessionId`, cancelling any prior in-flight task.
    public func activateRequest(sessionId: ADBFileSessionID, requestId: UUID) {
        lock.lock()
        activeRequestIds[sessionId] = requestId
        let previousTask = activeTasks.removeValue(forKey: sessionId)
        lock.unlock()
        previousTask?.cancel()
    }

    public func isRequestCurrent(sessionId: ADBFileSessionID, requestId: UUID) -> Bool {
        lock.lock()
        let current = activeRequestIds[sessionId] == requestId
        lock.unlock()
        return current
    }

    public func invalidateSession(_ sessionId: ADBFileSessionID) {
        lock.lock()
        activeRequestIds.removeValue(forKey: sessionId)
        let previousTask = activeTasks.removeValue(forKey: sessionId)
        lock.unlock()
        previousTask?.cancel()
    }

    private func registerTask(_ task: Task<Void, Never>, sessionId: ADBFileSessionID, requestId: UUID) {
        lock.lock()
        let matches = activeRequestIds[sessionId] == requestId
        if matches {
            activeTasks[sessionId] = task
        }
        lock.unlock()
        if !matches {
            task.cancel()
        }
    }

    private func clearTaskIfCurrent(sessionId: ADBFileSessionID, requestId: UUID) {
        lock.lock()
        if activeRequestIds[sessionId] == requestId {
            activeTasks.removeValue(forKey: sessionId)
        }
        lock.unlock()
    }

    /// Streams directory batches for `(sessionId, requestId)` while rejecting restricted paths
    /// and probing empty directories via Shell v2. Stale requests stop and drop late batches.
    public func listDirectory(
        sessionId: ADBFileSessionID,
        physicalRoot: String,
        relativeComponents: [Data],
        capabilities: ADBDeviceCapabilities,
        requestId: UUID = UUID(),
        batchEntryThreshold: Int = 200,
        batchInterval: TimeInterval = 0.05
    ) -> AsyncThrowingStream<ADBDirectoryBatch, Error> {
        activateRequest(sessionId: sessionId, requestId: requestId)
        let sync = self.syncClient
        let shell = self.shellClient

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    self.clearTaskIfCurrent(sessionId: sessionId, requestId: requestId)
                }
                do {
                    guard capabilities.hasShellV2 else {
                        throw ADBFileError.unsupportedDevice("缺少 shell_v2 能力")
                    }

                    let pathBytes = try ADBPathUtils.buildSyncPathBytes(
                        physicalRoot: physicalRoot,
                        components: relativeComponents
                    )

                    let conn = ADBSocketConnection(endpoint: sessionId.endpoint)
                    defer { conn.close() }
                    try await conn.connect()
                    try await conn.openDeviceService(
                        transportId: sessionId.transportId,
                        service: "sync:",
                        stage: "sync"
                    )

                    final class EntryCounter: @unchecked Sendable {
                        var total = 0
                    }
                    let counter = EntryCounter()

                    try await sync.listDirectory(
                        connection: conn,
                        pathBytes: pathBytes,
                        directoryComponents: relativeComponents,
                        useV2: capabilities.hasLsV2,
                        batchEntryThreshold: batchEntryThreshold,
                        batchInterval: batchInterval
                    ) { batch in
                        let stillCurrent = self.isRequestCurrent(sessionId: sessionId, requestId: requestId)
                        guard stillCurrent, !Task.isCancelled else { return }
                        counter.total += batch.count
                        continuation.yield(
                            ADBDirectoryBatch(
                                sessionId: sessionId,
                                requestId: requestId,
                                entries: batch,
                                isFinal: false
                            )
                        )
                    }

                    try? await sync.sendQuit(connection: conn)
                    conn.close()

                    guard self.isRequestCurrent(sessionId: sessionId, requestId: requestId) else {
                        continuation.finish()
                        return
                    }

                    if counter.total == 0 {
                        let probeConn = ADBSocketConnection(endpoint: sessionId.endpoint)
                        defer { probeConn.close() }
                        try await probeConn.connect()
                        let probe = try await shell.probeEmptyDirectory(
                            connection: probeConn,
                            transportId: sessionId.transportId,
                            physicalRoot: physicalRoot,
                            components: relativeComponents
                        )
                        switch probe {
                        case .accessibleEmpty:
                            break
                        case .permissionDenied:
                            throw ADBFileError.permissionDenied("无权限访问此目录")
                        case .pathChanged:
                            throw ADBFileError.pathChanged("父目录物理路径发生变化")
                        case .notFound:
                            throw ADBFileError.pathChanged("目录已不存在")
                        case .notDirectoryOrSymlink:
                            throw ADBFileError.restrictedPath("目标不是可浏览的普通目录（可能为符号链接或文件）")
                        }
                    }

                    guard self.isRequestCurrent(sessionId: sessionId, requestId: requestId) else {
                        continuation.finish()
                        return
                    }

                    continuation.yield(
                        ADBDirectoryBatch(
                            sessionId: sessionId,
                            requestId: requestId,
                            entries: [],
                            isFinal: true
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            self.registerTask(task, sessionId: sessionId, requestId: requestId)
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
