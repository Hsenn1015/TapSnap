import TapSnapIcons
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 编辑器和选区共用的工具栏。样式弹层由对应工具按钮锚定。
public struct ActionsBarView: View {
    public var theme: Theme
    public var model: ActionsBarModel
    public var selectedTool: ActionKind?
    public var canUndo: Bool
    public var canRedo: Bool
    public var annotationOptions: ((ActionKind) -> AnyView)?
    public var availableWidth: CGFloat?
    public var resolvedLayout: ActionsBarLayout?
    public var showsHistory: Bool
    public var showsToolTips: Bool
    public var usesNativeToolTips: Bool
    public var confirmationTitle: String
    public var cancellationTitle: String
    public var isOutputBlocked: Bool
    public var toolTip: (ActionKind) -> String
    public var onSelect: (ActionKind) -> Void

    @Binding private var openStyle: ActionKind?
    @State private var hoveredButton: HoverTarget?
    @State private var visibleTip: HoverTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum HoverTarget: Hashable {
        case action(ActionKind)
        case more
    }

    public init(
        theme: Theme = .dark,
        model: ActionsBarModel = ActionsBarModel(),
        selectedTool: ActionKind? = nil,
        canUndo: Bool = false,
        canRedo: Bool = false,
        openStyle: Binding<ActionKind?> = .constant(nil),
        annotationOptions: ((ActionKind) -> AnyView)? = nil,
        availableWidth: CGFloat? = nil,
        resolvedLayout: ActionsBarLayout? = nil,
        showsHistory: Bool = true,
        showsToolTips: Bool = true,
        usesNativeToolTips: Bool = false,
        confirmationTitle: String = "完成",
        cancellationTitle: String = "关闭编辑器",
        isOutputBlocked: Bool = false,
        toolTip: @escaping (ActionKind) -> String = { $0.title },
        onSelect: @escaping (ActionKind) -> Void
    ) {
        self.theme = theme
        self.model = model
        self.selectedTool = selectedTool
        self.canUndo = canUndo
        self.canRedo = canRedo
        self._openStyle = openStyle
        self.annotationOptions = annotationOptions
        self.availableWidth = availableWidth
        self.resolvedLayout = resolvedLayout
        self.showsHistory = showsHistory
        self.showsToolTips = showsToolTips
        self.usesNativeToolTips = usesNativeToolTips
        self.confirmationTitle = confirmationTitle
        self.cancellationTitle = cancellationTitle
        self.isOutputBlocked = isOutputBlocked
        self.toolTip = toolTip
        self.onSelect = onSelect
    }

    public var body: some View {
        let layout = resolvedLayout ?? model.layout(availableWidth: availableWidth, showsHistory: showsHistory)
        HStack(spacing: ActionsBarLayout.spacing) {
            ForEach(layout.annotationTools, id: \.self) { action in
                toolButton(action)
            }
            if layout.showsAnnotationDivider {
                PanelDivider(theme: theme)
            }
            if showsHistory {
                toolButton(.undo, enabled: canUndo)
                toolButton(.redo, enabled: canRedo)
                PanelDivider(theme: theme)
            }
            ForEach(layout.outputActions, id: \.self) { action in
                toolButton(action, enabled: !isOutputBlocked || !action.exportsImage)
            }
            if !layout.overflow.isEmpty {
                moreButton(layout.overflow)
            }
            PanelDivider(theme: theme)
            toolButton(.cancel)
            toolButton(.confirm, enabled: !isOutputBlocked)
                .padding(.leading, ActionsBarLayout.confirmLeadingPadding)
        }
        .padding(.horizontal, ActionsBarLayout.horizontalPadding)
        .frame(width: layout.width, height: theme.metrics.toolbarHeight)
        .overlayPreferenceValue(ToolbarTipAnchor.self) { anchor in
            if showsToolTips, !usesNativeToolTips, let visibleTip, let anchor, openStyle == nil {
                GeometryReader { proxy in
                    let bounds = proxy[anchor]
                    let title = hint(for: visibleTip)
                    let halfWidth = min(proxy.size.width / 2, CGFloat(title.count) * 6 + 10)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.token(.popoverForeground))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .fixedSize()
                        .background(theme.token(.popover), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(theme.token(.border), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                        .frame(width: 0, height: 0, alignment: .bottom)
                        .offset(x: min(max(bounds.midX, halfWidth), proxy.size.width - halfWidth),
                                y: bounds.minY - 6)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : Interaction.hover, value: visibleTip)
        .task(id: hoveredButton) {
            guard showsToolTips, !usesNativeToolTips, let target = hoveredButton, openStyle == nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, hoveredButton == target, openStyle == nil else { return }
            visibleTip = target
        }
        .onChange(of: selectedTool) { _, action in
            visibleTip = nil
            if openStyle != action { openStyle = nil }
        }
    }

    private func hint(for action: ActionKind) -> String {
        if action == .confirm {
            return isOutputBlocked ? "正在扫描隐私内容" : confirmationTitle
        }
        if action.exportsImage && isOutputBlocked { return "\(action.title) · 正在扫描隐私内容" }
        if action == .cancel { return cancellationTitle }
        return toolTip(action)
    }

    private func hint(for target: HoverTarget) -> String {
        switch target {
        case .action(let action): return hint(for: action)
        case .more: return "更多工具与操作"
        }
    }

    private func activate(_ action: ActionKind) {
        visibleTip = nil
        hoveredButton = nil
        let nextStyle = action.hasOptionsPanel && annotationOptions != nil && openStyle != action ? action : nil
        onSelect(action)
        openStyle = nextStyle
    }

    private func styleBinding(for actions: [ActionKind]) -> Binding<Bool> {
        Binding(
            get: { openStyle.map(actions.contains) ?? false },
            set: { presented in
                if !presented, let openStyle, actions.contains(openStyle) { self.openStyle = nil }
            }
        )
    }

    @ViewBuilder private func hover<V: View>(_ view: V, target: HoverTarget) -> some View {
        let tracked = view
            .onHover { inside in
                if inside {
                    hoveredButton = target
                    visibleTip = nil
                } else if hoveredButton == target {
                    hoveredButton = nil
                    visibleTip = nil
                }
            }
            .anchorPreference(key: ToolbarTipAnchor.self, value: .bounds) {
                visibleTip == target ? $0 : nil
            }
        if showsToolTips, usesNativeToolTips {
            tracked.help(hint(for: target))
        } else {
            tracked
        }
    }

    private func toolButton(_ action: ActionKind, enabled: Bool = true) -> some View {
        let label: String
        switch action {
        case .confirm: label = confirmationTitle
        case .cancel: label = cancellationTitle
        default: label = action.title
        }
        let button = IconButton(
            icon: action.icon,
            theme: theme,
            isSelected: selectedTool == action || openStyle == action || action == .confirm,
            isEnabled: enabled
        ) { activate(action) }
            .accessibilityLabel(label)
            .accessibilityHint(action == .privacy ? "打开打码工具、扫描和规则" :
                action.hasOptionsPanel ? "点击选择工具并打开样式" : hint(for: action))
            .accessibilityIdentifier("editor-tool-\(action.rawValue)")
        return hover(button, target: .action(action))
            .popover(isPresented: styleBinding(for: [action]), arrowEdge: .top) {
                annotationOptions?(action)
            }
    }

    private func moreButton(_ actions: [ActionKind]) -> some View {
        let selected = (selectedTool.map(actions.contains) ?? false) || (openStyle.map(actions.contains) ?? false)
        let menu = Menu {
            ForEach(actions, id: \.self) { action in
                Button {
                    // Wait for the native menu to release its mouse tracking before showing the popover.
                    DispatchQueue.main.async { activate(action) }
                } label: {
                    Label(hint(for: action), systemImage: selectedTool == action ? "checkmark" : action.icon.systemName)
                }
                .disabled(isOutputBlocked && action.exportsImage)
            }
        } label: {
            IconView(icon: .more, size: theme.metrics.iconSize,
                     color: theme.token(selected ? .primaryForeground : .foreground))
                .frame(width: ActionsBarLayout.buttonSize, height: ActionsBarLayout.buttonSize)
                .background(theme.token(selected ? .primary : .accent).opacity(selected || hoveredButton == .more ? 1 : 0),
                            in: RoundedRectangle(cornerRadius: theme.metrics.radiusMD))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: ActionsBarLayout.buttonSize, height: ActionsBarLayout.buttonSize)
        .accessibilityLabel("更多工具与操作")
        return hover(menu, target: .more)
            .popover(isPresented: styleBinding(for: actions), arrowEdge: .top) {
                if let openStyle, actions.contains(openStyle) { annotationOptions?(openStyle) }
            }
    }
}

private struct ToolbarTipAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}
