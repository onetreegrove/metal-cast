import AppKit
import SwiftUI

@MainActor
public final class FileManagerWindowController: NSWindowController, NSWindowDelegate {
    public let viewModel: FileManagerViewModel
    private let onClosed: (String) -> Void
    private var bypassCloseConfirmation = false

    public init(viewModel: FileManagerViewModel, onClosed: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.onClosed = onClosed

        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 160, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 820, height: 560)
        window.title = viewModel.windowTitle
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FileManagerView(viewModel: viewModel))

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassCloseConfirmation || !viewModel.hasActiveOrCommittingWork {
            Task { @MainActor in
                await viewModel.cancelWindowTasks()
            }
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "存在进行中的文件操作"
        alert.informativeText = "关闭窗口将取消未开始的传输并尝试清理当前临时文件；正在提交的指令将保留核对记录。确认关闭「\(viewModel.windowTitle)」？"
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "确认关闭")

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            return false
        }

        Task { @MainActor in
            await viewModel.cancelWindowTasks()
            self.bypassCloseConfirmation = true
            sender.close()
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        viewModel.shutdown()
        onClosed(viewModel.bindingKey)
    }
}
