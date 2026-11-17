import SwiftUI
import TapSnapActionsBar
import TapSnapIcons
import TapSnapMedia
import TapSnapTheme
import TapSnapUI

@MainActor
final class RecordingAnnotationToolbarState: ObservableObject {
    @Published var selectedTool: RecordingAnnotation.Kind?
    @Published var isEnabled = false
    @Published var canUndo = false
    @Published var canRedo = false
}

struct RecordingAnnotationToolbar: View {
    @ObservedObject var state: RecordingAnnotationToolbarState
    let theme: Theme
    let select: (RecordingAnnotation.Kind) -> Void
    let undo: () -> Void
    let redo: () -> Void
    private let tools: [RecordingAnnotation.Kind] = [.arrow, .rectangle, .ellipse, .line, .pen, .highlight, .text, .mask]

    var body: some View {
        HStack(spacing: ActionsBarLayout.spacing) {
            ForEach(tools, id: \.self) { kind in
                IconButton(icon: kind.icon, theme: theme, isSelected: kind == state.selectedTool,
                           isEnabled: state.isEnabled) { select(kind) }
                    .accessibilityLabel(kind.title)
                    .help(kind.title)
            }
            PanelDivider(theme: theme)
            IconButton(icon: .undo, theme: theme, isEnabled: state.isEnabled && state.canUndo, action: undo)
                .help("撤销标注 ⌘Z")
            IconButton(icon: .redo, theme: theme, isEnabled: state.isEnabled && state.canRedo, action: redo)
                .help("重做标注 ⇧⌘Z")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ActionsBarLayout.horizontalPadding)
        .frame(height: theme.metrics.toolbarHeight)
        .background(EditCanvasView.chromeColor(for: theme).color, in: RoundedRectangle(cornerRadius: theme.metrics.radiusLG))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("录屏标注工具栏")
    }
}

private extension RecordingAnnotation.Kind {
    var icon: IconSet {
        switch self {
        case .arrow: return ActionKind.arrow.icon
        case .rectangle: return ActionKind.rectangle.icon
        case .ellipse: return ActionKind.ellipse.icon
        case .line: return ActionKind.line.icon
        case .pen: return ActionKind.pen.icon
        case .highlight: return ActionKind.highlight.icon
        case .text: return ActionKind.text.icon
        case .mask: return ActionKind.privacy.icon
        }
    }
}
