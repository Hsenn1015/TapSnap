import TapSnapTheme
import SwiftUI

// 基础表单控件。外观按 shadcn 的 Switch / Slider / Tabs / Input 来，
// 交互按 bencho 的手感来（按压回弹、滑块跟随、切换有弹簧）。

/// 开关。shadcn 的 Switch：选中用 primary 底，圆点滑动。
public struct SnapToggle: View {
    @Binding public var isOn: Bool
    public var theme: Theme

    public init(isOn: Binding<Bool>, theme: Theme) {
        self._isOn = isOn
        self.theme = theme
    }

    private let trackWidth: CGFloat = 34
    private let trackHeight: CGFloat = 19
    private let knobSize: CGFloat = 15

    public var body: some View {
        Button {
            withAnimation(Interaction.toggle) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? theme.token(.primary) : theme.token(.input))
                    .frame(width: trackWidth, height: trackHeight)
                Circle()
                    .fill(isOn ? theme.token(.primaryForeground) : theme.token(.background))
                    .frame(width: knobSize, height: knobSize)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.94))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 滑块。细轨 + 圆钮，拖到哪轨填到哪。
public struct SnapSlider: View {
    @Binding public var value: Double
    public var range: ClosedRange<Double>
    public var theme: Theme
    public var width: CGFloat

    @State private var isHovering = false

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        theme: Theme,
        width: CGFloat = 140
    ) {
        self._value = value
        self.range = range
        self.theme = theme
        self.width = width
    }

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    public var body: some View {
        GeometryReader { proxy in
            let trackHeight: CGFloat = 4
            let knobSize: CGFloat = isHovering ? 14 : 12

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.token(.input))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(theme.token(.primary))
                    .frame(width: max(0, proxy.size.width * progress), height: trackHeight)

                Circle()
                    .fill(theme.token(.background))
                    .overlay(Circle().strokeBorder(theme.token(.primary), lineWidth: 1.5))
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: max(0, proxy.size.width * progress - knobSize / 2))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let ratio = (gesture.location.x / proxy.size.width).clamped(to: 0...1)
                        value = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(width: width, height: 20)
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
    }
}

/// 分段切换，shadcn 的 Tabs（pill 版）。
public struct SnapSegmented<Item: Hashable>: View {
    public var items: [Item]
    @Binding public var selection: Item
    public var theme: Theme
    public var fullWidth: Bool
    public var title: (Item) -> String

    @Namespace private var namespace

    public init(
        items: [Item],
        selection: Binding<Item>,
        theme: Theme,
        fullWidth: Bool = false,
        title: @escaping (Item) -> String
    ) {
        self.items = items
        self._selection = selection
        self.theme = theme
        self.fullWidth = fullWidth
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Text(title(item))
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? theme.token(.foreground) : theme.token(.mutedForeground))
                    .lineLimit(1)
                    .padding(.horizontal, fullWidth ? 6 : 10)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                                .fill(theme.token(.background))
                                .matchedGeometryEffect(id: "segment", in: namespace)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Interaction.toggle) { selection = item }
                    }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous)
                .fill(theme.token(.muted))
        }
    }
}

/// 输入框，shadcn 的 Input。
public struct SnapTextField: View {
    @Binding public var text: String
    public var theme: Theme
    public var placeholder: String
    public var width: CGFloat?
    public var monospaced: Bool

    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        theme: Theme,
        placeholder: String = "",
        width: CGFloat? = nil,
        monospaced: Bool = false
    ) {
        self._text = text
        self.theme = theme
        self.placeholder = placeholder
        self.width = width
        self.monospaced = monospaced
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(theme.token(.foreground))
            .padding(.horizontal, 8)
            .frame(width: width, height: 26)
            .fixedSize(horizontal: width == nil, vertical: true)
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .fill(theme.token(.background))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .strokeBorder(
                        isFocused ? theme.token(.ring) : theme.token(.input),
                        lineWidth: 1
                    )
            }
            .focused($isFocused)
            .animation(Interaction.hover, value: isFocused)
    }
}

/// 设置页里的「一行」：左边标题 + 说明，右边控件。
public struct SnapSettingRow<Control: View>: View {
    public var title: String
    public var subtitle: String?
    public var theme: Theme
    private let control: () -> Control

    public init(
        _ title: String,
        subtitle: String? = nil,
        theme: Theme,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.control = control
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.token(.foreground))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }
}

/// 一组设置在视觉上的一张卡片。
public struct SnapSettingGroup<Content: View>: View {
    public var title: String?
    public var theme: Theme
    private let content: () -> Content

    public init(_ title: String? = nil, theme: Theme, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.theme = theme
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .senCardStyle(theme: theme)
        }
    }
}

/// 分组卡片内的行间分隔，缩进对齐内容。
public struct SnapRowDivider: View {
    public var theme: Theme

    public init(theme: Theme) {
        self.theme = theme
    }

    public var body: some View {
        Rectangle()
            .fill(theme.token(.border))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
