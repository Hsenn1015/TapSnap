import SwiftUI
import TapSnapActionsBar
import TapSnapCore
import TapSnapIcons
import TapSnapMedia
import TapSnapTheme
import TapSnapUI

@MainActor
final class RecordingAnnotationToolbarState: ObservableObject {
    @Published var selectedTool: RecordingAnnotation.Kind?
    @Published var activeColor: RGBAColor?
    @Published var showsQuickColors = false
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
    var selectQuickColor: ((RGBAColor) -> Void)? = nil

    private let tools: [RecordingAnnotation.Kind] = [.arrow, .rectangle, .ellipse, .line, .pen, .highlight, .text, .mask]
    private let quickSwatches: [UInt32] = [0xEF4444, 0xF59E0B, 0x22C55E, 0x3B82F6, 0xA855F7]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tools, id: \.self) { kind in
                IconButton(icon: kind.icon, theme: theme, isSelected: kind == state.selectedTool,
                           isEnabled: state.isEnabled) { select(kind) }
                    .accessibilityLabel(kind.title)
                    .help(kind.title)
            }

            if state.showsQuickColors, let selectQuickColor {
                PanelDivider(theme: theme)
                HStack(spacing: 5) {
                    ForEach(quickSwatches, id: \.self) { rgb in
                        let swatch = RGBAColor(rgb: rgb)
                        let selected = state.activeColor.map {
                            abs($0.red - swatch.red) < 0.02 &&
                            abs($0.green - swatch.green) < 0.02 &&
                            abs($0.blue - swatch.blue) < 0.02
                        } ?? false
                        Button {
                            selectQuickColor(swatch)
                        } label: {
                            Circle()
                                .fill(Color(red: Double((rgb >> 16) & 0xFF) / 255,
                                            green: Double((rgb >> 8) & 0xFF) / 255,
                                            blue: Double(rgb & 0xFF) / 255))
                                .frame(width: 13, height: 13)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.25),
                                                      lineWidth: selected ? 2 : 0.75)
                                )
                                .shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: 3)
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.isEnabled)
                        .help("快速切换颜色")
                    }
                }
                .padding(.horizontal, 4)
            }

            PanelDivider(theme: theme)
            IconButton(icon: .undo, theme: theme, isEnabled: state.isEnabled && state.canUndo, action: undo)
                .help("撤销标注 ⌘Z")
            IconButton(icon: .redo, theme: theme, isEnabled: state.isEnabled && state.canRedo, action: redo)
                .help("重做标注 ⇧⌘Z")
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
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
