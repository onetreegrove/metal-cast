import AppKit

public final class GameKeyMapHUDView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let indicatorDot = NSBox()
    private var hideTimer: Timer?

    public init() {
        super.init(frame: .zero)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.zPosition = 1000 // Ensure always rendered on top of CAMetalLayer
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor

        // Indicator dot
        indicatorDot.boxType = .custom
        indicatorDot.borderWidth = 0
        indicatorDot.cornerRadius = 4
        indicatorDot.fillColor = .systemGreen
        indicatorDot.translatesAutoresizingMaskIntoConstraints = false

        // Controller Icon
        if let icon = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Game Controller") {
            iconView.image = icon
            iconView.contentTintColor = .systemGreen
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Label
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.drawsBackground = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [indicatorDot, iconView, statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            indicatorDot.widthAnchor.constraint(equalToConstant: 8),
            indicatorDot.heightAnchor.constraint(equalToConstant: 8),

            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])

        self.alphaValue = 0.0
    }

    public func show(message: String, isActive: Bool, isTemporaryReleased: Bool, autoHideDelay: TimeInterval? = nil) {
        hideTimer?.invalidate()
        hideTimer = nil

        statusLabel.stringValue = message

        if !isActive {
            indicatorDot.fillColor = .systemGray
            iconView.contentTintColor = .systemGray
        } else if isTemporaryReleased {
            indicatorDot.fillColor = .systemOrange
            iconView.contentTintColor = .systemOrange
        } else {
            indicatorDot.fillColor = .systemGreen
            iconView.contentTintColor = .systemGreen
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            self.animator().alphaValue = 1.0
        }

        if let delay = autoHideDelay {
            hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }
        }
    }

    public func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            self.animator().alphaValue = 0.0
        }
    }
}
