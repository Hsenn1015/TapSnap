import CoreGraphics
import Foundation

/// 与平台无关的 RGBA 颜色值。
///
/// 将颜色值和持久化格式与 AppKit、SwiftUI 的颜色对象分开。
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// 从 0xRRGGBB 形式的整数构造。
    public init(rgb: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static let clear = RGBAColor(white: 0, alpha: 0)
    public static let black = RGBAColor(white: 0)
    public static let white = RGBAColor(white: 1)

    public var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// "#RRGGBB" 或 "#RRGGBBAA"，与取色器输入框的格式一致。
    public var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        let a = Int((alpha * 255).rounded())
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(text, radix: 16) else { return nil }
        switch text.count {
        case 6:
            self.init(rgb: UInt32(value))
        case 8:
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        default:
            return nil
        }
    }
}

/// 截图时对单个像素取色的结果。
public struct PickedColor: Codable, Hashable, Sendable {
    public var color: RGBAColor
    public var point: CGPoint
    /// 该点所属屏幕的比例，用于把逻辑点换算成像素点。
    public var scale: Double

    public init(color: RGBAColor, point: CGPoint, scale: Double = 1) {
        self.color = color
        self.point = point
        self.scale = scale
    }

    public var pixelPoint: CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }
}
