import TapSnapCore
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 色块列表。
///
/// 一排小圆点，点一下选中；右键可加入/移出常用色。
public struct ColorBlockList: View {
    public var theme: Theme
    public var colors: [RGBAColor]
    @Binding public var selected: RGBAColor?

    public init(theme: Theme = .dark, colors: [RGBAColor], selected: Binding<RGBAColor?>) {
        self.theme = theme
        self.colors = colors
        self._selected = selected
    }

    public var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                ColorBlock(theme: theme, color: color, isSelected: selected == color)
                    .onTapGesture { selected = color }
            }
        }
    }
}

public struct ColorBlock: View {
    public var theme: Theme
    public var color: RGBAColor
    public var isSelected: Bool
    public var diameter: CGFloat

    @State private var isHovering = false

    public init(theme: Theme = .dark, color: RGBAColor, isSelected: Bool = false, diameter: CGFloat = 18) {
        self.theme = theme
        self.color = color
        self.isSelected = isSelected
        self.diameter = diameter
    }

    public var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: diameter, height: diameter)
            // 选中态用一圈 ring 外扩，和 shadcn 的 focus ring 一致
            .overlay(
                Circle().strokeBorder(
                    theme.token(.background),
                    lineWidth: isSelected ? 2 : 0
                )
            )
            .padding(isSelected ? 2 : 0)
            .background {
                Circle()
                    .fill(isSelected ? theme.token(.ring) : .clear)
            }
            .overlay(
                Circle().strokeBorder(
                    isHovering ? theme.token(.ring) : theme.token(.border),
                    lineWidth: 1
                )
            )
            .scaleEffect(isHovering ? 1.08 : 1)
            .animation(Interaction.hover, value: isHovering)
            .animation(Interaction.toggle, value: isSelected)
            .contentShape(Circle())
            .onHoverChange { isHovering = $0 }
    }
}

/// 包含标签的数值滑块，可用于调整透明度或尺寸。
public struct ValueSlider: View {
    public var theme: Theme
    public var title: String
    @Binding public var value: Double
    public var range: ClosedRange<Double>
    public var unit: String

    public init(
        theme: Theme = .dark,
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double> = 0...1,
        unit: String = ""
    ) {
        self.theme = theme
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
                .frame(width: 48, alignment: .leading)
            SnapSlider(value: $value, in: range, theme: theme, width: 120)
            Text("\(Int(value))\(unit)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.token(.mutedForeground))
                .frame(width: 36, alignment: .trailing)
        }
    }
}
