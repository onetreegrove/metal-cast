import AppKit
import MetalCastCore

@MainActor
public final class ClipboardManager {
    public static let shared = ClipboardManager()

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var isUpdatingFromDevice = false
    private var timer: Timer?
    private weak var connection: ScrcpyConnection?

    public init() {}

    public func startMonitoring(connection: ScrcpyConnection) {
        self.connection = connection
        self.lastChangeCount = NSPasteboard.general.changeCount

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkMacClipboard()
            }
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        connection = nil
    }

    private func checkMacClipboard() {
        guard !isUpdatingFromDevice else { return }
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        print("📋 [Clipboard] 检测到 Mac 剪贴板复制: \(text.prefix(20))...")
        connection?.sendControlMessage(.setClipboard(text: text, paste: false))
    }

    public func handleDeviceClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        print("📋 [Clipboard] 收到 Android 剪贴板更新: \(text.prefix(20))...")
        isUpdatingFromDevice = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
        isUpdatingFromDevice = false
    }
}
