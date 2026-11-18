import AppKit
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in background / menubar even if dashboard window is closed
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            SessionManager.shared.stopMirroring()
        }
    }
}
