import SwiftUI
import TapSnapCore

/// 界面里引用的语义颜色角色。
///
/// 这些名字是截图/贴图界面的固有概念（选区、工具栏、放大镜…），具体落到哪个
/// shadcn token 由 `Theme.color(_:)` 决定——界面代码只认角色，换肤时不用动。
public enum ColorRole: String, CaseIterable, Sendable {
    /// 强调色：选中态、主按钮、链接。
    case accent
    case panelBackground
    case panelBorder
    case toolbarBackground
    case primaryText
    case secondaryText
    case separator
    /// 选区高亮、放大镜描边这类需要跳出来的地方。
    case highlight
    case warning
    case danger
    case selectionOverlay
    case magnifierBorder
}

/// 主题：一套 shadcn token + 一套尺度。
///
/// 为浅色和深色主题提供语义色，通过 `color(_:)` 或 `token(_:)` 访问。
public struct Theme: Sendable {
    public struct Metrics: Sendable {
        /// 基准圆角，shadcn 的 `--radius`。
        public var radius: CGFloat
        public var toolbarHeight: CGFloat
        public var iconSize: CGFloat
        public var spacing: CGFloat
        public var panelPadding: CGFloat

        public init(
            radius: CGFloat = DesignTokens.baseRadius,
            toolbarHeight: CGFloat = 44,
            iconSize: CGFloat = 15,
            spacing: CGFloat = 8,
            panelPadding: CGFloat = 6
        ) {
            self.radius = radius
            self.toolbarHeight = toolbarHeight
            self.iconSize = iconSize
            self.spacing = spacing
            self.panelPadding = panelPadding
        }

        public var radiusSM: CGFloat { radius * 0.6 }
        public var radiusMD: CGFloat { radius * 0.8 }
        public var radiusLG: CGFloat { radius }
        public var radiusXL: CGFloat { radius * 1.4 }

        /// 可点击控件的标准高度（shadcn 的 h-9）。
        public var controlHeight: CGFloat { 32 }
        /// 菜单/列表单行高度。
        public var rowHeight: CGFloat { 30 }
    }

    public var name: String
    public var isDark: Bool
    public var metrics: Metrics

    public init(name: String = "neutral", isDark: Bool = true, metrics: Metrics = Metrics()) {
        self.name = name
        self.isDark = isDark
        self.metrics = metrics
    }

    public static let dark = Theme(name: "neutral-dark", isDark: true)
    public static let light = Theme(name: "neutral-light", isDark: false)

    public static func matching(isDark: Bool) -> Theme {
        isDark ? .dark : .light
    }

    // MARK: - shadcn token

    public func rgb(_ token: DesignToken) -> RGBAColor {
        isDark ? DesignTokens.darkValue(token) : DesignTokens.lightValue(token)
    }

    public func token(_ token: DesignToken) -> Color {
        rgb(token).color
    }

    /// 色面 + 落在它上面的前景色，shadcn 的 standard pair。
    public func pair(_ token: DesignToken) -> (surface: Color, foreground: Color) {
        switch token {
        case .primary, .secondary, .accent, .destructive,
             .card, .popover, .sidebar, .sidebarPrimary, .sidebarAccent:
            let foreground = DesignToken(rawValue: token.rawValue + "Foreground") ?? .foreground
            return (self.token(token), self.token(foreground))
        default:
            return (self.token(token), self.token(.foreground))
        }
    }

    // MARK: - 语义角色

    public func color(_ role: ColorRole) -> Color {
        switch role {
        case .accent:
            return token(.primary)
        case .panelBackground:
            return token(.popover)
        case .panelBorder:
            return token(.border)
        case .toolbarBackground:
            return token(.popover)
        case .primaryText:
            return token(.foreground)
        case .secondaryText:
            return token(.mutedForeground)
        case .separator:
            return token(.border)
        case .highlight:
            return highlight
        case .warning:
            return warning
        case .danger:
            return token(.destructive)
        case .selectionOverlay:
            return highlight.opacity(0.22)
        case .magnifierBorder:
            return token(.popover).opacity(0.9)
        }
    }

    public func rgba(_ role: ColorRole) -> RGBAColor {
        switch role {
        case .accent: return rgb(.primary)
        case .panelBackground, .toolbarBackground: return rgb(.popover)
        case .panelBorder, .separator: return rgb(.border)
        case .primaryText: return rgb(.foreground)
        case .secondaryText: return rgb(.mutedForeground)
        case .danger: return rgb(.destructive)
        case .highlight: return self.highlightRGBA
        case .warning: return self.warningRGBA
        case .selectionOverlay: return highlightRGBA.withAlpha(0.22)
        case .magnifierBorder: return rgb(.popover)
        }
    }

    /// shadcn 的 Neutral 主题是纯灰阶，选区/警示这两处需要跳出灰阶，单独补两个色。
    /// 取值沿用 shadcn chart 色系，保证与整体色调同源。
    public var highlight: Color {
        color(from: highlightRGBA)
    }

    public var warning: Color {
        color(from: warningRGBA)
    }

    private var highlightRGBA: RGBAColor {
        // chart-4 的琥珀色，明暗两套都用它，选区描边在两种主题下都清晰。
        ColorConversion.sRGB(from: OKLCH(0.828, 0.189, 84.429))
    }

    private var warningRGBA: RGBAColor {
        isDark
            ? ColorConversion.sRGB(from: OKLCH(0.769, 0.188, 70.08))
            : ColorConversion.sRGB(from: OKLCH(0.705, 0.17, 60))
    }

    private func color(from rgba: RGBAColor) -> Color {
        rgba.color
    }
}

public extension RGBAColor {
    /// 转成 SwiftUI 颜色（按 sRGB 解释数值）。
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// 换色相、保留饱和度与明度。取色器的色相条用它。
    func withHue(_ degrees: Double) -> RGBAColor {
        let (_, saturation, brightness) = hslComponents
        return Self.fromHSL(hue: degrees, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    /// 当前色的色相角（度）。
    var hue: Double {
        hslComponents.hue
    }

    private var hslComponents: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = Swift.max(red, green, blue)
        let minValue = Swift.min(red, green, blue)
        let delta = maxValue - minValue

        var hue: Double = 0
        if delta > 0 {
            if maxValue == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }

        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }

    private static func fromHSL(
        hue: Double,
        saturation: Double,
        brightness: Double,
        alpha: Double
    ) -> RGBAColor {
        let chroma = brightness * saturation
        let normalizedHue = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(normalizedHue.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma

        let rgb: (Double, Double, Double)
        switch Int(normalizedHue) {
        case 0: rgb = (chroma, x, 0)
        case 1: rgb = (x, chroma, 0)
        case 2: rgb = (0, chroma, x)
        case 3: rgb = (0, x, chroma)
        case 4: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        return RGBAColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: alpha)
    }
}
