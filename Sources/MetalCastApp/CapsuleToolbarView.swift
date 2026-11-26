import AppKit

public enum DockToolbarPosition: Sendable {
    case right
    case bottom
}

public protocol DockToolbarDelegate: AnyObject {
    func toolbarDidClickBack()
    func toolbarDidClickHome()
    func toolbarDidClickRecents()
    func toolbarDidToggleGameKeyMap()
    func toolbarDidToggleScreenPower(_ isOff: Bool)
    func toolbarDidToggleAudioMute(_ isMuted: Bool)
    func toolbarDidClickScreenshot()
    func toolbarDidClickVolumeUp()
    func toolbarDidClickVolumeDown()
    func toolbarDidClickPower()
    func toolbarDidClickFullscreen()
    func toolbarDidTogglePosition()
    func toolbarDidClickHide()
}

public final class DockToolbarView: NSVisualEffectView {
    public weak var delegate: DockToolbarDelegate?
    public private(set) var position: DockToolbarPosition = .right

    private var isScreenOff = false
    private var isAudioMuted = false
    private var isGameModeActive = false
    private var moonButton: ToolBarButton?
    private var audioMuteButton: ToolBarButton?
    private var gameButton: ToolBarButton?
    private var stackView: NSStackView!
    private var scrollView: NSScrollView!
    private var documentContainer: FlippedToolbarDocumentView!
    private var borderLine: NSBox!
    private var layoutConstraints: [NSLayoutConstraint] = []

    public func setGameModeActive(_ isActive: Bool) {
        self.isGameModeActive = isActive
        self.gameButton?.activeTone = isActive ? .green : .none
    }

    public func setScreenOff(_ isOff: Bool) {
        self.isScreenOff = isOff
        self.moonButton?.activeTone = isOff ? .amber : .none
        self.moonButton?.image = symbolImage(named: isOff ? "sun.max.fill" : "moon.fill", tooltip: "屏幕电源")
        self.moonButton?.toolTip = isOff ? "点亮手机物理屏幕" : "熄灭手机物理屏幕 (省电降温，投屏持续)"
    }

    public func toggleScreenPower() {
        let nextState = !isScreenOff
        setScreenOff(nextState)
        delegate?.toolbarDidToggleScreenPower(nextState)
    }

    public init(position: DockToolbarPosition = .right) {
        self.position = position
        super.init(frame: .zero)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    public func setPosition(_ newPosition: DockToolbarPosition) {
        guard position != newPosition else { return }
        self.position = newPosition
        rebuildUI()
    }

    private func setupUI() {
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true

        borderLine = NSBox()
        borderLine.boxType = .custom
        borderLine.fillColor = MCTheme.nsDockBorder
        borderLine.borderWidth = 0
        borderLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderLine)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        documentContainer = FlippedToolbarDocumentView()
        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentContainer

        stackView = NSStackView()
        stackView.alignment = .centerX
        stackView.spacing = 5
        stackView.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(stackView)

        buildButtons()
        applyConstraints()
    }

    private func rebuildUI() {
        stackView.subviews.forEach { $0.removeFromSuperview() }
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        buildButtons()
        applyConstraints()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyConstraints() {
        let clipView = scrollView.contentView

        switch position {
        case .right:
            stackView.orientation = .vertical
            stackView.alignment = .centerX
            stackView.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)

            let fitHeight = documentContainer.heightAnchor.constraint(equalTo: clipView.heightAnchor)
            fitHeight.priority = .defaultLow

            layoutConstraints = [
                borderLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                borderLine.topAnchor.constraint(equalTo: topAnchor),
                borderLine.bottomAnchor.constraint(equalTo: bottomAnchor),
                borderLine.widthAnchor.constraint(equalToConstant: 1),

                scrollView.leadingAnchor.constraint(equalTo: borderLine.trailingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

                documentContainer.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
                documentContainer.topAnchor.constraint(equalTo: clipView.topAnchor),
                documentContainer.widthAnchor.constraint(equalTo: clipView.widthAnchor),
                documentContainer.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor),
                fitHeight,

                stackView.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
                stackView.topAnchor.constraint(equalTo: documentContainer.topAnchor),
                stackView.bottomAnchor.constraint(lessThanOrEqualTo: documentContainer.bottomAnchor)
            ]

        case .bottom:
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            stackView.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

            let fitWidth = documentContainer.widthAnchor.constraint(equalTo: clipView.widthAnchor)
            fitWidth.priority = .defaultLow

            layoutConstraints = [
                borderLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                borderLine.trailingAnchor.constraint(equalTo: trailingAnchor),
                borderLine.topAnchor.constraint(equalTo: topAnchor),
                borderLine.heightAnchor.constraint(equalToConstant: 1),

                scrollView.topAnchor.constraint(equalTo: borderLine.bottomAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

                documentContainer.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
                documentContainer.topAnchor.constraint(equalTo: clipView.topAnchor),
                documentContainer.heightAnchor.constraint(equalTo: clipView.heightAnchor),
                documentContainer.widthAnchor.constraint(greaterThanOrEqualTo: clipView.widthAnchor),
                fitWidth,

                stackView.topAnchor.constraint(equalTo: documentContainer.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor),
                stackView.centerXAnchor.constraint(equalTo: documentContainer.centerXAnchor),
                stackView.leadingAnchor.constraint(greaterThanOrEqualTo: documentContainer.leadingAnchor),
                stackView.trailingAnchor.constraint(lessThanOrEqualTo: documentContainer.trailingAnchor)
            ]
        }

        NSLayoutConstraint.activate(layoutConstraints)
    }

    private func buildButtons() {
        // Navigation buttons
        let backBtn = createButton(systemName: "chevron.backward", fallbackText: "‹", tooltip: "返回 (Back · Cmd+B / Esc)") { [weak self] in
            self?.delegate?.toolbarDidClickBack()
        }
        let homeBtn = createButton(systemName: "circle", fallbackText: "○", tooltip: "主屏幕 (Home · Cmd+H)") { [weak self] in
            self?.delegate?.toolbarDidClickHome()
        }
        let recentsBtn = createButton(systemName: "square", fallbackText: "□", tooltip: "多任务后台 (Recents · Cmd+S)") { [weak self] in
            self?.delegate?.toolbarDidClickRecents()
        }

        let sep1 = createSeparator()

        // Device Controls
        let screenBtn = createButton(
            systemName: isScreenOff ? "sun.max.fill" : "moon.fill",
            fallbackText: "◐",
            tooltip: isScreenOff ? "点亮手机物理屏幕" : "熄灭手机物理屏幕 (省电降温，投屏持续)"
        ) { [weak self] in
            self?.toggleScreenPower()
        }
        screenBtn.activeTone = isScreenOff ? .amber : .none
        self.moonButton = screenBtn

        let gameBtn = createButton(systemName: "gamecontroller.fill", fallbackText: "⌖", tooltip: "手游键鼠映射模式 (按 ~ 锁定/释放视角)") { [weak self] in
            self?.delegate?.toolbarDidToggleGameKeyMap()
        }
        gameBtn.activeTone = isGameModeActive ? .green : .none
        self.gameButton = gameBtn

        let snapBtn = createButton(systemName: "camera.fill", fallbackText: "⊞", tooltip: "保存高清截图至桌面并写入剪贴板 (Cmd+Shift+S)") { [weak self] in
            self?.delegate?.toolbarDidClickScreenshot()
        }

        let volUpBtn = createButton(systemName: "speaker.wave.3.fill", fallbackText: "+", tooltip: "音量 +") { [weak self] in
            self?.delegate?.toolbarDidClickVolumeUp()
        }

        let volDownBtn = createButton(systemName: "speaker.wave.1.fill", fallbackText: "-", tooltip: "音量 -") { [weak self] in
            self?.delegate?.toolbarDidClickVolumeDown()
        }

        let muteBtn = createButton(
            systemName: isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            fallbackText: "×",
            tooltip: isAudioMuted ? "取消静音 (Mac 音频播放)" : "静音 (关闭 Mac 音频播放)"
        ) { [weak self] in
            guard let self = self else { return }
            self.isAudioMuted.toggle()
            self.delegate?.toolbarDidToggleAudioMute(self.isAudioMuted)
            self.audioMuteButton?.image = self.symbolImage(
                named: self.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tooltip: "音频静音"
            )
            self.audioMuteButton?.activeTone = self.isAudioMuted ? .danger : .none
            self.audioMuteButton?.toolTip = self.isAudioMuted ? "取消静音 (Mac 音频播放)" : "静音 (关闭 Mac 音频播放)"
        }
        muteBtn.activeTone = isAudioMuted ? .danger : .none
        self.audioMuteButton = muteBtn

        let powerBtn = createButton(systemName: "power", fallbackText: "⏻", tooltip: "电源 / 锁屏键") { [weak self] in
            self?.delegate?.toolbarDidClickPower()
        }

        let sep2 = createSeparator()

        // Window & Layout Controls
        let fullBtn = createButton(systemName: "arrow.up.left.and.arrow.down.right", fallbackText: "⤢", tooltip: "全屏模式切换") { [weak self] in
            self?.delegate?.toolbarDidClickFullscreen()
        }

        let posBtn = createButton(systemName: "dock.rectangle", fallbackText: "⇄", tooltip: position == .right ? "切换到窗口底部停靠" : "切换到窗口右侧停靠") { [weak self] in
            self?.delegate?.toolbarDidTogglePosition()
        }

        let hideBtn = createButton(systemName: position == .right ? "chevron.right" : "chevron.down", fallbackText: "›", tooltip: "收起工具栏 (Cmd+T 随时唤出)") { [weak self] in
            self?.delegate?.toolbarDidClickHide()
        }

        let items: [NSView] = [
            backBtn, homeBtn, recentsBtn,
            sep1,
            gameBtn, screenBtn, snapBtn, volUpBtn, volDownBtn, muteBtn, powerBtn,
            sep2,
            fullBtn, posBtn, hideBtn
        ]

        items.forEach { stackView.addArrangedSubview($0) }
    }

    private func createSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = MCTheme.nsDockSeparator
        box.borderWidth = 0
        box.translatesAutoresizingMaskIntoConstraints = false

        if position == .right {
            box.widthAnchor.constraint(equalToConstant: 22).isActive = true
            box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            box.widthAnchor.constraint(equalToConstant: 1).isActive = true
            box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        return box
    }

    private func symbolImage(named systemName: String, tooltip: String) -> NSImage? {
        guard let img = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return img.withSymbolConfiguration(config)
    }

    private func createButton(systemName: String, fallbackText: String, tooltip: String, action: @escaping () -> Void) -> ToolBarButton {
        let btn = ToolBarButton(action: action)
        btn.toolTip = tooltip
        btn.bezelStyle = .regularSquare
        btn.isBordered = false

        if let img = symbolImage(named: systemName, tooltip: tooltip) {
            btn.image = img
            btn.imagePosition = .imageOnly
        } else {
            btn.title = fallbackText
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }

        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return btn
    }
}

// Backward compatibility alias
public typealias CapsuleToolbarView = DockToolbarView
public typealias CapsuleToolbarDelegate = DockToolbarDelegate

private final class FlippedToolbarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private enum DockActiveTone {
    case none
    case green
    case amber
    case danger
}

private final class ToolBarButton: NSButton {
    private let actionClosure: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    var activeTone: DockActiveTone = .none {
        didSet {
            updateVisualAppearance()
        }
    }

    init(action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        self.target = self
        self.action = #selector(handleClick)
        self.wantsLayer = true
        self.layer?.cornerRadius = 7
        self.layer?.cornerCurve = .continuous
        self.layer?.masksToBounds = true
        updateVisualAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisualAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateVisualAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateVisualAppearance()
    }

    private func updateVisualAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch activeTone {
            case .green:
                contentTintColor = MCTheme.nsDockActiveGreenTint
                layer?.backgroundColor = MCTheme.nsDockActiveGreenBg.cgColor
                layer?.borderColor = MCTheme.nsDockActiveGreenBorder.cgColor
                layer?.borderWidth = 1
            case .amber:
                contentTintColor = MCTheme.nsDockActiveAmberTint
                layer?.backgroundColor = MCTheme.nsDockActiveAmberBg.cgColor
                layer?.borderColor = MCTheme.nsDockActiveAmberBorder.cgColor
                layer?.borderWidth = 1
            case .danger:
                contentTintColor = MCTheme.nsDockActiveDangerTint
                layer?.backgroundColor = MCTheme.nsDockActiveDangerBg.cgColor
                layer?.borderColor = MCTheme.nsDockActiveDangerBorder.cgColor
                layer?.borderWidth = 1
            case .none:
                contentTintColor = isHovered ? .labelColor : MCTheme.nsDockIcon
                layer?.backgroundColor = isHovered ? MCTheme.nsDockHover.cgColor : NSColor.clear.cgColor
                layer?.borderColor = NSColor.clear.cgColor
                layer?.borderWidth = 0
            }
        }
    }

    @objc private func handleClick() {
        actionClosure()
    }
}
