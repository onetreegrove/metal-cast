import AppKit
import Foundation
import MetalCastCore

@MainActor
public final class FileManagerViewModel: ObservableObject {
    public enum SortColumn: String, CaseIterable {
        case name, kind, size, mtime

        var title: String {
            switch self {
            case .name: return "名称"
            case .kind: return "类型"
            case .size: return "大小"
            case .mtime: return "修改时间"
            }
        }
    }

    public enum DrawerTab: String {
        case tasks, ledger
    }

    public enum ViewState: Equatable {
        case loading
        case normal
        case empty
        case permissionDenied(String)
        case disconnected(String)
        case unsupportedShellV2(String)
        case incompatibleEndpoint(String)
        case error(String)
    }

    public enum ConflictDirection {
        case upload(targetComponents: [Data], parentPhysicalPath: String, rejectedSummary: String?)
        case download(sourceComponents: [Data], localDirectory: URL)
    }

    public struct ConflictRowModel: Identifiable {
        public let id = UUID()
        public let originalName: String
        public let suggestedRename: String?
        public let renameError: String?
        public var resolution: ADBTransferConflictResolution
        public let uploadItem: ADBUploadPlanItem?
        public let downloadItem: ADBDownloadPlanItem?
    }

    public struct ConflictSheetState: Identifiable {
        public let id = UUID()
        public let direction: ConflictDirection
        public let destinationDisplayPath: String
        public let nonConflictUploads: [ADBUploadPlanItem]
        public let nonConflictDownloads: [ADBDownloadPlanItem]
        public var rows: [ConflictRowModel]
        public var applyAll: Bool = true
    }

    public struct DeleteConfirmSheetState: Identifiable {
        public let id = UUID()
        public let deviceName: String
        public let physicalDirectory: String
        public let directoryComponents: [Data]
        public let targets: [ADBDeleteTarget]
    }

    public struct DeleteReportSheetState: Identifiable {
        public let id = UUID()
        public let results: [ADBDeleteItemResult]
    }

    public private(set) var bindingKey: String
    public var onBindingKeyChanged: ((String, String) -> Void)?
    @Published public var boundDevice: ADBDevice
    @Published public var sessionSnapshot: ADBFileSessionSnapshot?
    @Published public var currentComponents: [Data] = []
    @Published public var rawEntries: [ADBRemoteEntry] = []
    @Published public var selectedEntryIds: Set<Data> = []
    @Published public var sortColumn: SortColumn = .name
    @Published public var sortAscending: Bool = true
    @Published public var viewState: ViewState = .loading

    @Published public var tasks: [ADBFileTaskSnapshot] = []
    @Published public var ledgerEntries: [ADBLedgerEntry] = []
    @Published public var globalActiveTransferSlots: Int = 0
    @Published public var isDrawerOpen: Bool = false
    @Published public var drawerTab: DrawerTab = .tasks
    @Published public var bannerMessage: String?

    @Published public var conflictSheet: ConflictSheetState?
    @Published public var deleteConfirmSheet: DeleteConfirmSheetState?
    @Published public var deleteReportSheet: DeleteReportSheetState?

    private let fileService: ADBFileService
    private var eventStreamTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var currentRequestId: UUID = UUID()

    public init(device: ADBDevice, bindingKey: String, fileService: ADBFileService = .shared) {
        self.boundDevice = device
        self.bindingKey = bindingKey
        self.fileService = fileService
        startObservingServiceEvents()
    }

    deinit {
        eventStreamTask?.cancel()
        browseTask?.cancel()
    }

    public var windowTitle: String {
        "手机文件 - \(boundDevice.model ?? boundDevice.serial)"
    }

    public var currentPhysicalDirectory: String {
        guard let root = sessionSnapshot?.physicalRoot else { return "/sdcard" }
        return (try? ADBPathUtils.buildRemotePath(physicalRoot: root, components: currentComponents)) ?? root
    }

    public var sortedEntries: [ADBRemoteEntry] {
        rawEntries.sorted { lhs, rhs in
            let lhsDir = lhs.kind == .directory ? 0 : 1
            let rhsDir = rhs.kind == .directory ? 0 : 1
            if lhsDir != rhsDir {
                return lhsDir < rhsDir
            }

            let cmp: ComparisonResult
            switch sortColumn {
            case .name:
                cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .kind:
                cmp = entryKindLabel(lhs).localizedStandardCompare(entryKindLabel(rhs))
            case .size:
                let lSize = lhs.isSizeReliable ? lhs.size : nil
                let rSize = rhs.isSizeReliable ? rhs.size : nil
                switch (lSize, rSize) {
                case let (l?, r?) where l != r:
                    cmp = l < r ? .orderedAscending : .orderedDescending
                case (.some, .none):
                    cmp = .orderedDescending
                case (.none, .some):
                    cmp = .orderedAscending
                default:
                    cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
                }
            case .mtime:
                let lTime = lhs.mtime?.timeIntervalSince1970 ?? 0
                let rTime = rhs.mtime?.timeIntervalSince1970 ?? 0
                if lTime != rTime {
                    cmp = lTime < rTime ? .orderedAscending : .orderedDescending
                } else {
                    cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
                }
            }

            if cmp == .orderedSame {
                let tie = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return sortAscending ? (tie == .orderedAscending) : (tie == .orderedDescending)
            }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
    }

    public var operableSelectedEntries: [ADBRemoteEntry] {
        rawEntries.filter {
            selectedEntryIds.contains($0.id) &&
            $0.kind == .regular &&
            !$0.isRestricted &&
            $0.isLosslessUTF8
        }
    }

    public var canNavigateBack: Bool {
        !currentComponents.isEmpty && !isSessionBlocked
    }

    public var isSessionBlocked: Bool {
        switch viewState {
        case .disconnected, .unsupportedShellV2, .incompatibleEndpoint:
            return true
        default:
            return false
        }
    }

    public var canUpload: Bool {
        guard !isSessionBlocked, let snap = sessionSnapshot else { return false }
        if case .permissionDenied = viewState { return false }
        return !snap.commitModeProbed || snap.capabilities.commitMode != .unsupported
    }

    public var canDownloadOrDeleteSelection: Bool {
        !isSessionBlocked && !operableSelectedEntries.isEmpty
    }

    public var hasActiveOrCommittingWork: Bool {
        tasks.contains { [.queued, .transferring, .committing].contains($0.state) }
    }

    public var attentionBadgeCount: Int {
        let active = tasks.filter {
            [.queued, .transferring, .committing, .pendingConfirmation].contains($0.state)
        }.count
        return active + ledgerEntries.count
    }

    // MARK: - Lifecycle & Events

    public func openInitialSession() async {
        viewState = .loading
        bannerMessage = nil
        ledgerEntries = await fileService.ledgerEntries()
        if !ledgerEntries.isEmpty {
            isDrawerOpen = true
        }

        do {
            let snap = try await fileService.openSession(for: boundDevice)
            self.sessionSnapshot = snap
            self.currentComponents = snap.initialComponents
            await loadCurrentDirectory()
        } catch let err as ADBFileError {
            applySessionOpenError(err)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    public func reconnectAndVerify() async {
        await SessionManager.shared.refreshDevices()
        let candidates = SessionManager.shared.devices.filter {
            $0.serial == boundDevice.serial && $0.state == .device && $0.transportId != nil
        }

        guard let matched = candidates.first else {
            bannerMessage = "未检测到设备 \(boundDevice.model ?? boundDevice.serial) 重新上线且已授权，请检查连接后重试。"
            return
        }

        if matched.selectionKey != bindingKey {
            let oldKey = bindingKey
            bindingKey = matched.selectionKey
            onBindingKeyChanged?(oldKey, matched.selectionKey)
        }
        boundDevice = matched
        await openInitialSession()
    }

    public func updateReboundDevice(_ device: ADBDevice) {
        let oldKey = bindingKey
        bindingKey = device.selectionKey
        boundDevice = device
        if oldKey != bindingKey {
            onBindingKeyChanged?(oldKey, bindingKey)
        }
        if case .disconnected = viewState {
            Task { await openInitialSession() }
        }
    }

    public func cancelWindowTasks() async {
        browseTask?.cancel()
        if let sid = sessionSnapshot?.sessionId {
            await fileService.cancelWindowTasks(sessionId: sid)
        }
    }

    public func shutdown() {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        browseTask?.cancel()
        browseTask = nil
    }

    private func startObservingServiceEvents() {
        eventStreamTask?.cancel()
        let service = self.fileService
        eventStreamTask = Task { [weak self] in
            let stream = await service.events
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleServiceEvent(event)
            }
        }
    }

    private func handleServiceEvent(_ event: ADBFileTaskEvent) {
        switch event {
        case .taskUpdated(let snap):
            guard isTaskForThisDevice(snap) else { return }
            if let idx = tasks.firstIndex(where: { $0.id == snap.id }) {
                tasks[idx] = snap
            } else {
                tasks.insert(snap, at: 0)
                isDrawerOpen = true
            }

            if snap.kind == .upload && snap.state == .completed,
               snap.sessionId == sessionSnapshot?.sessionId,
               snap.directoryComponents == currentComponents {
                Task { await self.loadCurrentDirectory(silent: true) }
            }
            if snap.kind == .delete && (snap.state == .completed || snap.state == .pendingConfirmation),
               snap.sessionId == sessionSnapshot?.sessionId {
                if let results = snap.deleteResults {
                    deleteReportSheet = DeleteReportSheetState(results: results)
                }
                if snap.directoryComponents == currentComponents {
                    Task { await self.loadCurrentDirectory(silent: true) }
                }
            }

        case .activeTransferSlotCountChanged(let count):
            globalActiveTransferSlots = count

        case .ledgerUpdated(let entries):
            ledgerEntries = entries
            if !entries.isEmpty {
                isDrawerOpen = true
            }

        case .sessionCapabilitiesUpdated(let sid, let caps, let probed):
            guard let current = sessionSnapshot, current.sessionId == sid else { return }
            sessionSnapshot = ADBFileSessionSnapshot(
                sessionId: current.sessionId,
                deviceName: current.deviceName,
                isWifi: current.isWifi,
                physicalRoot: current.physicalRoot,
                capabilities: caps,
                commitModeProbed: probed,
                initialComponents: current.initialComponents
            )

        case .sessionInvalidated(let sid, let reason):
            guard sessionSnapshot?.sessionId == sid else { return }
            browseTask?.cancel()
            viewState = .disconnected(reason)
        }
    }

    private func isTaskForThisDevice(_ snap: ADBFileTaskSnapshot) -> Bool {
        if let sid = sessionSnapshot?.sessionId {
            return snap.sessionId == sid || snap.sessionId.serial == sid.serial
        }
        return snap.sessionId.serial == boundDevice.serial
    }

    private func applySessionOpenError(_ err: ADBFileError) {
        switch err {
        case .incompatibleEndpoint(let detail):
            viewState = .incompatibleEndpoint(detail)
        case .unsupportedDevice(let detail):
            viewState = .unsupportedShellV2(detail)
        case .sessionInvalidated:
            viewState = .disconnected("设备已断线或未授权，请重新连接并核对设备")
        case .permissionDenied(let detail):
            viewState = .permissionDenied(detail)
        default:
            viewState = .error(err.localizedDescription)
        }
    }

    // MARK: - Browsing & Sorting

    public func toggleSort(column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    public func navigate(to components: [Data]) async {
        guard !isSessionBlocked else { return }
        if ADBPathUtils.isRestrictedComponents(components) {
            bannerMessage = "首版不支持访问 Android/data 与 Android/obb（restrictedPath）。"
            return
        }
        currentComponents = components
        selectedEntryIds.removeAll()
        await loadCurrentDirectory()
    }

    public func goBack() async {
        guard canNavigateBack else { return }
        await navigate(to: Array(currentComponents.dropLast()))
    }

    public func refresh() async {
        guard let sid = sessionSnapshot?.sessionId else {
            await reconnectAndVerify()
            return
        }
        _ = sid
        await loadCurrentDirectory()
    }

    public func activateEntry(_ entry: ADBRemoteEntry) async {
        if entry.isRestricted {
            bannerMessage = "已拦截：首版不支持访问 Android/\(entry.displayName)（restrictedPath）。"
            return
        }
        if entry.kind == .directory {
            await navigate(to: currentComponents + [entry.rawNameBytes])
        } else if entry.kind == .symlink {
            bannerMessage = "符号链接仅作展示，不允许进入或当作普通文件操作。"
        }
    }

    public func selectRow(_ entry: ADBRemoteEntry, additive: Bool) {
        if additive {
            if selectedEntryIds.contains(entry.id) {
                selectedEntryIds.remove(entry.id)
            } else {
                selectedEntryIds.insert(entry.id)
            }
        } else {
            selectedEntryIds = [entry.id]
        }
    }

    public func selectAllOperable() {
        let operable = rawEntries.filter { $0.kind == .regular && !$0.isRestricted && $0.isLosslessUTF8 }
        selectedEntryIds = Set(operable.map(\.id))
    }

    public func loadCurrentDirectory(silent: Bool = false) async {
        guard let snap = sessionSnapshot else { return }
        browseTask?.cancel()
        let requestId = UUID()
        currentRequestId = requestId
        if !silent {
            rawEntries = []
            selectedEntryIds.removeAll()
            viewState = .loading
        }

        let comps = currentComponents
        let stream = await fileService.listDirectory(
            sessionId: snap.sessionId,
            relativeComponents: comps,
            requestId: requestId
        )

        browseTask = Task { [weak self] in
            var buffer: [ADBRemoteEntry] = []
            do {
                for try await batch in stream {
                    guard let self,
                          !Task.isCancelled,
                          self.currentRequestId == batch.requestId,
                          self.sessionSnapshot?.sessionId == batch.sessionId else {
                        return
                    }
                    if !batch.entries.isEmpty {
                        buffer.append(contentsOf: batch.entries)
                        if !silent {
                            self.rawEntries = buffer
                            self.viewState = .normal
                        }
                    }
                    if batch.isFinal {
                        self.rawEntries = buffer
                        let validIds = Set(buffer.map(\.id))
                        self.selectedEntryIds.formIntersection(validIds)
                        self.viewState = buffer.isEmpty ? .empty : .normal
                    }
                }
            } catch is CancellationError {
                return
            } catch let err as ADBFileError {
                guard let self, self.currentRequestId == requestId else { return }
                switch err {
                case .permissionDenied(let msg):
                    self.viewState = .permissionDenied(msg)
                case .restrictedPath(let msg):
                    self.viewState = .permissionDenied(msg)
                case .sessionInvalidated:
                    self.viewState = .disconnected("会话已失效，请重新连接并核对设备")
                case .unsupportedDevice(let msg):
                    self.viewState = .unsupportedShellV2(msg)
                case .incompatibleEndpoint(let msg):
                    self.viewState = .incompatibleEndpoint(msg)
                default:
                    self.viewState = .error(err.localizedDescription)
                }
            } catch {
                guard let self, self.currentRequestId == requestId else { return }
                self.viewState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Upload / Download / Delete Flows

    public func beginUpload() async {
        guard canUpload, let snap = sessionSnapshot else { return }

        let panel = NSOpenPanel()
        panel.title = "选择要上传到手机的文件"
        panel.message = "上传目标目录: \(currentPhysicalDirectory)"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        // Refresh current directory names before conflict analysis
        await loadCurrentDirectory()
        await browseTask?.value
        guard case .normal = viewStateOrEmptyAsValid() else { return }

        let existingNames = rawEntries.map(\.displayName)
        let parentPhysical = currentPhysicalDirectory
        let analysis = ADBTransferPlanner.analyzeUploadConflicts(
            localURLs: panel.urls,
            existingRemoteNames: existingNames,
            parentPhysicalPath: parentPhysical
        )

        var rejectedSummary: String? = nil
        if !analysis.rejected.isEmpty {
            let firstReason = analysis.rejected[0].reason
            rejectedSummary = "已前置拦截 \(analysis.rejected.count) 个不合规文件（\(firstReason)）"
            bannerMessage = rejectedSummary
        }

        if analysis.conflicts.isEmpty {
            if !analysis.nonConflicts.isEmpty {
                do {
                    _ = try await fileService.enqueueUpload(
                        sessionId: snap.sessionId,
                        targetComponents: currentComponents,
                        items: analysis.nonConflicts
                    )
                    isDrawerOpen = true
                    drawerTab = .tasks
                } catch {
                    bannerMessage = error.localizedDescription
                }
            }
        } else {
            let rows = analysis.conflicts.map { c in
                ConflictRowModel(
                    originalName: c.originalName,
                    suggestedRename: c.suggestedKeepBothName,
                    renameError: c.keepBothError,
                    resolution: c.suggestedKeepBothName != nil ? .keepBoth : .skip,
                    uploadItem: c.item,
                    downloadItem: nil
                )
            }
            conflictSheet = ConflictSheetState(
                direction: .upload(
                    targetComponents: currentComponents,
                    parentPhysicalPath: parentPhysical,
                    rejectedSummary: rejectedSummary
                ),
                destinationDisplayPath: parentPhysical,
                nonConflictUploads: analysis.nonConflicts,
                nonConflictDownloads: [],
                rows: rows,
                applyAll: true
            )
        }
    }

    private func viewStateOrEmptyAsValid() -> ViewState {
        switch viewState {
        case .empty: return .normal
        default: return viewState
        }
    }

    public func beginDownload() async {
        guard canDownloadOrDeleteSelection, let snap = sessionSnapshot else { return }
        let selected = operableSelectedEntries
        guard !selected.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "选择 Mac 保存目录"
        panel.message = "将检查 macOS APFS 大小写不敏感与 NFC/NFD 同名冲突"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        do {
            let analysis = try ADBTransferPlanner.analyzeDownloadConflicts(
                entries: selected,
                localDirectory: destURL
            )
            if analysis.conflicts.isEmpty {
                _ = try await fileService.enqueueDownload(
                    sessionId: snap.sessionId,
                    sourceComponents: currentComponents,
                    items: analysis.nonConflicts,
                    localDirectory: destURL
                )
                isDrawerOpen = true
                drawerTab = .tasks
            } else {
                let rows = analysis.conflicts.map { c in
                    ConflictRowModel(
                        originalName: c.originalName,
                        suggestedRename: c.suggestedKeepBothName,
                        renameError: c.keepBothError,
                        resolution: c.suggestedKeepBothName != nil ? .keepBoth : .skip,
                        uploadItem: nil,
                        downloadItem: c.item
                    )
                }
                conflictSheet = ConflictSheetState(
                    direction: .download(sourceComponents: currentComponents, localDirectory: destURL),
                    destinationDisplayPath: destURL.path,
                    nonConflictUploads: [],
                    nonConflictDownloads: analysis.nonConflicts,
                    rows: rows,
                    applyAll: true
                )
            }
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    public func confirmConflictSheet(globalResolution: ADBTransferConflictResolution?) async {
        guard let sheet = conflictSheet, let snap = sessionSnapshot else { return }
        conflictSheet = nil

        switch sheet.direction {
        case .upload(let targetComponents, let parentPhysicalPath, _):
            var finalItems = sheet.nonConflictUploads
            var occupied = Set(rawEntries.map { ADBTransferPlanner.normalizeAndroidName($0.displayName) })
            for item in finalItems {
                occupied.insert(ADBTransferPlanner.normalizeAndroidName(item.targetFileName))
            }

            for row in sheet.rows {
                guard let baseItem = row.uploadItem else { continue }
                let effective = sheet.applyAll ? (globalResolution ?? row.resolution) : row.resolution
                if effective == .skip { continue }

                do {
                    let candidate = try ADBTransferPlanner.nextAvailableRenameCandidate(
                        originalName: row.originalName,
                        occupiedNormalizedNames: occupied,
                        normalize: ADBTransferPlanner.normalizeAndroidName,
                        validateCandidate: { try ADBPathUtils.validateUploadFileName($0) }
                    )
                    let fullBytes = Data("\(parentPhysicalPath)/\(candidate)".utf8).count
                    guard fullBytes <= ADBPathUtils.syncMaxPathBytes else {
                        throw ADBFileError.pathTooLong(fullBytes)
                    }
                    occupied.insert(ADBTransferPlanner.normalizeAndroidName(candidate))
                    finalItems.append(
                        ADBUploadPlanItem(
                            localURL: baseItem.localURL,
                            targetFileName: candidate,
                            originalBaseName: row.originalName,
                            conflictResolution: .keepBoth,
                            fileSize: baseItem.fileSize,
                            mtime: baseItem.mtime
                        )
                    )
                } catch {
                    bannerMessage = "跳过无法重命名项「\(row.originalName)」: \(error.localizedDescription)"
                }
            }

            if !finalItems.isEmpty {
                do {
                    _ = try await fileService.enqueueUpload(
                        sessionId: snap.sessionId,
                        targetComponents: targetComponents,
                        items: finalItems
                    )
                    isDrawerOpen = true
                    drawerTab = .tasks
                } catch {
                    bannerMessage = error.localizedDescription
                }
            }

        case .download(let sourceComponents, let localDirectory):
            var finalItems = sheet.nonConflictDownloads
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: localDirectory.path)) ?? []
            var occupied = Set(existing.map(ADBTransferPlanner.normalizeMacAPFSName))
            for item in finalItems {
                occupied.insert(ADBTransferPlanner.normalizeMacAPFSName(item.targetFileName))
            }

            for row in sheet.rows {
                guard let baseItem = row.downloadItem else { continue }
                let effective = sheet.applyAll ? (globalResolution ?? row.resolution) : row.resolution
                if effective == .skip { continue }

                do {
                    let candidate = try ADBTransferPlanner.nextAvailableRenameCandidate(
                        originalName: row.originalName,
                        occupiedNormalizedNames: occupied,
                        normalize: ADBTransferPlanner.normalizeMacAPFSName
                    )
                    occupied.insert(ADBTransferPlanner.normalizeMacAPFSName(candidate))
                    finalItems.append(
                        ADBDownloadPlanItem(
                            remoteEntry: baseItem.remoteEntry,
                            targetFileName: candidate,
                            originalBaseName: row.originalName,
                            conflictResolution: .keepBoth
                        )
                    )
                } catch {
                    bannerMessage = "跳过无法重命名项「\(row.originalName)」: \(error.localizedDescription)"
                }
            }

            if !finalItems.isEmpty {
                do {
                    _ = try await fileService.enqueueDownload(
                        sessionId: snap.sessionId,
                        sourceComponents: sourceComponents,
                        items: finalItems,
                        localDirectory: localDirectory
                    )
                    isDrawerOpen = true
                    drawerTab = .tasks
                } catch {
                    bannerMessage = error.localizedDescription
                }
            }
        }
    }

    public func beginDelete() {
        guard canDownloadOrDeleteSelection else { return }
        let targets = operableSelectedEntries.map { ADBDeleteTarget(remoteEntry: $0) }
        guard !targets.isEmpty else { return }
        deleteConfirmSheet = DeleteConfirmSheetState(
            deviceName: boundDevice.model ?? boundDevice.serial,
            physicalDirectory: currentPhysicalDirectory,
            directoryComponents: currentComponents,
            targets: targets
        )
    }

    public func confirmDelete() async {
        guard let sheet = deleteConfirmSheet, let snap = sessionSnapshot else { return }
        deleteConfirmSheet = nil
        do {
            _ = try await fileService.enqueueDelete(
                sessionId: snap.sessionId,
                directoryComponents: sheet.directoryComponents,
                items: sheet.targets
            )
            isDrawerOpen = true
            drawerTab = .tasks
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    // MARK: - Task & Ledger Actions

    public func cancelTask(id: UUID) async {
        await fileService.cancelTransfer(taskId: id)
    }

    public func retryTask(id: UUID) async {
        guard let sid = sessionSnapshot?.sessionId else {
            bannerMessage = "设备未处于有效连接会话，请先重新连接"
            return
        }
        do {
            _ = try await fileService.retryTask(taskId: id, sessionId: sid)
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    public func verifyPendingTask(id: UUID) async {
        do {
            _ = try await fileService.verifyPendingTask(taskId: id)
            ledgerEntries = await fileService.ledgerEntries()
            await loadCurrentDirectory()
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    public func verifyPendingLedgerEntry(id: UUID) async {
        do {
            guard let result = try await fileService.verifyPendingLedgerEntry(entryId: id) else { return }
            ledgerEntries = await fileService.ledgerEntries()
            if result.committed {
                bannerMessage = result.tempDirCleaned
                    ? "核对确认：文件「\(result.finalTargetName)」已成功提交并清理暂存目录"
                    : "核对确认：文件「\(result.finalTargetName)」已提交，空暂存目录待清理"
                await loadCurrentDirectory(silent: true)
            } else {
                bannerMessage = "核对确认：目标「\(result.finalTargetName)」尚未提交，可重试清理暂存目录后重新上传"
            }
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    public func clearFinishedTasks() async {
        let terminal: Set<ADBFileTaskState> = [.completed, .skipped, .cancelled, .failed]
        tasks.removeAll { terminal.contains($0.state) }
        await fileService.clearFinishedTasks(serial: boundDevice.serial)
    }

    public func retryLedgerCleanup(id: UUID) async {
        do {
            try await fileService.retryLedgerCleanup(entryId: id)
            ledgerEntries = await fileService.ledgerEntries()
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    public func dismissLedgerEntry(id: UUID) async {
        await fileService.dismissLedgerEntry(entryId: id)
        ledgerEntries = await fileService.ledgerEntries()
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Display Helpers

    public func entryKindLabel(_ entry: ADBRemoteEntry) -> String {
        if entry.isRestricted { return "受限目录" }
        switch entry.kind {
        case .directory: return "文件夹"
        case .symlink: return "符号链接"
        case .regular:
            return entry.displayName.lowercased().hasSuffix(".apk") ? "APK 文件" : "普通文件"
        case .other:
            return "其他"
        }
    }

    public func formattedSize(_ entry: ADBRemoteEntry) -> String {
        if entry.kind == .directory || !entry.isSizeReliable {
            return "—"
        }
        guard let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(size, UInt64(Int64.max))), countStyle: .file)
    }
}
