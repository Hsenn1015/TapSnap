import TapSnapIcons
import TapSnapTheme
import SwiftUI

/// 按钮变体，对应 shadcn Button 的几种默认样式。
public enum SnapButtonVariant: Sendable {
    /// 主按钮：primary 底 + primary-foreground 字。
    case primary
    /// 次按钮：secondary 底。
    case secondary
    /// 描边按钮：透明底 + border。
    case outline
    /// 幽灵按钮：无底，悬停才显底色。
    case ghost
    /// 危险操作。
    case destructive
    /// 链接样式。
    case link
}

public enum SnapButtonSize: Sendable {
    case sm
    case md
    case icon

    var height: CGFloat {
        switch self {
        case .sm: return 26
        case .md: return 32
        case .icon: return 28
        }
    }
}

/// 统一按钮。样式与 shadcn 对齐：圆角 radius-md、字号 13、按压回弹、悬停变色。
public struct SnapButton<Label: View>: View {
    public var theme: Theme
    public var variant: SnapButtonVariant
    public var size: SnapButtonSize
    public var isEnabled: Bool
    public var action: () -> Void
    private let label: () -> Label

    @State private var isHovering = false

    public init(
        theme: Theme,
        variant: SnapButtonVariant = .secondary,
        size: SnapButtonSize = .md,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.theme = theme
        self.variant = variant
        self.size = size
        self.isEnabled = isEnabled
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: size == .sm ? 12 : 13))
                .lineLimit(1)
                .padding(.horizontal, size == .icon ? 0 : 12)
                .frame(height: size.height)
                .frame(minWidth: size == .icon ? size.height : 0)
                .foregroundStyle(foreground)
                .background {
                    RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous)
                        .fill(background)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous)
                                .strokeBorder(borderColor, lineWidth: variant == .outline ? 1 : 0)
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous))
        }
        .buttonStyle(SnapPressStyle())
        .onHoverChange { isHovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return theme.token(.primaryForeground)
        case .secondary: return theme.token(.secondaryForeground)
        case .outline, .ghost, .link: return theme.token(.foreground)
        case .destructive: return theme.token(.destructiveForeground)
        }
    }

    private var background: Color {
        switch variant {
        case .primary:
            return theme.token(.primary).opacity(isHovering ? 0.88 : 1)
        case .secondary:
            return theme.token(.secondary).opacity(isHovering ? 0.80 : 1)
        case .outline:
            return isHovering ? theme.token(.accent) : .clear
        case .ghost, .link:
            return isHovering ? theme.token(.accent) : .clear
        case .destructive:
            return theme.token(.destructive).opacity(isHovering ? 0.88 : 1)
        }
    }

    private var borderColor: Color {
        variant == .outline ? theme.token(.input) : .clear
    }
}

extension SnapButton where Label == Text {
    /// 纯文字按钮的便捷构造。
    public init(
        _ title: String,
        theme: Theme,
        variant: SnapButtonVariant = .secondary,
        size: SnapButtonSize = .md,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            theme: theme,
            variant: variant,
            size: size,
            isEnabled: isEnabled,
            action: action
        ) {
            Text(title)
        }
    }
}

/// 带图标的按钮。
public struct SnapIconButton: View {
    public var icon: IconSet
    public var theme: Theme
    public var variant: SnapButtonVariant
    public var size: SnapButtonSize
    public var isEnabled: Bool
    public var isSelected: Bool
    public var action: () -> Void

    @State private var isHovering = false

    public init(
        icon: IconSet,
        theme: Theme,
        variant: SnapButtonVariant = .ghost,
        size: SnapButtonSize = .icon,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.theme = theme
        self.variant = variant
        self.size = size
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: theme.metrics.iconSize, color: iconColor)
                .frame(width: size.height, height: size.height)
                .background {
                    RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous)
                        .fill(background)
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous))
        }
        .buttonStyle(SnapPressStyle(scale: 0.92))
        .onHoverChange { isHovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }

    private var iconColor: Color {
        if isSelected { return theme.token(.primaryForeground) }
        if variant == .destructive { return theme.token(.destructive) }
        return theme.token(.foreground)
    }

    private var background: Color {
        if isSelected { return theme.token(.primary) }
        if isHovering { return theme.token(.accent) }
        return .clear
    }
}

/// 快捷键标签，shadcn 的 `Kbd`。
public struct SnapKbd: View {
    public var keys: String
    public var theme: Theme

    public init(_ keys: String, theme: Theme) {
        self.keys = keys
        self.theme = theme
    }

    public var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(theme.token(.mutedForeground))
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .fill(theme.token(.muted))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
            }
    }
}

/// 分隔线，shadcn 的 `Separator`。
public struct SnapSeparator: View {
    public var theme: Theme
    public var isVertical: Bool

    public init(theme: Theme, isVertical: Bool = true) {
        self.theme = theme
        self.isVertical = isVertical
    }

    public var body: some View {
        Rectangle()
            .fill(theme.token(.border))
            .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
    }
}
