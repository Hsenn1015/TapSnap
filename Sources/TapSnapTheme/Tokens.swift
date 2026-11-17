import Foundation
import TapSnapCore

// shadcn/ui 的主题 token，原样搬到 Swift。
//
// 官方主题是一组 CSS 变量（`--background`、`--primary`…），值写成 oklch 颜色空间。
// 这里做两件事：实现 oklch -> sRGB 的转换，再把 light / dark 两套 token 表落成常量。
// 这样界面上任何位置都只引用语义 token，不出现写死的颜色值。
//
// 取值来自 https://ui.shadcn.com/docs/theming 的 Neutral 基色默认主题。

// MARK: - 颜色空间

/// oklch 颜色。L 为明度 0...1，C 为彩度，H 为色相角（度）。
public struct OKLCH: Hashable, Sendable {
    public var lightness: Double
    public var chroma: Double
    public var hue: Double
    public var alpha: Double

    public init(_ lightness: Double, _ chroma: Double, _ hue: Double, alpha: Double = 1) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
        self.alpha = alpha
    }
}

public enum ColorConversion {
    /// oklch -> sRGB。走 oklch -> oklab -> LMS -> linear sRGB -> gamma 编码这条标准路径。
    public static func sRGB(from color: OKLCH) -> RGBAColor {
        let radians = color.hue * .pi / 180
        let a = color.chroma * cos(radians)
        let b = color.chroma * sin(radians)

        let lPrime = color.lightness + 0.3963377774 * a + 0.2158037573 * b
        let mPrime = color.lightness - 0.1055613458 * a - 0.0638541728 * b
        let sPrime = color.lightness - 0.0894841775 * a - 1.2914855480 * b

        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime

        let linearRed = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let linearGreen = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let linearBlue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        return RGBAColor(
            red: gammaEncode(linearRed),
            green: gammaEncode(linearGreen),
            blue: gammaEncode(linearBlue),
            alpha: color.alpha
        )
    }

    private static func gammaEncode(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        let encoded = clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return encoded
    }
}

// MARK: - Token

/// shadcn 的语义色 token。
///
/// 命名与官方一致：`background` 是色面，`xxxForeground` 是落在该色面上的文字/图标色。
public enum DesignToken: String, CaseIterable, Sendable {
    case background
    case foreground
    case card
    case cardForeground
    case popover
    case popoverForeground
    case primary
    case primaryForeground
    case secondary
    case secondaryForeground
    case muted
    case mutedForeground
    case accent
    case accentForeground
    case destructive
    case destructiveForeground
    case border
    case input
    case ring

    case chart1, chart2, chart3, chart4, chart5

    case sidebar
    case sidebarForeground
    case sidebarPrimary
    case sidebarPrimaryForeground
    case sidebarAccent
    case sidebarAccentForeground
    case sidebarBorder
    case sidebarRing
}

public enum DesignTokens {
    /// radius 基准值，对应 CSS 里的 `--radius: 0.625rem`。
    public static let baseRadius: CGFloat = 10

    /// shadcn 按倍数从基准值派生出的小尺度。
    public static let radiusSM: CGFloat = baseRadius * 0.6
    public static let radiusMD: CGFloat = baseRadius * 0.8
    public static let radiusLG: CGFloat = baseRadius
    public static let radiusXL: CGFloat = baseRadius * 1.4
    public static let radius2XL: CGFloat = baseRadius * 1.8

    /// 浅色主题（`:root`）。
    public static func lightValue(_ token: DesignToken) -> RGBAColor {
        let value: OKLCH
        switch token {
        case .background: value = OKLCH(1, 0, 0)
        case .foreground: value = OKLCH(0.145, 0, 0)
        case .card: value = OKLCH(1, 0, 0)
        case .cardForeground: value = OKLCH(0.145, 0, 0)
        case .popover: value = OKLCH(1, 0, 0)
        case .popoverForeground: value = OKLCH(0.145, 0, 0)
        case .primary: value = OKLCH(0.205, 0, 0)
        case .primaryForeground: value = OKLCH(0.985, 0, 0)
        case .secondary: value = OKLCH(0.97, 0, 0)
        case .secondaryForeground: value = OKLCH(0.205, 0, 0)
        case .muted: value = OKLCH(0.97, 0, 0)
        case .mutedForeground: value = OKLCH(0.556, 0, 0)
        case .accent: value = OKLCH(0.97, 0, 0)
        case .accentForeground: value = OKLCH(0.205, 0, 0)
        case .destructive: value = OKLCH(0.577, 0.245, 27.325)
        case .destructiveForeground: value = OKLCH(0.985, 0, 0)
        case .border: value = OKLCH(0.922, 0, 0)
        case .input: value = OKLCH(0.922, 0, 0)
        case .ring: value = OKLCH(0.708, 0, 0)
        case .chart1: value = OKLCH(0.646, 0.222, 41.116)
        case .chart2: value = OKLCH(0.6, 0.118, 184.704)
        case .chart3: value = OKLCH(0.398, 0.07, 227.392)
        case .chart4: value = OKLCH(0.828, 0.189, 84.429)
        case .chart5: value = OKLCH(0.769, 0.188, 70.08)
        case .sidebar: value = OKLCH(0.985, 0, 0)
        case .sidebarForeground: value = OKLCH(0.145, 0, 0)
        case .sidebarPrimary: value = OKLCH(0.205, 0, 0)
        case .sidebarPrimaryForeground: value = OKLCH(0.985, 0, 0)
        case .sidebarAccent: value = OKLCH(0.97, 0, 0)
        case .sidebarAccentForeground: value = OKLCH(0.205, 0, 0)
        case .sidebarBorder: value = OKLCH(0.922, 0, 0)
        case .sidebarRing: value = OKLCH(0.708, 0, 0)
        }
        return ColorConversion.sRGB(from: value)
    }

    /// 深色主题（`.dark`）。官方在这里用了半透明的 border / input。
    public static func darkValue(_ token: DesignToken) -> RGBAColor {
        let value: OKLCH
        switch token {
        case .background: value = OKLCH(0.145, 0, 0)
        case .foreground: value = OKLCH(0.985, 0, 0)
        case .card: value = OKLCH(0.205, 0, 0)
        case .cardForeground: value = OKLCH(0.985, 0, 0)
        case .popover: value = OKLCH(0.205, 0, 0)
        case .popoverForeground: value = OKLCH(0.985, 0, 0)
        case .primary: value = OKLCH(0.922, 0, 0)
        case .primaryForeground: value = OKLCH(0.205, 0, 0)
        case .secondary: value = OKLCH(0.269, 0, 0)
        case .secondaryForeground: value = OKLCH(0.985, 0, 0)
        case .muted: value = OKLCH(0.269, 0, 0)
        case .mutedForeground: value = OKLCH(0.708, 0, 0)
        case .accent: value = OKLCH(0.269, 0, 0)
        case .accentForeground: value = OKLCH(0.985, 0, 0)
        case .destructive: value = OKLCH(0.704, 0.191, 22.216)
        case .destructiveForeground: value = OKLCH(0.985, 0, 0)
        case .border: value = OKLCH(1, 0, 0, alpha: 0.10)
        case .input: value = OKLCH(1, 0, 0, alpha: 0.15)
        case .ring: value = OKLCH(0.556, 0, 0)
        case .chart1: value = OKLCH(0.488, 0.243, 264.376)
        case .chart2: value = OKLCH(0.696, 0.17, 162.48)
        case .chart3: value = OKLCH(0.769, 0.188, 70.08)
        case .chart4: value = OKLCH(0.627, 0.265, 303.9)
        case .chart5: value = OKLCH(0.645, 0.246, 16.439)
        case .sidebar: value = OKLCH(0.205, 0, 0)
        case .sidebarForeground: value = OKLCH(0.985, 0, 0)
        case .sidebarPrimary: value = OKLCH(0.488, 0.243, 264.376)
        case .sidebarPrimaryForeground: value = OKLCH(0.985, 0, 0)
        case .sidebarAccent: value = OKLCH(0.269, 0, 0)
        case .sidebarAccentForeground: value = OKLCH(0.985, 0, 0)
        case .sidebarBorder: value = OKLCH(1, 0, 0, alpha: 0.10)
        case .sidebarRing: value = OKLCH(0.556, 0, 0)
        }
        return ColorConversion.sRGB(from: value)
    }

    /// 字体规格。shadcn 的默认字号是 14px，小字 12px，标题 16px。
    public enum Typography {
        public static let title: CGFloat = 16
        public static let body: CGFloat = 13
        public static let label: CGFloat = 12
        public static let caption: CGFloat = 11

        public static let codeWidth: CGFloat = 11
    }
}
