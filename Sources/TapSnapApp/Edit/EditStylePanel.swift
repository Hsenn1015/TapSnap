import AppKit
import TapSnapActionsBar
import TapSnapCore
import TapSnapPalette
import TapSnapPrivacy
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 从对应的标注工具打开。
struct EditStylePanel: View {
    @ObservedObject var controller: EditController
    let theme: Theme
    let action: ActionKind
    @State private var editsSecondaryColor = false

    private static let fontFamilies: [(name: String, title: String)] = {
        let fonts = NSFontManager.shared
        return fonts.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, title: fonts.localizedName(forFamily: $0, face: nil)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    private var kind: EditItemKind? { EditItemFactory.itemKind(for: action) }
    private var isShape: Bool { kind?.isShape == true }
    private var showsStroke: Bool {
        if isShape { return controller.style.shapeFill != .fill }
        return kind == .arrow || kind == .line || kind == .pen || kind == .pathTag
    }
    private var hasSecondaryColor: Bool {
        (kind == .text && controller.toolOptions.textBackground != .none)
            || (isShape && controller.style.shapeFill == .fillAndOutline)
    }
    private var usesSecondaryColor: Bool {
        (isShape && controller.style.shapeFill == .fill) || (hasSecondaryColor && editsSecondaryColor)
    }
    private var selectedColor: Binding<RGBAColor> {
        guard usesSecondaryColor else { return $controller.style.color }
        if kind == .text { return $controller.style.textBackgroundColor }
        return Binding(get: { controller.style.shapeFillColor }, set: { controller.style.fillColor = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(action.title)样式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.token(.foreground))
            if kind?.supportsHandDrawn == true {
                LabeledRow("风格", theme: theme) {
                    Picker("风格", selection: $controller.style.strokeStyle) {
                        Text("标准").tag(EditItemStyle.StrokeStyle.standard)
                        Text("手绘").tag(EditItemStyle.StrokeStyle.handDrawn)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 176)
                }
            }
            toolOptions

            if showsStroke {
                if kind?.supportsHandDrawn == true, controller.style.strokeStyle == .handDrawn {
                    LabeledRow("笔触", theme: theme) {
                        Picker("笔触", selection: $controller.style.handDrawnPen) {
                            Text("单笔").tag(EditItemStyle.HandDrawnPen.single)
                            Text("复描").tag(EditItemStyle.HandDrawnPen.sketch)
                            Text("浓墨").tag(EditItemStyle.HandDrawnPen.ink)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 176)
                    }
                    LabeledRow("线条起伏", theme: theme) {
                        Picker("线条起伏", selection: $controller.style.handDrawnRoughness) {
                            Text("轻微").tag(EditItemStyle.HandDrawnRoughness.subtle)
                            Text("自然").tag(EditItemStyle.HandDrawnRoughness.natural)
                            Text("明显").tag(EditItemStyle.HandDrawnRoughness.pronounced)
                            Text("强烈").tag(EditItemStyle.HandDrawnRoughness.expressive)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 206)
                    }
                }
                LabeledRow("线型", theme: theme) {
                    Picker("线型", selection: $controller.style.strokePattern) {
                        Text("实线").tag(EditItemStyle.StrokePattern.solid)
                        Text("虚线").tag(EditItemStyle.StrokePattern.dashed)
                        Text("点线").tag(EditItemStyle.StrokePattern.dotted)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 176)
                }
            }
            if kind == .highlight {
                let width = Binding(get: { HighlightItem.lineWidth(for: controller.style) },
                                    set: { controller.style.lineWidth = $0 / HighlightItem.widthMultiplier })
                sizeSlider("线宽", value: width, in: HighlightItem.minimumWidth...(20 * HighlightItem.widthMultiplier))
            } else if showsStroke || kind == .magnifier {
                sizeSlider("线宽", value: $controller.style.lineWidth, in: 1...20)
            }
            if kind != .mosaic && kind != .magnifier && kind != .spotlight {
                colors
            }
            if kind != .mosaic && kind != .magnifier {
                opacity
            }
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.token(.popover))
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: hasSecondaryColor) { _, available in
            if !available { editsSecondaryColor = false }
        }
        .onDisappear { controller.setStyleEditing(false) }
    }

    private var colors: some View {
        let selection = selectedColor
        return VStack(alignment: .leading, spacing: 8) {
            if hasSecondaryColor {
                Picker("颜色对象", selection: $editsSecondaryColor) {
                    Text(kind == .text ? "文字" : "描边").tag(false)
                    Text(kind == .text ? "背景" : "填充").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            HStack(spacing: 4) {
                ForEach(ColorPalette.defaultFavorites, id: \.self) { favorite in
                    let color = RGBAColor(red: favorite.red, green: favorite.green, blue: favorite.blue,
                                          alpha: usesSecondaryColor ? selection.wrappedValue.alpha : favorite.alpha)
                    Button { selection.wrappedValue = color } label: {
                        ColorBlock(theme: theme, color: favorite,
                                   isSelected: selection.wrappedValue == color, diameter: 20)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(favorite.hex)
                    .accessibilityLabel("颜色 \(favorite.hex)")
                    .accessibilityAddTraits(selection.wrappedValue == color ? .isSelected : [])
                }
            }
            ColorPickerPanel(theme: theme, color: selection)
                .id(usesSecondaryColor)
        }
    }

    private var opacity: some View {
        let title = kind == .highlight ? "高亮强度" : "整体不透明度"
        return LabeledRow(title, theme: theme) {
            HStack(spacing: 8) {
                Slider(value: $controller.style.opacity, in: 0.1...1,
                       onEditingChanged: controller.setStyleEditing)
                    .accessibilityLabel(title)
                Text("\(Int((controller.style.opacity * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.token(.mutedForeground))
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(width: 176)
        }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch kind {
        case .arrow:
            Picker("箭头", selection: $controller.toolOptions.arrowHead) {
                Text("实心").tag(ArrowItem.HeadStyle.filled)
                Text("空心").tag(ArrowItem.HeadStyle.hollow)
                Text("线条").tag(ArrowItem.HeadStyle.simple)
            }
        case .rectangle, .ellipse, .polygon:
            LabeledRow("形状", theme: theme) {
                Picker("形状", selection: $controller.style.shapeFill) {
                    Text("描边").tag(EditItemStyle.ShapeFill.outline)
                    Text("填充").tag(EditItemStyle.ShapeFill.fill)
                    Text("描边＋填充").tag(EditItemStyle.ShapeFill.fillAndOutline)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 206)
            }
            if controller.style.strokeStyle == .handDrawn, controller.style.shapeFill != .outline {
                handDrawnFillOptions
            }
            if kind == .rectangle {
                sizeSlider("圆角", value: $controller.style.cornerRadius, in: 0...40)
            }
        case .text:
            textOptions
        case .mosaic:
            PrivacyAppearanceControls(
                appearance: Binding(
                    get: {
                        controller.toolOptions.mosaicMode.redactionAppearance
                            ?? controller.environment.config.settings.privacy.appearance
                    },
                    set: { controller.toolOptions.mosaicMode = .redaction($0) }
                ),
                mosaicOptions: ($controller.toolOptions.mosaicMode, $controller.toolOptions.mosaicBlockSize),
                onEditingChanged: controller.setStyleEditing
            )
            Toggle("自动识别人脸", isOn: $controller.mosaicAutoDetect)
            Toggle("自动识别文字", isOn: $controller.mosaicDetectText)
            if controller.isDetectingMosaic {
                HStack { ProgressView().controlSize(.small); Text("正在本机识别框内内容…") }
                    .font(.system(size: 11))
            }
        case .serialNumber:
            Picker("序号格式", selection: $controller.toolOptions.serialFormat) {
                ForEach(SerialItem.Format.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
        case .magnifier:
            Picker("放大倍率", selection: $controller.toolOptions.magnifierZoom) {
                ForEach([1.5, 2, 3, 4, 6], id: \.self) { zoom in
                    Text("\(zoom.formatted())×").tag(CGFloat(zoom))
                }
            }
        case .watermark:
            TextField("水印文字", text: $controller.toolOptions.watermarkText)
                .textFieldStyle(.roundedBorder)
            sizeSlider("字号", value: $controller.style.fontSize, in: 8...96)
            HStack {
                Text("角度 \(Int(controller.toolOptions.watermarkAngle))°")
                Slider(value: $controller.toolOptions.watermarkAngle, in: -90...90, step: 5)
            }
            Toggle("平铺水印", isOn: $controller.toolOptions.watermarkTiled)
            Text("单击添加，或拖动设置水印覆盖范围。")
                .font(.system(size: 11)).foregroundStyle(theme.token(.mutedForeground))
        default:
            EmptyView()
        }
    }

    private var handDrawnFillOptions: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("填充纹理")
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
                .padding(.top, 5)
            Spacer(minLength: 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(EditItemStyle.HandDrawnFill.allCases, id: \.self) { pattern in
                    let isSelected = controller.style.handDrawnFill == pattern
                    let border = RoundedRectangle(cornerRadius: theme.metrics.radiusSM)
                    Button {
                        controller.style.handDrawnFill = pattern
                    } label: {
                        VStack(spacing: 2) {
                            Canvas { context, size in
                                context.withCGContext { cg in
                                    let swatch = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                                                        cornerWidth: 3, cornerHeight: 3, transform: nil)
                                    HandDrawnStroke.fill(swatch, color: theme.rgb(.foreground).cgColor, width: 2,
                                                        pattern: pattern, in: cg)
                                }
                            }
                            .frame(width: 40, height: 13)
                            .accessibilityHidden(true)
                            Text(fillTitle(pattern))
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(theme.token(.foreground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(theme.token(isSelected ? .accent : .muted), in: border)
                        .overlay(border.strokeBorder(theme.token(isSelected ? .foreground : .border),
                                                     lineWidth: 1))
                        .contentShape(border)
                    }
                    .buttonStyle(SnapPressStyle(scale: 0.95))
                    .accessibilityLabel("\(fillTitle(pattern))填充")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .frame(width: 206)
        }
    }

    private func fillTitle(_ pattern: EditItemStyle.HandDrawnFill) -> String {
        switch pattern {
        case .hachure: return "斜线"
        case .crossHatch: return "交叉线"
        case .zigzag: return "折线"
        case .horizontal: return "横线"
        case .dots: return "点描"
        case .solid: return "纯色"
        }
    }

    @ViewBuilder
    private var textOptions: some View {
        LabeledRow("字体", theme: theme) {
            Picker("字体", selection: $controller.style.textFormat.fontFamily) {
                Text("系统字体").tag("")
                ForEach(Self.fontFamilies, id: \.name) { family in
                    Text(family.title).tag(family.name)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 176)
        }
        sizeSlider("字号", value: $controller.style.fontSize, in: 8...96)
        LabeledRow("字形", theme: theme) {
            HStack(spacing: 4) {
                textToggle("加粗", icon: "bold", isOn: $controller.style.textFormat.isBold)
                textToggle("斜体", icon: "italic", isOn: $controller.style.textFormat.isItalic)
                textToggle("下划线", icon: "underline", isOn: $controller.style.textFormat.isUnderlined)
                textToggle("删除线", icon: "strikethrough", isOn: $controller.style.textFormat.isStruckThrough)
            }
        }
        LabeledRow("对齐", theme: theme) {
            Picker("对齐", selection: $controller.style.textFormat.alignment) {
                Text("左").tag(NSTextAlignment.left)
                Text("居中").tag(NSTextAlignment.center)
                Text("右").tag(NSTextAlignment.right)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 176)
        }
        LabeledRow("背景", theme: theme) {
            Picker("背景", selection: $controller.toolOptions.textBackground) {
                Text("无").tag(TextItem.BackgroundStyle.none)
                Text("矩形").tag(TextItem.BackgroundStyle.solid)
                Text("圆角").tag(TextItem.BackgroundStyle.rounded)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 176)
        }
    }

    private func textToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.token(isOn.wrappedValue ? .primaryForeground : .foreground))
                .frame(width: 40, height: 24)
                .background(theme.token(isOn.wrappedValue ? .primary : .muted),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(SnapPressStyle(scale: 0.94))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .help(title)
    }

    private func sizeSlider(_ title: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>) -> some View {
        LabeledRow(title, theme: theme) {
            let wholePoints = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() })
            HStack(spacing: 8) {
                Slider(value: wholePoints, in: range, onEditingChanged: controller.setStyleEditing)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value.wrappedValue.rounded())) 点")
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.token(.mutedForeground))
                    .frame(width: 26, alignment: .trailing)
            }
            .frame(width: 176)
        }
    }
}
