import SwiftUI
import TapSnapCore
import TapSnapMedia
import TapSnapPalette
import TapSnapTheme
import TapSnapUI

@MainActor
final class RecordingAnnotationStyleDraft: ObservableObject {
    @Published var style: RecordingAnnotation.Style

    init(_ style: RecordingAnnotation.Style) {
        self.style = style
    }
}

struct RecordingAnnotationStylePanel: View {
    @ObservedObject var draft: RecordingAnnotationStyleDraft
    let kind: RecordingAnnotation.Kind
    let theme: Theme
    let onChange: () -> Void
    @State private var editsSecondaryColor = false

    private var isShape: Bool { kind == .rectangle || kind == .ellipse }
    private var hasSecondaryColor: Bool {
        kind == .text ? draft.style.textBackground != nil : isShape && draft.style.fillColor != nil
    }

    private var color: Binding<RGBAColor> {
        if editsSecondaryColor && hasSecondaryColor {
            return Binding(
                get: { (kind == .text ? draft.style.textBackground : draft.style.fillColor) ?? draft.style.color },
                set: { value in
                    if kind == .text { draft.style.textBackground = value }
                    else { draft.style.fillColor = value }
                }
            )
        }
        return Binding(
            get: { draft.style.color },
            set: { draft.style.color = kind == .mask ? $0.withAlpha(1) : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(kind.title)样式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.token(.foreground))
            dimensions
            if kind == .text || isShape {
                Picker("颜色对象", selection: $editsSecondaryColor) {
                    Text(kind == .text ? "文字" : "描边").tag(false)
                    Text(kind == .text ? "背景" : "填充").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!hasSecondaryColor)
            }
            palette
            ColorPickerPanel(theme: theme, color: color, supportsOpacity: kind != .mask)
                .id(editsSecondaryColor && hasSecondaryColor)
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.token(.popover))
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: draft.style) { _, _ in onChange() }
        .onChange(of: hasSecondaryColor) { _, available in
            if !available { editsSecondaryColor = false }
        }
    }

    @ViewBuilder private var dimensions: some View {
        if kind == .text {
            sizeSlider("字号", value: $draft.style.fontSize, in: 8...96)
            Toggle("加粗", isOn: $draft.style.isBold)
            Toggle("文字背景", isOn: Binding(
                get: { draft.style.textBackground != nil },
                set: { draft.style.textBackground = $0 ? RGBAColor(white: 0.07, alpha: 0.86) : nil }
            ))
        } else if kind != .mask {
            if kind != .highlight {
                LabeledRow("线型", theme: theme) {
                    Picker("线型", selection: $draft.style.strokePattern) {
                        Text("实线").tag(RecordingAnnotation.Style.StrokePattern.solid)
                        Text("虚线").tag(RecordingAnnotation.Style.StrokePattern.dashed)
                        Text("点线").tag(RecordingAnnotation.Style.StrokePattern.dotted)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 176)
                }
            }
            sizeSlider("线宽", value: $draft.style.lineWidth, in: kind == .highlight ? 4...72 : 1...48)
            if isShape {
                Toggle("填充", isOn: Binding(
                    get: { draft.style.fillColor != nil },
                    set: { draft.style.fillColor = $0 ? draft.style.color.withAlpha(0.3) : nil }
                ))
            }
        }
    }

    private var palette: some View {
        HStack(spacing: 4) {
            ForEach(ColorPalette.defaultFavorites, id: \.self) { favorite in
                let value = favorite.withAlpha(color.wrappedValue.alpha)
                Button { color.wrappedValue = value } label: {
                    ColorBlock(theme: theme, color: favorite, isSelected: color.wrappedValue == value, diameter: 20)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(favorite.hex)
                .accessibilityLabel("颜色 \(favorite.hex)")
                .accessibilityAddTraits(color.wrappedValue == value ? .isSelected : [])
            }
        }
    }

    private func sizeSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledRow(title, theme: theme) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: 1)
                    .accessibilityLabel(title)
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.token(.mutedForeground))
                    .frame(width: 26, alignment: .trailing)
            }
            .frame(width: 176)
        }
    }
}
