import Darwin
import Foundation

public protocol ADBFileServicing: Actor {
    func openSession(for device: ADBDevice) async throws -> ADBFileSessionSnapshot
    func listDirectory(sessionId: ADBFileSessionID, relativeComponents: [Data], requestId: UUID) -> AsyncThrowingStream<ADBDirectoryBatch, Error>
    func enqueueUpload(sessionId: ADBFileSessionID, targetComponents: [Data], items: [ADBUploadPlanItem]) async throws -> [UUID]
    func enqueueDownload(sessionId: ADBFileSessionID, sourceComponents: [Data], items: [ADBDownloadPlanItem], localDirectory: URL) async throws -> [UUID]
    func enqueueDelete(sessionId: ADBFileSessionID, directoryComponents: [Data], items: [ADBDeleteTarget]) async throws -> UUID
    func cancelTransfer(taskId: UUID) async
    func cancelWindowTasks(sessionId: ADBFileSessionID) async
    func retryLedgerCleanup(entryId: UUID) async throws
    func dismissLedgerEntry(entryId: UUID) async
    var events: AsyncStream<ADBFileTaskEvent> { get }
}

/// Core actor managing bound device sessions, per-device FIFO write queues,
/// global 2-slot transfer scheduling, throttled progress/rate events, and cleanup ledger recovery.
public actor ADBFileService: ADBFileServicing {
    public static let shared = ADBFileService()
    public static let maxGlobalTransferSlots = 2
    public static let progressThrottleInterval: TimeInterval = 0.1

    private struct BoundSession {
        let sessionId: ADBFileSessionID
        let deviceName: String
        let isWifi: Bool
        let physicalRoot: String
        var capabilities: ADBDeviceCapabilities
        var commitModeProbed: Bool = false
    }

    private enum TaskPayload {
        case upload(targetComponents: [Data], item: ADBUploadPlanItem)
        case download(sourceComponents: [Data], item: ADBDownloadPlanItem, localDirectory: URL)
        case delete(directoryComponents: [Data], items: [ADBDeleteTarget])
    }

    private struct ManagedTask {
        var snapshot: ADBFileTaskSnapshot
        let payload: TaskPayload
        var runningTask: Task<Void, Never>?
        var lastProgressEmitTime: Date = .distantPast
        var rateWindowStartTime: Date = Date()
        var rateWindowStartBytes: UInt64 = 0
        var smoothedBytesPerSec: Double = 0
    }

    private let endpointOverride: ADBServerEndpoint?
    private let starter: ADBServerStarter
    private let syncClient: ADBSyncClient
    private let shellClient: ADBShellClient
    private let browser: ADBDirectoryBrowser
    public let ledgerStore: ADBLedgerStore

    private var tracker: ADBDeviceTracker?
    private var trackerTask: Task<Void, Never>?
    private var sessions: [ADBFileSessionID: BoundSession] = [:]
    private var tasks: [UUID: ManagedTask] = [:]
    private var deviceQueues: [String: [UUID]] = [:] // deviceQueueKey -> FIFO queued/running taskIds
    private var activeDeviceHeadTasks: [String: UUID] = [:]
    private var activeGlobalTransferTasks: Set<UUID> = []

    private var eventContinuations: [UUID: AsyncStream<ADBFileTaskEvent>.Continuation] = [:]

    public init(
        endpoint: ADBServerEndpoint? = nil,
        ledgerURL: URL = ADBLedgerStore.defaultLedgerURL(),
        starter: ADBServerStarter = .shared
    ) {
        self.endpointOverride = endpoint
        self.starter = starter
        self.syncClient = ADBSyncClient()
        self.shellClient = ADBShellClient()
        self.browser = ADBDirectoryBrowser(syncClient: self.syncClient, shellClient: self.shellClient)
        self.ledgerStore = ADBLedgerStore(fileURL: ledgerURL)
    }

    private final class StreamBox: @unchecked Sendable {
        var continuation: AsyncStream<ADBFileTaskEvent>.Continuation?
    }

    public var events: AsyncStream<ADBFileTaskEvent> {
        let box = StreamBox()
        let stream = AsyncStream<ADBFileTaskEvent> { continuation in
            box.continuation = continuation
        }
        let id = UUID()
        if let continuation = box.continuation {
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
        return stream
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func emit(_ event: ADBFileTaskEvent) {
        for cont in eventContinuations.values {
            cont.yield(event)
        }
    }

    // MARK: - Device Tracking & Session Binding

    public func ensureTrackerStarted() async throws -> ADBDeviceTracker {
        let endpoint = try ADBServerEndpoint.resolve(explicit: endpointOverride)
        if let tracker, tracker.endpoint == endpoint {
            return tracker
        }

        trackerTask?.cancel()
        await tracker?.stop()

        let newTracker = ADBDeviceTracker(endpoint: endpoint, starter: starter)
        self.tracker = newTracker
        let stream = await newTracker.events()
        await newTracker.start()

        trackerTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handleTrackingEvent(event)
            }
        }
        return newTracker
    }

    private func handleTrackingEvent(_ event: ADBDeviceTrackingEvent) async {
        switch event {
        case .disconnected(let gen, let reason):
            let invalidated = sessions.keys.filter { $0.serverGeneration <= gen }
            for sid in invalidated {
                await invalidateSession(sid, reason: reason)
            }
        case .snapshot(let gen, let devices, _):
            for sid in Array(sessions.keys) {
                let stillAlive = sid.serverGeneration == gen && devices.contains { dev in
                    dev.state == .device && dev.transportId == sid.transportId && dev.serial == sid.serial
                }
                if !stillAlive {
                    await invalidateSession(sid, reason: "设备已断开或 transport_id 已变更")
                }
            }
        }
    }

    private func invalidateSession(_ sessionId: ADBFileSessionID, reason: String) async {
        guard sessions.removeValue(forKey: sessionId) != nil else { return }
        browser.invalidateSession(sessionId)

        for (taskId, managed) in tasks where managed.snapshot.sessionId == sessionId {
            if managed.snapshot.state == .queued {
                tasks[taskId]?.snapshot = updatingSnapshot(managed.snapshot, state: .failed, detail: "会话已失效: \(reason)")
                emit(.taskUpdated(tasks[taskId]!.snapshot))
            } else if managed.snapshot.state == .transferring {
                managed.runningTask?.cancel()
            }
        }

        emit(.sessionInvalidated(sessionId, reason: reason))
    }

    public func openSession(for device: ADBDevice) async throws -> ADBFileSessionSnapshot {
        guard device.state == .device else {
            throw ADBFileError.sessionInvalidated
        }
        guard let transportId = device.transportId, !transportId.isEmpty else {
            throw ADBFileError.unsupportedDevice("设备缺少 transport_id，请升级或重新初始化 ADB 连接")
        }

        let activeTracker = try await ensureTrackerStarted()
        let (_, devices) = try await activeTracker.refreshOnce()
        let generation = await activeTracker.currentGeneration

        guard devices.contains(where: { $0.state == .device && $0.transportId == transportId && $0.serial == device.serial }) else {
            throw ADBFileError.sessionInvalidated
        }

        let endpoint = activeTracker.endpoint
        let featConn = ADBSocketConnection(endpoint: endpoint)
        defer { featConn.close() }
        try await featConn.connect()
        let features = try await featConn.queryFeatures(transportId: transportId)

        guard features.contains("shell_v2") else {
            throw ADBFileError.unsupportedDevice("当前设备缺少 shell_v2 协议支持（需要 Android 7.0+）")
        }

        let rootConn = ADBSocketConnection(endpoint: endpoint)
        defer { rootConn.close() }
        try await rootConn.connect()
        let physicalRoot = try await shellClient.resolveSharedStorageRoot(
            connection: rootConn,
            transportId: transportId
        )

        // Probe Download folder availability; fall back to root if missing/unreadable.
        var initialComponents: [Data] = []
        let downloadProbeConn = ADBSocketConnection(endpoint: endpoint)
        defer { downloadProbeConn.close() }
        if (try? await downloadProbeConn.connect()) != nil {
            let downloadComps = [Data("Download".utf8)]
            if let probe = try? await shellClient.probeEmptyDirectory(
                connection: downloadProbeConn,
                transportId: transportId,
                physicalRoot: physicalRoot,
                components: downloadComps
            ), probe == .accessibleEmpty {
                initialComponents = downloadComps
            }
        }

        // Probe mv -nT / mv -n commit capability once per session so UI reflects upload readiness immediately.
        let probePath = (try? ADBPathUtils.buildRemotePath(physicalRoot: physicalRoot, components: initialComponents)) ?? physicalRoot
        let commitMode: ADBCommitMode
        let probed: Bool
        if let detected = try? await shellClient.probeCommitCapability(
            endpoint: endpoint,
            transportId: transportId,
            parentPhysicalPath: probePath
        ) {
            commitMode = detected
            probed = true
        } else {
            commitMode = .unsupported
            probed = false
        }

        let sessionId = ADBFileSessionID(
            endpoint: endpoint,
            serverGeneration: generation,
            transportId: transportId,
            serial: device.serial
        )
        let caps = ADBDeviceCapabilities(features: features, commitMode: commitMode)
        let bound = BoundSession(
            sessionId: sessionId,
            deviceName: device.model ?? device.serial,
            isWifi: device.isWifi,
            physicalRoot: physicalRoot,
            capabilities: caps,
            commitModeProbed: probed
        )
        sessions[sessionId] = bound

        return ADBFileSessionSnapshot(
            sessionId: sessionId,
            deviceName: bound.deviceName,
            isWifi: bound.isWifi,
            physicalRoot: physicalRoot,
            capabilities: caps,
            initialComponents: initialComponents
        )
    }

    /// Registers a pre-bound session directly (useful for integration tests against MockADBTCPServer).
    public func registerSessionForTesting(
        sessionId: ADBFileSessionID,
        deviceName: String = "Test Device",
        isWifi: Bool = false,
        physicalRoot: String,
        capabilities: ADBDeviceCapabilities
    ) {
        sessions[sessionId] = BoundSession(
            sessionId: sessionId,
            deviceName: deviceName,
            isWifi: isWifi,
            physicalRoot: physicalRoot,
            capabilities: capabilities
        )
    }

    // MARK: - Directory Browsing (Independent Channel)

    public func listDirectory(
        sessionId: ADBFileSessionID,
        relativeComponents: [Data],
        requestId: UUID = UUID()
    ) -> AsyncThrowingStream<ADBDirectoryBatch, Error> {
        guard let bound = sessions[sessionId] else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ADBFileError.sessionInvalidated)
            }
        }
        return browser.listDirectory(
            sessionId: sessionId,
            physicalRoot: bound.physicalRoot,
            relativeComponents: relativeComponents,
            capabilities: bound.capabilities,
            requestId: requestId
        )
    }

    // MARK: - Enqueue Upload / Download / Delete

    public func enqueueUpload(
        sessionId: ADBFileSessionID,
        targetComponents: [Data],
        items: [ADBUploadPlanItem]
    ) async throws -> [UUID] {
        guard let bound = sessions[sessionId] else {
            throw ADBFileError.sessionInvalidated
        }
        try ADBPathUtils.ensureNotRestricted(targetComponents)
        _ = try ADBPathUtils.buildRemotePath(physicalRoot: bound.physicalRoot, components: targetComponents)

        var taskIds: [UUID] = []
        for item in items {
            try ADBPathUtils.validateUploadFileName(item.targetFileName)
            let id = UUID()
            let snapshot = ADBFileTaskSnapshot(
                id: id,
                sessionId: sessionId,
                kind: .upload,
                displayName: item.targetFileName,
                totalBytes: item.fileSize,
                isSizeReliable: true,
                bytesTransferred: 0,
                bytesPerSecond: 0,
                state: .queued,
                detail: "等待设备写队列"
            )
            tasks[id] = ManagedTask(
                snapshot: snapshot,
                payload: .upload(targetComponents: targetComponents, item: item)
            )
            appendTaskToDeviceQueue(taskId: id, sessionId: sessionId)
            emit(.taskUpdated(snapshot))
            taskIds.append(id)
        }

        pumpDeviceQueue(for: deviceQueueKey(sessionId))
        return taskIds
    }

    public func enqueueDownload(
        sessionId: ADBFileSessionID,
        sourceComponents: [Data],
        items: [ADBDownloadPlanItem],
        localDirectory: URL
    ) async throws -> [UUID] {
        guard let bound = sessions[sessionId] else {
            throw ADBFileError.sessionInvalidated
        }
        try ADBPathUtils.ensureNotRestricted(sourceComponents)
        _ = try ADBPathUtils.buildRemotePath(physicalRoot: bound.physicalRoot, components: sourceComponents)

        var taskIds: [UUID] = []
        for item in items {
            let entry = item.remoteEntry
            guard entry.kind == .regular, !entry.isRestricted, entry.isLosslessUTF8 else {
                throw ADBFileError.invalidFileName("仅支持下载合法普通文件: \(entry.displayName)")
            }
            let comps = sourceComponents + [entry.rawNameBytes]
            _ = try ADBPathUtils.buildSyncPathBytes(physicalRoot: bound.physicalRoot, components: comps)

            let id = UUID()
            let snapshot = ADBFileTaskSnapshot(
                id: id,
                sessionId: sessionId,
                kind: .download,
                displayName: item.targetFileName,
                totalBytes: entry.isSizeReliable ? entry.size : nil,
                isSizeReliable: entry.isSizeReliable,
                bytesTransferred: 0,
                bytesPerSecond: 0,
                state: .queued,
                detail: "等待设备写队列"
            )
            tasks[id] = ManagedTask(
                snapshot: snapshot,
                payload: .download(sourceComponents: sourceComponents, item: item, localDirectory: localDirectory)
            )
            appendTaskToDeviceQueue(taskId: id, sessionId: sessionId)
            emit(.taskUpdated(snapshot))
            taskIds.append(id)
        }

        pumpDeviceQueue(for: deviceQueueKey(sessionId))
        return taskIds
    }

    public func enqueueDelete(
        sessionId: ADBFileSessionID,
        directoryComponents: [Data],
        items: [ADBDeleteTarget]
    ) async throws -> UUID {
        guard let bound = sessions[sessionId] else {
            throw ADBFileError.sessionInvalidated
        }
        try ADBPathUtils.ensureNotRestricted(directoryComponents)
        _ = try ADBPathUtils.buildRemotePath(physicalRoot: bound.physicalRoot, components: directoryComponents)

        for target in items {
            guard target.remoteEntry.kind == .regular,
                  !target.remoteEntry.isRestricted,
                  target.remoteEntry.isLosslessUTF8 else {
                throw ADBFileError.invalidFileName("仅支持删除当前目录的合法普通文件: \(target.remoteEntry.displayName)")
            }
        }

        let id = UUID()
        let label = items.count == 1 ? items[0].remoteEntry.displayName : "删除 \(items.count) 个文件"
        let snapshot = ADBFileTaskSnapshot(
            id: id,
            sessionId: sessionId,
            kind: .delete,
            displayName: label,
            totalBytes: nil,
            isSizeReliable: false,
            bytesTransferred: 0,
            bytesPerSecond: 0,
            state: .queued,
            detail: "等待设备写队列"
        )
        tasks[id] = ManagedTask(
            snapshot: snapshot,
            payload: .delete(directoryComponents: directoryComponents, items: items)
        )
        appendTaskToDeviceQueue(taskId: id, sessionId: sessionId)
        emit(.taskUpdated(snapshot))
        pumpDeviceQueue(for: deviceQueueKey(sessionId))
        return id
    }

    // MARK: - Task Control, Ledger & Termination

    public func cancelTransfer(taskId: UUID) async {
        guard let managed = tasks[taskId] else { return }
        switch managed.snapshot.state {
        case .queued:
            let qKey = deviceQueueKey(managed.snapshot.sessionId)
            deviceQueues[qKey]?.removeAll { $0 == taskId }
            tasks[taskId]?.snapshot = updatingSnapshot(managed.snapshot, state: .cancelled, detail: "已从排队取消")
            emit(.taskUpdated(tasks[taskId]!.snapshot))
            pumpDeviceQueue(for: qKey)
        case .transferring:
            managed.runningTask?.cancel()
        default:
            break
        }
    }

    public func cancelWindowTasks(sessionId: ADBFileSessionID) async {
        let matchingIds = tasks.values
            .filter { $0.snapshot.sessionId == sessionId }
            .map(\.snapshot.id)
        for taskId in matchingIds {
            await cancelTransfer(taskId: taskId)
        }
    }

    public func retryTask(taskId: UUID, sessionId: ADBFileSessionID) async throws -> UUID? {
        guard let managed = tasks[taskId],
              managed.snapshot.state == .failed || managed.snapshot.state == .cancelled else {
            return nil
        }

        switch managed.payload {
        case .upload(let targetComponents, let item):
            let ids = try await enqueueUpload(sessionId: sessionId, targetComponents: targetComponents, items: [item])
            return ids.first
        case .download(let sourceComponents, let item, let localDirectory):
            let ids = try await enqueueDownload(
                sessionId: sessionId,
                sourceComponents: sourceComponents,
                items: [item],
                localDirectory: localDirectory
            )
            return ids.first
        case .delete(let directoryComponents, let items):
            return try await enqueueDelete(sessionId: sessionId, directoryComponents: directoryComponents, items: items)
        }
    }

    public func clearFinishedTasks(sessionId: ADBFileSessionID? = nil) async {
        let terminalStates: Set<ADBFileTaskState> = [.completed, .skipped, .cancelled, .failed]
        let toRemove = tasks.values
            .filter { terminalStates.contains($0.snapshot.state) && (sessionId == nil || $0.snapshot.sessionId == sessionId) }
            .map(\.snapshot.id)
        for id in toRemove {
            tasks.removeValue(forKey: id)
        }
    }

    public func ledgerEntries() async -> [ADBLedgerEntry] {
        await ledgerStore.entries()
    }

    public func retryLedgerCleanup(entryId: UUID) async throws {
        guard let entry = await ledgerStore.entry(id: entryId) else { return }
        guard let activeSession = sessions.values.first(where: {
            $0.sessionId.endpoint == entry.endpoint && $0.sessionId.serial == entry.serial
        }) else {
            throw ADBFileError.sessionInvalidated
        }

        let conn = ADBSocketConnection(endpoint: activeSession.sessionId.endpoint)
        defer { conn.close() }
        try await conn.connect()
        try await shellClient.cleanupTempUploadDirectory(
            connection: conn,
            transportId: activeSession.sessionId.transportId,
            parentPhysicalPath: entry.targetParentPhysicalPath,
            tempDirName: entry.tempDirName,
            tempPayloadName: entry.tempPayloadName
        )
        try await ledgerStore.remove(id: entryId)
        emit(.ledgerUpdated(await ledgerStore.entries()))
    }

    public func dismissLedgerEntry(entryId: UUID) async {
        try? await ledgerStore.remove(id: entryId)
        emit(.ledgerUpdated(await ledgerStore.entries()))
    }

    public func verifyPendingTask(taskId: UUID) async throws -> ADBFileTaskSnapshot? {
        guard let managed = tasks[taskId],
              managed.snapshot.state == .pendingConfirmation,
              let ledgerId = managed.snapshot.ledgerEntryId,
              let entry = await ledgerStore.entry(id: ledgerId) else {
            return nil
        }
        guard let bound = sessions.values.first(where: {
            $0.sessionId.endpoint == entry.endpoint && $0.sessionId.serial == entry.serial
        }) else {
            throw ADBFileError.sessionInvalidated
        }

        let conn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
        defer { conn.close() }
        try await conn.connect()
        let check = try await shellClient.verifyPendingUpload(
            connection: conn,
            transportId: bound.sessionId.transportId,
            parentPhysicalPath: entry.targetParentPhysicalPath,
            tempDirName: entry.tempDirName,
            tempPayloadName: entry.tempPayloadName,
            finalTargetName: entry.finalTargetName
        )

        if check.committed {
            if check.tempDirCleaned {
                try? await ledgerStore.remove(id: ledgerId)
            } else {
                try? await ledgerStore.updateState(id: ledgerId, state: .cleanupPending)
            }
            let updated = updatingSnapshot(
                managed.snapshot,
                state: .completed,
                bytesTransferred: managed.snapshot.totalBytes ?? managed.snapshot.bytesTransferred,
                detail: check.tempDirCleaned ? "核对确认：文件已成功提交并清理暂存目录" : "核对确认：文件已提交，空暂存目录待清理"
            )
            tasks[taskId]?.snapshot = updated
            emit(.taskUpdated(updated))
            emit(.ledgerUpdated(await ledgerStore.entries()))
            return updated
        } else {
            try? await ledgerStore.updateState(id: ledgerId, state: .cleanupPending)
            let updated = updatingSnapshot(
                managed.snapshot,
                state: .failed,
                detail: "核对确认：目标尚未提交，可重试清理暂存目录后重新上传"
            )
            tasks[taskId]?.snapshot = updated
            emit(.taskUpdated(updated))
            emit(.ledgerUpdated(await ledgerStore.entries()))
            return updated
        }
    }

    public func hasActiveWork() -> Bool {
        tasks.values.contains {
            [.queued, .transferring, .committing].contains($0.snapshot.state)
        }
    }

    public func taskSnapshot(id: UUID) -> ADBFileTaskSnapshot? {
        tasks[id]?.snapshot
    }

    public func activeTransferSlotCount() -> Int {
        activeGlobalTransferTasks.count
    }

    public func prepareForAppTermination(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)

        for (taskId, managed) in tasks {
            switch managed.snapshot.state {
            case .queued, .transferring:
                await cancelTransfer(taskId: taskId)
            default:
                break
            }
        }

        // Wait up to budget for in-flight committing/cleanup tasks to settle.
        while Date() < deadline && tasks.values.contains(where: { $0.snapshot.state == .committing || $0.snapshot.state == .transferring }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        try? await ledgerStore.markUnfinishedForTermination()
    }

    // MARK: - Per-Device FIFO + Global 2-Slot Scheduler

    private func deviceQueueKey(_ sessionId: ADBFileSessionID) -> String {
        "\(sessionId.endpoint.host):\(sessionId.endpoint.port)::\(sessionId.transportId)"
    }

    private func appendTaskToDeviceQueue(taskId: UUID, sessionId: ADBFileSessionID) {
        let key = deviceQueueKey(sessionId)
        deviceQueues[key, default: []].append(taskId)
    }

    private func pumpDeviceQueue(for qKey: String) {
        guard activeDeviceHeadTasks[qKey] == nil else { return }
        guard let queue = deviceQueues[qKey], let headTaskId = queue.first else { return }
        guard let managed = tasks[headTaskId], managed.snapshot.state == .queued else {
            deviceQueues[qKey]?.removeFirst()
            pumpDeviceQueue(for: qKey)
            return
        }

        // Deadlock-free lock ordering: only the head of each device's FIFO queue checks global 2-slot capacity.
        let needsTransferSlot = managed.snapshot.kind != .delete
        if needsTransferSlot && activeGlobalTransferTasks.count >= Self.maxGlobalTransferSlots {
            return
        }

        guard let bound = sessions[managed.snapshot.sessionId] else {
            deviceQueues[qKey]?.removeFirst()
            tasks[headTaskId]?.snapshot = updatingSnapshot(managed.snapshot, state: .failed, detail: "设备会话已失效")
            emit(.taskUpdated(tasks[headTaskId]!.snapshot))
            pumpDeviceQueue(for: qKey)
            return
        }

        activeDeviceHeadTasks[qKey] = headTaskId
        if needsTransferSlot {
            activeGlobalTransferTasks.insert(headTaskId)
            emit(.activeTransferSlotCountChanged(activeGlobalTransferTasks.count))
        }

        let runner = Task { [weak self] in
            guard let self else { return }
            await self.executeTask(taskId: headTaskId, bound: bound, queueKey: qKey)
        }
        tasks[headTaskId]?.runningTask = runner
    }

    private func finishHeadTask(taskId: UUID, queueKey: String) {
        if activeGlobalTransferTasks.remove(taskId) != nil {
            emit(.activeTransferSlotCountChanged(activeGlobalTransferTasks.count))
        }
        if activeDeviceHeadTasks[queueKey] == taskId {
            activeDeviceHeadTasks.removeValue(forKey: queueKey)
        }
        if var q = deviceQueues[queueKey], q.first == taskId {
            q.removeFirst()
            deviceQueues[queueKey] = q
        }
        tasks[taskId]?.runningTask = nil

        // Pump this device's next head task and any other waiting device head tasks.
        pumpDeviceQueue(for: queueKey)
        for otherKey in Array(deviceQueues.keys) where otherKey != queueKey {
            pumpDeviceQueue(for: otherKey)
        }
    }

    // MARK: - Task Execution

    private func executeTask(taskId: UUID, bound: BoundSession, queueKey: String) async {
        defer {
            finishHeadTask(taskId: taskId, queueKey: queueKey)
        }

        guard let managed = tasks[taskId] else { return }

        switch managed.payload {
        case .upload(let targetComponents, let item):
            await executeUpload(taskId: taskId, bound: bound, targetComponents: targetComponents, item: item)
        case .download(let sourceComponents, let item, let localDirectory):
            await executeDownload(taskId: taskId, bound: bound, sourceComponents: sourceComponents, item: item, localDirectory: localDirectory)
        case .delete(let directoryComponents, let items):
            await executeDelete(taskId: taskId, bound: bound, directoryComponents: directoryComponents, items: items)
        }
    }

    private func ensureCommitModeProbed(bound: BoundSession, parentPhysicalPath: String) async throws -> ADBCommitMode {
        if let current = sessions[bound.sessionId], current.commitModeProbed {
            return current.capabilities.commitMode
        }
        let mode = try await shellClient.probeCommitCapability(
            endpoint: bound.sessionId.endpoint,
            transportId: bound.sessionId.transportId,
            parentPhysicalPath: parentPhysicalPath
        )
        if var session = sessions[bound.sessionId] {
            session.capabilities = ADBDeviceCapabilities(
                hasShellV2: session.capabilities.hasShellV2,
                hasStatV2: session.capabilities.hasStatV2,
                hasLsV2: session.capabilities.hasLsV2,
                commitMode: mode
            )
            session.commitModeProbed = true
            sessions[bound.sessionId] = session
        }
        return mode
    }

    private func executeUpload(
        taskId: UUID,
        bound: BoundSession,
        targetComponents: [Data],
        item: ADBUploadPlanItem
    ) async {
        let parentPhysicalPath: String
        do {
            parentPhysicalPath = try ADBPathUtils.buildRemotePath(
                physicalRoot: bound.physicalRoot,
                components: targetComponents
            )
        } catch {
            updateTaskTerminal(taskId: taskId, state: .failed, detail: error.localizedDescription)
            return
        }

        var ledgerEntry: ADBLedgerEntry?
        var createdRemoteTempDir = false

        do {
            let commitMode = try await ensureCommitModeProbed(bound: bound, parentPhysicalPath: parentPhysicalPath)
            guard commitMode != .unsupported else {
                throw ADBFileError.unsupportedDevice("当前设备缺少 mv -n，禁止安全上传")
            }

            let tempDirName = ".metalcast-tmp-\(UUID().uuidString.lowercased())"
            let tempPayloadName = "payload"
            let tempFilePath = "\(parentPhysicalPath)/\(tempDirName)/\(tempPayloadName)"
            let sendSpecLen = Data("\(tempFilePath),33188".utf8).count
            guard sendSpecLen <= ADBPathUtils.syncMaxPathBytes else {
                throw ADBFileError.pathTooLong(sendSpecLen)
            }

            let entry = ADBLedgerEntry(
                taskId: taskId,
                endpoint: bound.sessionId.endpoint,
                serial: bound.sessionId.serial,
                transportId: bound.sessionId.transportId,
                serverGeneration: bound.sessionId.serverGeneration,
                targetParentPhysicalPath: parentPhysicalPath,
                tempDirName: tempDirName,
                tempPayloadName: tempPayloadName,
                finalTargetName: item.targetFileName,
                state: .planned
            )
            ledgerEntry = entry
            try await ledgerStore.upsert(entry)
            if let currentSnap = tasks[taskId]?.snapshot {
                tasks[taskId]?.snapshot = updatingSnapshot(currentSnap, ledgerEntryId: entry.id)
            }
            emit(.ledgerUpdated(await ledgerStore.entries()))

            // Create hidden staging directory exclusively
            let mkdirConn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
            defer { mkdirConn.close() }
            try await mkdirConn.connect()
            try await shellClient.createTempUploadDirectory(
                connection: mkdirConn,
                transportId: bound.sessionId.transportId,
                parentPhysicalPath: parentPhysicalPath,
                tempDirName: tempDirName
            )
            createdRemoteTempDir = true

            try await ledgerStore.updateState(id: entry.id, state: .created)
            emit(.ledgerUpdated(await ledgerStore.entries()))

            // Start streaming SEND
            updateTaskProgressState(taskId: taskId, state: .transferring, detail: "正在传输至暂存目录…")

            let syncConn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
            defer { syncConn.close() }
            try await syncConn.connect()
            try await syncConn.openDeviceService(
                transportId: bound.sessionId.transportId,
                service: "sync:",
                stage: "sync"
            )

            try await syncClient.sendFile(
                connection: syncConn,
                localFileURL: item.localURL,
                remoteTempPath: tempFilePath,
                mtime: item.mtime
            ) { bytesSent in
                Task { [weak self] in
                    await self?.recordProgress(taskId: taskId, bytesTransferred: bytesSent)
                }
            }
            try? await syncClient.sendQuit(connection: syncConn)
            syncConn.close()

            // Commit phase
            try await ledgerStore.updateState(id: entry.id, state: .committing)
            updateTaskProgressState(taskId: taskId, state: .committing, detail: "正在提交…")

            var candidateName = item.targetFileName
            var commitOutcome: ADBUploadCommitOutcome?

            while true {
                let commitConn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
                defer { commitConn.close() }
                try await commitConn.connect()

                do {
                    let outcome = try await shellClient.commitUploadedFile(
                        connection: commitConn,
                        transportId: bound.sessionId.transportId,
                        parentPhysicalPath: parentPhysicalPath,
                        tempDirName: tempDirName,
                        tempPayloadName: tempPayloadName,
                        destinationName: candidateName,
                        commitMode: commitMode
                    )
                    commitConn.close()
                    if outcome == .targetConflict {
                        if item.conflictResolution == .skip {
                            commitOutcome = .targetConflict
                            break
                        } else {
                            // Re-scan current directory names and pick next Name (k).ext
                            let existing = try await listRemoteEntryNames(
                                bound: bound,
                                components: targetComponents
                            )
                            var occupied = Set(existing.map(ADBTransferPlanner.normalizeAndroidName))
                            occupied.insert(ADBTransferPlanner.normalizeAndroidName(candidateName))
                            candidateName = try ADBTransferPlanner.nextAvailableRenameCandidate(
                                originalName: item.targetFileName,
                                occupiedNormalizedNames: occupied,
                                normalize: ADBTransferPlanner.normalizeAndroidName,
                                validateCandidate: { try ADBPathUtils.validateUploadFileName($0) }
                            )
                            continue
                        }
                    } else {
                        commitOutcome = outcome
                        break
                    }
                } catch let err as ADBFileError {
                    if case .operationUnconfirmed = err {
                        try? await ledgerStore.updateState(id: entry.id, state: .pendingConfirmation)
                        updateTaskTerminal(
                            taskId: taskId,
                            state: .pendingConfirmation,
                            detail: "提交命令已发出但未收到退出回执，请重连后核对结果"
                        )
                        emit(.ledgerUpdated(await ledgerStore.entries()))
                        return
                    }
                    throw err
                }
            }

            switch commitOutcome {
            case .committedAndCleaned:
                try? await ledgerStore.remove(id: entry.id)
                updateTaskTerminal(
                    taskId: taskId,
                    state: .completed,
                    displayName: candidateName,
                    bytesTransferred: item.fileSize,
                    detail: "已完成上传并清理临时目录"
                )
                emit(.ledgerUpdated(await ledgerStore.entries()))
            case .committedPendingDirCleanup:
                try? await ledgerStore.updateState(id: entry.id, state: .cleanupPending)
                updateTaskTerminal(
                    taskId: taskId,
                    state: .completed,
                    displayName: candidateName,
                    bytesTransferred: item.fileSize,
                    detail: "文件已提交（空暂存目录待清理）"
                )
                emit(.ledgerUpdated(await ledgerStore.entries()))
            case .targetConflict:
                await cleanupTempDirOrMarkPending(
                    bound: bound,
                    entry: entry,
                    parentPhysicalPath: parentPhysicalPath,
                    tempDirName: tempDirName,
                    tempPayloadName: tempPayloadName
                )
                updateTaskTerminal(taskId: taskId, state: .skipped, detail: "目标已存在，按策略跳过")
            case .none:
                break
            }
        } catch is CancellationError {
            if createdRemoteTempDir, let entry = ledgerEntry {
                await cleanupTempDirOrMarkPending(
                    bound: bound,
                    entry: entry,
                    parentPhysicalPath: parentPhysicalPath,
                    tempDirName: entry.tempDirName,
                    tempPayloadName: entry.tempPayloadName
                )
            } else if let entry = ledgerEntry {
                try? await ledgerStore.remove(id: entry.id)
                emit(.ledgerUpdated(await ledgerStore.entries()))
            }
            updateTaskTerminal(taskId: taskId, state: .cancelled, detail: "已取消上传并清理暂存")
        } catch {
            if createdRemoteTempDir, let entry = ledgerEntry {
                await cleanupTempDirOrMarkPending(
                    bound: bound,
                    entry: entry,
                    parentPhysicalPath: parentPhysicalPath,
                    tempDirName: entry.tempDirName,
                    tempPayloadName: entry.tempPayloadName
                )
            } else if let entry = ledgerEntry {
                try? await ledgerStore.remove(id: entry.id)
                emit(.ledgerUpdated(await ledgerStore.entries()))
            }
            updateTaskTerminal(taskId: taskId, state: .failed, detail: error.localizedDescription)
        }
    }

    private func cleanupTempDirOrMarkPending(
        bound: BoundSession,
        entry: ADBLedgerEntry,
        parentPhysicalPath: String,
        tempDirName: String,
        tempPayloadName: String
    ) async {
        do {
            let conn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
            defer { conn.close() }
            try await conn.connect(timeout: 3.0)
            try await shellClient.cleanupTempUploadDirectory(
                connection: conn,
                transportId: bound.sessionId.transportId,
                parentPhysicalPath: parentPhysicalPath,
                tempDirName: tempDirName,
                tempPayloadName: tempPayloadName,
                timeout: 4.0
            )
            try? await ledgerStore.remove(id: entry.id)
        } catch {
            try? await ledgerStore.updateState(id: entry.id, state: .cleanupPending)
        }
        emit(.ledgerUpdated(await ledgerStore.entries()))
    }

    private func executeDownload(
        taskId: UUID,
        bound: BoundSession,
        sourceComponents: [Data],
        item: ADBDownloadPlanItem,
        localDirectory: URL
    ) async {
        var partURL: URL?
        var fd: Int32 = -1

        func cleanupPart() {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            if let partURL {
                try? FileManager.default.removeItem(at: partURL)
            }
        }

        do {
            let remoteComponents = sourceComponents + [item.remoteEntry.rawNameBytes]
            let remotePathBytes = try ADBPathUtils.buildSyncPathBytes(
                physicalRoot: bound.physicalRoot,
                components: remoteComponents
            )

            // Pre-transfer identity check
            let statConnBefore = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
            defer { statConnBefore.close() }
            try await statConnBefore.connect()
            try await statConnBefore.openDeviceService(transportId: bound.sessionId.transportId, service: "sync:", stage: "sync")
            _ = try await ADBTransferPlanner.verifyRemoteEntryIdentity(
                connection: statConnBefore,
                syncClient: syncClient,
                remotePathBytes: remotePathBytes,
                expected: item.remoteEntry,
                useV2: bound.capabilities.hasStatV2
            )
            try? await syncClient.sendQuit(connection: statConnBefore)
            statConnBefore.close()

            let (createdPartURL, openedFD) = try ADBMacFilePublisher.createExclusivePartFile(in: localDirectory)
            partURL = createdPartURL
            fd = openedFD

            updateTaskProgressState(taskId: taskId, state: .transferring, detail: "正在下载到临时文件…")

            let recvConn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
            defer { recvConn.close() }
            try await recvConn.connect()
            try await recvConn.openDeviceService(transportId: bound.sessionId.transportId, service: "sync:", stage: "sync")

            let bytesWritten = try await syncClient.receiveFile(
                connection: recvConn,
                remotePathBytes: remotePathBytes,
                destinationFD: fd
            ) { bytesReceived in
                Task { [weak self] in
                    await self?.recordProgress(taskId: taskId, bytesTransferred: bytesReceived)
                }
            }
            try? await syncClient.sendQuit(connection: recvConn)
            recvConn.close()

            updateTaskProgressState(taskId: taskId, state: .committing, detail: "正在校验并发布文件…")

            // Only verify byte count when size is reliable (stat_v2 / ls_v2) — never for v1!
            if item.remoteEntry.isSizeReliable, let expectedSize = item.remoteEntry.size {
                guard bytesWritten == expectedSize else {
                    throw ADBFileError.targetChanged("下载字节数不一致（预期 \(expectedSize)，实收 \(bytesWritten)），请重新下载")
                }
            }

            // Post-DONE source identity recheck
            let statConnAfter = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
            defer { statConnAfter.close() }
            try await statConnAfter.connect()
            try await statConnAfter.openDeviceService(transportId: bound.sessionId.transportId, service: "sync:", stage: "sync")
            let verifiedStat = try await ADBTransferPlanner.verifyRemoteEntryIdentity(
                connection: statConnAfter,
                syncClient: syncClient,
                remotePathBytes: remotePathBytes,
                expected: item.remoteEntry,
                useV2: bound.capabilities.hasStatV2
            )
            try? await syncClient.sendQuit(connection: statConnAfter)
            statConnAfter.close()

            // Restore mtime via futimens before closing fd
            ADBMacFilePublisher.applyModificationTime(fd: fd, mtime: verifiedStat.mtime ?? item.remoteEntry.mtime)
            Darwin.close(fd)
            fd = -1

            if let finalURL = try ADBMacFilePublisher.publishExclusive(
                partURL: createdPartURL,
                targetDirectory: localDirectory,
                preferredName: item.targetFileName,
                conflictResolution: item.conflictResolution
            ) {
                updateTaskTerminal(
                    taskId: taskId,
                    state: .completed,
                    displayName: finalURL.lastPathComponent,
                    bytesTransferred: bytesWritten,
                    detail: "已保存到 \(finalURL.lastPathComponent)",
                    localOutputURL: finalURL
                )
            } else {
                updateTaskTerminal(taskId: taskId, state: .skipped, detail: "目标文件已存在，按策略跳过")
            }
        } catch is CancellationError {
            cleanupPart()
            updateTaskTerminal(taskId: taskId, state: .cancelled, detail: "已取消下载并清理临时文件")
        } catch {
            cleanupPart()
            updateTaskTerminal(taskId: taskId, state: .failed, detail: error.localizedDescription)
        }
    }

    private func executeDelete(
        taskId: UUID,
        bound: BoundSession,
        directoryComponents: [Data],
        items: [ADBDeleteTarget]
    ) async {
        do {
            let parentPhysicalPath = try ADBPathUtils.buildRemotePath(
                physicalRoot: bound.physicalRoot,
                components: directoryComponents
            )
            updateTaskProgressState(taskId: taskId, state: .committing, detail: "正在逐项删除 (\(items.count))…")

            var results: [ADBDeleteItemResult] = []
            var abortedDisconnect = false

            for (idx, target) in items.enumerated() {
                if abortedDisconnect || Task.isCancelled {
                    results.append(
                        ADBDeleteItemResult(
                            fileName: target.remoteEntry.displayName,
                            rawNameBytes: target.remoteEntry.rawNameBytes,
                            status: .notExecuted,
                            message: "未执行"
                        )
                    )
                    continue
                }

                let entry = target.remoteEntry
                let itemComponents = directoryComponents + [entry.rawNameBytes]
                do {
                    let syncPathBytes = try ADBPathUtils.buildSyncPathBytes(
                        physicalRoot: bound.physicalRoot,
                        components: itemComponents
                    )
                    let statConn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
                    defer { statConn.close() }
                    try await statConn.connect()
                    try await statConn.openDeviceService(transportId: bound.sessionId.transportId, service: "sync:", stage: "sync")
                    _ = try await ADBTransferPlanner.verifyRemoteEntryIdentity(
                        connection: statConn,
                        syncClient: syncClient,
                        remotePathBytes: syncPathBytes,
                        expected: entry,
                        useV2: bound.capabilities.hasStatV2
                    )
                    try? await syncClient.sendQuit(connection: statConn)
                    statConn.close()
                } catch ADBFileError.targetChanged(let msg) {
                    results.append(
                        ADBDeleteItemResult(
                            fileName: entry.displayName,
                            rawNameBytes: entry.rawNameBytes,
                            status: .targetChanged,
                            message: msg
                        )
                    )
                    continue
                } catch {
                    abortedDisconnect = true
                    results.append(
                        ADBDeleteItemResult(
                            fileName: entry.displayName,
                            rawNameBytes: entry.rawNameBytes,
                            status: .notExecuted,
                            message: "未执行（连接异常: \(error.localizedDescription)）"
                        )
                    )
                    continue
                }

                // Identity matched — execute single-file non-recursive rm --
                do {
                    let delConn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
                    defer { delConn.close() }
                    try await delConn.connect()
                    let status = try await shellClient.deleteSingleFile(
                        connection: delConn,
                        transportId: bound.sessionId.transportId,
                        parentPhysicalPath: parentPhysicalPath,
                        targetName: entry.displayName
                    )
                    results.append(
                        ADBDeleteItemResult(
                            fileName: entry.displayName,
                            rawNameBytes: entry.rawNameBytes,
                            status: status,
                            message: deleteStatusMessage(status)
                        )
                    )
                } catch ADBFileError.operationUnconfirmed {
                    abortedDisconnect = true
                    results.append(
                        ADBDeleteItemResult(
                            fileName: entry.displayName,
                            rawNameBytes: entry.rawNameBytes,
                            status: .pendingConfirmation,
                            message: "待确认（删除指令已发出但连接中断，请重连刷新核对）"
                        )
                    )
                } catch {
                    abortedDisconnect = true
                    let isPending = idx < items.count
                    results.append(
                        ADBDeleteItemResult(
                            fileName: entry.displayName,
                            rawNameBytes: entry.rawNameBytes,
                            status: isPending ? .pendingConfirmation : .notExecuted,
                            message: "连接中断: \(error.localizedDescription)"
                        )
                    )
                }
            }

            let deletedCount = results.filter { $0.status == .deleted }.count
            let summary = "删除完成：\(deletedCount)/\(items.count) 项已删除"
            let finalState: ADBFileTaskState = results.contains { $0.status == .pendingConfirmation }
                ? .pendingConfirmation
                : .completed
            updateTaskTerminal(
                taskId: taskId,
                state: finalState,
                detail: summary,
                deleteResults: results
            )
        } catch {
            updateTaskTerminal(taskId: taskId, state: .failed, detail: error.localizedDescription)
        }
    }

    private func deleteStatusMessage(_ status: ADBDeleteItemStatus) -> String {
        switch status {
        case .deleted: return "已删除"
        case .notFound: return "已不存在"
        case .notRegularFile: return "非普通文件（链接或目录），已拒绝"
        case .pathChanged: return "目录已变化"
        case .permissionDenied: return "权限不足或删除失败"
        case .targetChanged: return "目标已变化"
        case .pendingConfirmation: return "待确认"
        case .notExecuted: return "未执行"
        }
    }

    private func listRemoteEntryNames(bound: BoundSession, components: [Data]) async throws -> [String] {
        let pathBytes = try ADBPathUtils.buildSyncPathBytes(physicalRoot: bound.physicalRoot, components: components)
        let conn = ADBSocketConnection(endpoint: bound.sessionId.endpoint)
        defer { conn.close() }
        try await conn.connect()
        try await conn.openDeviceService(transportId: bound.sessionId.transportId, service: "sync:", stage: "sync")

        final class NamesBox: @unchecked Sendable {
            var names: [String] = []
        }
        let box = NamesBox()
        try await syncClient.listDirectory(
            connection: conn,
            pathBytes: pathBytes,
            directoryComponents: components,
            useV2: bound.capabilities.hasLsV2
        ) { batch in
            box.names.append(contentsOf: batch.map(\.displayName))
        }
        try? await syncClient.sendQuit(connection: conn)
        return box.names
    }

    // MARK: - Progress Throttling & Rate Calculation

    private func recordProgress(taskId: UUID, bytesTransferred: UInt64) {
        guard var managed = tasks[taskId], managed.snapshot.state == .transferring else { return }
        let now = Date()
        let windowElapsed = now.timeIntervalSince(managed.rateWindowStartTime)
        var rate = managed.smoothedBytesPerSec

        if windowElapsed >= 0.25 {
            let deltaBytes = bytesTransferred >= managed.rateWindowStartBytes
                ? Double(bytesTransferred - managed.rateWindowStartBytes)
                : 0
            let instantRate = deltaBytes / windowElapsed
            rate = managed.smoothedBytesPerSec == 0 ? instantRate : (0.4 * instantRate + 0.6 * managed.smoothedBytesPerSec)
            if windowElapsed >= 1.0 {
                managed.rateWindowStartTime = now
                managed.rateWindowStartBytes = bytesTransferred
            }
            managed.smoothedBytesPerSec = rate
        }

        managed.snapshot = updatingSnapshot(
            managed.snapshot,
            bytesTransferred: bytesTransferred,
            bytesPerSecond: rate
        )

        let sinceLastEmit = now.timeIntervalSince(managed.lastProgressEmitTime)
        if sinceLastEmit >= Self.progressThrottleInterval {
            managed.lastProgressEmitTime = now
            tasks[taskId] = managed
            emit(.taskUpdated(managed.snapshot))
        } else {
            tasks[taskId] = managed
        }
    }

    private func updateTaskProgressState(taskId: UUID, state: ADBFileTaskState, detail: String) {
        guard var managed = tasks[taskId] else { return }
        let now = Date()
        managed.rateWindowStartTime = now
        managed.rateWindowStartBytes = managed.snapshot.bytesTransferred
        managed.lastProgressEmitTime = now
        managed.snapshot = updatingSnapshot(managed.snapshot, state: state, detail: detail)
        tasks[taskId] = managed
        emit(.taskUpdated(managed.snapshot))
    }

    private func updateTaskTerminal(
        taskId: UUID,
        state: ADBFileTaskState,
        displayName: String? = nil,
        bytesTransferred: UInt64? = nil,
        detail: String,
        localOutputURL: URL? = nil,
        deleteResults: [ADBDeleteItemResult]? = nil
    ) {
        guard var managed = tasks[taskId] else { return }
        managed.snapshot = updatingSnapshot(
            managed.snapshot,
            state: state,
            displayName: displayName,
            bytesTransferred: bytesTransferred,
            bytesPerSecond: 0,
            detail: detail,
            localOutputURL: localOutputURL,
            deleteResults: deleteResults
        )
        tasks[taskId] = managed
        emit(.taskUpdated(managed.snapshot))
    }

    private func updatingSnapshot(
        _ old: ADBFileTaskSnapshot,
        state: ADBFileTaskState? = nil,
        displayName: String? = nil,
        bytesTransferred: UInt64? = nil,
        bytesPerSecond: Double? = nil,
        detail: String? = nil,
        localOutputURL: URL? = nil,
        ledgerEntryId: UUID? = nil,
        deleteResults: [ADBDeleteItemResult]? = nil
    ) -> ADBFileTaskSnapshot {
        ADBFileTaskSnapshot(
            id: old.id,
            sessionId: old.sessionId,
            kind: old.kind,
            displayName: displayName ?? old.displayName,
            totalBytes: old.totalBytes,
            isSizeReliable: old.isSizeReliable,
            bytesTransferred: bytesTransferred ?? old.bytesTransferred,
            bytesPerSecond: bytesPerSecond ?? old.bytesPerSecond,
            state: state ?? old.state,
            detail: detail ?? old.detail,
            localOutputURL: localOutputURL ?? old.localOutputURL,
            ledgerEntryId: ledgerEntryId ?? old.ledgerEntryId,
            deleteResults: deleteResults ?? old.deleteResults
        )
    }
}
