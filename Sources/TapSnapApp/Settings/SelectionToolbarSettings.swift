import SwiftUI
import TapSnapActionsBar
import TapSnapIcons
import TapSnapTheme
import TapSnapUI

struct SelectionToolbarSettings: View {
    let theme: Theme
    let save: ([String]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pinned: [ActionKind]?

    init(theme: Theme, identifiers: [String]?, save: @escaping ([String]?) -> Void) {
        self.theme = theme
        self.save = save
        _pinned = State(initialValue: SelectionToolbar.pinnedActions(from: identifiers))
    }

    var body: some View {
        let preview = SelectionToolbar.layout(availableWidth: theme.metrics.toolbarHeight * 9, pinned: pinned)
        let actions = pinned ?? (preview.annotationTools + preview.outputActions)
        let available = SelectionToolbar.availableActions.filter { !actions.contains($0) }

        VStack(alignment: .leading, spacing: 14) {
            Text("自定义框选工具栏").font(.headline)
            ActionsBarView(theme: theme, resolvedLayout: preview, showsHistory: false, showsToolTips: false,
                           onSelect: { _ in })
                .background(EditCanvasView.chromeColor(for: theme).color, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.token(.border)) }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            HStack {
                Text("常用按钮").font(.subheadline.weight(.semibold))
                Spacer()
                Menu("添加按钮") {
                    ForEach(available, id: \.self) { action in
                        Button { pinned = [action] + actions } label: {
                            Label(action.title, systemImage: action.icon.systemName)
                        }
                    }
                }
                .fixedSize()
                .disabled(available.isEmpty)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if actions.isEmpty {
                        Text("常用按钮已全部收起")
                            .foregroundStyle(theme.token(.mutedForeground))
                            .padding(12)
                    }
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        if index > 0 { SnapRowDivider(theme: theme) }
                        HStack(spacing: 10) {
                            IconView(icon: action.icon, size: 14, color: theme.token(.mutedForeground))
                                .accessibilityHidden(true)
                            Text(action.title)
                            Spacer()
                            Button { move(actions, from: index, by: -1) } label: {
                                Label("向上移动\(action.title)", systemImage: "chevron.up")
                            }
                            .disabled(index == 0)
                            .help("往左移")
                            Button { move(actions, from: index, by: 1) } label: {
                                Label("向下移动\(action.title)", systemImage: "chevron.down")
                            }
                            .disabled(index == actions.count - 1)
                            .help("往右移")
                            Button { pinned = actions.filter { $0 != action } } label: {
                                Label("将\(action.title)移入更多", systemImage: "minus.circle")
                            }
                            .help("移入更多")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .frame(height: theme.metrics.rowHeight)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 185)
            .senCardStyle(theme: theme)

            Text("列表从上到下对应工具栏从左到右。收起或放不下的按钮可从「更多」使用。")
                .font(.system(size: 11))
                .foregroundStyle(theme.token(.mutedForeground))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("恢复默认布局") { pinned = nil }
                    .disabled(pinned == nil)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    save(pinned?.map(\.rawValue))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 468)
        .foregroundStyle(theme.token(.foreground))
        .background(theme.token(.background))
    }

    private func move(_ actions: [ActionKind], from index: Int, by offset: Int) {
        var reordered = actions
        reordered.swapAt(index, index + offset)
        pinned = reordered
    }
}
