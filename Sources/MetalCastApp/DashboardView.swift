import MetalCastCore
import SwiftUI

public struct DashboardView: View {
    private enum WorkspaceTab: String, Hashable, Identifiable {
        case stream, keymap, capabilities
        var id: Self { self }
    }

    @ObservedObject var session = SessionManager.shared
    @ObservedObject var keyMap = KeyMapManager.shared
    @ObservedObject var fileCoordinator = FileManagerWindowCoordinator.shared

    @State private var activeTab: WorkspaceTab = .stream
    @State private var showingWirelessSheet = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebarView
                    .frame(width: 254)

                Rectangle()
                    .fill(MCTheme.border)
                    .frame(width: 1)

                workspaceView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(MCTheme.borderSubtle)
                .frame(height: 1)

            footerStatusBar
        }
        .background(MCTheme.windowBackground)
        .frame(minWidth: 880, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                MCPillBadge(
                    session.isRunning ? "投屏中" : "待机",
                    tone: session.isRunning ? .success : .neutral,
                    showDot: true
                )
            }
        }
        .onAppear {
            Task {
                await session.refreshDevices()
                keyMap.refreshPresets()
            }
        }
        .sheet(isPresented: $showingWirelessSheet) {
            WirelessConnectSheet(session: session)
        }
    }

    // MARK: - Left Sidebar (Connected Devices Only + Compact Wireless Sheet Trigger)

    private var sidebarView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("已连接设备")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MCTheme.textTertiary)
                Spacer()
                HStack(spacing: 4) {
                    Button(action: {
                        showingWirelessSheet = true
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(MCButtonStyle(.ghost, iconOnly: true))
                    .help("无线发现与手动 IP 连接")

                    Button(action: {
                        Task { await session.refreshDevices() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(MCButtonStyle(.ghost, iconOnly: true))
                    .help("刷新已连接设备")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if session.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 22))
                        .foregroundColor(MCTheme.textTertiary)
                    Text("未检测到已连接设备")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MCTheme.textSecondary)
                    Text("通过 USB 接入手机开启调试，或点击下方连接无线设备")
                        .font(.system(size: 11))
                        .foregroundColor(MCTheme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(session.devices, id: \.selectionKey) { device in
                            DeviceSidebarRow(
                                device: device,
                                isSelected: session.selectedDevice?.selectionKey == device.selectionKey
                            ) {
                                session.selectedDevice = device
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }

            VStack(spacing: 0) {
                Rectangle()
                    .fill(MCTheme.borderSubtle)
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                WirelessTriggerButton(nearbyCount: session.discoveredWirelessDevices.count) {
                    showingWirelessSheet = true
                }
                .padding(12)
            }
        }
        .background(MCTheme.sidebarBackground)
    }

    // MARK: - Right Workspace

    private var workspaceView: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroDeviceCard

            signalSummaryStrip

            VStack(spacing: 0) {
                MCUnderlineTabBar(
                    items: [
                        .init(value: .stream, title: "投屏与画质"),
                        .init(value: .keymap, title: "键鼠映射"),
                        .init(value: .capabilities, title: "系统能力与快捷")
                    ],
                    selection: $activeTab
                )

                ScrollView {
                    Group {
                        switch activeTab {
                        case .stream:
                            streamPresetTab
                        case .keymap:
                            keyMapTab
                        case .capabilities:
                            capabilitiesTab
                        }
                    }
                    .padding(.top, 14)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var heroDeviceCard: some View {
        if let device = session.selectedDevice {
            let isFileReady = device.state == .device && device.transportId != nil
            MCCard(padding: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        heroIdentityView(for: device)
                            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                        heroActionsRow(for: device, isFileReady: isFileReady)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        heroIdentityView(for: device)
                        heroActionsRow(for: device, isFileReady: isFileReady)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            MCCard(padding: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 20))
                        .foregroundColor(MCTheme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未选择操作设备")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(MCTheme.textPrimary)
                        Text("请在左侧已连接设备列表中点选一台设备，或打开无线连接与发现接入手机。")
                            .font(.system(size: 12))
                            .foregroundColor(MCTheme.textSecondary)
                    }
                    Spacer()
                    Button("无线连接与发现") {
                        showingWirelessSheet = true
                    }
                    .buttonStyle(MCButtonStyle(.secondary))
                    .fixedSize()
                }
            }
        }
    }

    private func heroIdentityView(for device: ADBDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(device.model ?? "Android 设备")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(MCTheme.textPrimary)
                    .lineLimit(1)

                MCPillBadge(
                    statusTitle(for: device.state),
                    tone: device.state == .device ? .success : .warning
                )
                .fixedSize()

                MCPillBadge(
                    device.isWifi ? "Wi-Fi 无线" : "USB 有线",
                    tone: .neutral
                )
                .fixedSize()
            }

            HStack(spacing: 6) {
                MCPillBadge(device.serial, tone: .neutral, monospaced: true)
                    .fixedSize()
                if let tid = device.transportId {
                    MCPillBadge("tid:\(tid)", tone: .neutral, monospaced: true)
                        .fixedSize()
                }
            }

            if device.state == .device && device.transportId == nil {
                Text("当前连接缺少 transport_id，请升级或重新初始化 ADB 连接后使用手机文件管理")
                    .font(.system(size: 11.5))
                    .foregroundColor(MCTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if device.state != .device {
                Text("当前设备状态为 \(device.state.rawValue)，请在手机端确认 USB 调试授权")
                    .font(.system(size: 11.5))
                    .foregroundColor(MCTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heroActionsRow(for device: ADBDevice, isFileReady: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                fileCoordinator.openOrFocus(device: device)
            }) {
                Label(
                    fileCoordinator.isWindowOpen(for: device) ? "置前文件窗口" : "手机文件",
                    systemImage: "folder"
                )
                .lineLimit(1)
            }
            .buttonStyle(MCButtonStyle(.secondary))
            .fixedSize()
            .disabled(!isFileReady)
            .help("打开独立手机文件管理窗口（不依赖投屏状态）")

            if !device.isWifi {
                Button(action: {
                    Task { await session.switchSelectedDeviceToWireless() }
                }) {
                    Label("一键切无线", systemImage: "bolt.fill")
                        .lineLimit(1)
                }
                .buttonStyle(MCButtonStyle(.secondary))
                .fixedSize()
                .disabled(device.state != .device)
                .help("自动开启 tcpip 5555 并连入无线，之后可安全拔下 USB 线")
            }

            Button(action: {
                Task {
                    if session.isRunning {
                        session.stopMirroring()
                    } else {
                        await session.startMirroring()
                    }
                }
            }) {
                Label(
                    session.isRunning ? "停止投屏" : "开启原生投屏",
                    systemImage: session.isRunning ? "stop.fill" : "play.fill"
                )
                .lineLimit(1)
            }
            .buttonStyle(MCButtonStyle(session.isRunning ? .destructive : .primary))
            .fixedSize()
            .disabled(device.state != .device && !session.isRunning)
        }
    }

    private var signalSummaryStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                signalMetricsGroup
                Spacer(minLength: 8)
                Text("VideoToolbox · Metal NV12 (0-Copy)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(MCTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack {
                signalMetricsGroup
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .fill(MCTheme.cardSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .strokeBorder(MCTheme.borderSubtle, lineWidth: 1)
        )
    }

    private var signalMetricsGroup: some View {
        HStack(spacing: 14) {
            signalMetric("分辨率", resolutionLabel(session.selectedResolution))
            signalMetric("帧率", fpsLabel(session.selectedFps))
            signalMetric("码率", "\(session.selectedBitrate / 1_000_000) Mbps")
            signalMetric("编码", session.selectedCodec == "h265" ? "H.265" : "H.264")
            signalMetric("音频", session.isAudioEnabled ? "Mac 转发" : "关闭")
            signalMetric("映射", shortKeyMapName)
        }
    }

    private func signalMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(MCTheme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(MCTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Tab 1: Stream & Quality Presets

    private var streamPresetTab: some View {
        HStack(alignment: .top, spacing: 12) {
            MCCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("画面与编码参数")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(MCTheme.textPrimary)
                        Spacer()
                        Text("即时写入下一次会话")
                            .font(.system(size: 11))
                            .foregroundColor(MCTheme.textTertiary)
                    }

                    labeledSegment("目标分辨率限制") {
                        MCSegmentedControl(
                            options: [
                                .init("原生原画", value: UInt16(0)),
                                .init("1080P", value: UInt16(1080)),
                                .init("720P", value: UInt16(720))
                            ],
                            selection: $session.selectedResolution
                        )
                    }

                    labeledSegment("最大帧率上限") {
                        MCSegmentedControl(
                            options: [
                                .init("自适应", value: UInt16(0)),
                                .init("60 fps", value: UInt16(60)),
                                .init("120 fps", value: UInt16(120))
                            ],
                            selection: $session.selectedFps
                        )
                    }

                    labeledSegment("视频比特率") {
                        MCSegmentedControl(
                            options: [
                                .init("8 Mbps", value: UInt32(8_000_000)),
                                .init("16 Mbps", value: UInt32(16_000_000)),
                                .init("32 Mbps", value: UInt32(32_000_000))
                            ],
                            selection: $session.selectedBitrate
                        )
                    }

                    labeledSegment("硬件视频编码") {
                        MCSegmentedControl(
                            options: [
                                .init("H.264（高兼容）", value: "h264"),
                                .init("H.265（省带宽）", value: "h265")
                            ],
                            selection: $session.selectedCodec
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                MCCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("音频与设备行为")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(MCTheme.textPrimary)
                            Spacer()
                            Text("投屏连接后自动应用")
                                .font(.system(size: 11))
                                .foregroundColor(MCTheme.textTertiary)
                        }

                        insetToggleRow(
                            title: "低延迟音频转发",
                            description: "将手机媒体与游戏音频通过 Mac 扬声器或耳机播放",
                            isOn: $session.isAudioEnabled
                        )

                        insetToggleRow(
                            title: "启动后自动熄灭手机屏幕",
                            description: "保持电脑端持续渲染与触控操作，显著降低手机发热",
                            isOn: $session.screenOffOnStart
                        )
                    }
                }

                MCCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("快捷操作与拖放")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(MCTheme.textPrimary)
                            Spacer()
                            Text("投屏窗口常用热键")
                                .font(.system(size: 11))
                                .foregroundColor(MCTheme.textTertiary)
                        }

                        VStack(spacing: 8) {
                            shortcutRow("收起 / 唤出工具栏", keys: ["Cmd", "T"])
                            shortcutRow("原画截图至桌面", keys: ["Cmd", "Shift", "S"])
                            shortcutRow("键鼠视角锁定", keys: ["~"])
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    Text("拖拽 APK / 普通文件")
                                        .font(.system(size: 12))
                                        .foregroundColor(MCTheme.textSecondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                    Spacer(minLength: 8)
                                    Text("静默安装或推送至 Download")
                                        .font(.system(size: 11))
                                        .foregroundColor(MCTheme.textTertiary)
                                        .lineLimit(1)
                                        .fixedSize()
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("拖拽 APK / 普通文件")
                                        .font(.system(size: 12))
                                        .foregroundColor(MCTheme.textSecondary)
                                    Text("静默安装或推送至 Download")
                                        .font(.system(size: 11))
                                        .foregroundColor(MCTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func labeledSegment<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(MCTheme.textSecondary)
            content()
        }
    }

    private func insetToggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(MCTheme.textPrimary)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(MCTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .fill(MCTheme.cardSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .strokeBorder(MCTheme.borderSubtle, lineWidth: 1)
        )
    }

    private func shortcutRow(_ label: String, keys: [String]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(MCTheme.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { idx, key in
                    if idx > 0 {
                        Text("+")
                            .font(.system(size: 11))
                            .foregroundColor(MCTheme.textTertiary)
                    }
                    MCKeyCap(key)
                }
            }
        }
    }

    // MARK: - Tab 2: Gaming KeyMap Presets

    private var keyMapTab: some View {
        VStack(spacing: 12) {
            MCCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("选择游戏 / 应用映射预设")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(MCTheme.textPrimary)
                        Spacer()
                        Button(action: openCustomKeyMapDirectory) {
                            Label("打开配置目录 JSON", systemImage: "folder")
                        }
                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                        .help("打开 ~/Library/Application Support/MetalCast/keymap 目录添加或编辑 JSON 配置文件")
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                        spacing: 10
                    ) {
                        keyMapPresetTile(
                            id: "none",
                            title: "关闭映射",
                            subtitle: "普通桌面鼠标与触控透传模式"
                        )
                        ForEach(keyMap.availablePresets) { preset in
                            keyMapPresetTile(
                                id: preset.id,
                                title: preset.displayName,
                                subtitle: keyMapDescription(for: preset.fileName)
                            )
                        }
                    }
                    .onChange(of: keyMap.selectedPresetId) { _ in
                        session.updateActiveKeyMapProfile()
                    }
                }
            }

            MCCard(padding: 12, backgroundColor: MCTheme.cardSubtle, borderColor: MCTheme.borderSubtle) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        keyMapTipLock
                        keyMapTipJoystick
                        keyMapTipRelease
                        keyMapTipToolbar
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            keyMapTipLock
                            keyMapTipJoystick
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 16) {
                            keyMapTipRelease
                            keyMapTipToolbar
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundColor(MCTheme.textSecondary)
            }
        }
    }

    private var keyMapTipLock: some View {
        HStack(spacing: 6) {
            MCKeyCap("~")
            Text("锁定 / 释放 3D 视角")
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var keyMapTipJoystick: some View {
        HStack(spacing: 6) {
            MCKeyCap("WASD")
            Text("虚拟摇杆走位")
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var keyMapTipRelease: some View {
        HStack(spacing: 6) {
            MCKeyCap("M")
            Text("/")
                .foregroundColor(MCTheme.textTertiary)
            MCKeyCap("Tab")
            Text("地图与背包自动释放鼠标")
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var keyMapTipToolbar: some View {
        HStack(spacing: 6) {
            MCKeyCap("Cmd")
            Text("+")
                .foregroundColor(MCTheme.textTertiary)
            MCKeyCap("T")
            Text("隐藏或唤出工具栏")
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func keyMapPresetTile(id: String, title: String, subtitle: String) -> some View {
        let isSelected = keyMap.selectedPresetId == id
        return Button(action: {
            keyMap.selectedPresetId = id
        }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(MCTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(MCTheme.accent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(MCTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous)
                    .fill(isSelected ? MCTheme.accentSoft : MCTheme.cardSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? MCTheme.accentBorder : MCTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 3: System Capabilities

    private var capabilitiesTab: some View {
        HStack(alignment: .top, spacing: 12) {
            capabilityCard(
                icon: "keyboard",
                title: "macOS 原生输入法直通",
                description: "支持拼音候选词与全键盘按键透传，在投屏窗口直接用 Mac 输入法聊天或输入文本。"
            )
            capabilityCard(
                icon: "doc.on.clipboard",
                title: "双向剪贴板无感同步",
                description: "Mac 复制文本、验证码或链接后自动同步至手机剪贴板，手机端复制同样即时回传。"
            )
            capabilityCard(
                icon: "square.and.arrow.down.on.square",
                title: "拖拽安装 APK 与快捷推流",
                description: "将本地 APK 拖入投屏画面自动静默安装；拖入普通文件则快速推送至手机 Download 目录。"
            )
        }
    }

    private func capabilityCard(icon: String, title: String, description: String) -> some View {
        MCCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(MCTheme.accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(MCTheme.textPrimary)
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundColor(MCTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bottom Status Bar

    private var footerStatusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.isRunning ? MCTheme.success : MCTheme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(session.statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(MCTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("已接入 \(session.devices.count) 台 · 附近无线 \(session.discoveredWirelessDevices.count) 台")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(MCTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(MCTheme.cardSubtle)
    }

    // MARK: - Helpers

    private func statusTitle(for state: ADBDevice.DeviceState) -> String {
        switch state {
        case .device: return "已授权在线"
        case .unauthorized: return "未授权"
        case .offline: return "离线"
        case .recovery: return "Recovery"
        case .bootloader: return "Bootloader"
        case .unknown: return "未知状态"
        }
    }

    private func resolutionLabel(_ maxRes: UInt16) -> String {
        maxRes == 0 ? "原生原画" : "\(maxRes)P"
    }

    private func fpsLabel(_ fps: UInt16) -> String {
        fps == 0 ? "自适应" : "\(fps) fps"
    }

    private var shortKeyMapName: String {
        guard let preset = keyMap.activePreset else { return "关闭" }
        return preset.displayName.split(separator: "/").first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? preset.displayName
    }

    private func keyMapDescription(for fileName: String) -> String {
        switch fileName.lowercased() {
        case "gameforpeace.json":
            return "WASD 摇杆、~ 锁定无边界视角、M 地图自动释放鼠标"
        case "tiktok.json":
            return "方向键上下切换短视频、热键快速点赞"
        case "identityv.json":
            return "多点触控与视角协同映射配置"
        case "frag.json":
            return "FPS 左键开火、右键开镜与走位预设"
        case "test.json":
            return "用于测试多点触控与拖拽轨迹的调试配置"
        default:
            return "用户自定义 JSON 按键映射配置文件"
        }
    }

    private func openCustomKeyMapDirectory() {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("MetalCast/keymap")
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
            keyMap.refreshPresets()
        }
    }
}

// MARK: - Sidebar Views

private struct DeviceSidebarRow: View {
    let device: ADBDevice
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    private var badgeTitle: String {
        switch device.state {
        case .device: return device.isWifi ? "Wi-Fi" : "USB"
        case .unauthorized: return "未授权"
        case .offline: return "离线"
        case .recovery: return "Recovery"
        case .bootloader: return "Bootloader"
        case .unknown: return "未知"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? MCTheme.accent : MCTheme.controlWell)
                    Image(systemName: device.isWifi ? "wifi" : "iphone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : MCTheme.textSecondary)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.model ?? "Android 设备")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(MCTheme.textPrimary)
                        .lineLimit(1)
                    Text(device.serial)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(MCTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(badgeTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(device.state == .device ? MCTheme.textSecondary : MCTheme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(device.state == .device ? MCTheme.controlWell : MCTheme.warningSoft)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                    .fill(isSelected ? MCTheme.accentSoft : (isHovered ? MCTheme.hoverFill : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                    .strokeBorder(isSelected ? MCTheme.accentBorder : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct WirelessTriggerButton: View {
    let nearbyCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "wifi")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MCTheme.textSecondary)
                    Text("无线连接与发现")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MCTheme.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    MCPillBadge(
                        nearbyCount > 0 ? "\(nearbyCount) 附近" : "无广播",
                        tone: nearbyCount > 0 ? .success : .neutral,
                        showDot: nearbyCount > 0
                    )
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(MCTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                        .fill(MCTheme.cardSurface)
                    RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                        .fill(isHovered ? MCTheme.hoverFill : Color.clear)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                    .strokeBorder(isHovered ? MCTheme.borderStrong : MCTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Unified Wireless Discovery + Manual IP Sheet

private struct WirelessConnectSheet: View {
    @ObservedObject var session: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var wifiIpInput = ""
    @State private var wifiPortInput = "5555"
    @State private var pairingTarget: DiscoveredWirelessDevice?
    @State private var pairCodeInput = ""
    @State private var isSubmittingPair = false
    @State private var isConnecting = false
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    private var isManualIpValid: Bool {
        let trimmed = wifiIpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasSuffix(".")
    }

    private var parsedManualPort: Int? {
        let trimmed = wifiPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
        return port
    }

    private var isManualEndpointValid: Bool {
        isManualIpValid && parsedManualPort != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(MCTheme.accent)
                    Text("无线连接与局域网发现")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(MCTheme.textPrimary)
                }
                Text("局域网 mDNS 自动发现配对与手动 IP 连接统一收口在此面板，不占用主侧栏空间。")
                    .font(.system(size: 12))
                    .foregroundColor(MCTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle()
                .fill(MCTheme.borderSubtle)
                .frame(height: 1)

            ViewThatFits(in: .vertical) {
                sheetBodyContent
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    sheetBodyContent
                }
                .frame(height: 460)
            }
            .frame(maxHeight: 460)

            Rectangle()
                .fill(MCTheme.borderSubtle)
                .frame(height: 1)

            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(MCButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(MCTheme.cardSurface)
        .frame(width: 540)
        .onAppear {
            if session.discoveredWirelessDevices.isEmpty {
                Task { await session.scanWirelessDevices() }
            }
        }
        .onChange(of: session.discoveredWirelessDevices.map(\.id)) { ids in
            if let target = pairingTarget, !ids.contains(target.id) {
                pairingTarget = nil
                pairCodeInput = ""
            }
        }
    }

    private var sheetBodyContent: some View {
        VStack(spacing: 12) {
            // Section 1: mDNS Auto-Discovery
            MCCard(padding: 14, backgroundColor: MCTheme.cardSubtle, borderColor: MCTheme.borderSubtle) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("局域网无线发现（mDNS / Bonjour）")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(MCTheme.textPrimary)
                            Text("手机开启「开发者选项 → 无线调试」后自动显现")
                                .font(.system(size: 11))
                                .foregroundColor(MCTheme.textTertiary)
                        }
                        Spacer()
                        Button(action: {
                            Task { await session.scanWirelessDevices() }
                        }) {
                            HStack(spacing: 5) {
                                if session.isScanningWireless {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("重新扫描")
                            }
                        }
                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                        .disabled(session.isScanningWireless || isConnecting || isSubmittingPair)
                    }

                    if session.discoveredWirelessDevices.isEmpty {
                        HStack {
                            Spacer()
                            Text("暂未发现局域网无线调试广播")
                                .font(.system(size: 12))
                                .foregroundColor(MCTheme.textTertiary)
                                .padding(.vertical, 12)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 6) {
                            ForEach(session.discoveredWirelessDevices) { dev in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(dev.isPairing ? MCTheme.warning : MCTheme.success)
                                        .frame(width: 7, height: 7)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dev.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(MCTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(dev.address)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(MCTheme.textTertiary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if dev.isPairing {
                                        Button("配对") {
                                            pairingTarget = dev
                                            pairCodeInput = ""
                                            feedbackMessage = nil
                                        }
                                        .buttonStyle(MCButtonStyle(.secondary, compact: true))
                                        .disabled(isConnecting || isSubmittingPair)
                                    } else {
                                        Button("连接") {
                                            isConnecting = true
                                            feedbackMessage = nil
                                            Task {
                                                let ok = await session.connectDiscoveredWirelessDevice(dev)
                                                isConnecting = false
                                                if ok {
                                                    dismiss()
                                                } else {
                                                    feedbackIsError = true
                                                    feedbackMessage = session.statusMessage
                                                }
                                            }
                                        }
                                        .buttonStyle(MCButtonStyle(.primary, compact: true))
                                        .disabled(isConnecting || isSubmittingPair)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                                        .fill(MCTheme.cardSurface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                                        .strokeBorder(MCTheme.borderSubtle, lineWidth: 1)
                                )
                            }
                        }
                    }

                    if let target = pairingTarget {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("正在配对：\(target.displayName) (\(target.address))")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(MCTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Button("取消配对") {
                                    pairingTarget = nil
                                    pairCodeInput = ""
                                }
                                .buttonStyle(MCButtonStyle(.ghost, compact: true))
                                .disabled(isSubmittingPair)
                            }

                            HStack(alignment: .bottom, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("6 位无线配对码")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(MCTheme.textSecondary)
                                    TextField("输入手机显示的 6 位配对码", text: $pairCodeInput)
                                        .font(.system(size: 13, design: .monospaced))
                                        .mcInputField(height: 32)
                                }

                                Button {
                                    let code = pairCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !code.isEmpty else { return }
                                    isSubmittingPair = true
                                    feedbackMessage = nil
                                    Task {
                                        let ok = await session.pairWirelessDevice(address: target.address, code: code)
                                        isSubmittingPair = false
                                        if ok {
                                            pairingTarget = nil
                                            pairCodeInput = ""
                                            feedbackIsError = false
                                            feedbackMessage = "已完成配对 \(target.address)"
                                        } else {
                                            feedbackIsError = true
                                            feedbackMessage = session.statusMessage
                                        }
                                    }
                                } label: {
                                    Text(isSubmittingPair ? "配对中…" : "立即配对")
                                        .frame(minHeight: 18)
                                }
                                .buttonStyle(MCButtonStyle(.primary))
                                .disabled(pairCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingPair || isConnecting)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                                .fill(MCTheme.cardSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                                .strokeBorder(MCTheme.accentBorder, lineWidth: 1)
                        )
                    }
                }
            }

            // Section 2: Manual IP Connect
            MCCard(padding: 14, backgroundColor: MCTheme.cardSubtle, borderColor: MCTheme.borderSubtle) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("手动输入 IP 连接")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(MCTheme.textPrimary)
                        Text("适用于已知 IP 的 tcpip 5555 或固定端口设备")
                            .font(.system(size: 11))
                            .foregroundColor(MCTheme.textTertiary)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("IP 地址")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(MCTheme.textSecondary)
                            TextField("例如 192.168.1.50", text: $wifiIpInput)
                                .font(.system(size: 12.5, design: .monospaced))
                                .mcInputField(height: 32)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("端口")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(MCTheme.textSecondary)
                            TextField("5555", text: $wifiPortInput)
                                .font(.system(size: 12.5, design: .monospaced))
                                .mcInputField(height: 32)
                        }
                        .frame(width: 90)

                        Button {
                            let ip = wifiIpInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !ip.isEmpty, !ip.hasSuffix("."), let port = parsedManualPort else { return }
                            isConnecting = true
                            feedbackMessage = nil
                            Task {
                                let ok = await session.connectWifi(ip: ip, port: port)
                                isConnecting = false
                                if ok {
                                    dismiss()
                                } else {
                                    feedbackIsError = true
                                    feedbackMessage = session.statusMessage
                                }
                            }
                        } label: {
                            Text(isConnecting ? "连接中…" : "连接")
                                .frame(minHeight: 18)
                        }
                        .buttonStyle(MCButtonStyle(.primary))
                        .disabled(!isManualEndpointValid || isConnecting || isSubmittingPair)
                    }
                }
            }

            if let msg = feedbackMessage {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundColor(feedbackIsError ? MCTheme.danger : MCTheme.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
    }
}
