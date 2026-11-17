import TapSnapCore
import TapSnapTheme
import SwiftUI

/// 取色器面板。
///
/// 截图标注时选颜色：色相条、透明度滑块、十六进制输入、最近使用色。
public struct ColorPickerPanel: View {
    public var theme: Theme
    @Binding public var color: RGBAColor
    public var recentColors: [RGBAColor]
    public var onCommit: ((RGBAColor) -> Void)?
    public var supportsOpacity: Bool

    @State private var hexText: String?

    public init(
        theme: Theme = .dark,
        color: Binding<RGBAColor>,
        recentColors: [RGBAColor] = [],
        supportsOpacity: Bool = true,
        onCommit: ((RGBAColor) -> Void)? = nil
    ) {
        self.theme = theme
        self._color = color
        self.recentColors = recentColors
        self.onCommit = onCommit
        self.supportsOpacity = supportsOpacity
    }

    public var body: some View {
        FloatPanel(theme: theme, padding: 12) {
            // 当前色预览 + 十六进制输入
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .fill(color.color)
                    .frame(width: 30, height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                            .strokeBorder(theme.token(.border), lineWidth: 1)
                    )

                SnapTextField(
                    text: Binding(
                        get: { hexText ?? color.hex },
                        set: { newValue in
                            hexText = newValue
                            if let parsed = RGBAColor(hex: newValue) { color = parsed }
                        }
                    ),
                    theme: theme,
                    placeholder: "#000000",
                    width: 92,
                    monospaced: true
                )
                .accessibilityLabel("十六进制颜色")
            }

            // 色相条
            HueSlider(theme: theme, hue: color.hue) { hue in
                // 与色相条的饱和度和亮度一致，选黑白色后仍能直接取彩色。
                color = RGBAColor(red: 0.95, green: 0.1425, blue: 0.1425, alpha: color.alpha).withHue(hue)
                hexText = nil
            }

            if supportsOpacity {
                HStack(spacing: 8) {
                    Text("颜色不透明度")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Slider(
                        value: Binding(
                            get: { color.alpha },
                            set: { value in
                                color = RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: value)
                                hexText = nil
                            }
                        ),
                        in: 0...1
                    )
                    .frame(width: 140)
                    .accessibilityLabel("颜色不透明度")
                }
            }

            if !recentColors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    PanelSectionTitle("最近使用", theme: theme)
                    HStack(spacing: 5) {
                        ForEach(Array(recentColors.enumerated()), id: \.offset) { _, recent in
                            ColorSwatchDot(theme: theme, color: recent) {
                                color = recent
                                hexText = nil
                                onCommit?(recent)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: color) { _, newColor in
            // 保留正在输入的有效 HEX；外部色块改色时清除过期草稿。
            if let hexText, RGBAColor(hex: hexText) != newColor { self.hexText = nil }
        }
    }
}

/// 单个最近色圆点。
struct ColorSwatchDot: View {
    var theme: Theme
    var color: RGBAColor
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(theme.token(.border), lineWidth: 1))
                .scaleEffect(isHovering ? 1.15 : 1)
        }
        .buttonStyle(SnapPressStyle(scale: 0.9))
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
    }
}

/// 色相条。拖动取色，饱和度与明度固定，够标注用。
struct HueSlider: View {
    var theme: Theme
    var hue: Double
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                    Color(hue: $0 / 360, saturation: 0.85, brightness: 0.95)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(Capsule())
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let ratio = min(max(gesture.location.x / proxy.size.width, 0), 1)
                        onChange(ratio * 360)
                    }
            )
        }
        .frame(height: 14)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: onChange(max(0, hue - 3))
            case .right, .up: onChange(min(360, hue + 3))
            default: break
            }
        }
        .accessibilityLabel("色相")
        .accessibilityValue("\(Int(hue)) 度")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(360, hue + 3))
            case .decrement: onChange(max(0, hue - 3))
            @unknown default: break
            }
        }
    }
}

/// 透明度滑块。
public struct OpacitySlider: View {
    public var theme: Theme
    @Binding public var value: Double
    public var range: ClosedRange<Double>

    public init(theme: Theme = .dark, value: Binding<Double>, range: ClosedRange<Double> = 0...1) {
        self.theme = theme
        self._value = value
        self.range = range
    }

    public var body: some View {
        SnapSlider(value: $value, in: range, theme: theme, width: 120)
    }
}
