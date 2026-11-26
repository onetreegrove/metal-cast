import MetalCastCore
import SwiftUI

public struct FileManagerView: View {
    @ObservedObject var viewModel: FileManagerViewModel

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    public init(viewModel: FileManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbarView
            Divider()
            bannerArea
            mainSplitArea
            Divider()
            statusBarView
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(
            Button("") { viewModel.selectAllOperable() }
                .keyboardShortcut("a", modifiers: .command)
                .hidden()
        )
        .sheet(item: $viewModel.conflictSheet) { sheet in
            BatchConflictSheet(viewModel: viewModel, sheet: sheet)
        }
        .sheet(item: $viewModel.deleteConfirmSheet) { sheet in
            DeleteConfirmSheet(viewModel: viewModel, sheet: sheet)
        }
        .sheet(item: $viewModel.deleteReportSheet) { report in
            DeleteResultReportSheet(results: report.results) {
                viewModel.deleteReportSheet = nil
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button(action: {
                    Task { await viewModel.goBack() }
                }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canNavigateBack)
                .help("返回上一级")

                Button(action: {
                    Task { await viewModel.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新当前目录")
            }

            breadcrumbBar

            HStack(spacing: 8) {
                Button(action: {
                    Task { await viewModel.beginUpload() }
                }) {
                    Label("上传文件", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canUpload)

                Button(action: {
                    Task { await viewModel.beginDownload() }
                }) {
                    Label("下载所选", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.canDownloadOrDeleteSelection)

                Button(role: .destructive, action: {
                    viewModel.beginDelete()
                }) {
                    Label("删除所选", systemImage: "trash")
                }
                .disabled(!viewModel.canDownloadOrDeleteSelection)

                Button(action: {
                    viewModel.isDrawerOpen.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full")
                        Text("任务与账本")
                        if viewModel.attentionBadgeCount > 0 {
                            Text("\(viewModel.attentionBadgeCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("共享存储") {
                    Task { await viewModel.navigate(to: []) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: viewModel.currentComponents.isEmpty ? .semibold : .regular))
                .foregroundColor(viewModel.currentComponents.isEmpty ? .primary : .secondary)

                ForEach(Array(viewModel.currentComponents.enumerated()), id: \.offset) { index, comp in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    let label = ADBPathUtils.decodeEntryName(comp).displayName
                    let isLast = index == viewModel.currentComponents.count - 1
                    Button(ADBPathUtils.sanitizeControlCharactersForDisplay(label).text) {
                        let target = Array(viewModel.currentComponents.prefix(index + 1))
                        Task { await viewModel.navigate(to: target) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                    .foregroundColor(isLast ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    // MARK: - Contextual Warning Banner

    @ViewBuilder
    private var bannerArea: some View {
        let notices = activeCapabilityNotices
        if let msg = viewModel.bannerMessage ?? notices {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Spacer()
                if viewModel.bannerMessage != nil {
                    Button("关闭") {
                        viewModel.bannerMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            Divider()
        }
    }

    private var activeCapabilityNotices: String? {
        guard let snap = viewModel.sessionSnapshot else { return nil }
        let caps = snap.capabilities
        var parts: [String] = []
        if !caps.hasStatV2 || !caps.hasLsV2 {
            parts.append("当前设备使用 v1 元数据（大小显示为 —，下载跳过长度校验）")
        }
        if snap.commitModeProbed {
            if caps.commitMode == .mvNoClobberWithGuard {
                parts.append("旧版 Toybox 不支持 mv -nT，已降级为 mv -n 护栏提交")
            } else if caps.commitMode == .unsupported {
                parts.append("设备缺少 mv -n，已禁用上传（浏览/下载/删除可正常使用）")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    // MARK: - Main Content + Drawer

    private var mainSplitArea: some View {
        VStack(spacing: 0) {
            Group {
                switch viewModel.viewState {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取手机目录...")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .normal:
                    fileTableView

                case .empty:
                    statePanel(
                        icon: "folder",
                        tint: .accentColor,
                        title: "此文件夹为空",
                        description: "目录枚举返回空且已通过 Shell 探测确认可读。",
                        actionTitle: viewModel.canUpload ? "上传文件到当前目录" : nil
                    ) {
                        Task { await viewModel.beginUpload() }
                    }

                case .permissionDenied(let detail):
                    statePanel(
                        icon: "lock.folder",
                        tint: .orange,
                        title: "无权限访问此目录",
                        description: detail,
                        actionTitle: viewModel.canNavigateBack ? "返回上一级" : nil
                    ) {
                        Task { await viewModel.goBack() }
                    }

                case .disconnected(let reason):
                    statePanel(
                        icon: "wifi.slash",
                        tint: .red,
                        title: "设备连接已断开",
                        description: "\(reason)。为防止跨设备误操作，窗口不会自动迁移到其他设备，请重新连接并核对。",
                        actionTitle: "重新连接并核对"
                    ) {
                        Task { await viewModel.reconnectAndVerify() }
                    }

                case .unsupportedShellV2(let detail):
                    statePanel(
                        icon: "exclamationmark.octagon",
                        tint: .red,
                        title: "当前设备不支持所需 Shell 协议",
                        description: detail,
                        actionTitle: nil,
                        action: {}
                    )

                case .incompatibleEndpoint(let detail):
                    statePanel(
                        icon: "network.slash",
                        tint: .red,
                        title: "ADB 端点配置不兼容",
                        description: detail,
                        actionTitle: nil,
                        action: {}
                    )

                case .error(let detail):
                    statePanel(
                        icon: "exclamationmark.triangle",
                        tint: .orange,
                        title: "操作失败",
                        description: detail,
                        actionTitle: "刷新重试"
                    ) {
                        Task { await viewModel.refresh() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isDrawerOpen {
                Divider()
                drawerView
                    .frame(height: 185)
            }
        }
    }

    private func statePanel(
        icon: String,
        tint: Color,
        title: String,
        description: String,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(tint)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Table

    private var fileTableView: some View {
        VStack(spacing: 0) {
            // Sortable Column Headers
            HStack(spacing: 8) {
                headerButton(.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                headerButton(.kind)
                    .frame(width: 110, alignment: .leading)
                headerButton(.size)
                    .frame(width: 100, alignment: .trailing)
                headerButton(.mtime)
                    .frame(width: 135, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.sortedEntries) { entry in
                        fileRow(entry)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func headerButton(_ col: FileManagerViewModel.SortColumn) -> some View {
        Button(action: {
            viewModel.toggleSort(column: col)
        }) {
            HStack(spacing: 4) {
                Text(col.title)
                    .font(.caption.weight(.semibold))
                if viewModel.sortColumn == col {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ entry: ADBRemoteEntry) -> some View {
        let isSelected = viewModel.selectedEntryIds.contains(entry.id)
        let sanitized = ADBPathUtils.sanitizeControlCharactersForDisplay(entry.displayName)

        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: entry))
                    .foregroundColor(iconColor(for: entry))
                    .frame(width: 18)

                Text(sanitized.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(entry.isRestricted ? .secondary : .primary)

                if entry.isRestricted {
                    badge("首版不支持访问", color: .orange)
                } else if entry.kind == .symlink {
                    badge("符号链接", color: .secondary)
                } else if !entry.isLosslessUTF8 {
                    badge("非 UTF-8", color: .red)
                } else if sanitized.hasControlCharacters {
                    badge("控制字符转义", color: .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(viewModel.entryKindLabel(entry))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)

            Text(viewModel.formattedSize(entry))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)

            Text(entry.mtime.map { Self.dateFormatter.string(from: $0) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 135, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .opacity(entry.isRestricted ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { await viewModel.activateEntry(entry) }
        }
        .onTapGesture(count: 1) {
            let additive = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            viewModel.selectRow(entry, additive: additive)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func iconName(for entry: ADBRemoteEntry) -> String {
        if entry.isRestricted { return "lock.folder.fill" }
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink: return "link"
        case .regular:
            let lower = entry.displayName.lowercased()
            if lower.hasSuffix(".apk") { return "shippingbox.fill" }
            if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") { return "photo" }
            if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".mkv") { return "film" }
            return "doc"
        case .other:
            return "questionmark.square.dashed"
        }
    }

    private func iconColor(for entry: ADBRemoteEntry) -> Color {
        if entry.isRestricted { return .secondary }
        if entry.kind == .directory { return .accentColor }
        if !entry.isLosslessUTF8 { return .red }
        return .secondary
    }

    // MARK: - Collapsible Drawer

    private var drawerView: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $viewModel.drawerTab) {
                    Text("任务队列 (\(viewModel.tasks.count))").tag(FileManagerViewModel.DrawerTab.tasks)
                    Text("清理账本 (\(viewModel.ledgerEntries.count))").tag(FileManagerViewModel.DrawerTab.ledger)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                Text("全局传输槽 \(viewModel.globalActiveTransferSlots)/2")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                if viewModel.drawerTab == .tasks && !viewModel.tasks.isEmpty {
                    Button("清除已完成") {
                        Task { await viewModel.clearFinishedTasks() }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if viewModel.drawerTab == .tasks {
                tasksListView
            } else {
                ledgerListView
            }
        }
    }

    private var tasksListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if !viewModel.ledgerEntries.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("发现 \(viewModel.ledgerEntries.count) 条未收敛暂存清理记录，请切换至「清理账本」处理。")
                            .font(.caption)
                        Spacer()
                        Button("查看账本") {
                            viewModel.drawerTab = .ledger
                        }
                        .font(.caption)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(6)
                }

                if viewModel.tasks.isEmpty {
                    Text("暂无传输或删除任务")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 24)
                } else {
                    ForEach(viewModel.tasks) { task in
                        taskRow(task)
                    }
                }
            }
            .padding(10)
        }
    }

    private func taskRow(_ task: ADBFileTaskSnapshot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(taskKindTitle(task.kind))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)

                    Text(task.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    Text(taskStateTitle(task.state))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(taskStateColor(task.state))
                }

                if task.kind != .delete {
                    if task.state == .transferring && !task.isSizeReliable {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: progressFraction(task))
                            .progressViewStyle(.linear)
                    }
                }

                Text(taskSubtitle(task))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                if task.state == .queued || task.state == .transferring {
                    Button("取消") {
                        Task { await viewModel.cancelTask(id: task.id) }
                    }
                    .controlSize(.small)
                } else if task.state == .pendingConfirmation && task.kind == .upload {
                    Button("核对结果") {
                        Task { await viewModel.verifyPendingTask(id: task.id) }
                    }
                    .controlSize(.small)
                } else if task.state == .completed, let localURL = task.localOutputURL {
                    Button("在 Finder 中显示") {
                        viewModel.revealInFinder(localURL)
                    }
                    .controlSize(.small)
                } else if task.state == .failed || task.state == .cancelled {
                    Button("重试") {
                        Task { await viewModel.retryTask(id: task.id) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    private var ledgerListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if viewModel.ledgerEntries.isEmpty {
                    Text("当前没有未收敛的暂存清理记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 24)
                } else {
                    ForEach(viewModel.ledgerEntries) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.tempDirName)/\(entry.tempPayloadName) → \(entry.finalTargetName)")
                                    .font(.caption.weight(.semibold))
                                Text("设备 \(entry.serial) · 目录 \(entry.targetParentPhysicalPath) · 状态 \(entry.state.rawValue)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if entry.state == .pendingConfirmation {
                                Button("核对结果") {
                                    Task { await viewModel.verifyPendingLedgerEntry(id: entry.id) }
                                }
                                .controlSize(.small)
                            } else {
                                Button("重试清理") {
                                    Task { await viewModel.retryLedgerCleanup(id: entry.id) }
                                }
                                .controlSize(.small)
                            }
                            Button("忽略并移除") {
                                Task { await viewModel.dismissLedgerEntry(id: entry.id) }
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                        .cornerRadius(6)
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: - Status Bar

    private var statusBarView: some View {
        HStack {
            Text("\(viewModel.boundDevice.isWifi ? "Wi-Fi" : "USB") · 物理根: \(viewModel.sessionSnapshot?.physicalRoot ?? "未解析") · 共 \(viewModel.rawEntries.count) 项 · 已选 \(viewModel.selectedEntryIds.count) 项")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            if let snap = viewModel.sessionSnapshot {
                let caps = snap.capabilities
                let mvText: String = {
                    guard snap.commitModeProbed else { return "mv 待探测" }
                    switch caps.commitMode {
                    case .mvNoClobberNoTarget: return "mv -nT"
                    case .mvNoClobberWithGuard: return "mv -n"
                    case .unsupported: return "无 mv -n"
                    }
                }()
                Text("\(caps.hasShellV2 ? "shell_v2" : "无 shell_v2") · \(caps.hasStatV2 ? "stat_v2" : "STAT v1") · \(caps.hasLsV2 ? "ls_v2" : "LIST v1") · \(mvText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Formatting Helpers

    private func progressFraction(_ task: ADBFileTaskSnapshot) -> Double {
        if task.state == .completed { return 1.0 }
        if task.state == .committing { return 0.99 }
        guard task.isSizeReliable, let total = task.totalBytes, total > 0 else { return 0 }
        return min(0.99, Double(task.bytesTransferred) / Double(total))
    }

    private func taskSubtitle(_ task: ADBFileTaskSnapshot) -> String {
        var parts: [String] = []
        if task.kind != .delete {
            if task.state == .completed {
                parts.append("100%")
            } else if task.isSizeReliable, let total = task.totalBytes, total > 0 {
                let pct = Int(min(99, (Double(task.bytesTransferred) / Double(total)) * 100))
                parts.append("\(pct)%")
            }
            if task.bytesTransferred > 0 && task.state == .transferring {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(task.bytesTransferred), countStyle: .file))
            }
            if task.state == .transferring && task.bytesPerSecond > 0 {
                let rate = ByteCountFormatter.string(fromByteCount: Int64(task.bytesPerSecond), countStyle: .file)
                parts.append("\(rate)/s")
            }
        }
        parts.append(task.detail)
        return parts.joined(separator: " · ")
    }

    private func taskKindTitle(_ kind: ADBFileTaskKind) -> String {
        switch kind {
        case .upload: return "上传"
        case .download: return "下载"
        case .delete: return "删除"
        }
    }

    private func taskStateTitle(_ state: ADBFileTaskState) -> String {
        switch state {
        case .queued: return "排队中"
        case .transferring: return "传输中"
        case .committing: return "正在提交"
        case .completed: return "已完成"
        case .skipped: return "已跳过"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        case .pendingConfirmation: return "待确认"
        }
    }

    private func taskStateColor(_ state: ADBFileTaskState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .pendingConfirmation: return .orange
        case .transferring, .committing: return .accentColor
        default: return .secondary
        }
    }
}

// MARK: - Modal Sheets

private struct BatchConflictSheet: View {
    @ObservedObject var viewModel: FileManagerViewModel
    @State var sheet: FileManagerViewModel.ConflictSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发现 \(sheet.rows.count) 个同名冲突")
                .font(.headline)

            Text("目标路径: \(sheet.destinationDisplayPath)")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($sheet.rows) { $row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ADBPathUtils.sanitizeControlCharactersForDisplay(row.originalName).text)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                if !sheet.applyAll {
                                    if row.suggestedRename != nil {
                                        Picker("", selection: $row.resolution) {
                                            Text("保留两份").tag(ADBTransferConflictResolution.keepBoth)
                                            Text("跳过").tag(ADBTransferConflictResolution.skip)
                                        }
                                        .frame(width: 110)
                                    } else {
                                        Text("仅可跳过")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            if let err = row.renameError {
                                Text("无法保留两份（\(err)），将只能跳过")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            } else if let rename = row.suggestedRename {
                                let showSkip = !sheet.applyAll && row.resolution == .skip
                                Text(showSkip ? "将跳过此文件" : "若保留两份将重命名为: \(rename)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
            }
            .frame(maxHeight: 240)

            Toggle("应用到本次全部冲突", isOn: $sheet.applyAll)

            HStack {
                Button("取消") {
                    viewModel.conflictSheet = nil
                }
                Spacer()
                if sheet.applyAll {
                    Button("跳过冲突文件") {
                        viewModel.conflictSheet = sheet
                        Task { await viewModel.confirmConflictSheet(globalResolution: .skip) }
                    }
                    Button("保留两份") {
                        viewModel.conflictSheet = sheet
                        Task { await viewModel.confirmConflictSheet(globalResolution: .keepBoth) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("按逐项选择执行") {
                        viewModel.conflictSheet = sheet
                        Task { await viewModel.confirmConflictSheet(globalResolution: nil) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct DeleteConfirmSheet: View {
    @ObservedObject var viewModel: FileManagerViewModel
    let sheet: FileManagerViewModel.DeleteConfirmSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认永久删除手机文件？")
                .font(.headline)

            Text("此操作直接执行非递归删除，不经过回收站，删除后无法恢复。")
                .font(.caption)
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 4) {
                Text("目标设备: \(sheet.deviceName)")
                Text("物理目录: \(sheet.physicalDirectory)")
                Text("删除数量: \(sheet.targets.count) 个普通文件")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            List(sheet.targets.indices, id: \.self) { idx in
                Text(ADBPathUtils.sanitizeControlCharactersForDisplay(sheet.targets[idx].remoteEntry.displayName).text)
                    .font(.caption)
            }
            .frame(height: 160)

            HStack {
                Button("取消") {
                    viewModel.deleteConfirmSheet = nil
                }
                Spacer()
                Button("永久删除", role: .destructive) {
                    Task { await viewModel.confirmDelete() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct DeleteResultReportSheet: View {
    let results: [ADBDeleteItemResult]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("逐项删除结果报告")
                .font(.headline)

            List(results) { item in
                HStack {
                    Text(ADBPathUtils.sanitizeControlCharactersForDisplay(item.fileName).text)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(item.message)
                        .font(.caption)
                        .foregroundColor(item.status == .deleted ? .green : (item.status == .pendingConfirmation ? .orange : .red))
                }
            }
            .frame(height: 200)

            HStack {
                Spacer()
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
