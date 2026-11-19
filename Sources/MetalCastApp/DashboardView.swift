import SwiftUI
import MetalCastCore

public struct DashboardView: View {
    @ObservedObject var session = SessionManager.shared

    @State private var showingWifiDialog = false
    @State private var wifiIpInput = "192.168.1."
    @State private var wifiPortInput = "5555"

    @State private var showingPairDialog = false
    @State private var pairTargetAddress = ""
    @State private var pairCodeInput = ""

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Sidebar (Device List & Wireless Auto-Discovery)
            VStack(alignment: .leading, spacing: 10) {
                // Section 1: Connected Devices
                HStack {
                    Text("已连接设备")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        Task { await session.refreshDevices() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("刷新已连接设备")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                List(session.devices, id: \.serial, selection: $session.selectedDevice) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.isWifi ? "wifi" : "iphone")
                            .font(.system(size: 15))
                            .foregroundColor(device.state.isAvailable ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.model ?? "Android 设备")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(device.serial)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(device.isWifi ? "Wi-Fi" : "USB")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(4)
                    }
                    .tag(device)
                    .padding(.vertical, 2)
                }
                .listStyle(.sidebar)
                .frame(maxHeight: 180)

                Divider()

                // Section 2: Wireless Auto-Discovery (mDNS / Bonjour)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                        Text("局域网无线发现")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if session.isScanningWireless {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Button(action: {
                                Task { await session.scanWirelessDevices() }
                            }) {
                                Image(systemName: "sparkle.magnifyingglass")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("主动扫描局域网无线调试广播")
                        }
                    }
                    .padding(.horizontal, 14)

                    if session.discoveredWirelessDevices.isEmpty {
                        VStack(spacing: 6) {
                            Text("未发现无线广播")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("手机开启【开发者选项->无线调试】后在此自动显现")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(session.discoveredWirelessDevices) { dev in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(dev.isPairing ? Color.orange : Color.green)
                                            .frame(width: 7, height: 7)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(dev.displayName)
                                                .font(.system(size: 11, weight: .medium))
                                                .lineLimit(1)
                                            Text(dev.address)
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }

                                        Spacer()

                                        if dev.isPairing {
                                            Button("配对") {
                                                pairTargetAddress = dev.address
                                                pairCodeInput = ""
                                                showingPairDialog = true
                                            }
                                            .font(.system(size: 10, weight: .semibold))
                                            .buttonStyle(.borderedProminent)
                                            .tint(.orange)
                                            .controlSize(.small)
                                        } else {
                                            Button("连接") {
                                                Task {
                                                    await session.connectDiscoveredWirelessDevice(dev)
                                                }
                                            }
                                            .font(.system(size: 10, weight: .semibold))
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.04))
                                    .cornerRadius(6)
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                }

                Divider()

                // Manual Wireless Connect
                Button(action: {
                    showingWifiDialog = true
                }) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("手动输入 IP 连接")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .frame(width: 230)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))

            Divider()

            // MARK: - Right Main Panel
            VStack(alignment: .leading, spacing: 18) {
                // Device Summary Hero Card
                if let device = session.selectedDevice {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.model ?? "Android 设备")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("状态: \(device.state.rawValue) · 模式: \(device.isWifi ? "Wi-Fi 无线" : "USB 有线") · 序列号: \(device.serial)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()

                        // One-click switch USB to wireless if USB connected
                        if !device.isWifi {
                            Button(action: {
                                Task {
                                    await session.switchSelectedDeviceToWireless()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                    Text("一键切无线")
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
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
                            HStack {
                                Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                                Text(session.isRunning ? "停止投屏" : "开启原生投屏")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(session.isRunning ? .red : .accentColor)
                    }
                    .padding(16)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                } else {
                    HStack {
                        Text("未选择设备，请在左侧列表中点击选择")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding()
                }

                // Presets & Settings Group
                VStack(alignment: .leading, spacing: 14) {
                    Text("画质与流参数预设")
                        .font(.headline)

                    HStack {
                        Text("目标分辨率限制")
                            .frame(width: 140, alignment: .leading)
                        Picker("", selection: $session.selectedResolution) {
                            Text("原生原画").tag(UInt16(0))
                            Text("1080P").tag(UInt16(1080))
                            Text("720P").tag(UInt16(720))
                        }
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("最大帧率上限")
                            .frame(width: 140, alignment: .leading)
                        Picker("", selection: $session.selectedFps) {
                            Text("自适应 (推荐)").tag(UInt16(0))
                            Text("60 fps").tag(UInt16(60))
                            Text("120 fps (高刷)").tag(UInt16(120))
                        }
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("视频比特率")
                            .frame(width: 140, alignment: .leading)
                        Picker("", selection: $session.selectedBitrate) {
                            Text("8 Mbps").tag(UInt32(8_000_000))
                            Text("16 Mbps (推荐)").tag(UInt32(16_000_000))
                            Text("32 Mbps").tag(UInt32(32_000_000))
                        }
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("硬件视频编码")
                            .frame(width: 140, alignment: .leading)
                        Picker("", selection: $session.selectedCodec) {
                            Text("H.264 (兼容性高)").tag("h264")
                            Text("H.265 / HEVC (省50%带宽)").tag("h265")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)

                // Native macOS Features
                VStack(alignment: .leading, spacing: 12) {
                    Text("核心体验与原生功能")
                        .font(.headline)

                    Toggle("低延迟音频转发（手机声音通过 Mac 扬声器/耳机输出）", isOn: $session.isAudioEnabled)
                        .toggleStyle(.switch)

                    Toggle("投屏启动后自动熄灭手机屏幕（省电降温，投屏持续）", isOn: $session.screenOffOnStart)
                        .toggleStyle(.switch)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("macOS 原生中文输入法与全键盘直通（支持拼音输入与全按键透传）")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("双向剪贴板无感同步（NSPasteboard 实时互通）")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("拖拽静默安装 APK 与拖拽推流到 /sdcard/Download/")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)

                Spacer()

                // Footer Status Bar
                HStack {
                    Circle()
                        .fill(session.isRunning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(session.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("VideoToolbox + Metal NV12 (0-Copy)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: 560)
        .onAppear {
            Task {
                await session.refreshDevices()
            }
        }
        // Manual Wi-Fi Connect Sheet
        .sheet(isPresented: $showingWifiDialog) {
            VStack(spacing: 16) {
                Text("手动连接无线设备")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("IP 地址:")
                        .font(.caption)
                    TextField("例如 192.168.1.50", text: $wifiIpInput)
                        .textFieldStyle(.roundedBorder)

                    Text("端口 (默认 5555):")
                        .font(.caption)
                    TextField("5555", text: $wifiPortInput)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(width: 260)

                HStack {
                    Button("取消") {
                        showingWifiDialog = false
                    }
                    Button("连接") {
                        showingWifiDialog = false
                        let port = Int(wifiPortInput) ?? 5555
                        Task {
                            await session.connectWifi(ip: wifiIpInput, port: port)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        // Android 11+ Wireless Debugging Pairing Sheet
        .sheet(isPresented: $showingPairDialog) {
            VStack(spacing: 16) {
                Text("无线调试配对")
                    .font(.headline)

                Text("配对目标: \(pairTargetAddress)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("在手机【开发者选项 -> 无线调试】中点击【使用配对码配对设备】，在此输入 6 位配对码：")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    TextField("6 位配对码 (如 123456)", text: $pairCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .frame(width: 280)

                HStack {
                    Button("取消") {
                        showingPairDialog = false
                    }
                    Button("立即配对") {
                        showingPairDialog = false
                        let target = pairTargetAddress
                        let code = pairCodeInput
                        Task {
                            _ = await session.pairWirelessDevice(address: target, code: code)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pairCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }
}
