import SwiftUI
import TapSnapTheme

/// 统一图标视图。
public struct IconView: View {
    public var icon: IconSet
    public var size: CGFloat
    public var color: Color

    public init(icon: IconSet, size: CGFloat = 15, color: Color = .primary) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(systemName: icon.systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityLabel(icon.accessibilityLabel)
    }
}

/// 带选中态的图标按钮。
///
/// 工具栏与气泡菜单里通用。外观按 shadcn 的 ghost icon button：平时透明，
/// 悬停浮现 `accent` 底，选中时用 `primary` 实底 + `primary-foreground` 图标。
public struct IconButton: View {
    public var icon: IconSet
    public var theme: Theme
    public var isSelected: Bool
    public var isEnabled: Bool
    public var size: CGFloat
    public var action: () -> Void

    @State private var isHovering = false

    public init(
        icon: IconSet,
        theme: Theme = .dark,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        size: CGFloat = 28,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.theme = theme
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconView(
                icon: icon,
                size: theme.metrics.iconSize,
                color: isSelected ? theme.token(.primaryForeground) : theme.token(.foreground)
            )
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous)
                    .fill(background)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.92))
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return theme.token(.primary) }
        if isHovering { return theme.token(.accent) }
        return .clear
    }
}
