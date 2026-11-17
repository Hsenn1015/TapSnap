import TapSnapIcons
import TapSnapTheme
import SwiftUI

/// 气泡菜单项。
public struct BubbleMenuItem: Identifiable {
    public let id = UUID()
    public var icon: IconSet?
    public var title: String
    public var shortcut: String?
    public var isEnabled: Bool
    public var action: () -> Void

    public init(
        icon: IconSet? = nil,
        title: String,
        shortcut: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// 气泡菜单。
///
/// 截图工具栏的「更多」、贴图右键菜单都用它。外观按 shadcn 的 DropdownMenu：
/// 行高 30、悬停浮现 `accent` 底、快捷键右对齐显示为灰字。
public struct BubbleMenu: View {
    public var theme: Theme
    public var items: [BubbleMenuItem]
    public var columns: Int

    public init(theme: Theme = .dark, items: [BubbleMenuItem], columns: Int = 1) {
        self.theme = theme
        self.items = items
        self.columns = columns
    }

    public var body: some View {
        FloatPanel(theme: theme, padding: 5) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: max(1, columns)),
                spacing: 2
            ) {
                ForEach(items) { item in
                    BubbleMenuRow(theme: theme, item: item)
                }
            }
        }
    }
}

/// 菜单行。
struct BubbleMenuRow: View {
    var theme: Theme
    var item: BubbleMenuItem

    @State private var isHovering = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 8) {
                if let icon = item.icon {
                    IconView(
                        icon: icon,
                        size: 13,
                        color: item.isEnabled ? theme.token(.foreground) : theme.token(.mutedForeground)
                    )
                    .frame(width: 16)
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isEnabled ? theme.token(.foreground) : theme.token(.mutedForeground))
                Spacer(minLength: 12)
                if let shortcut = item.shortcut {
                    SnapKbd(shortcut, theme: theme)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: theme.metrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .fill(isHovering && item.isEnabled ? theme.token(.accent) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.98))
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.5)
    }
}

/// 菜单分隔线。
public struct BubbleMenuDivider: View {
    public var theme: Theme

    public init(theme: Theme) {
        self.theme = theme
    }

    public var body: some View {
        Rectangle()
            .fill(theme.token(.border))
            .frame(height: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
    }
}
