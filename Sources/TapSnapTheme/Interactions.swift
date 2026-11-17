import SwiftUI

// 交互反馈。
//
// 取自 bencho.dev 那套界面的手感：按下去有轻微的「压扁」，松开弹回；
// 指针悬停时底色渐变浮现，而不是瞬间切换；状态切换一律用弹簧而非线性动画。
// SwiftUI 没有 hover 事件，这里用 `onHover` 自己跟。
//
// 放在主题层而不是控件层：`TapSnapIcons` 里的图标按钮也要用，
// 而它比 `TapSnapUI` 低一层，放上面会形成循环依赖。

// MARK: - 按压

/// 按压缩放 + 回弹。`isPressed` 由 `ButtonStyle` 传入，这里只负责形变。
public struct PressEffect: ViewModifier {
    public var isPressed: Bool
    public var scale: CGFloat
    public var pressedOpacity: Double

    public init(isPressed: Bool, scale: CGFloat = 0.96, pressedOpacity: Double = 1) {
        self.isPressed = isPressed
        self.scale = scale
        self.pressedOpacity = pressedOpacity
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1)
            .opacity(isPressed ? pressedOpacity : 1)
            .animation(Interaction.press, value: isPressed)
    }
}

// MARK: - 悬停

/// 跟踪指针是否停在视图上，供悬停高亮使用。
public struct HoverState: ViewModifier {
    @State private var isHovering = false
    private let onChange: (Bool) -> Void

    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                onChange(hovering)
            }
    }
}

/// 悬停时渐显一层底色，用于菜单行、图标按钮。
public struct HoverHighlight: ViewModifier {
    public var isActive: Bool
    public var color: Color
    public var cornerRadius: CGFloat

    public init(isActive: Bool, color: Color, cornerRadius: CGFloat) {
        self.isActive = isActive
        self.color = color
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isActive ? color : .clear)
            }
            .animation(Interaction.hover, value: isActive)
    }
}

// MARK: - 曲线

public enum Interaction {
    /// 按压：快下、带一点回弹。
    public static let press: Animation = .spring(response: 0.22, dampingFraction: 0.62)
    /// 悬停：短促的淡入淡出，不要有重量感。
    public static let hover: Animation = .easeOut(duration: 0.14)
    /// 状态切换（选中、开关）：明确的弹簧。
    public static let toggle: Animation = .spring(response: 0.28, dampingFraction: 0.72)
    /// 面板进出。
    public static let panel: Animation = .spring(response: 0.32, dampingFraction: 0.80)
}

public extension View {
    func pressEffect(isPressed: Bool, scale: CGFloat = 0.96) -> some View {
        modifier(PressEffect(isPressed: isPressed, scale: scale))
    }

    func onHoverChange(_ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(HoverState(onChange: onChange))
    }

    func hoverHighlight(
        isActive: Bool,
        color: Color,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(HoverHighlight(isActive: isActive, color: color, cornerRadius: cornerRadius))
    }
}

/// 所有可点击控件共用的按压反馈样式。
public struct SnapPressStyle: ButtonStyle {
    public var scale: CGFloat

    public init(scale: CGFloat = 0.96) {
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressEffect(isPressed: configuration.isPressed, scale: scale)
    }
}

// MARK: - 焦点环

/// shadcn 的焦点环：3px 的半透明 ring + 1px 实色描边。
public struct FocusRing: ViewModifier {
    public var isActive: Bool
    public var theme: Theme
    public var cornerRadius: CGFloat

    public init(isActive: Bool, theme: Theme, cornerRadius: CGFloat) {
        self.isActive = isActive
        self.theme = theme
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.token(.ring), lineWidth: 2)
                    .opacity(isActive ? 0.6 : 0)
            )
            .animation(Interaction.hover, value: isActive)
    }
}
