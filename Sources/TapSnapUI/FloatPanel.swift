import TapSnapIcons
import TapSnapTheme
import SwiftUI

/// 悬浮面板容器。
///
/// 点击按钮打开的小面板，可带分隔线，点击面板外部可关闭。
///
/// 外观按 shadcn 的 Popover：`popover` 底、1px `border`、`radius-lg` 圆角、
/// 内边距 12，投影散而淡。
public struct FloatPanel<Content: View>: View {
    public var theme: Theme
    public var showsArrow: Bool
    public var padding: CGFloat
    private let content: () -> Content

    public init(
        theme: Theme = .dark,
        showsArrow: Bool = false,
        padding: CGFloat = 12,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.theme = theme
        self.showsArrow = showsArrow
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 10) {
            content()
        }
        .padding(padding)
        .senPanelStyle(theme: theme)
        // TODO: 箭头指向触发按钮；用 NSPanel + 非活跃窗口接收点击关闭。
    }
}

/// 面板内的分隔线。
public struct PanelDivider: View {
    public var theme: Theme
    public var isVertical: Bool

    public init(theme: Theme = .dark, isVertical: Bool = true) {
        self.theme = theme
        self.isVertical = isVertical
    }

    public var body: some View {
        Rectangle()
            .fill(theme.token(.border))
            .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
            .padding(.horizontal, isVertical ? 3 : 0)
            .padding(.vertical, isVertical ? 4 : 3)
    }
}

/// 面板里的行（左标签右控件），设置项与参数面板复用。
public struct LabeledRow<Control: View>: View {
    public var title: String
    public var theme: Theme
    private let control: () -> Control

    public init(_ title: String, theme: Theme = .dark, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.theme = theme
        self.control = control
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
            Spacer(minLength: 10)
            control()
        }
        .frame(height: 26)
    }
}

/// 面板标题：小号灰字，用于给一段控件分组。
public struct PanelSectionTitle: View {
    public var text: String
    public var theme: Theme

    public init(_ text: String, theme: Theme) {
        self.text = text
        self.theme = theme
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(theme.token(.mutedForeground))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
