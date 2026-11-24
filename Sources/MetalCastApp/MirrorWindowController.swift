import AppKit
import MetalKit
import MetalCastCore
import MetalCastMedia

public final class MirrorWindowController: NSWindowController, NSWindowDelegate, DockToolbarDelegate {
    public let serial: String
    public let deviceName: String
    private var initialWidth: CGFloat
    private var initialHeight: CGFloat

    private var containerView: NSView!
    public private(set) var mtkView: MirrorMTKView!
    private var renderer: MetalRenderer?
    private var toolbarView: DockToolbarView!

    private var toolbarPosition: DockToolbarPosition = .right
    private var isToolbarHidden = false
    private var activeConstraints: [NSLayoutConstraint] = []
    private var keyMonitor: Any?
    private var appResignObserver: Any?

    private let rightToolbarWidth: CGFloat = 42
    private let bottomToolbarHeight: CGFloat = 38

    public var onClose: (() -> Void)?

    public init(serial: String, deviceName: String, width: Int = 720, height: Int = 1600) {
        self.serial = serial
        self.deviceName = deviceName
        self.initialWidth = CGFloat(width)
        self.initialHeight = CGFloat(height)

        let targetVideoHeight: CGFloat = 780
        let targetVideoWidth = targetVideoHeight * (CGFloat(width) / CGFloat(height))
        let initialWindowWidth = targetVideoWidth + rightToolbarWidth
        let initialWindowHeight = targetVideoHeight

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: initialWindowWidth, height: initialWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "\(deviceName) - MetalCast"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0)

        super.init(window: window)
        window.delegate = self

        setupContent(videoWidth: targetVideoWidth, videoHeight: targetVideoHeight)
        setupKeyMonitor()
    }

    public required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        let mtk = mtkView
        DispatchQueue.main.async {
            mtk?.gameInputController.deactivateGameMode()
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let obs = appResignObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func setupContent(videoWidth: CGFloat, videoHeight: CGFloat) {
        guard let window = self.window else { return }

        containerView = NSView(frame: window.contentView?.bounds ?? .zero)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0).cgColor
        window.contentView = containerView

        // 1. Mirror MTKView - Pure Phone Video Surface
        mtkView = MirrorMTKView(frame: .zero)
        mtkView.serial = self.serial
        mtkView.inputController.deviceSize = CGSize(width: initialWidth, height: initialHeight)
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(mtkView)

        if let r = MetalRenderer(metalView: mtkView) {
            self.renderer = r
            print("✅ [MirrorWindow] MetalRenderer 初始化就绪")
        } else {
            print("❌ [MirrorWindow] MetalRenderer 初始化失败！")
        }

        // 2. Dock Toolbar View - Completely Outside MTKView
        toolbarView = DockToolbarView(position: toolbarPosition)
        toolbarView.delegate = self
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(toolbarView)

        // 3. Configure Active Game KeyMap Profile
        if let activeProf = KeyMapManager.shared.activeProfile, let preset = KeyMapManager.shared.activePreset {
            mtkView.gameInputController.setProfile(activeProf, name: preset.displayName)
            print("🎮 [MirrorWindow] 已挂载按键映射预设: \(preset.displayName)")
        }

        applyLayoutConstraints()
    }

    private func applyLayoutConstraints() {
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints.removeAll()

        toolbarView.isHidden = isToolbarHidden

        if isToolbarHidden {
            // MTKView fills the entire window
            activeConstraints = [
                mtkView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                mtkView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                mtkView.topAnchor.constraint(equalTo: containerView.topAnchor),
                mtkView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ]
        } else {
            switch toolbarPosition {
            case .right:
                activeConstraints = [
                    mtkView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    mtkView.topAnchor.constraint(equalTo: containerView.topAnchor),
                    mtkView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                    mtkView.trailingAnchor.constraint(equalTo: toolbarView.leadingAnchor),

                    toolbarView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                    toolbarView.topAnchor.constraint(equalTo: containerView.topAnchor),
                    toolbarView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                    toolbarView.widthAnchor.constraint(equalToConstant: rightToolbarWidth)
                ]

            case .bottom:
                activeConstraints = [
                    mtkView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    mtkView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                    mtkView.topAnchor.constraint(equalTo: containerView.topAnchor),
                    mtkView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor),

                    toolbarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    toolbarView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                    toolbarView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                    toolbarView.heightAnchor.constraint(equalToConstant: bottomToolbarHeight)
                ]
            }
        }

        NSLayoutConstraint.activate(activeConstraints)
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let window = self.window, window.isKeyWindow else {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Cmd + shortcuts
            if flags == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "b":
                    self.toolbarDidClickBack()
                    return nil
                case "h":
                    self.toolbarDidClickHome()
                    return nil
                case "s":
                    self.toolbarDidClickRecents()
                    return nil
                case "t":
                    self.toggleToolbarVisibility()
                    return nil
                default:
                    break
                }
            } else if flags == [.command, .shift] {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "p":
                    self.toolbarView.delegate?.toolbarDidToggleScreenPower(true)
                    return nil
                case "s":
                    self.toolbarDidClickScreenshot()
                    return nil
                default:
                    break
                }
            }

            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.mtkView.gameInputController.isGameModeActive else { return }
                self.mtkView.gameInputController.deactivateGameMode()
                self.toolbarView.setGameModeActive(false)
            }
        }
    }

    public func toggleToolbarVisibility() {
        guard let window = self.window else { return }

        isToolbarHidden.toggle()
        applyLayoutConstraints()

        var frame = window.frame
        if toolbarPosition == .right {
            let delta = isToolbarHidden ? -rightToolbarWidth : rightToolbarWidth
            frame.size.width += delta
            frame.origin.x -= delta / 2
        } else {
            let delta = isToolbarHidden ? -bottomToolbarHeight : bottomToolbarHeight
            frame.size.height += delta
            frame.origin.y -= delta / 2
        }
        window.setFrame(frame, display: true, animate: true)
    }

    public func attachConnection(_ connection: ScrcpyConnection) {
        mtkView.inputController.setConnection(connection)
    }

    public func setKeyMapProfile(_ profile: KeyMapProfile?, name: String) {
        mtkView.gameInputController.setProfile(profile, name: name)
        toolbarView.setGameModeActive(mtkView.gameInputController.isGameModeActive)
    }

    public func updateResolution(width: Int, height: Int) {
        guard height > 0 else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.initialWidth = CGFloat(width)
            self.initialHeight = CGFloat(height)
            self.mtkView.inputController.deviceSize = CGSize(width: width, height: height)

            guard let window = self.window else { return }
            let curHeight = self.currentVideoHeight(windowHeight: window.frame.height)
            let newWidth = round(curHeight * (CGFloat(width) / CGFloat(height)))
            let extraW = (self.toolbarPosition == .right && !self.isToolbarHidden) ? self.rightToolbarWidth : 0
            var frame = window.frame
            frame.size.width = newWidth + extraW
            window.setFrame(frame, display: true, animate: true)
        }
    }

    public func renderFrame(_ pixelBuffer: CVPixelBuffer) {
        renderer?.enqueueFrame(pixelBuffer)
    }

    private func currentVideoHeight(windowHeight: CGFloat) -> CGFloat {
        if toolbarPosition == .bottom && !isToolbarHidden {
            return max(100, windowHeight - bottomToolbarHeight)
        }
        return windowHeight
    }

    // MARK: - Window Delegate (Aspect Ratio Maintenance)

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard initialWidth > 0 && initialHeight > 0 else { return frameSize }

        var targetVideoHeight = frameSize.height
        if toolbarPosition == .bottom && !isToolbarHidden {
            targetVideoHeight = max(100, frameSize.height - bottomToolbarHeight)
        }

        let targetVideoWidth = round(targetVideoHeight * (initialWidth / initialHeight))

        var totalWidth = targetVideoWidth
        if toolbarPosition == .right && !isToolbarHidden {
            totalWidth += rightToolbarWidth
        }

        var totalHeight = targetVideoHeight
        if toolbarPosition == .bottom && !isToolbarHidden {
            totalHeight += bottomToolbarHeight
        }

        return NSSize(width: totalWidth, height: totalHeight)
    }

    public func windowWillClose(_ notification: Notification) {
        mtkView.gameInputController.deactivateGameMode()
        onClose?()
    }

    public func windowDidResignKey(_ notification: Notification) {
        if mtkView.gameInputController.isGameModeActive {
            mtkView.gameInputController.deactivateGameMode()
            toolbarView.setGameModeActive(false)
        }
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        if mtkView.gameInputController.isGameModeActive {
            mtkView.gameInputController.deactivateGameMode()
            toolbarView.setGameModeActive(false)
        }
    }

    // MARK: - DockToolbarDelegate

    public func toolbarDidToggleGameKeyMap() {
        mtkView.gameInputController.toggleGameMode()
        toolbarView.setGameModeActive(mtkView.gameInputController.isGameModeActive)
    }

    public func toolbarDidClickBack() {
        mtkView.inputController.sendBack()
    }

    public func toolbarDidClickHome() {
        mtkView.inputController.sendHome()
    }

    public func toolbarDidClickRecents() {
        mtkView.inputController.sendAppSwitch()
    }

    public func toolbarDidToggleScreenPower(_ isOff: Bool) {
        print("🌙 [ScreenPower] 手机屏幕物理电源: \(isOff ? "熄灭 (投屏保持)" : "点亮")")
        mtkView.inputController.setScreenPower(on: !isOff)
    }

    public func toolbarDidToggleAudioMute(_ isMuted: Bool) {
        print("🔇 [AudioMute] 音频静音状态切换: \(isMuted ? "静音" : "开启声音")")
        SessionManager.shared.setAudioMuted(isMuted)
    }

    public func toolbarDidClickVolumeUp() {
        mtkView.inputController.sendVolumeUp()
    }

    public func toolbarDidClickVolumeDown() {
        mtkView.inputController.sendVolumeDown()
    }

    public func toolbarDidClickPower() {
        mtkView.inputController.sendPower()
    }

    public func toolbarDidClickScreenshot() {
        var capturedCGImage: CGImage?

        // 1. Preferred lossless path: directly grab the full-resolution decoded CVPixelBuffer
        if let pixelBuffer = renderer?.latestFrame() {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            capturedCGImage = context.createCGImage(ciImage, from: ciImage.extent)
        }

        // 2. Fallback path if no frame buffer yet
        if capturedCGImage == nil, let window = self.window {
            let videoRect = window.convertToScreen(mtkView.convert(mtkView.bounds, to: nil))
            if let screen = window.screen {
                let screenRect = screen.frame
                let cgRect = CGRect(
                    x: videoRect.origin.x,
                    y: screenRect.height - (videoRect.origin.y + videoRect.height),
                    width: videoRect.width,
                    height: videoRect.height
                )
                capturedCGImage = CGWindowListCreateImage(cgRect, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
            }
        }

        guard let cgImage = capturedCGImage else { return }
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: imageSize)

        // 1. Copy to NSPasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])

        // 2. Save PNG to Desktop
        if let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let dateStr = formatter.string(from: Date())
            let desktopUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/MetalCast_\(dateStr).png")
            try? pngData.write(to: desktopUrl)
            print("📸 [Screenshot] 手机原画级无损截图已保存至桌面: \(desktopUrl.path) (\(cgImage.width)x\(cgImage.height))")
        }
    }

    public func toolbarDidClickFullscreen() {
        window?.toggleFullScreen(nil)
    }

    public func toolbarDidTogglePosition() {
        guard let window = self.window else { return }

        let newPosition: DockToolbarPosition = (toolbarPosition == .right) ? .bottom : .right
        self.toolbarPosition = newPosition
        toolbarView.setPosition(newPosition)

        // Adjust window dimensions smoothly
        var frame = window.frame
        if newPosition == .bottom {
            // Switched from right to bottom: remove right width, add bottom height
            frame.size.width -= rightToolbarWidth
            frame.size.height += bottomToolbarHeight
        } else {
            // Switched from bottom to right: remove bottom height, add right width
            frame.size.height -= bottomToolbarHeight
            frame.size.width += rightToolbarWidth
        }

        applyLayoutConstraints()
        window.setFrame(frame, display: true, animate: true)
    }

    public func toolbarDidClickHide() {
        toggleToolbarVisibility()
    }
}
