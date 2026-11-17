import SwiftUI
import TapSnapCore

/// 阴影规格。
///
/// 为菜单、工具栏、悬浮球和卡片提供不同的阴影预设。
public struct ShadowSpec: Sendable, Equatable {
    public var color: RGBAColor
    public var radius: CGFloat
    public var offsetX: CGFloat
    public var offsetY: CGFloat

    public init(color: RGBAColor, radius: CGFloat, offsetX: CGFloat = 0, offsetY: CGFloat = 0) {
        self.color = color
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// 弹出层（菜单、面板、提示）：往下掉一点点，边缘散开。
    public static let panel = ShadowSpec(color: RGBAColor(white: 0, alpha: 0.16), radius: 18, offsetY: 6)
    /// 工具栏这类贴着内容浮起的面板。
    public static let toolbar = ShadowSpec(color: RGBAColor(white: 0, alpha: 0.20), radius: 22, offsetY: 8)
    /// 小圆钮、悬浮球。
    public static let floatingBall = ShadowSpec(color: RGBAColor(white: 0, alpha: 0.22), radius: 10, offsetY: 3)
    /// 卡片：几乎只有描边，投影只是为了脱离背景。
    public static let card = ShadowSpec(color: RGBAColor(white: 0, alpha: 0.06), radius: 2, offsetY: 1)
    public static let none = ShadowSpec(color: .clear, radius: 0)
}

public extension View {
    func senShadow(_ spec: ShadowSpec) -> some View {
        shadow(
            color: spec.color.color,
            radius: spec.radius,
            x: spec.offsetX,
            y: spec.offsetY
        )
    }

    /// 弹出面板的统一外观：popover 底、border 描边、radius-lg 圆角、柔和投影。
    func senPanelStyle(theme: Theme, radius: CGFloat? = nil) -> some View {
        let corner = radius ?? theme.metrics.radiusLG
        return self
            .background(theme.token(.popover))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
            )
            .senShadow(.panel)
    }

    /// 卡片：card 底 + border 描边，投影几乎不可见。
    func senCardStyle(theme: Theme, radius: CGFloat? = nil) -> some View {
        let corner = radius ?? theme.metrics.radiusLG
        return self
            .background(theme.token(.card))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
            )
            .senShadow(.card)
    }
}
