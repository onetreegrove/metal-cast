import AppKit
import MetalCastCore
import SwiftUI

@main
struct MetalCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("MetalCast 控制中心") {
            DashboardView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isCompletingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = FileManagerWindowCoordinator.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in background / menubar even if dashboard window is closed
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isCompletingTermination else { return .terminateNow }

        if !FileManagerWindowCoordinator.shared.hasActiveWork {
            SessionManager.shared.stopMirroring()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "存在进行中的手机文件操作"
        alert.informativeText = "当前有活跃传输或正在提交的文件操作。退出将取消未开始的传输，并在 5 秒内尝试清理临时文件与保存清理账本。确认退出 MetalCast？"
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "确认退出")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }

        isCompletingTermination = true
        Task { @MainActor in
            SessionManager.shared.stopMirroring()
            await ADBFileService.shared.prepareForAppTermination(timeout: 5.0)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
