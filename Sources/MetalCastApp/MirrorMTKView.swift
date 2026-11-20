import AppKit
import MetalKit
import MetalCastCore
import MetalCastMedia

public final class MirrorMTKView: MTKView, NSTextInputClient {
    public let inputController = InputController()
    public let gameInputController = GameInputController()
    public let hudView = GameKeyMapHUDView()

    public var serial: String = ""
    private var markedTextStorage: String = ""
    private var trackingArea: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.wantsLayer = true
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        setupDragAndDrop()

        gameInputController.inputController = inputController

        // Setup Floating Keymap HUD Overlay
        hudView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hudView)

        NSLayoutConstraint.activate([
            hudView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            hudView.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])

        gameInputController.onHUDMessage = { [weak self] message in
            guard let self = self else { return }
            let isActive = self.gameInputController.isGameModeActive
            let isTempReleased = self.gameInputController.isCursorTemporarilyReleased
            let autoHide: TimeInterval? = isActive ? (isTempReleased ? nil : 4.0) : 2.5
            self.hudView.show(
                message: message,
                isActive: isActive,
                isTemporaryReleased: isTempReleased,
                autoHideDelay: autoHide
            )
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
        window?.acceptsMouseMovedEvents = true
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if gameInputController.handleMouseDown(button: 0) {
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleMouseDown(at: location, in: bounds.size)
    }

    public override func mouseUp(with event: NSEvent) {
        if gameInputController.handleMouseUp(button: 0) {
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleMouseUp(at: location, in: bounds.size)
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if gameInputController.handleMouseDown(button: 1) {
            return
        }
        // Normal mode: Right click defaults to Android BACK button
        inputController.sendBack()
    }

    public override func rightMouseUp(with event: NSEvent) {
        if gameInputController.handleMouseUp(button: 1) {
            return
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if gameInputController.handleMouseDown(button: event.buttonNumber) {
            return
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if gameInputController.handleMouseUp(button: event.buttonNumber) {
            return
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        if gameInputController.handleMouseMove(deltaX: event.deltaX, deltaY: event.deltaY) {
            return
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if gameInputController.isGameModeActive && !gameInputController.isCursorTemporarilyReleased {
            if gameInputController.handleMouseMove(deltaX: event.deltaX, deltaY: event.deltaY) {
                return
            }
        }
        let location = convert(event.locationInWindow, from: nil)
        inputController.handleMouseDragged(to: location, in: bounds.size)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if gameInputController.isGameModeActive && !gameInputController.isCursorTemporarilyReleased {
            if gameInputController.handleMouseMove(deltaX: event.deltaX, deltaY: event.deltaY) {
                return
            }
        }
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if gameInputController.isGameModeActive && !gameInputController.isCursorTemporarilyReleased {
            if gameInputController.handleMouseMove(deltaX: event.deltaX, deltaY: event.deltaY) {
                return
            }
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if gameInputController.isGameModeActive && !gameInputController.isCursorTemporarilyReleased {
            return
        }
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

        // 2. Intercept keys in Game Mode (WASD, hotkeys, switchKey ~)
        if gameInputController.handleKeyDown(with: event) {
            return
        }

        // 3. If IME is composing, let Cocoa IME handle all keys (including Space, Enter, Backspace)
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        // 4. Hardware / navigation keys when NOT composing in IME
        switch event.keyCode {
        case 36: // Enter / Return
            inputController.sendKeycode(66) // AKEYCODE_ENTER
        case 51: // Delete / Backspace
            inputController.sendKeycode(67) // AKEYCODE_DEL
        case 53: // Escape
            inputController.sendBack()       // AKEYCODE_BACK (4)
        case 48: // Tab
            inputController.sendKeycode(61) // AKEYCODE_TAB
        case 123: // Left Arrow
            inputController.sendKeycode(21) // AKEYCODE_DPAD_LEFT
        case 124: // Right Arrow
            inputController.sendKeycode(22) // AKEYCODE_DPAD_RIGHT
        case 125: // Down Arrow
            inputController.sendKeycode(20) // AKEYCODE_DPAD_DOWN
        case 126: // Up Arrow
            inputController.sendKeycode(19) // AKEYCODE_DPAD_UP
        default:
            // 5. Forward to Cocoa Text Input Manager (handles letters, digits, punctuation, and IME activation)
            interpretKeyEvents([event])
        }
    }

    public override func keyUp(with event: NSEvent) {
        if gameInputController.handleKeyUp(with: event) {
            return
        }
        super.keyUp(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let flags = event.modifierFlags

        switch event.keyCode {
        case 58, 61: // Option / Alt (e.g. SmallEyes free look)
            let isPressed = flags.contains(.option)
            if isPressed {
                _ = gameInputController.handleKeyDown(with: event)
            } else {
                _ = gameInputController.handleKeyUp(with: event)
            }
        case 56, 60: // Shift
            let isPressed = flags.contains(.shift)
            if isPressed {
                _ = gameInputController.handleKeyDown(with: event)
            } else {
                _ = gameInputController.handleKeyUp(with: event)
            }
        case 59, 62: // Control
            let isPressed = flags.contains(.control)
            if isPressed {
                _ = gameInputController.handleKeyDown(with: event)
            } else {
                _ = gameInputController.handleKeyUp(with: event)
            }
        default:
            break
        }
    }

    // MARK: - NSTextInputClient (macOS IME & Typed Text Forwarding)

    public func insertText(_ string: Any, replacementRange: NSRange) {
        markedTextStorage = ""
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
        if let str = string as? String {
            markedTextStorage = str
        } else if let attrStr = string as? NSAttributedString {
            markedTextStorage = attrStr.string
        }
    }

    public func unmarkText() {
        markedTextStorage = ""
    }

    public func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        return markedTextStorage.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedTextStorage as NSString).length)
    }

    public func hasMarkedText() -> Bool {
        return !markedTextStorage.isEmpty
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
