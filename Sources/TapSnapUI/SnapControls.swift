import TapSnapTheme
import SwiftUI

// 基础表单控件：融合 macOS 原生质感（系统蓝强调、柔和层次与清晰焦点环）
// 与细腻交互手感（按压回弹、滑块步进与键盘无障碍支持）。

extension Theme {
    /// 控件激活态主色（macOS 系统蓝，浅/深色自动适配）。
    public var controlAccent: Color {
        isDark
            ? Color(red: 0.04, green: 0.52, blue: 1.0)
            : Color(red: 0.0, green: 0.48, blue: 1.0)
    }

    /// 设置页画布底色：比卡片略深/略沉，让分组卡片自然浮起。
    public var settingsCanvas: Color {
        isDark
            ? Color(red: 0.095, green: 0.100, blue: 0.115)
            : Color(red: 0.955, green: 0.960, blue: 0.972)
    }

    /// 设置分组卡片表面色。
    public var settingsCardSurface: Color {
        isDark
            ? Color(red: 0.135, green: 0.142, blue: 0.165)
            : Color.white
    }

    /// 设置分组卡片描边色。
    public var settingsCardBorder: Color {
        isDark ? Color.white.opacity(0.085) : Color.black.opacity(0.075)
    }

    /// 输入框柔和底色。
    public var fieldSurface: Color {
        isDark ? Color.black.opacity(0.24) : Color.black.opacity(0.028)
    }
}

/// 开关。macOS 系统蓝激活轨 + 柔和白色圆钮。
public struct SnapToggle: View {
    @Binding public var isOn: Bool
    public var theme: Theme

    @Environment(\.snapRowTitle) private var rowTitle

    public init(isOn: Binding<Bool>, theme: Theme) {
        self._isOn = isOn
        self.theme = theme
    }

    private let trackWidth: CGFloat = 38
    private let trackHeight: CGFloat = 21
    private let knobSize: CGFloat = 17

    public var body: some View {
        Button {
            withAnimation(Interaction.toggle) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? theme.controlAccent : offTrackColor)
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                isOn ? Color.clear : (theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)),
                                lineWidth: 0.75
                            )
                    }
                    .frame(width: trackWidth, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(theme.isDark ? 0.32 : 0.18), radius: 2, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.95))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .snapRowAccessibilityLabel(rowTitle)
        .accessibilityValue(isOn ? "开" : "关")
    }

    private var offTrackColor: Color {
        theme.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }
}

/// 滑块。细轨 + 立体白钮，支持步进、延迟落盘回调、键盘 ←→ 与 VoiceOver。
public struct SnapSlider: View {
    @Binding public var value: Double
    public var range: ClosedRange<Double>
    public var step: Double?
    public var theme: Theme
    public var width: CGFloat
    public var onEditingChanged: ((Bool) -> Void)?

    @State private var isHovering = false
    @State private var isDragging = false
    @Environment(\.snapRowTitle) private var rowTitle

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        theme: Theme,
        width: CGFloat = 140,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.theme = theme
        self.width = width
        self.onEditingChanged = onEditingChanged
    }

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    private var increment: Double {
        step ?? (range.upperBound - range.lowerBound) / 20
    }

    private func snapped(_ raw: Double) -> Double {
        var result = raw.clamped(to: range)
        if let step, step > 0 {
            result = range.lowerBound + ((result - range.lowerBound) / step).rounded() * step
            result = result.clamped(to: range)
        }
        return result
    }

    private func adjust(by delta: Double) {
        let next = snapped(value + delta)
        if next != value { value = next }
    }

    public var body: some View {
        GeometryReader { proxy in
            let trackHeight: CGFloat = 4.5
            let knobSize: CGFloat = (isHovering || isDragging) ? 15 : 13.5
            let usableWidth = max(1, proxy.size.width - knobSize)
            let fillWidth = knobSize / 2 + usableWidth * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(theme.controlAccent)
                    .frame(width: max(trackHeight, fillWidth), height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isDragging ? theme.controlAccent : Color.black.opacity(theme.isDark ? 0.12 : 0.14),
                                lineWidth: isDragging ? 1.5 : 0.75
                            )
                    )
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: usableWidth * progress)
                    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.18), radius: 2.5, y: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let ratio = ((gesture.location.x - knobSize / 2) / usableWidth).clamped(to: 0...1)
                        let next = snapped(range.lowerBound + ratio * (range.upperBound - range.lowerBound))
                        if next != value { value = next }
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(width: width, height: 22)
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
        .onDisappear {
            if isDragging {
                isDragging = false
                onEditingChanged?(false)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: adjust(by: -increment)
            case .right, .up: adjust(by: increment)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .snapRowAccessibilityLabel(rowTitle)
        .accessibilityValue(Text(step.map { $0 >= 1 ? String(Int(value.rounded())) : String(format: "%.2f", value) }
            ?? "\(Int((progress * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: increment)
            case .decrement: adjust(by: -increment)
            @unknown default: break
            }
        }
    }
}

/// 分段切换，柔和胶囊底 + 浮起滑块。
public struct SnapSegmented<Item: Hashable>: View {
    public var items: [Item]
    @Binding public var selection: Item
    public var theme: Theme
    public var fullWidth: Bool
    public var title: (Item) -> String

    @Namespace private var namespace
    @Environment(\.snapRowTitle) private var rowTitle

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
                    .padding(.horizontal, fullWidth ? 8 : 11)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(theme.isDark ? Color(red: 0.22, green: 0.23, blue: 0.27) : Color.white)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .strokeBorder(
                                            theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                                            lineWidth: 0.75
                                        )
                                }
                                .matchedGeometryEffect(id: "segment", in: namespace)
                                .shadow(color: .black.opacity(theme.isDark ? 0.28 : 0.08), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Interaction.toggle) { selection = item }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title(item))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { withAnimation(Interaction.toggle) { selection = item } }
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(theme.isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.055))
        }
        .accessibilityElement(children: .contain)
        .snapRowAccessibilityLabel(rowTitle)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let index = items.firstIndex(of: selection) else { return }
            let next: Int
            switch direction {
            case .left: next = max(index - 1, 0)
            case .right: next = min(index + 1, items.count - 1)
            default: return
            }
            guard next != index else { return }
            withAnimation(Interaction.toggle) { selection = items[next] }
        }
    }
}

/// 输入框。柔和内陷底 + 聚焦系统蓝光环，高度更舒展。
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
            .padding(.horizontal, 10)
            .frame(width: width, height: 30)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(isFocused ? theme.settingsCardSurface : theme.fieldSurface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .strokeBorder(
                        isFocused ? theme.controlAccent : theme.settingsCardBorder,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .shadow(color: isFocused ? theme.controlAccent.opacity(0.18) : .clear, radius: 3)
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
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.token(.foreground))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
                .environment(\.snapRowTitle, title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// 一组设置在视觉上的一张浮起卡片。
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
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .padding(.leading, 6)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(theme.settingsCardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(theme.settingsCardBorder, lineWidth: 0.75)
            }
            .shadow(
                color: Color.black.opacity(theme.isDark ? 0.22 : 0.045),
                radius: theme.isDark ? 8 : 5,
                y: theme.isDark ? 3 : 1.5
            )
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
            .fill(theme.isDark ? Color.white.opacity(0.065) : Color.black.opacity(0.06))
            .frame(height: 0.75)
            .padding(.leading, 16)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private struct SnapRowTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// 所在设置行的标题，供控件作为无障碍标签。
    public var snapRowTitle: String? {
        get { self[SnapRowTitleKey.self] }
        set { self[SnapRowTitleKey.self] = newValue }
    }
}

extension View {
    /// 有行标题时设为无障碍标签；没有时保持原样。
    @ViewBuilder
    func snapRowAccessibilityLabel(_ title: String?) -> some View {
        if let title {
            accessibilityLabel(title)
        } else {
            self
        }
    }
}
