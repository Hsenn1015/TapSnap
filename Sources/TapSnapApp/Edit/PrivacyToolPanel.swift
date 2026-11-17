import AppKit
import SwiftUI
import TapSnapConfig
import TapSnapCore
import TapSnapPrivacy

struct PrivacyToolPanel: View {
    @ObservedObject var controller: EditController
    @ObservedObject var privacy: PrivacyEditing
    @ObservedObject private var config: ConfigStore

    init(controller: EditController, privacy: PrivacyEditing) {
        self.controller = controller
        self.privacy = privacy
        self.config = controller.environment.config
    }

    var body: some View {
        let configuration = config.settings.privacy.ai
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("隐私打码", systemImage: "lock.shield").font(.headline)
                Spacer()
                Button("规则与模型") { controller.environment.openSettings(section: .privacy) }
                    .help("设置检测规则和 AI 模型")
            }
            Text("拖动打码。点已有打码块可移动、缩放或删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrivacyAppearanceControls(
                appearance: Binding(get: { controller.toolOptions.privacyAppearance },
                                    set: controller.updatePrivacyAppearance),
                onEditingChanged: controller.setStyleEditing
            )
            Divider()
            HStack {
                Button("扫描图片") { controller.scanPrivacy() }
                    .buttonStyle(.borderedProminent)
                    .disabled(privacy.blocksOutput)
                if let configuration, configuration.isConfigured {
                    Menu("AI 补查") {
                        Button("图片定位") { confirmAI(configuration, image: true) }
                        Button("仅文字") { confirmAI(configuration, image: false) }
                    }
                    .fixedSize()
                    .disabled(privacy.blocksOutput)
                    .help("使用 \(configuration.provider.title) 补查图片或文字")
                } else {
                    Button("AI 补查") { controller.environment.openSettings(section: .privacy) }
                        .disabled(privacy.blocksOutput)
                        .help("配置 AI 模型")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 326)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { controller.setStyleEditing(false) }
    }

    private func confirmAI(_ configuration: PrivacyAIConfiguration, image: Bool) {
        guard config.settings.privacy.ai == configuration else { return }
        let key: String?
        do {
            key = try config.privacyAIKeys.read(for: configuration)
        } catch {
            controller.environment.toast.warning(PrivacyAIError.keyStorage.message)
            return
        }
        if configuration.provider.requiresAPIKey && key == nil {
            controller.environment.openSettings(section: .privacy)
            controller.environment.toast.info(PrivacyAIError.missingKey.message)
            return
        }
        if configuration.usesLoopback {
            controller.scanPrivacy(using: configuration, image: image, key: key)
            return
        }
        let alert = NSAlert()
        let host = configuration.endpoint?.host ?? "已配置服务"
        alert.messageText = image ? "发送当前图片给 \(configuration.provider.title) 定位？" : "用 \(configuration.provider.title) 补查文字？"
        alert.informativeText = image
            ? "图片像素会发送到 \(host)。发送前会覆盖已有的隐私打码块和本机规则找到的区域。有裁剪时只发送裁剪范围，其余像素仍可能包含尚未识别的敏感信息。"
            : "OCR 文字会发送到 \(host)。发送前会遮住规则命中的敏感值和常见长号码，其余文字仍可能包含隐私。"
        let send = alert.addButton(withTitle: image ? "发送图片并定位" : "发送文字并补查")
        send.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn, config.settings.privacy.ai == configuration else { return }
        controller.scanPrivacy(using: configuration, image: image, key: key)
    }
}

struct PrivacyAppearanceControls: View {
    @Binding var appearance: PrivacyMaskAppearance
    var mosaicOptions: (mode: Binding<MosaicItem.Mode>, blockSize: Binding<Int>)? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 5) {
                if let mosaicOptions {
                    ForEach([MosaicItem.Mode.mosaic, .blur], id: \.self) { mode in
                        styleCard(mode, selected: mosaicOptions.mode.wrappedValue == mode) {
                            mosaicOptions.mode.wrappedValue = mode
                        }
                    }
                }
                ForEach(PrivacyMaskStyle.allCases, id: \.self) { style in
                    let sample = PrivacyMaskAppearance(style: style, patternSize: appearance.patternSize, rgb: appearance.rgb)
                    let selected = (mosaicOptions == nil || mosaicOptions?.mode.wrappedValue.redactionAppearance != nil)
                        && appearance.style == style
                    styleCard(.redaction(sample), selected: selected) {
                        appearance = sample
                    }
                }
            }
            if let mosaicOptions, mosaicOptions.mode.wrappedValue.redactionAppearance == nil {
                Stepper("强度 \(mosaicOptions.blockSize.wrappedValue)", value: mosaicOptions.blockSize, in: 2...64, step: 2)
            } else if appearance.style.usesPatternSize {
                HStack(spacing: 10) {
                    Text(appearance.style == .mosaic ? "色块大小" : "斜纹间距")
                    Slider(value: $appearance.patternSize, in: 3...24, step: 1, onEditingChanged: onEditingChanged)
                        .accessibilityLabel("图案大小")
                    Text(appearance.patternSize.formatted(.number.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 22, alignment: .trailing)
                }
                .font(.caption)
            } else if appearance.style == .solid {
                ColorPicker("遮盖颜色", selection: color, supportsOpacity: false)
            }
        }
    }

    private func styleCard(_ mode: MosaicItem.Mode, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RedactionStylePreview(mode: mode, blockSize: mosaicOptions?.blockSize.wrappedValue ?? 12)
                    .equatable()
                Text(mode.title).font(.system(size: 11)).lineLimit(1)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var color: Binding<Color> {
        Binding(
            get: {
                let rgb = RGBAColor(rgb: appearance.rgb)
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let red = UInt32((min(max(rgb.redComponent, 0), 1) * 255).rounded())
                let green = UInt32((min(max(rgb.greenComponent, 0), 1) * 255).rounded())
                let blue = UInt32((min(max(rgb.blueComponent, 0), 1) * 255).rounded())
                appearance.rgb = (red << 16) | (green << 8) | blue
            }
        )
    }
}
