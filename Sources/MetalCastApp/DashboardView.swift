import SwiftUI
import MetalCastCore

public struct DashboardView: View {
    @ObservedObject var session = SessionManager.shared

    @State private var showingWifiDialog = false
    @State private var wifiIpInput = "192.168.1."

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Sidebar (Device List)
            VStack(alignment: .leading, spacing: 12) {
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
                    .help("刷新设备列表")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                List(session.devices, id: \.serial, selection: $session.selectedDevice) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.isWifi ? "wifi" : "iphone")
                            .font(.system(size: 16))
                            .foregroundColor(device.state.isAvailable ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.model ?? "Android 设备")
                                .font(.system(size: 13, weight: .medium))
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
                    .padding(.vertical, 4)
                }
                .listStyle(.sidebar)

                Divider()

                Button(action: {
                    showingWifiDialog = true
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("连接无线设备")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(width: 220)
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
                            Text("状态: \(device.state.rawValue) · 序列号: \(device.serial)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()

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
        .frame(width: 700, height: 520)
        .onAppear {
            Task {
                await session.refreshDevices()
            }
        }
        .sheet(isPresented: $showingWifiDialog) {
            VStack(spacing: 16) {
                Text("连接无线 Android 设备")
                    .font(.headline)

                TextField("手机 IP 地址 (默认端口 5555)", text: $wifiIpInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                HStack {
                    Button("取消") {
                        showingWifiDialog = false
                    }
                    Button("连接") {
                        showingWifiDialog = false
                        Task {
                            await session.connectWifi(ip: wifiIpInput)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }
}
