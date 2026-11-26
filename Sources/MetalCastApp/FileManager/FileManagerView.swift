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
            Rectangle().fill(MCTheme.border).frame(height: 1)
            bannerArea
            mainSplitArea
            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)
            statusBarView
        }
        .background(MCTheme.windowBackground)
        .frame(minWidth: 820, minHeight: 560)
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
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(MCButtonStyle(.secondary, iconOnly: true))
                .disabled(!viewModel.canNavigateBack)
                .help("返回上一级")

                Button(action: {
                    Task { await viewModel.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(MCButtonStyle(.secondary, iconOnly: true))
                .help("刷新当前目录")
            }

            breadcrumbBar

            HStack(spacing: 8) {
                Button(action: {
                    Task { await viewModel.beginUpload() }
                }) {
                    Label("上传文件", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(MCButtonStyle(.primary, compact: true))
                .disabled(!viewModel.canUpload)

                Button(action: {
                    Task { await viewModel.beginDownload() }
                }) {
                    Label("下载所选", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(MCButtonStyle(.secondary, compact: true))
                .disabled(!viewModel.canDownloadOrDeleteSelection)

                Button(action: {
                    viewModel.beginDelete()
                }) {
                    Label("删除所选", systemImage: "trash")
                }
                .buttonStyle(MCButtonStyle(.destructiveOutline, compact: true))
                .disabled(!viewModel.canDownloadOrDeleteSelection)

                Button(action: {
                    viewModel.isDrawerOpen.toggle()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.full")
                        Text("任务与账本")
                        if viewModel.attentionBadgeCount > 0 {
                            Text("\(viewModel.attentionBadgeCount)")
                                .font(.system(size: 10.5, weight: .bold))
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(MCTheme.accent))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(MCButtonStyle(.secondary, compact: true, isActive: viewModel.isDrawerOpen))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MCTheme.cardSubtle)
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("共享存储") {
                    Task { await viewModel.navigate(to: []) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: viewModel.currentComponents.isEmpty ? .semibold : .regular))
                .foregroundColor(viewModel.currentComponents.isEmpty ? MCTheme.textPrimary : MCTheme.textSecondary)

                ForEach(Array(viewModel.currentComponents.enumerated()), id: \.offset) { index, comp in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(MCTheme.textTertiary)

                    let label = ADBPathUtils.decodeEntryName(comp).displayName
                    let isLast = index == viewModel.currentComponents.count - 1
                    Button(ADBPathUtils.sanitizeControlCharactersForDisplay(label).text) {
                        let target = Array(viewModel.currentComponents.prefix(index + 1))
                        Task { await viewModel.navigate(to: target) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                    .foregroundColor(isLast ? MCTheme.textPrimary : MCTheme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .fill(MCTheme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .strokeBorder(MCTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Contextual Warning Banner

    @ViewBuilder
    private var bannerArea: some View {
        let notices = activeCapabilityNotices
        if let msg = viewModel.bannerMessage ?? notices {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(MCTheme.warning)
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(MCTheme.warning)
                        .lineLimit(2)
                    Spacer()
                    if viewModel.bannerMessage != nil {
                        Button("关闭") {
                            viewModel.bannerMessage = nil
                        }
                        .buttonStyle(MCButtonStyle(.ghost, compact: true))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(MCTheme.warningSoft)

                Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)
            }
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
                            .font(.system(size: 12.5))
                            .foregroundColor(MCTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .normal:
                    fileTableView

                case .empty:
                    statePanel(
                        icon: "folder",
                        tone: .accent,
                        title: "此文件夹为空",
                        description: "目录枚举返回空且已通过 Shell 探测确认可读。",
                        actionTitle: viewModel.canUpload ? "上传文件到当前目录" : nil
                    ) {
                        Task { await viewModel.beginUpload() }
                    }

                case .permissionDenied(let detail):
                    statePanel(
                        icon: "lock.folder",
                        tone: .warning,
                        title: "无权限访问此目录",
                        description: detail,
                        actionTitle: viewModel.canNavigateBack ? "返回上一级" : nil
                    ) {
                        Task { await viewModel.goBack() }
                    }

                case .disconnected(let reason):
                    statePanel(
                        icon: "wifi.slash",
                        tone: .danger,
                        title: "设备连接已断开",
                        description: "\(reason)。为防止跨设备误操作，窗口不会自动迁移到其他设备，请重新连接并核对。",
                        actionTitle: "重新连接并核对"
                    ) {
                        Task { await viewModel.reconnectAndVerify() }
                    }

                case .unsupportedShellV2(let detail):
                    statePanel(
                        icon: "exclamationmark.octagon",
                        tone: .danger,
                        title: "当前设备不支持所需 Shell 协议",
                        description: detail,
                        actionTitle: nil,
                        action: {}
                    )

                case .incompatibleEndpoint(let detail):
                    statePanel(
                        icon: "network.slash",
                        tone: .danger,
                        title: "ADB 端点配置不兼容",
                        description: detail,
                        actionTitle: nil,
                        action: {}
                    )

                case .error(let detail):
                    statePanel(
                        icon: "exclamationmark.triangle",
                        tone: .warning,
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
                Rectangle().fill(MCTheme.border).frame(height: 1)
                drawerView
                    .frame(height: 204)
            }
        }
    }

    private func statePanel(
        icon: String,
        tone: MCPillTone,
        title: String,
        description: String,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tone.background)
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(tone.foreground)
            }
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(MCTheme.textPrimary)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(MCTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(MCButtonStyle(.primary))
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Table

    private var fileTableView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                headerButton(.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                headerButton(.kind)
                    .frame(width: 110, alignment: .leading)
                headerButton(.size)
                    .frame(width: 100, alignment: .trailing)
                headerButton(.mtime)
                    .frame(width: 140, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MCTheme.cardSubtle)

            Rectangle().fill(MCTheme.border).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.sortedEntries) { entry in
                        FileRowView(
                            entry: entry,
                            isSelected: viewModel.selectedEntryIds.contains(entry.id),
                            kindLabel: viewModel.entryKindLabel(entry),
                            formattedSize: viewModel.formattedSize(entry),
                            formattedDate: entry.mtime.map { Self.dateFormatter.string(from: $0) } ?? "—",
                            onSelect: { additive in
                                viewModel.selectRow(entry, additive: additive)
                            },
                            onActivate: {
                                Task { await viewModel.activateEntry(entry) }
                            }
                        )
                        Rectangle()
                            .fill(MCTheme.borderSubtle)
                            .frame(height: 1)
                    }
                }
            }
        }
    }

    private func headerButton(_ col: FileManagerViewModel.SortColumn) -> some View {
        let isSorted = viewModel.sortColumn == col
        return Button(action: {
            viewModel.toggleSort(column: col)
        }) {
            HStack(spacing: 4) {
                Text(col.title)
                    .font(.system(size: 11.5, weight: .semibold))
                if isSorted {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(isSorted ? MCTheme.textPrimary : MCTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Collapsible Drawer

    private var drawerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MCUnderlineTabBar(
                    items: [
                        .init(value: FileManagerViewModel.DrawerTab.tasks, title: "任务队列 (\(viewModel.tasks.count))"),
                        .init(value: FileManagerViewModel.DrawerTab.ledger, title: "清理账本 (\(viewModel.ledgerEntries.count))")
                    ],
                    selection: $viewModel.drawerTab,
                    showBottomDivider: false
                )

                Text("全局传输槽 \(viewModel.globalActiveTransferSlots)/2")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(MCTheme.textSecondary)

                if viewModel.drawerTab == .tasks && !viewModel.tasks.isEmpty {
                    Button("清除已完成") {
                        Task { await viewModel.clearFinishedTasks() }
                    }
                    .buttonStyle(MCButtonStyle(.ghost, compact: true))
                }
            }
            .padding(.horizontal, 12)
            .background(MCTheme.cardSubtle)

            Rectangle()
                .fill(MCTheme.borderSubtle)
                .frame(height: 1)

            if viewModel.drawerTab == .tasks {
                tasksListView
            } else {
                ledgerListView
            }
        }
        .background(MCTheme.cardSubtle)
    }

    private var tasksListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !viewModel.ledgerEntries.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(MCTheme.warning)
                        Text("发现 \(viewModel.ledgerEntries.count) 条未收敛暂存清理记录，请切换至「清理账本」处理。")
                            .font(.system(size: 11.5))
                            .foregroundColor(MCTheme.warning)
                        Spacer()
                        Button("查看账本") {
                            viewModel.drawerTab = .ledger
                        }
                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                            .fill(MCTheme.warningSoft)
                    )
                }

                if viewModel.tasks.isEmpty {
                    Text("暂无传输或删除任务")
                        .font(.system(size: 12))
                        .foregroundColor(MCTheme.textTertiary)
                        .padding(.vertical, 28)
                } else {
                    ForEach(viewModel.tasks) { task in
                        taskRow(task)
                    }
                }
            }
            .padding(12)
        }
    }

    private func taskRow(_ task: ADBFileTaskSnapshot) -> some View {
        MCCard(padding: 10, radius: MCRadius.control) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        MCPillBadge(taskKindTitle(task.kind), tone: .accent)

                        Text(task.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(MCTheme.textPrimary)
                            .lineLimit(1)

                        Text(taskStateTitle(task.state))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(taskStateColor(task.state))
                    }

                    if task.kind != .delete {
                        if task.state == .transferring && !task.isSizeReliable {
                            ProgressView()
                                .progressViewStyle(.linear)
                        } else {
                            GeometryReader { geo in
                                let fraction = progressFraction(task)
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(MCTheme.controlWell)
                                        .frame(height: 4)
                                    Capsule()
                                        .fill(taskProgressColor(task.state))
                                        .frame(width: max(0, geo.size.width * fraction), height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                    }

                    Text(taskSubtitle(task))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(MCTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    if task.state == .queued || task.state == .transferring {
                        Button("取消") {
                            Task { await viewModel.cancelTask(id: task.id) }
                        }
                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                    } else if task.state == .pendingConfirmation && task.kind == .upload {
                        Button("核对结果") {
                            Task { await viewModel.verifyPendingTask(id: task.id) }
                        }
                        .buttonStyle(MCButtonStyle(.primary, compact: true))
                    } else if task.state == .completed, let localURL = task.localOutputURL {
                        Button("在 Finder 中显示") {
                            viewModel.revealInFinder(localURL)
                        }
                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                    } else if task.state == .failed || task.state == .cancelled {
                        Button("重试") {
                            Task { await viewModel.retryTask(id: task.id) }
                        }
                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                    }
                }
            }
        }
    }

    private var ledgerListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if viewModel.ledgerEntries.isEmpty {
                    Text("当前没有未收敛的暂存清理记录")
                        .font(.system(size: 12))
                        .foregroundColor(MCTheme.textTertiary)
                        .padding(.vertical, 28)
                } else {
                    ForEach(viewModel.ledgerEntries) { entry in
                        MCCard(padding: 10, radius: MCRadius.control) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(entry.tempDirName)/\(entry.tempPayloadName) → \(entry.finalTargetName)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(MCTheme.textPrimary)
                                    Text("设备 \(entry.serial) · 目录 \(entry.targetParentPhysicalPath) · 状态 \(entry.state.rawValue)")
                                        .font(.system(size: 11))
                                        .foregroundColor(MCTheme.textTertiary)
                                }
                                Spacer()
                                if entry.state == .pendingConfirmation {
                                    Button("核对结果") {
                                        Task { await viewModel.verifyPendingLedgerEntry(id: entry.id) }
                                    }
                                    .buttonStyle(MCButtonStyle(.primary, compact: true))
                                } else {
                                    Button("重试清理") {
                                        Task { await viewModel.retryLedgerCleanup(id: entry.id) }
                                    }
                                    .buttonStyle(MCButtonStyle(.secondary, compact: true))
                                }
                                Button("忽略并移除") {
                                    Task { await viewModel.dismissLedgerEntry(id: entry.id) }
                                }
                                .buttonStyle(MCButtonStyle(.ghost, compact: true))
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Status Bar

    private var statusBarView: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.boundDevice.isWifi ? "Wi-Fi" : "USB") · 物理根: \(viewModel.sessionSnapshot?.physicalRoot ?? "未解析") · 共 \(viewModel.rawEntries.count) 项 · 已选 \(viewModel.selectedEntryIds.count) 项")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(MCTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(MCTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(MCTheme.cardSubtle)
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
        case .completed: return MCTheme.success
        case .failed: return MCTheme.danger
        case .pendingConfirmation: return MCTheme.warning
        case .transferring, .committing: return MCTheme.accent
        default: return MCTheme.textSecondary
        }
    }

    private func taskProgressColor(_ state: ADBFileTaskState) -> Color {
        switch state {
        case .completed: return MCTheme.success
        case .pendingConfirmation: return MCTheme.warning
        case .failed: return MCTheme.danger
        default: return MCTheme.accent
        }
    }
}

// MARK: - Table Row

private struct FileRowView: View {
    let entry: ADBRemoteEntry
    let isSelected: Bool
    let kindLabel: String
    let formattedSize: String
    let formattedDate: String
    let onSelect: (Bool) -> Void
    let onActivate: () -> Void

    @State private var isHovered = false

    var body: some View {
        let sanitized = ADBPathUtils.sanitizeControlCharactersForDisplay(entry.displayName)

        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13.5))
                    .foregroundColor(iconColor)
                    .frame(width: 18)

                Text(sanitized.text)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(entry.isRestricted ? MCTheme.textSecondary : MCTheme.textPrimary)

                if entry.isRestricted {
                    MCPillBadge("首版不支持访问", tone: .warning)
                } else if entry.kind == .symlink {
                    MCPillBadge("符号链接", tone: .neutral)
                } else if !entry.isLosslessUTF8 {
                    MCPillBadge("非 UTF-8", tone: .danger)
                } else if sanitized.hasControlCharacters {
                    MCPillBadge("控制字符转义", tone: .neutral)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(kindLabel)
                .font(.system(size: 12))
                .foregroundColor(MCTheme.textSecondary)
                .frame(width: 110, alignment: .leading)

            Text(formattedSize)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(MCTheme.textSecondary)
                .frame(width: 100, alignment: .trailing)

            Text(formattedDate)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(MCTheme.textSecondary)
                .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? MCTheme.accentSoft : (isHovered ? MCTheme.hoverFill : Color.clear))
        .opacity(entry.isRestricted ? 0.65 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onActivate()
        }
        .onTapGesture(count: 1) {
            let additive = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            onSelect(additive)
        }
    }

    private var iconName: String {
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

    private var iconColor: Color {
        if entry.isRestricted { return MCTheme.textTertiary }
        if entry.kind == .directory { return MCTheme.accent }
        if !entry.isLosslessUTF8 { return MCTheme.danger }
        return MCTheme.textSecondary
    }
}

// MARK: - Modal Sheets

private struct BatchConflictSheet: View {
    @ObservedObject var viewModel: FileManagerViewModel
    @State var sheet: FileManagerViewModel.ConflictSheetState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现 \(sheet.rows.count) 个同名冲突")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MCTheme.textPrimary)
                Text("目标路径: \(sheet.destinationDisplayPath)")
                    .font(.system(size: 12))
                    .foregroundColor(MCTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($sheet.rows) { $row in
                            MCCard(padding: 10, radius: MCRadius.control, backgroundColor: MCTheme.cardSubtle, borderColor: MCTheme.borderSubtle) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(ADBPathUtils.sanitizeControlCharactersForDisplay(row.originalName).text)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundColor(MCTheme.textPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        if !sheet.applyAll {
                                            if row.suggestedRename != nil {
                                                Picker("", selection: $row.resolution) {
                                                    Text("保留两份").tag(ADBTransferConflictResolution.keepBoth)
                                                    Text("跳过").tag(ADBTransferConflictResolution.skip)
                                                }
                                                .labelsHidden()
                                                .frame(width: 110)
                                            } else {
                                                MCPillBadge("仅可跳过", tone: .neutral)
                                            }
                                        }
                                    }
                                    if let err = row.renameError {
                                        Text("无法保留两份（\(err)），将只能跳过")
                                            .font(.system(size: 11))
                                            .foregroundColor(MCTheme.danger)
                                    } else if let rename = row.suggestedRename {
                                        let showSkip = !sheet.applyAll && row.resolution == .skip
                                        Text(showSkip ? "将跳过此文件" : "若保留两份将重命名为: \(rename)")
                                            .font(.system(size: 11))
                                            .foregroundColor(MCTheme.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)

                Toggle("应用到本次全部冲突", isOn: $sheet.applyAll)
                    .font(.system(size: 12))
            }
            .padding(18)

            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)

            HStack(spacing: 8) {
                Button("取消") {
                    viewModel.conflictSheet = nil
                }
                .buttonStyle(MCButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

                Spacer()

                if sheet.applyAll {
                    Button("跳过冲突文件") {
                        viewModel.conflictSheet = sheet
                        Task { await viewModel.confirmConflictSheet(globalResolution: .skip) }
                    }
                    .buttonStyle(MCButtonStyle(.secondary))

                    Button("保留两份") {
                        viewModel.conflictSheet = sheet
                        Task { await viewModel.confirmConflictSheet(globalResolution: .keepBoth) }
                    }
                    .buttonStyle(MCButtonStyle(.primary))
                } else {
                    Button("按逐项选择执行") {
                        viewModel.conflictSheet = sheet
                        Task { await viewModel.confirmConflictSheet(globalResolution: nil) }
                    }
                    .buttonStyle(MCButtonStyle(.primary))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(MCTheme.cardSurface)
        .frame(width: 540)
    }
}

private struct DeleteConfirmSheet: View {
    @ObservedObject var viewModel: FileManagerViewModel
    let sheet: FileManagerViewModel.DeleteConfirmSheetState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("确认永久删除手机文件？")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MCTheme.textPrimary)
                Text("此操作直接执行非递归删除，不经过回收站，删除后无法恢复。")
                    .font(.system(size: 12))
                    .foregroundColor(MCTheme.danger)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                MCCard(padding: 12, radius: MCRadius.control, backgroundColor: MCTheme.cardSubtle, borderColor: MCTheme.borderSubtle) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标设备: \(sheet.deviceName)")
                        Text("物理目录: \(sheet.physicalDirectory)")
                        Text("删除数量: \(sheet.targets.count) 个普通文件")
                    }
                    .font(.system(size: 11.5))
                    .foregroundColor(MCTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sheet.targets.indices, id: \.self) { idx in
                            Text(ADBPathUtils.sanitizeControlCharactersForDisplay(sheet.targets[idx].remoteEntry.displayName).text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(MCTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                        .fill(MCTheme.cardSubtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                        .strokeBorder(MCTheme.borderSubtle, lineWidth: 1)
                )
            }
            .padding(18)

            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)

            HStack {
                Button("取消") {
                    viewModel.deleteConfirmSheet = nil
                }
                .buttonStyle(MCButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("永久删除") {
                    Task { await viewModel.confirmDelete() }
                }
                .buttonStyle(MCButtonStyle(.destructive))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(MCTheme.cardSurface)
        .frame(width: 480)
    }
}

private struct DeleteResultReportSheet: View {
    let results: [ADBDeleteItemResult]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("逐项删除结果报告")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MCTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(results) { item in
                        HStack {
                            Text(ADBPathUtils.sanitizeControlCharactersForDisplay(item.fileName).text)
                                .font(.system(size: 12))
                                .foregroundColor(MCTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            MCPillBadge(
                                item.message,
                                tone: item.status == .deleted ? .success : (item.status == .pendingConfirmation ? .warning : .danger)
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: MCRadius.small, style: .continuous)
                                .fill(MCTheme.cardSubtle)
                        )
                    }
                }
            }
            .frame(height: 210)
            .padding(18)

            Rectangle().fill(MCTheme.borderSubtle).frame(height: 1)

            HStack {
                Spacer()
                Button("完成", action: onClose)
                    .buttonStyle(MCButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(MCTheme.cardSurface)
        .frame(width: 480)
    }
}
