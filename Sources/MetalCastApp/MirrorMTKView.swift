import AppKit
import MetalKit
import MetalCastCore
import MetalCastMedia

public final class MirrorMTKView: MTKView, NSTextInputClient {
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
        window?.makeFirstResponder(self)
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
        // 1. Preserve Command shortcuts (Cmd+C, Cmd+V, Cmd+T, Cmd+B, etc.)
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        // 2. Hardware / navigation keys
        switch event.keyCode {
        case 36: // Enter / Return
            inputController.sendKeycode(66) // AKEYCODE_ENTER
        case 51: // Delete / Backspace
            inputController.sendKeycode(67) // AKEYCODE_DEL
        case 53: // Escape
            inputController.sendBack()       // AKEYCODE_BACK (4)
        case 48: // Tab
            inputController.sendKeycode(61) // AKEYCODE_TAB
        case 49: // Space
            inputController.sendKeycode(62) // AKEYCODE_SPACE
        case 123: // Left Arrow
            inputController.sendKeycode(21) // AKEYCODE_DPAD_LEFT
        case 124: // Right Arrow
            inputController.sendKeycode(22) // AKEYCODE_DPAD_RIGHT
        case 125: // Down Arrow
            inputController.sendKeycode(20) // AKEYCODE_DPAD_DOWN
        case 126: // Up Arrow
            inputController.sendKeycode(19) // AKEYCODE_DPAD_UP
        default:
            // 3. Forward to Cocoa Text Input Manager (handles Chinese IME & direct text typing)
            interpretKeyEvents([event])
        }
    }

    // MARK: - NSTextInputClient (macOS IME & Typed Text Forwarding)

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let str = string as? String {
            text = str
        } else if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else {
            return
        }

        guard !text.isEmpty else { return }
        inputController.sendText(text)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Intermediate composing text from IME
    }

    public func unmarkText() {}

    public func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool {
        return false
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else { return .zero }
        let centerPoint = NSPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(centerPoint, to: nil)
        let screenPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        return NSRect(origin: screenPoint, size: CGSize(width: 1, height: 20))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        return 0
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
