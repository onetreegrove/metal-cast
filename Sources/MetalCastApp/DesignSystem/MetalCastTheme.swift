import AppKit
import SwiftUI

public enum MCRadius {
    public static let card: CGFloat = 11
    public static let control: CGFloat = 8
    public static let small: CGFloat = 6
    public static let badge: CGFloat = 999
}

public enum MCTheme {
    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptive(light: light, dark: dark))
    }

    // MARK: - Surfaces

    public static let windowBackground = color(light: rgba(246, 247, 250), dark: rgba(26, 29, 37))
    public static let sidebarBackground = color(light: rgba(241, 243, 247), dark: rgba(20, 22, 29))
    public static let cardSurface = color(light: rgba(255, 255, 255), dark: rgba(34, 38, 49))
    public static let cardSubtle = color(light: rgba(245, 247, 250), dark: rgba(28, 31, 41))
    public static let controlWell = color(light: rgba(235, 239, 245), dark: rgba(21, 24, 33))
    public static let hoverFill = color(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.045),
        dark: NSColor(white: 1.0, alpha: 0.065)
    )

    // MARK: - Borders

    public static let border = color(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.11),
        dark: NSColor(white: 1.0, alpha: 0.11)
    )
    public static let borderSubtle = color(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.065),
        dark: NSColor(white: 1.0, alpha: 0.065)
    )
    public static let borderStrong = color(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.20),
        dark: NSColor(white: 1.0, alpha: 0.22)
    )
    public static let accentBorder = color(
        light: rgba(0, 113, 227, 0.36),
        dark: rgba(10, 132, 255, 0.44)
    )

    // MARK: - Typography

    public static let textPrimary = color(light: rgba(20, 23, 31), dark: rgba(243, 245, 249))
    public static let textSecondary = color(light: rgba(20, 23, 31, 0.68), dark: rgba(243, 245, 249, 0.68))
    public static let textTertiary = color(light: rgba(20, 23, 31, 0.46), dark: rgba(243, 245, 249, 0.44))

    // MARK: - Semantic Tints

    public static let accent = color(light: rgba(0, 113, 227), dark: rgba(10, 132, 255))
    public static let accentHover = color(light: rgba(0, 94, 196), dark: rgba(59, 158, 255))
    public static let accentSoft = color(light: rgba(0, 113, 227, 0.11), dark: rgba(10, 132, 255, 0.18))

    public static let success = color(light: rgba(31, 139, 77), dark: rgba(48, 209, 88))
    public static let successSoft = color(light: rgba(31, 139, 77, 0.12), dark: rgba(48, 209, 88, 0.15))

    public static let warning = color(light: rgba(179, 89, 0), dark: rgba(255, 159, 10))
    public static let warningSoft = color(light: rgba(217, 119, 6, 0.12), dark: rgba(255, 159, 10, 0.16))

    public static let danger = color(light: rgba(207, 34, 46), dark: rgba(255, 69, 58))
    public static let dangerSoft = color(light: rgba(207, 34, 46, 0.11), dark: rgba(255, 69, 58, 0.16))

    // MARK: - AppKit Dock Toolbar Tokens

    public static let nsDockBorder = adaptive(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.12),
        dark: NSColor(white: 1.0, alpha: 0.12)
    )
    public static let nsDockSeparator = adaptive(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.11),
        dark: NSColor(white: 1.0, alpha: 0.14)
    )
    public static let nsDockHover = adaptive(
        light: NSColor(srgbRed: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 0.08),
        dark: NSColor(white: 1.0, alpha: 0.11)
    )
    public static let nsDockIcon = adaptive(
        light: rgba(20, 23, 31, 0.78),
        dark: rgba(243, 245, 249, 0.80)
    )

    public static let nsDockActiveGreenBg = adaptive(light: rgba(31, 139, 77, 0.14), dark: rgba(48, 209, 88, 0.17))
    public static let nsDockActiveGreenBorder = adaptive(light: rgba(31, 139, 77, 0.35), dark: rgba(48, 209, 88, 0.38))
    public static let nsDockActiveGreenTint = adaptive(light: rgba(31, 139, 77), dark: rgba(48, 209, 88))

    public static let nsDockActiveAmberBg = adaptive(light: rgba(217, 119, 6, 0.14), dark: rgba(255, 159, 10, 0.18))
    public static let nsDockActiveAmberBorder = adaptive(light: rgba(217, 119, 6, 0.38), dark: rgba(255, 159, 10, 0.40))
    public static let nsDockActiveAmberTint = adaptive(light: rgba(179, 89, 0), dark: rgba(255, 159, 10))

    public static let nsDockActiveDangerBg = adaptive(light: rgba(207, 34, 46, 0.13), dark: rgba(255, 69, 58, 0.18))
    public static let nsDockActiveDangerBorder = adaptive(light: rgba(207, 34, 46, 0.35), dark: rgba(255, 69, 58, 0.40))
    public static let nsDockActiveDangerTint = adaptive(light: rgba(207, 34, 46), dark: rgba(255, 69, 58))
}

// MARK: - Shared SwiftUI Primitives

public struct MCCard<Content: View>: View {
    private let padding: CGFloat
    private let radius: CGFloat
    private let backgroundColor: Color
    private let borderColor: Color
    private let content: Content

    public init(
        padding: CGFloat = 16,
        radius: CGFloat = MCRadius.card,
        backgroundColor: Color = MCTheme.cardSurface,
        borderColor: Color = MCTheme.border,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.radius = radius
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

public enum MCPillTone {
    case neutral, accent, success, warning, danger

    var foreground: Color {
        switch self {
        case .neutral: return MCTheme.textSecondary
        case .accent: return MCTheme.accent
        case .success: return MCTheme.success
        case .warning: return MCTheme.warning
        case .danger: return MCTheme.danger
        }
    }

    var background: Color {
        switch self {
        case .neutral: return MCTheme.controlWell
        case .accent: return MCTheme.accentSoft
        case .success: return MCTheme.successSoft
        case .warning: return MCTheme.warningSoft
        case .danger: return MCTheme.dangerSoft
        }
    }
}

public struct MCPillBadge: View {
    private let text: String
    private let tone: MCPillTone
    private let showDot: Bool
    private let monospaced: Bool

    public init(
        _ text: String,
        tone: MCPillTone = .neutral,
        showDot: Bool = false,
        monospaced: Bool = false
    ) {
        self.text = text
        self.tone = tone
        self.showDot = showDot
        self.monospaced = monospaced
    }

    public var body: some View {
        HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(tone.foreground)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(monospaced ? .system(size: 11, weight: .medium, design: .monospaced) : .system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundColor(tone.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.background))
    }
}

public struct MCKeyCap: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(MCTheme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(MCTheme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(MCTheme.border, lineWidth: 1)
            )
    }
}

public struct MCSegmentedControl<Value: Hashable>: View {
    public struct Option: Identifiable {
        public var id: Value { value }
        public let title: String
        public let value: Value

        public init(_ title: String, value: Value) {
            self.title = title
            self.value = value
        }
    }

    private let options: [Option]
    @Binding private var selection: Value

    public init(options: [Option], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button(action: {
                    selection = option.value
                }) {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(isSelected ? MCTheme.textPrimary : MCTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: MCRadius.small, style: .continuous)
                                .fill(isSelected ? MCTheme.cardSurface : Color.clear)
                        )
                        .shadow(color: isSelected ? Color.black.opacity(0.08) : Color.clear, radius: 2, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .fill(MCTheme.controlWell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                .strokeBorder(MCTheme.borderSubtle, lineWidth: 1)
        )
    }
}

public struct MCUnderlineTabBar<Tab: Hashable>: View {
    public struct TabItem: Identifiable {
        public var id: Tab { value }
        public let value: Tab
        public let title: String

        public init(value: Tab, title: String) {
            self.value = value
            self.title = title
        }
    }

    private let items: [TabItem]
    @Binding private var selection: Tab
    private let showBottomDivider: Bool

    public init(items: [TabItem], selection: Binding<Tab>, showBottomDivider: Bool = true) {
        self.items = items
        self._selection = selection
        self.showBottomDivider = showBottomDivider
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let isSelected = selection == item.value
                Button(action: {
                    selection = item.value
                }) {
                    VStack(spacing: 0) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(isSelected ? MCTheme.accent : MCTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Rectangle()
                            .fill(isSelected ? MCTheme.accent : Color.clear)
                            .frame(height: 2.5)
                            .padding(.horizontal, 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            if showBottomDivider {
                Rectangle()
                    .fill(MCTheme.border)
                    .frame(height: 1)
            }
        }
    }
}

public struct MCButtonStyle: ButtonStyle {
    public enum Variant {
        case primary
        case secondary
        case destructive
        case destructiveOutline
        case ghost
    }

    private let variant: Variant
    private let compact: Bool
    private let iconOnly: Bool
    private let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ variant: Variant = .secondary,
        compact: Bool = false,
        iconOnly: Bool = false,
        isActive: Bool = false
    ) {
        self.variant = variant
        self.compact = compact
        self.iconOnly = iconOnly
        self.isActive = isActive
    }

    public func makeBody(configuration: Configuration) -> some View {
        MCButtonStyleBody(
            configuration: configuration,
            variant: variant,
            compact: compact,
            iconOnly: iconOnly,
            isActive: isActive,
            isEnabled: isEnabled
        )
    }

    private struct MCButtonStyleBody: View {
        let configuration: Configuration
        let variant: Variant
        let compact: Bool
        let iconOnly: Bool
        let isActive: Bool
        let isEnabled: Bool
        @State private var isHovered = false

        private var cornerRadius: CGFloat {
            (compact || iconOnly) ? MCRadius.small : MCRadius.control
        }

        var body: some View {
            configuration.label
                .font(.system(size: (compact || iconOnly) ? 11.5 : 12.5, weight: .medium))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, iconOnly ? 0 : (compact ? 10 : 12))
                .padding(.vertical, iconOnly ? 0 : (compact ? 5 : 7))
                .frame(width: iconOnly ? 28 : nil, height: iconOnly ? 28 : nil)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(baseBackgroundColor)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(hoverOverlayColor)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1.0) : 0.42)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
        }

        private var foregroundColor: Color {
            switch variant {
            case .primary, .destructive:
                return .white
            case .destructiveOutline:
                return MCTheme.danger
            case .secondary:
                return isActive ? MCTheme.accent : MCTheme.textPrimary
            case .ghost:
                return isHovered ? MCTheme.textPrimary : MCTheme.textSecondary
            }
        }

        private var baseBackgroundColor: Color {
            switch variant {
            case .primary:
                return (isHovered && isEnabled) ? MCTheme.accentHover : MCTheme.accent
            case .destructive:
                return MCTheme.danger.opacity((isHovered && isEnabled) ? 0.88 : 1.0)
            case .secondary:
                return isActive ? MCTheme.accentSoft : MCTheme.cardSurface
            case .destructiveOutline:
                return MCTheme.cardSurface
            case .ghost:
                return Color.clear
            }
        }

        private var hoverOverlayColor: Color {
            guard isHovered && isEnabled else { return Color.clear }
            switch variant {
            case .primary, .destructive:
                return Color.clear
            case .secondary, .ghost:
                return MCTheme.hoverFill
            case .destructiveOutline:
                return MCTheme.dangerSoft
            }
        }

        private var borderColor: Color {
            switch variant {
            case .primary, .destructive, .ghost:
                return Color.clear
            case .secondary:
                return isActive ? MCTheme.accentBorder : MCTheme.border
            case .destructiveOutline:
                return (isHovered && isEnabled) ? Color.clear : MCTheme.border
            }
        }
    }
}

public struct MCInputFieldModifier: ViewModifier {
    private let height: CGFloat

    public init(height: CGFloat = 32) {
        self.height = height
    }

    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                    .fill(MCTheme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous)
                    .strokeBorder(MCTheme.border, lineWidth: 1)
            )
    }
}

public extension View {
    /// Applies the unified compact bordered field appearance matching `MCButtonStyle` controls.
    func mcInputField(height: CGFloat = 32) -> some View {
        modifier(MCInputFieldModifier(height: height))
    }
}
