import AppKit
import MetalKit
import MetalCastCore
import MetalCastMedia

public final class MirrorMTKView: MTKView {
    public let inputController = InputController()
    public var serial: String = ""

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        self.wantsLayer = true
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        setupDragAndDrop()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        setupDragAndDrop()
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleMouseDown(at: location, in: bounds.size)
    }

    public override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleMouseDragged(to: location, in: bounds.size)
    }

    public override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleMouseUp(at: location, in: bounds.size)
    }

    public override func rightMouseDown(with event: NSEvent) {
        // Right click defaults to Android BACK button
        inputController.sendBack()
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleScroll(at: location, in: bounds.size, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }

    // MARK: - Keyboard & Text Events

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Enter
            inputController.sendHome() // or Enter keycode 66
        case 51: // Delete / Backspace
            // AKEYCODE_DEL = 67
            inputController.sendBack()
        case 53: // Escape
            inputController.sendBack()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drag and Drop (File push & APK silent install)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pboard = sender.draggingPasteboard
        if pboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !items.isEmpty, !serial.isEmpty else {
            return false
        }

        for fileUrl in items {
            let path = fileUrl.path
            let filename = fileUrl.lastPathComponent

            Task {
                if fileUrl.pathExtension.lowercased() == "apk" {
                    print("📦 [Drag&Drop] 正在静默安装 APK: \(filename) ...")
                    do {
                        try await ADBManager.shared.installApk(serial: self.serial, apkPath: path)
                        print("✅ [Drag&Drop] APK 安装成功: \(filename)")
                    } catch {
                        print("❌ [Drag&Drop] APK 安装失败: \(error.localizedDescription)")
                    }
                } else {
                    let remoteDestination = "/sdcard/Download/\(filename)"
                    print("📤 [Drag&Drop] 正在推送文件到 Android 手机: \(remoteDestination) ...")
                    do {
                        try await ADBManager.shared.push(serial: self.serial, localPath: path, remotePath: remoteDestination)
                        print("✅ [Drag&Drop] 文件推送成功: \(filename)")
                    } catch {
                        print("❌ [Drag&Drop] 文件推送失败: \(error.localizedDescription)")
                    }
                }
            }
        }
        return true
    }
}
