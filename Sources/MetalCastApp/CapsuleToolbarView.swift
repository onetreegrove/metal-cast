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
    private var moonButton: NSButton?
    private var audioMuteButton: NSButton?
    private var gameButton: NSButton?
    private var stackView: NSStackView!
    private var borderLine: NSBox!

    public func setGameModeActive(_ isActive: Bool) {
        self.isGameModeActive = isActive
        self.gameButton?.contentTintColor = isActive ? .systemGreen : .labelColor
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
        borderLine.fillColor = NSColor(white: 1.0, alpha: 0.12)
        borderLine.borderWidth = 0
        borderLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderLine)

        stackView = NSStackView()
        stackView.alignment = .centerX
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        buildButtons()
        applyConstraints()
    }

    private func rebuildUI() {
        stackView.subviews.forEach { $0.removeFromSuperview() }
        NSLayoutConstraint.deactivate(borderLine.constraints)
        NSLayoutConstraint.deactivate(stackView.constraints)

        buildButtons()
        applyConstraints()
    }

    private func applyConstraints() {
        switch position {
        case .right:
            stackView.orientation = .vertical
            stackView.edgeInsets = NSEdgeInsets(top: 12, left: 4, bottom: 12, right: 4)

            NSLayoutConstraint.activate([
                borderLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                borderLine.topAnchor.constraint(equalTo: topAnchor),
                borderLine.bottomAnchor.constraint(equalTo: bottomAnchor),
                borderLine.widthAnchor.constraint(equalToConstant: 1),

                stackView.leadingAnchor.constraint(equalTo: borderLine.trailingAnchor),
                stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
                stackView.topAnchor.constraint(equalTo: topAnchor),
                stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
            ])

        case .bottom:
            stackView.orientation = .horizontal
            stackView.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

            NSLayoutConstraint.activate([
                borderLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                borderLine.trailingAnchor.constraint(equalTo: trailingAnchor),
                borderLine.topAnchor.constraint(equalTo: topAnchor),
                borderLine.heightAnchor.constraint(equalToConstant: 1),

                stackView.topAnchor.constraint(equalTo: borderLine.bottomAnchor),
                stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
                stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                stackView.centerXAnchor.constraint(equalTo: centerXAnchor)
            ])
        }
    }

    private func buildButtons() {
        // Navigation buttons
        let backBtn = createButton(systemName: "chevron.backward", fallbackText: "◀", tooltip: "返回 (Back · Cmd+B / Esc)") { [weak self] in
            self?.delegate?.toolbarDidClickBack()
        }
        let homeBtn = createButton(systemName: "circle.fill", fallbackText: "●", tooltip: "主屏幕 (Home · Cmd+H)") { [weak self] in
            self?.delegate?.toolbarDidClickHome()
        }
        let recentsBtn = createButton(systemName: "square.fill", fallbackText: "■", tooltip: "多任务后台 (Recents · Cmd+S)") { [weak self] in
            self?.delegate?.toolbarDidClickRecents()
        }

        let sep1 = createSeparator()

        // Device Controls
        let screenBtn = createButton(systemName: isScreenOff ? "sun.max.fill" : "moon.fill", fallbackText: "🌙", tooltip: "熄灭手机物理屏幕 (省电降温，投屏持续)") { [weak self] in
            guard let self = self else { return }
            self.isScreenOff.toggle()
            self.delegate?.toolbarDidToggleScreenPower(self.isScreenOff)
            self.moonButton?.contentTintColor = self.isScreenOff ? .systemOrange : .labelColor
            self.moonButton?.toolTip = self.isScreenOff ? "点亮手机物理屏幕" : "熄灭手机物理屏幕 (省电降温，投屏持续)"
        }
        screenBtn.contentTintColor = isScreenOff ? .systemOrange : .labelColor
        self.moonButton = screenBtn

        let gameBtn = createButton(systemName: "gamecontroller.fill", fallbackText: "🎮", tooltip: "手游键鼠映射模式 (按 ~ 锁定/释放视角)") { [weak self] in
            self?.delegate?.toolbarDidToggleGameKeyMap()
        }
        gameBtn.contentTintColor = isGameModeActive ? .systemGreen : .labelColor
        self.gameButton = gameBtn

        let snapBtn = createButton(systemName: "camera.fill", fallbackText: "📸", tooltip: "保存高清截图至桌面并写入剪贴板") { [weak self] in
            self?.delegate?.toolbarDidClickScreenshot()
        }

        let volUpBtn = createButton(systemName: "speaker.wave.3.fill", fallbackText: "🔊", tooltip: "音量 +") { [weak self] in
            self?.delegate?.toolbarDidClickVolumeUp()
        }

        let volDownBtn = createButton(systemName: "speaker.wave.1.fill", fallbackText: "🔉", tooltip: "音量 -") { [weak self] in
            self?.delegate?.toolbarDidClickVolumeDown()
        }

        let muteBtn = createButton(systemName: isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", fallbackText: "🔈", tooltip: isAudioMuted ? "取消静音 (Mac 音频播放)" : "静音 (关闭 Mac 音频播放)") { [weak self] in
            guard let self = self else { return }
            self.isAudioMuted.toggle()
            self.delegate?.toolbarDidToggleAudioMute(self.isAudioMuted)
            self.audioMuteButton?.image = NSImage(systemSymbolName: self.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
            self.audioMuteButton?.contentTintColor = self.isAudioMuted ? .systemRed : .labelColor
            self.audioMuteButton?.toolTip = self.isAudioMuted ? "取消静音 (Mac 音频播放)" : "静音 (关闭 Mac 音频播放)"
        }
        muteBtn.contentTintColor = isAudioMuted ? .systemRed : .labelColor
        self.audioMuteButton = muteBtn

        let powerBtn = createButton(systemName: "power", fallbackText: "⚡️", tooltip: "电源 / 锁屏键") { [weak self] in
            self?.delegate?.toolbarDidClickPower()
        }

        let sep2 = createSeparator()

        // Window & Layout Controls
        let fullBtn = createButton(systemName: "arrow.up.left.and.arrow.down.right", fallbackText: "⛶", tooltip: "全屏模式切换") { [weak self] in
            self?.delegate?.toolbarDidClickFullscreen()
        }

        let posBtn = createButton(systemName: "dock.rectangle", fallbackText: "⇄", tooltip: position == .right ? "切换到窗口底部停靠" : "切换到窗口右侧停靠") { [weak self] in
            self?.delegate?.toolbarDidTogglePosition()
        }

        let hideBtn = createButton(systemName: position == .right ? "chevron.right" : "chevron.down", fallbackText: "⇥", tooltip: "收起工具栏 (Cmd+T 随时唤出)") { [weak self] in
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
        box.fillColor = NSColor(white: 1.0, alpha: 0.15)
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

    private func createButton(systemName: String, fallbackText: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let btn = ToolBarButton(action: action)
        btn.toolTip = tooltip
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.contentTintColor = .labelColor

        if let img = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            btn.image = img.withSymbolConfiguration(config)
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

private final class ToolBarButton: NSButton {
    private let actionClosure: () -> Void
    private var trackingArea: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        self.target = self
        self.action = #selector(handleClick)
        self.wantsLayer = true
        self.layer?.cornerRadius = 6
        self.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError()
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
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @objc private func handleClick() {
        actionClosure()
    }
}
