import TapSnapTheme
import SwiftUI

/// 以细环和旋转弧线表示正在加载。
public struct LoadingIndicator: View {
    public var theme: Theme
    public var size: CGFloat
    @State private var isAnimating = false

    public init(theme: Theme = .dark, size: CGFloat = 16) {
        self.theme = theme
        self.size = size
    }

    public var body: some View {
        Circle()
            .stroke(theme.token(.muted), lineWidth: lineWidth)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        theme.token(.primary),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }

    private var lineWidth: CGFloat {
        max(1.5, size / 9)
    }
}

/// 带文字的加载状态行。
public struct LoadingLabel: View {
    public var theme: Theme
    public var text: String

    public init(theme: Theme = .dark, text: String) {
        self.theme = theme
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 8) {
            LoadingIndicator(theme: theme, size: 12)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
        }
    }
}

/// 多选下拉控件，例如用于设置 OCR 语言。
///
/// 触发器做成 shadcn 的 Select：`background` 底 + `input` 描边。
public struct MultiSelectComboBox<Item: Hashable & CustomStringConvertible>: View {
    public var theme: Theme
    public var items: [Item]
    @Binding public var selection: Set<Item>
    public var placeholder: String

    @State private var isHovering = false

    public init(
        theme: Theme = .dark,
        items: [Item],
        selection: Binding<Set<Item>>,
        placeholder: String = "请选择"
    ) {
        self.theme = theme
        self.items = items
        self._selection = selection
        self.placeholder = placeholder
    }

    public var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {
                    if selection.contains(item) {
                        selection.remove(item)
                    } else {
                        selection.insert(item)
                    }
                } label: {
                    Text(selection.contains(item) ? "✓ \(item.description)" : "   \(item.description)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(displayText)
                    .font(.system(size: 12))
                    .foregroundStyle(selection.isEmpty ? theme.token(.mutedForeground) : theme.token(.foreground))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(minWidth: 130)
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .fill(isHovering ? theme.token(.accent) : theme.token(.background))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .strokeBorder(theme.token(.input), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
    }

    private var displayText: String {
        selection.isEmpty
            ? placeholder
            : selection.map(\.description).sorted().joined(separator: ", ")
    }
}
