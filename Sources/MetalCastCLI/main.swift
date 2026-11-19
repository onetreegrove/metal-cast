import Foundation
import AppKit
import MetalKit
import CoreMedia
import VideoToolbox
import MetalCastCore
import MetalCastMedia

@main
struct MetalCastCLI {
    static func main() async {
        print("==================================================")
        print("    MetalCast 核心引擎里程碑 (M1 & M2) 验证测试    ")
        print("==================================================")

        let testView = MTKView(frame: CGRect(x: 0, y: 0, width: 720, height: 1600))
        if MetalRenderer(metalView: testView) != nil {
            print("🎨 [MetalRenderer] 初始化成功！")
        } else {
            print("❌ [MetalRenderer] 初始化失败！返回了 nil")
        }

        let adbRunner = ADBProcessRunner.shared
        let adbPath = adbRunner.resolveAdbPath()
        print(">>> [ADB] 探测到 ADB 路径: \(adbPath)")

        let manager = ADBManager.shared
        do {
            print(">>> [ADB] 正在扫描已连接的 Android 设备...")
            let devices = try await manager.getDevices()

            guard let device = devices.first(where: { $0.state == .device }) else {
                print("⚠️ [ADB] 未发现可用的 Android 设备 (状态为 device)。")
                return
            }

            print("✅ [ADB] 锁定目标设备: \(device.model ?? "Android") (序列号: \(device.serial))")

            // 1. 定位本地 scrcpy-server.jar
            let serverLocalPath = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/scrcpy-server").path

            guard FileManager.default.fileExists(atPath: serverLocalPath) else {
                print("❌ [Resources] 未找到本地 scrcpy-server 资源文件: \(serverLocalPath)")
                return
            }

            let serverRemotePath = "/data/local/tmp/scrcpy-server.jar"
            print(">>> [ADB] 正在向设备推送服务端: \(serverRemotePath) ...")
            try await manager.push(serial: device.serial, localPath: serverLocalPath, remotePath: serverRemotePath)
            print("✅ [ADB] 服务端推送成功！")

            // 2. 配置 ADB 隧道 (Reverse: 设备 localabstract:scrcpy_20261117 -> Mac tcp:27199)
            let scid: UInt32 = 0x20261117
            let socketName = String(format: "scrcpy_%08x", scid)
            let localPort: UInt16 = 27199
            print(">>> [ADB] 配置反向隧道: localabstract:\(socketName) -> tcp:\(localPort) ...")
            try await manager.reverse(serial: device.serial, remoteSocket: socketName, localPort: localPort)
            print("✅ [ADB] 反向隧道建立成功！")

            // 3. 准备解码流水线 (Annex-B -> VTDecoder)
            let parser = AnnexBParser()
            let decoder = VTDecoder()

            var frameCount = 0

            decoder.onPixelBuffer = { pixelBuffer in
                frameCount += 1
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                if frameCount % 30 == 0 || frameCount == 1 {
                    print("🎬 [VideoToolbox] 成功硬解第 \(frameCount) 帧画面! 分辨率: \(w)x\(h) (NV12)")
                }
            }

            parser.onFormatDescription = { formatDesc in
                let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
                print("📐 [AnnexBParser] 提取到 SPS/PPS 参数集, 物理尺寸: \(dimensions.width)x\(dimensions.height)")
                decoder.updateFormatDescription(formatDesc)
            }

            parser.onSampleBuffer = { sampleBuffer in
                decoder.decode(sampleBuffer: sampleBuffer)
            }

            // 4. 启动本地 TCP 监听
            let connection = ScrcpyConnection(port: localPort)
            connection.onDeviceName = { name, codec, w, h in
                print("🎉 [Scrcpy] 成功握手设备: \(name) (\(codec), \(w)x\(h))")
            }

            connection.onVideoData = { chunk in
                parser.parse(chunk: chunk)
            }

            connection.onDeviceMessage = { msg in
                switch msg {
                case .clipboard(let text):
                    print("📋 [Android] 收到剪贴板同步: \(text)")
                default:
                    break
                }
            }

            connection.onDisconnected = {
                print("🛑 [Scrcpy] 设备连接中断。")
            }

            try await connection.startListening()
            print("✅ [Network] 本地 TCP 服务监听已就绪")

            // 5. 启动设备端 scrcpy-server
            print(">>> [Server] 正在拉起 Android 端 scrcpy-server ...")
            let serverProcess = try await manager.executeServer(
                serial: device.serial,
                serverRemotePath: serverRemotePath,
                maxSize: 0,
                bitRate: 16_000_000,
                maxFps: 60,
                scid: scid,
                onLog: { log in
                    let clean = log.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        print("📱 [Server Log] \(clean)")
                    }
                }
            )

            print("🚀 [Run] 引擎开始运行并采集流数据 (测试将运行 6 秒)...")
            try await Task.sleep(nanoseconds: 6_000_000_000)

            print("\n==================================================")
            print("🏁 测试结束统计:")
            print("   累计接收并硬解帧数: \(frameCount) 帧")
            print("   平均实时帧率: \(frameCount / 6) FPS")
            print("   硬件解码器: VideoToolbox NV12 Zero-Copy")
            print("==================================================")

            connection.stop()
            serverProcess.terminate()
            try? await manager.removeReverse(serial: device.serial, remoteSocket: socketName)

        } catch {
            print("❌ [Error] 发生异常: \(error.localizedDescription)")
        }
    }
}
