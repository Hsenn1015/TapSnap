import AppKit
import SwiftUI
import TapSnapConfig
import TapSnapOCR
import TapSnapPrivacy
import TapSnapTheme
import TapSnapUI
import Translation

enum TranslationDisplayMode: String, CaseIterable, Hashable {
    case split
    case overlay

    var title: String {
        switch self {
        case .split: return "对照"
        case .overlay: return "原图"
        }
    }
}

@MainActor
struct ScreenshotTranslationView: View {
    let image: CGImage
    let environment: AppEnvironment
    let onTogglePin: @MainActor (Bool) -> Void
    let onClose: @MainActor () -> Void
    let onRecapture: @MainActor () -> Void

    @ObservedObject private var config: ConfigStore
    @StateObject private var docSession = TranslationDocumentSession()
    @StateObject private var reading = TranslationReadingSession()

    @State private var document: OCRDocument?
    @State private var isRecognizing = false
    @State private var recognitionError: String?
    @State private var selectionMessage: String?

    @State private var source = "auto"
    @State private var displayMode: TranslationDisplayMode = .split
    @State private var showBilingual = false
    @State private var showOverlayLayer = true
    @AppStorage("translation.hoverTranslateEnabled") private var hoverTranslateEnabled = false
    @State private var peekingOriginal = false
    @State private var isPinned: Bool
    @State private var zoom: CGFloat = 1
    @State private var resetSelection = 0

    @State private var settingsPopoverOpen = false
    @State private var stylePopoverOpen = false
    @State private var floatStylePopoverOpen = false
    @State private var isOrganizing = false
    @State private var selectedBlockIDs: Set<UUID> = []
    @State private var lastSelectedBlockID: UUID?
    @State private var hoveredBlockID: UUID?
    @State private var scrollToBlockID: UUID?
    @State private var editingBlockID: UUID?
    @State private var editingBlockDraft = ""
    @State private var editingTargetText = false
    @State private var editingFocusText = false
    @State private var focusDraft = ""
    @State private var copiedTag: String?
    @State private var isHoveringImage = false
    @AppStorage("translation.splitRatio") private var splitRatio: Double = 0.45
    @State private var splitDragStartRatio: Double?
    @State private var isHoveringDivider = false
    @AppStorage("translation.floatCardWidth") private var floatCardWidth: Double = 360
    @AppStorage("translation.floatCardHeight") private var floatCardHeight: Double = 220
    @AppStorage("translation.floatCardCustomHeight") private var floatCardCustomHeight = false
    @State private var floatCardOrigin: CGPoint?
    @State private var floatDragStartOrigin: CGPoint?
    @State private var floatResizeStartSize: CGSize?
    @State private var cardSize = CGSize(width: 360, height: 150)
    @State private var spaceMonitor: Any?

    private var theme: Theme { environment.theme }
    private var languages: [(code: String, name: String)] { TranslationServiceSettingsView.supportedLanguages }
    private var activeProvider: ScreenshotTranslationProvider? { config.settings.translation.provider }
    private var shouldAutoTranslate: Bool { activeProvider != nil && config.settings.translation.autoTranslateOnOpen }
    private var targetLanguage: String { config.settings.translation.targetLanguage }
    private var typography: TranslationTypographyStyle { config.settings.translation.style }
    private var accentColor: Color { typography.accent.rgb.color }
    private var accentNSColor: NSColor {
        let c = typography.accent.rgb
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
    private var fontDesign: Font.Design {
        switch typography.fontFamily {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }

    private var engineSignature: TranslationEngineSignature {
        let t = config.settings.translation
        return TranslationEngineSignature(
            provider: t.provider,
            targetLanguage: t.targetLanguage,
            apiProvider: t.apiProvider,
            apiConfig: t.apiConfiguration,
            onlineProvider: t.onlineProvider,
            modelConfig: t.modelConfiguration
        )
    }

    init(
        image: CGImage,
        initialDocument: OCRDocument?,
        environment: AppEnvironment,
        initialPinned: Bool = true,
        onTogglePin: @MainActor @escaping (Bool) -> Void = { _ in },
        onClose: @MainActor @escaping () -> Void = {},
        onRecapture: @MainActor @escaping () -> Void = {}
    ) {
        self.image = image
        self.environment = environment
        self.onTogglePin = onTogglePin
        self.onClose = onClose
        self.onRecapture = onRecapture
        _document = State(initialValue: initialDocument)
        _isPinned = State(initialValue: initialPinned)
        _config = ObservedObject(wrappedValue: environment.config)
    }

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            headerBar
            contentArea
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.token(.foreground))
        .background(theme.token(.muted))
        .clipShape(outline)
        .overlay {
            outline.strokeBorder(theme.token(.foreground).opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .background { translationWorkers }
        .background { hiddenShortcuts }
        .task {
            await prepareDocument()
        }
        .onAppear { installSpaceMonitor() }
        .onDisappear {
            removeSpaceMonitor()
            reading.dismiss()
            docSession.cancel()
        }
        .onChange(of: engineSignature) { _, _ in
            reading.refresh()
            docSession.invalidateAndRestart(autoStart: shouldAutoTranslate)
        }
        .onChange(of: source) { _, _ in
            reading.refresh()
            docSession.invalidateAndRestart(autoStart: shouldAutoTranslate)
        }
        .onChange(of: displayMode) { _, newMode in
            peekingOriginal = false
            if newMode == .split {
                hoveredBlockID = nil
            }
        }
        .onExitCommand { handleEscape() }
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.token(.primary))
                    .frame(width: 28, height: 28)
                    .background(theme.token(.muted), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)

                languageControlGroup
            }

            ZStack {
                WindowDragArea().accessibilityHidden(true)
                SnapSegmented(
                    items: TranslationDisplayMode.allCases,
                    selection: $displayMode,
                    theme: theme,
                    title: \.title
                )
                .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("拖动标题栏移动窗口")

            HStack(spacing: 6) {
                providerPillButton

                headerIconButton(
                    title: "再截一张翻译",
                    icon: "camera.viewfinder",
                    isSelected: false,
                    action: onRecapture
                )

                headerIconButton(
                    title: isPinned ? "取消窗口置顶" : "置顶显示窗口",
                    icon: isPinned ? "pin.fill" : "pin",
                    isSelected: isPinned
                ) {
                    withAnimation(Interaction.toggle) {
                        isPinned.toggle()
                        onTogglePin(isPinned)
                    }
                }

                headerIconButton(
                    title: "关闭翻译窗口",
                    icon: "xmark",
                    isSelected: false,
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.token(.popover))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.token(.border)).frame(height: 1).allowsHitTesting(false)
        }
    }

    private var languageControlGroup: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("原文语言", selection: $source) {
                    Text("自动识别").tag("auto")
                    Divider()
                    ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                }
            } label: {
                languagePillLabel(title: languageName(for: source, isSource: true))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("原文语言")

            Button {
                guard source != "auto", source != targetLanguage else { return }
                let oldTarget = targetLanguage
                let oldSource = source
                withAnimation(Interaction.toggle) {
                    source = oldTarget
                    config.update { $0.translation.targetLanguage = oldSource }
                }
            } label: {
                Image(systemName: source == "auto" ? "arrow.right" : "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(source == "auto" ? theme.token(.mutedForeground) : theme.token(.foreground))
                    .frame(width: 22, height: 22)
                    .background(source == "auto" ? Color.clear : theme.token(.muted).opacity(0.8), in: Circle())
            }
            .buttonStyle(SnapPressStyle(scale: 0.9))
            .disabled(source == "auto")
            .help(source == "auto" ? "自动识别原文语言" : "互换源语言与目标语言")

            Menu {
                Picker("目标语言", selection: Binding(
                    get: { targetLanguage },
                    set: { newValue in config.update { $0.translation.targetLanguage = newValue } }
                )) {
                    ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                }
            } label: {
                languagePillLabel(title: languageName(for: targetLanguage, isSource: false))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("目标语言")
        }
    }

    private func languagePillLabel(title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.token(.foreground))
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(theme.token(.mutedForeground))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.token(.border), lineWidth: 1)
        )
    }

    private var providerPillButton: some View {
        Button {
            reading.isConfiguring = true
            settingsPopoverOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(activeProvider == nil ? theme.warning : Color.green)
                    .frame(width: 6, height: 6)
                Text(providerBadgeTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.token(.foreground))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
            )
        }
        .buttonStyle(SnapPressStyle(scale: 0.96))
        .help("配置截图翻译服务")
        .popover(isPresented: $settingsPopoverOpen, arrowEdge: .bottom) {
            TranslationServiceSettingsView(
                config: config,
                theme: theme,
                compact: true,
                onCancel: {
                    settingsPopoverOpen = false
                },
                onSave: { settingsChanged in
                    if !settingsChanged {
                        reading.refresh()
                        docSession.invalidateAndRestart(autoStart: shouldAutoTranslate)
                    }
                    settingsPopoverOpen = false
                }
            )
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .onDisappear { reading.isConfiguring = false }
        }
    }

    private var providerBadgeTitle: String {
        guard let provider = activeProvider else { return "选择服务" }
        switch provider {
        case .api:
            return config.settings.translation.apiProvider.shortTitle
        case .online:
            return config.settings.translation.onlineProvider.title
        default:
            return provider.title
        }
    }

    private func headerIconButton(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? accentColor : theme.token(.mutedForeground))
                .frame(width: 28, height: 28)
                .background(
                    isSelected ? accentColor.opacity(0.15) : theme.token(.muted),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(SnapPressStyle(scale: 0.93))
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - 主内容区

    @ViewBuilder
    private var contentArea: some View {
        switch displayMode {
        case .split:
            GeometryReader { proxy in
                let handleWidth: CGFloat = 10
                let usableWidth = max(1, proxy.size.width - handleWidth)
                let minPane: CGFloat = min(220, usableWidth * 0.42)
                let minRatio = Double(minPane / usableWidth)
                let maxRatio = Double((usableWidth - minPane) / usableWidth)
                let clampedRatio = min(max(splitRatio, minRatio), maxRatio)
                let imageWidth = usableWidth * CGFloat(clampedRatio)

                HStack(spacing: 0) {
                    imagePane(showsOverlayControls: false)
                        .frame(width: imageWidth)

                    splitResizeHandle(
                        width: handleWidth,
                        usableWidth: usableWidth,
                        minRatio: minRatio,
                        maxRatio: maxRatio,
                        currentRatio: clampedRatio
                    )

                    translationListPane
                        .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "translationSplit")
            }
        case .overlay:
            imagePane(showsOverlayControls: true)
        }
    }

    private func splitResizeHandle(
        width: CGFloat,
        usableWidth: CGFloat,
        minRatio: Double,
        maxRatio: Double,
        currentRatio: Double
    ) -> some View {
        let active = isHoveringDivider || splitDragStartRatio != nil
        return ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(active ? theme.token(.foreground).opacity(0.45) : theme.token(.border))
                .frame(width: active ? 3.5 : 2.5, height: active ? 40 : 28)
                .animation(Interaction.hover, value: active)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(ResizeCursorView())
        .onHover { isHoveringDivider = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("translationSplit"))
                .onChanged { value in
                    let base = splitDragStartRatio ?? currentRatio
                    if splitDragStartRatio == nil {
                        splitDragStartRatio = base
                    }
                    let next = base + Double(value.translation.width / usableWidth)
                    splitRatio = min(max(next, minRatio), maxRatio)
                }
                .onEnded { _ in
                    splitDragStartRatio = nil
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(Interaction.toggle) {
                splitRatio = 0.45
            }
        }
        .help("拖动调整左右比例，双击恢复默认")
    }

    // MARK: - 原图画布卡片

    private func imagePane(showsOverlayControls: Bool) -> some View {
        card {
            GeometryReader { geometry in
                let overlayActive = showsOverlayControls && showOverlayLayer && !overlayItems.isEmpty
                ZStack(alignment: .topLeading) {
                    // 画布衬底，确保白底或纯黑底截图都能看清边界
                    theme.token(.muted).opacity(theme.isDark ? 0.55 : 0.72)

                    TranslationImageView(
                        image: image,
                        document: document,
                        zoom: zoom,
                        onHover: { text, bounds in
                            reading.hover(text, bounds: bounds)
                        },
                        onSelection: { text, bounds in
                            withAnimation(Interaction.panel) {
                                reading.select(text, bounds: bounds)
                            }
                        },
                        onSelectionUnavailable: { selectionMessage = $0 },
                        onZoomChange: { zoom = $0 },
                        onBlockClick: { blockID in
                            withAnimation(Interaction.hover) {
                                hoveredBlockID = blockID
                                scrollToBlockID = blockID
                            }
                        },
                        resetSelection: resetSelection,
                        recognitionLanguages: config.settings.ocr.languages,
                        highlightedBlockID: hoveredBlockID,
                        scrollToBlockID: scrollToBlockID,
                        overlayItems: overlayItems,
                        showsTranslationOverlay: overlayActive,
                        peekingOriginal: peekingOriginal,
                        hoverEnabled: displayMode == .overlay && !showOverlayLayer && hoverTranslateEnabled,
                        accentNSColor: accentNSColor
                    )
                    .padding(10)
                    .accessibilityIdentifier("translationImage")

                    // 原图点读模式（overlay 关闭覆译）时的可拖动、可缩放、可固定译文浮卡
                    if displayMode == .overlay, !showOverlayLayer, let focus = reading.focus {
                        let maxWidth = max(240, geometry.size.width - 20)
                        let maxHeight = max(140, geometry.size.height - 72)
                        let width = min(maxWidth, max(240, CGFloat(floatCardWidth)))
                        let measuredHeight = floatCardCustomHeight
                            ? min(maxHeight, max(140, CGFloat(floatCardHeight)))
                            : min(maxHeight, cardSize.height)
                        let origin = resolvedFloatCardOrigin(
                            anchor: focus.bounds.offsetBy(dx: 10, dy: 10),
                            size: CGSize(width: width, height: measuredHeight),
                            viewport: geometry.size
                        )

                        floatingResultCard(
                            focus,
                            currentOrigin: origin,
                            currentSize: CGSize(width: width, height: measuredHeight),
                            viewport: geometry.size
                        )
                        .frame(width: width, height: floatCardCustomHeight ? measuredHeight : nil)
                        .fixedSize(horizontal: false, vertical: !floatCardCustomHeight)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .onHover { reading.cardHover($0) }
                        .offset(x: origin.x, y: origin.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                        .animation(floatDragStartOrigin == nil && floatResizeStartSize == nil ? Interaction.panel : nil, value: focus.text)
                    }

                    // 顶部轻量状态胶囊（识别中 / 未配置 / 下载提示）
                    VStack(spacing: 6) {
                        if isRecognizing {
                            statusCapsule(icon: nil, text: "正在识别原图文字…", isLoading: true)
                        } else if let recognitionError {
                            statusCapsule(icon: "exclamationmark.triangle", text: recognitionError, isLoading: false)
                        } else if showsOverlayControls, activeProvider == nil {
                            overlaySetupBanner
                        } else if showsOverlayControls, docSession.needsLanguageDownload {
                            overlayDownloadBanner
                        } else if showsOverlayControls, docSession.isTranslating {
                            statusCapsule(
                                icon: nil,
                                text: "正在生成原位译文 (\(docSession.completedCount)/\(docSession.totalCount))…",
                                isLoading: true
                            )
                        } else if let selectionMessage, displayMode == .overlay, !showOverlayLayer {
                            statusCapsule(icon: "info.circle", text: selectionMessage, isLoading: false)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .animation(Interaction.panel, value: isRecognizing)
                    .animation(Interaction.panel, value: docSession.isTranslating)

                    // 底部悬浮操控胶囊
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            if showsOverlayControls {
                                overlayFloatingBar
                            } else if isHoveringImage || abs(zoom - 1) > 0.01 {
                                compactZoomPill
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            Spacer()
                        }
                        .padding(.bottom, 10)
                    }
                    .animation(Interaction.hover, value: isHoveringImage)
                    .animation(Interaction.hover, value: zoom)
                }
                .coordinateSpace(name: "translationOverlayCanvas")
                .clipped()
            }
            .onHover { hovering in
                isHoveringImage = hovering
            }
        }
    }

    private var overlayItems: [TranslationOverlayItem] {
        docSession.blocks.compactMap { block in
            guard let translated = block.phase.translatedText else { return nil }
            return TranslationOverlayItem(
                id: block.id,
                normalizedBounds: block.normalizedBounds,
                text: translated,
                lineCount: block.lineCount,
                backdrop: block.backdrop
            )
        }
    }

    private func statusCapsule(icon: String?, text: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
            }
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.token(.foreground))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .senPanelStyle(theme: theme, radius: 999)
    }

    private var overlaySetupBanner: some View {
        HStack(spacing: 8) {
            Text("选择翻译服务以启用原位译文")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.token(.foreground))
            if #available(macOS 15, *) {
                SnapButton("启用 Apple 离线", theme: theme, variant: .primary, size: .sm) {
                    enableAppleTranslationQuickly()
                }
            }
            SnapButton("配置模型", theme: theme, variant: .outline, size: .sm) {
                reading.isConfiguring = true
                settingsPopoverOpen = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .senPanelStyle(theme: theme, radius: 10)
    }

    private var overlayDownloadBanner: some View {
        HStack(spacing: 8) {
            Text("Apple 离线翻译需要下载该语言包")
                .font(.system(size: 12, weight: .medium))
            SnapButton("下载并翻译", theme: theme, variant: .primary, size: .sm) {
                docSession.authorizeDownload()
            }
            SnapButton("换服务", theme: theme, variant: .outline, size: .sm) {
                reading.isConfiguring = true
                settingsPopoverOpen = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .senPanelStyle(theme: theme, radius: 10)
    }

    private var compactZoomPill: some View {
        HStack(spacing: 2) {
            zoomPillButton(icon: "minus", label: "缩小原图", enabled: zoom > 0.5) {
                withAnimation(Interaction.hover) { zoom = max(0.5, zoom / 1.25) }
            }
            Button {
                withAnimation(Interaction.toggle) { zoom = 1 }
            } label: {
                Text(Double(zoom).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.token(.foreground))
                    .frame(minWidth: 40, minHeight: 24)
            }
            .buttonStyle(SnapPressStyle(scale: 0.94))
            .help("恢复适合窗口 (⌘0)")
            zoomPillButton(icon: "plus", label: "放大原图", enabled: zoom < 5) {
                withAnimation(Interaction.hover) { zoom = min(5, zoom * 1.25) }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .senPanelStyle(theme: theme, radius: 999)
    }

    private var overlayFloatingBar: some View {
        HStack(spacing: 6) {
            // 覆译 / 划词 模式切换
            HStack(spacing: 2) {
                miniPillToggle("原位覆译", icon: "text.bubble", selected: showOverlayLayer) {
                    withAnimation(Interaction.toggle) {
                        showOverlayLayer = true
                        reading.dismiss()
                        resetSelection += 1
                    }
                }
                miniPillToggle("划词翻译", icon: "cursorarrow.and.square.on.square.dashed", selected: !showOverlayLayer) {
                    withAnimation(Interaction.toggle) {
                        showOverlayLayer = false
                    }
                }
            }
            .padding(2)
            .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !showOverlayLayer {
                Button {
                    withAnimation(Interaction.toggle) {
                        hoverTranslateEnabled.toggle()
                        if !hoverTranslateEnabled && reading.focus?.trigger == .hover && !reading.isPinned {
                            reading.dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hoverTranslateEnabled ? "cursorarrow.rays" : "cursorarrow")
                            .font(.system(size: 10.5, weight: .medium))
                        Text("悬停译")
                            .font(.system(size: 11.5, weight: hoverTranslateEnabled ? .semibold : .regular))
                    }
                    .foregroundStyle(hoverTranslateEnabled ? accentColor : theme.token(.mutedForeground))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        hoverTranslateEnabled ? accentColor.opacity(0.14) : theme.token(.muted),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hoverTranslateEnabled ? accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(SnapPressStyle(scale: 0.95))
                .help(hoverTranslateEnabled ? "已开启悬停自动翻译（停留约 0.6 秒触发），点击关闭仅保留划词" : "开启后鼠标停在句子上可自动翻译，默认关闭防误触")
            }

            if showOverlayLayer && !overlayItems.isEmpty {
                Rectangle().fill(theme.token(.border)).frame(width: 1, height: 16)
                Button {} label: {
                    HStack(spacing: 4) {
                        Image(systemName: peekingOriginal ? "eye.fill" : "eye")
                            .font(.system(size: 11))
                        Text("按住看原图")
                            .font(.system(size: 11.5, weight: .medium))
                        SnapKbd("Space", theme: theme)
                    }
                    .foregroundStyle(peekingOriginal ? theme.token(.primaryForeground) : theme.token(.foreground))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        peekingOriginal ? theme.token(.primary) : theme.token(.muted),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !peekingOriginal { peekingOriginal = true } }
                        .onEnded { _ in peekingOriginal = false }
                )
                .help("按住此按钮或键盘空格键可瞬间对比原图")
            }

            Rectangle().fill(theme.token(.border)).frame(width: 1, height: 16)

            HStack(spacing: 1) {
                zoomPillButton(icon: "minus", label: "缩小原图", enabled: zoom > 0.5) {
                    withAnimation(Interaction.hover) { zoom = max(0.5, zoom / 1.25) }
                }
                Button {
                    withAnimation(Interaction.toggle) { zoom = 1 }
                } label: {
                    Text(Double(zoom).formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.token(.foreground))
                        .frame(minWidth: 38, minHeight: 24)
                }
                .buttonStyle(SnapPressStyle(scale: 0.94))
                .help("恢复适合窗口 (⌘0)")
                zoomPillButton(icon: "plus", label: "放大原图", enabled: zoom < 5) {
                    withAnimation(Interaction.hover) { zoom = min(5, zoom * 1.25) }
                }
            }

            if !showOverlayLayer {
                Rectangle().fill(theme.token(.border)).frame(width: 1, height: 16)
                stylePopoverButton
            }

            if !docSession.combinedTranslatedText.isEmpty {
                Rectangle().fill(theme.token(.border)).frame(width: 1, height: 16)
                Button {
                    copyText(docSession.combinedTranslatedText, tag: "all")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedTag == "all" ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text(copiedTag == "all" ? "已复制" : "复制译文")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(theme.token(.primaryForeground))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(theme.token(.primary), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(SnapPressStyle(scale: 0.95))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .senPanelStyle(theme: theme, radius: 11)
    }

    private func miniPillToggle(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? theme.token(.foreground) : theme.token(.mutedForeground))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(selected ? theme.token(.background) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
    }

    private func zoomPillButton(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.token(.foreground))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(SnapPressStyle(scale: 0.9))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    // MARK: - 右侧译文对照卡片

    private var translationListPane: some View {
        card {
            // 控制顶条（普通阅读态 vs 批量整理态）
            Group {
                if isOrganizing {
                    organizeHeaderBar
                } else {
                    normalListHeaderBar
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 43)
            .animation(Interaction.toggle, value: isOrganizing)
            .animation(Interaction.toggle, value: docSession.deletedCount)

            Rectangle().fill(theme.token(.border)).frame(height: 1)

            // 主列表内容
            Group {
                if isRecognizing {
                    loadingState("正在识别图片文字…")
                } else if let recognitionError {
                    emptyState(icon: "exclamationmark.triangle", title: "文字识别失败", subtitle: recognitionError)
                } else if document?.isEmpty == true {
                    emptyState(icon: "text.magnifyingglass", title: "未识别到可翻译的文字", subtitle: "可以尝试放大画面后重新框选截图。")
                } else if activeProvider == nil {
                    setupOnboardingState
                } else {
                    VStack(spacing: 0) {
                        // 划词精翻插槽（有选区时丝滑滑入，不遮挡原图）
                        if let focus = reading.focus, focus.trigger == .selection {
                            selectionFocusBanner(focus)
                                .padding(10)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            Rectangle().fill(theme.token(.border)).frame(height: 1)
                        }

                        // Apple 语言包下载横幅
                        if docSession.needsLanguageDownload {
                            downloadRequiredBanner
                                .padding(10)
                            Rectangle().fill(theme.token(.border)).frame(height: 1)
                        }

                        if docSession.blocks.isEmpty && docSession.deletedCount > 0 {
                            VStack(spacing: 10) {
                                Image(systemName: "trash.slash")
                                    .font(.system(size: 22))
                                    .foregroundStyle(theme.token(.mutedForeground))
                                Text("已清理全部段落")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("你可以一键恢复已删除的 \(docSession.deletedCount) 段文字，或重新框选截图。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.token(.mutedForeground))
                                    .multilineTextAlignment(.center)
                                HStack(spacing: 8) {
                                    SnapButton("恢复已删段落", theme: theme, variant: .primary, size: .sm) {
                                        withAnimation(Interaction.panel) { docSession.restoreAllRemoved() }
                                    }
                                    SnapButton("再截一张", theme: theme, variant: .outline, size: .sm, action: onRecapture)
                                }
                                .padding(.top, 4)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollViewReader { scrollProxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: showBilingual || isOrganizing ? 8 : 4) {
                                        ForEach(docSession.blocks) { block in
                                            blockRow(block)
                                                .id(block.id)
                                                .transition(.asymmetric(
                                                    insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                                    removal: .opacity.combined(with: .move(edge: .trailing))
                                                ))
                                        }
                                    }
                                    .padding(10)
                                    .animation(Interaction.panel, value: docSession.blocks.map(\.id))
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .onChange(of: scrollToBlockID) { _, newID in
                                    guard let newID else { return }
                                    withAnimation(Interaction.panel) {
                                        scrollProxy.scrollTo(newID, anchor: .center)
                                    }
                                }
                            }

                            if isOrganizing && !docSession.blocks.isEmpty {
                                Rectangle().fill(theme.token(.border)).frame(height: 1)
                                organizeActionBar
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .animation(Interaction.panel, value: reading.focus?.text)
                    .animation(Interaction.panel, value: isOrganizing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 右侧顶条与批量整理条

    private var normalListHeaderBar: some View {
        HStack(spacing: 6) {
            if docSession.isTranslating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("翻译中 \(docSession.completedCount)/\(docSession.totalCount)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.token(.mutedForeground))
                }
            } else if docSession.totalCount > 0 {
                Text("\(docSession.totalCount) 段")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.token(.foreground))
            } else {
                Text("译文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
            }

            if docSession.deletedCount > 0 {
                Button {
                    withAnimation(Interaction.panel) {
                        if let restored = docSession.undoLastRemoval() {
                            hoveredBlockID = restored
                            scrollToBlockID = restored
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                        Text("撤销(\(docSession.deletedCount))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(accentColor.opacity(0.32), lineWidth: 1)
                    )
                }
                .buttonStyle(SnapPressStyle(scale: 0.95))
                .help("撤销上一次删除 (⌘Z)，右键可全部恢复")
                .contextMenu {
                    Button("撤销上一次删除") {
                        withAnimation(Interaction.panel) { _ = docSession.undoLastRemoval() }
                    }
                    Button("恢复全部已删段落 (\(docSession.deletedCount))") {
                        withAnimation(Interaction.panel) { docSession.restoreAllRemoved() }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            Spacer(minLength: 4)

            if docSession.totalCount > 0 {
                if docSession.hasUntranslatedBlocks && !docSession.isTranslating && activeProvider != nil {
                    SnapButton("翻译全部", theme: theme, variant: .primary, size: .sm) {
                        docSession.startPending(allowDownload: false)
                    }
                    .help("立即翻译当前保留的 \(docSession.untranslatedCount) 段文字")
                }

                HStack(spacing: 2) {
                    miniPillToggle("译文", icon: "text.justifyleft", selected: !showBilingual) {
                        withAnimation(Interaction.toggle) { showBilingual = false }
                    }
                    miniPillToggle("对照", icon: "text.alignleft", selected: showBilingual) {
                        withAnimation(Interaction.toggle) { showBilingual = true }
                    }
                }
                .padding(2)
                .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("切换纯译文阅读或双语对照卡片")

                Button {
                    enterOrganizeMode()
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .frame(width: 26, height: 26)
                        .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(theme.token(.border), lineWidth: 1)
                        )
                }
                .buttonStyle(SnapPressStyle(scale: 0.94))
                .help("批量整理：多选清理杂文、仅保留所选或一键清空（也可按住 ⌘ 点击段落进入）")

                stylePopoverButton
            }

            if docSession.hasFailures && !docSession.isTranslating {
                SnapButton("重试失败", theme: theme, variant: .outline, size: .sm) {
                    docSession.startPending(allowDownload: false)
                }
            }

            let hasResult = !docSession.combinedTranslatedText.isEmpty
            Button {
                copyText(docSession.combinedTranslatedText, tag: "all")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copiedTag == "all" ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(copiedTag == "all" ? "已复制" : "复制全部")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(copiedTag == "all" ? Color.green : theme.token(.foreground))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(copiedTag == "all" ? Color.green.opacity(0.45) : theme.token(.border), lineWidth: 1)
                )
            }
            .buttonStyle(SnapPressStyle(scale: 0.96))
            .disabled(!hasResult)
            .opacity(hasResult ? 1 : 0.42)
            .help("复制全部译文（右键可复制原文+译文对照）")
            .contextMenu {
                Button("复制全部译文") {
                    copyText(docSession.combinedTranslatedText, tag: "all")
                }
                Button("复制原文与译文对照") {
                    copyText(docSession.combinedBilingualText, tag: "all")
                }
            }
        }
    }

    private var organizeHeaderBar: some View {
        let total = docSession.totalCount
        let selectedCount = selectedBlockIDs.intersection(Set(docSession.blocks.map(\.id))).count
        let allSelected = total > 0 && selectedCount == total

        return HStack(spacing: 6) {
            Text("已选 \(selectedCount)/\(total)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(accentColor)

            Button {
                let noise = docSession.suspectedNoiseIDs()
                withAnimation(Interaction.toggle) {
                    selectedBlockIDs = noise
                    lastSelectedBlockID = nil
                }
                if noise.isEmpty {
                    environment.toast.info("未发现明显的符号、数字或状态栏杂项")
                } else {
                    environment.toast.info("已预选 \(noise.count) 段疑似杂项，核对后可一键删除")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("选中杂项")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(SnapPressStyle(scale: 0.95))
            .help("自动预选纯符号、页码、时间戳和状态条等冗余碎片")

            Button(allSelected ? "取消全选" : "全选") {
                withAnimation(Interaction.toggle) {
                    if allSelected {
                        selectedBlockIDs.removeAll()
                    } else {
                        selectedBlockIDs = Set(docSession.blocks.map(\.id))
                    }
                    lastSelectedBlockID = nil
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.token(.mutedForeground))
            .padding(.horizontal, 5)

            Button("反选") {
                withAnimation(Interaction.toggle) {
                    let all = Set(docSession.blocks.map(\.id))
                    selectedBlockIDs = all.subtracting(selectedBlockIDs)
                    lastSelectedBlockID = nil
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.token(.mutedForeground))
            .padding(.horizontal, 4)

            Spacer(minLength: 4)

            SnapButton("完成", theme: theme, variant: .secondary, size: .sm) {
                exitOrganizeMode()
            }
        }
    }

    private var organizeActionBar: some View {
        let validIDs = Set(docSession.blocks.map(\.id))
        let activeSelection = selectedBlockIDs.intersection(validIDs)
        let selectedCount = activeSelection.count
        let untranslatedSelected = docSession.blocks.filter {
            activeSelection.contains($0.id) && $0.phase == .idle
        }.count

        return HStack(spacing: 6) {
            Button {
                let removed = withAnimation(Interaction.panel) {
                    docSession.remove(blockIDs: activeSelection)
                }
                selectedBlockIDs.subtract(activeSelection)
                lastSelectedBlockID = nil
                if removed > 0 {
                    environment.toast.info("已删除 \(removed) 段，按 ⌘Z 可撤销")
                }
                if docSession.blocks.isEmpty { exitOrganizeMode() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(selectedCount > 0 ? "删除所选 (\(selectedCount))" : "删除所选")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(selectedCount > 0 ? theme.token(.destructiveForeground) : theme.token(.mutedForeground))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    selectedCount > 0 ? theme.token(.destructive) : theme.token(.muted),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
            .buttonStyle(SnapPressStyle(scale: 0.96))
            .disabled(selectedCount == 0)
            .opacity(selectedCount > 0 ? 1 : 0.45)

            Button {
                let removed = withAnimation(Interaction.panel) {
                    docSession.keepOnly(blockIDs: activeSelection)
                }
                exitOrganizeMode()
                if removed > 0 {
                    environment.toast.info("已保留 \(selectedCount) 段并清理其余 \(removed) 段（⌘Z 撤销）")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("仅保留所选")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(theme.token(.foreground))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.token(.border), lineWidth: 1)
                )
            }
            .buttonStyle(SnapPressStyle(scale: 0.96))
            .disabled(selectedCount == 0 || selectedCount == docSession.totalCount)
            .opacity(selectedCount > 0 && selectedCount < docSession.totalCount ? 1 : 0.42)
            .help("保留勾选的正文段，一键删掉其余所有杂乱段落")

            if untranslatedSelected > 0 && activeProvider != nil {
                SnapButton("翻译所选 (\(untranslatedSelected))", theme: theme, variant: .primary, size: .sm) {
                    let targets = activeSelection
                    exitOrganizeMode()
                    docSession.startPending(for: targets, allowDownload: false)
                }
                .help("只翻译当前勾选的段落，节省 API 额度")
            }

            Spacer(minLength: 4)

            Button("清空全部") {
                let removed = withAnimation(Interaction.panel) {
                    docSession.removeAll()
                }
                exitOrganizeMode()
                if removed > 0 {
                    environment.toast.info("已清空全部 \(removed) 段，按 ⌘Z 可一键恢复")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.token(.destructive).opacity(0.9))
            .padding(.horizontal, 6)
            .help("一键清空全部段落，随时可按 ⌘Z 恢复")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.token(.popover))
    }

    private func enterOrganizeMode(initialSelection: UUID? = nil) {
        withAnimation(Interaction.toggle) {
            editingBlockID = nil
            isOrganizing = true
            if let initialSelection {
                selectedBlockIDs = [initialSelection]
                lastSelectedBlockID = initialSelection
            } else {
                selectedBlockIDs.removeAll()
                lastSelectedBlockID = nil
            }
        }
    }

    private func exitOrganizeMode() {
        withAnimation(Interaction.toggle) {
            isOrganizing = false
            selectedBlockIDs.removeAll()
            lastSelectedBlockID = nil
        }
    }

    private func toggleBlockSelection(_ blockID: UUID) {
        let shiftPressed = NSEvent.modifierFlags.contains(.shift)
        withAnimation(Interaction.hover) {
            if shiftPressed,
               let anchorID = lastSelectedBlockID,
               let startIdx = docSession.blocks.firstIndex(where: { $0.id == anchorID }),
               let endIdx = docSession.blocks.firstIndex(where: { $0.id == blockID }) {
                let lower = min(startIdx, endIdx)
                let upper = max(startIdx, endIdx)
                for idx in lower...upper {
                    selectedBlockIDs.insert(docSession.blocks[idx].id)
                }
            } else if selectedBlockIDs.contains(blockID) {
                selectedBlockIDs.remove(blockID)
            } else {
                selectedBlockIDs.insert(blockID)
            }
            lastSelectedBlockID = blockID
        }
    }

    // MARK: - 首次引导状态（一键直达）

    private var setupOnboardingState: some View {
        VStack(spacing: 14) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 28))
                .foregroundStyle(theme.token(.primary))
                .frame(width: 52, height: 52)
                .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 4) {
                Text("选择翻译引擎，即刻开始")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
                Text("已识别到 \(docSession.totalCount) 段文字。选择服务后将自动翻译整图并支持原位覆译与划词精翻。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 300)

            VStack(spacing: 8) {
                if #available(macOS 15, *) {
                    SnapButton(theme: theme, variant: .primary, size: .md) {
                        enableAppleTranslationQuickly()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 12, weight: .semibold))
                            Text("启用 Apple 离线翻译（本机）")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .frame(minWidth: 230)
                    }
                }
                SnapButton(theme: theme, variant: .secondary, size: .md) {
                    enableGoogleQuickTranslation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("使用 Google 翻译（免配置快翻）")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .frame(minWidth: 230)
                }
                SnapButton(theme: theme, variant: .outline, size: .md) {
                    reading.isConfiguring = true
                    settingsPopoverOpen = true
                } label: {
                    Text("配置百度 / DeepL / 微软 / 腾讯 / 模型…")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 230)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func enableAppleTranslationQuickly() {
        guard #available(macOS 15, *) else { return }
        withAnimation(Interaction.panel) {
            config.update { $0.translation.provider = .apple }
        }
    }

    private func enableGoogleQuickTranslation() {
        withAnimation(Interaction.panel) {
            config.update {
                $0.translation.provider = .api
                $0.translation.apiProvider = .google
            }
        }
    }

    // MARK: - 划词精翻焦点卡（右侧顶部插槽）

    private func selectionFocusBanner(_ focus: TranslationReadingSession.Focus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.token(.primary))
                Text("划词精翻")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
                Spacer()
                if !editingFocusText {
                    rowActionIcon("修改选中原文", icon: "pencil") {
                        focusDraft = focus.text
                        withAnimation(Interaction.toggle) { editingFocusText = true }
                    }
                }
                if case .translated(let result) = reading.phase {
                    rowActionIcon("复制划词译文", icon: copiedTag == "focus" ? "checkmark" : "doc.on.doc", highlighted: copiedTag == "focus") {
                        copyText(result, tag: "focus")
                    }
                }
                rowActionIcon("清除划词", icon: "xmark") {
                    withAnimation(Interaction.panel) {
                        editingFocusText = false
                        resetSelection += 1
                        reading.dismiss()
                    }
                }
            }

            if editingFocusText {
                inlineEditor(text: $focusDraft, onCancel: {
                    withAnimation(Interaction.toggle) { editingFocusText = false }
                }, onCommit: {
                    let trimmed = focusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    withAnimation(Interaction.toggle) { editingFocusText = false }
                    reading.show(trimmed, bounds: focus.bounds, trigger: .selection)
                })
            } else {
                Text(focus.text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("translationSource")

                Rectangle().fill(theme.token(.border)).frame(height: 1)

                focusPhaseBody
            }
        }
        .padding(11)
        .background(theme.token(.muted).opacity(0.65), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(accentColor.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var focusPhaseBody: some View {
        switch reading.phase {
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在翻译…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
            }
        case .languageDownload:
            HStack(spacing: 8) {
                Text("需要下载 Apple 语言包")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
                Spacer()
                SnapButton("下载并翻译", theme: theme, variant: .primary, size: .sm) {
                    reading.authorizeDownload()
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.destructive))
                    .lineLimit(3)
                Spacer()
                SnapButton("重试", theme: theme, variant: .outline, size: .sm) {
                    reading.start()
                }
            }
        case .translated(let result):
            Text(result)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.token(.foreground))
                .lineSpacing(3.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("translationResult")
        }
    }

    private var downloadRequiredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15))
                .foregroundStyle(theme.token(.primary))
            VStack(alignment: .leading, spacing: 2) {
                Text("需要下载 Apple 离线语言包")
                    .font(.system(size: 12, weight: .semibold))
                Text("下载完成后即可在本机离线翻译此语言组合。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.token(.mutedForeground))
            }
            Spacer()
            SnapButton("换服务", theme: theme, variant: .ghost, size: .sm) {
                reading.isConfiguring = true
                settingsPopoverOpen = true
            }
            SnapButton("下载并翻译", theme: theme, variant: .primary, size: .sm) {
                docSession.authorizeDownload()
            }
        }
        .padding(10)
        .background(theme.token(.muted).opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.token(.border), lineWidth: 1)
        )
    }

    // MARK: - 译文样式定制 Popover（字号 / 字体 / 行距 / 高亮色）

    private var stylePopoverButton: some View {
        Button {
            stylePopoverOpen.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(stylePopoverOpen ? accentColor : theme.token(.mutedForeground))
                .frame(width: 26, height: 26)
                .background(
                    stylePopoverOpen ? accentColor.opacity(0.14) : theme.token(.muted),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(stylePopoverOpen ? accentColor.opacity(0.45) : theme.token(.border), lineWidth: 1)
                )
        }
        .buttonStyle(SnapPressStyle(scale: 0.94))
        .help("自定义字体、字号、行距与高亮色")
        .popover(isPresented: $stylePopoverOpen, arrowEdge: .bottom) {
            typographyPopoverContent
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
        }
    }

    private var typographyPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("排版与高亮样式")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if typography != .default {
                    Button("恢复默认") {
                        withAnimation(Interaction.toggle) {
                            config.update { $0.translation.style = .default }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(accentColor)
                }
            }

            // 高亮色盘
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("高亮强调色")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                    Text(typography.accent.title)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
                HStack(spacing: 10) {
                    ForEach(TranslationAccentPreset.allCases, id: \.self) { preset in
                        let selected = typography.accent == preset
                        let swatch = preset.rgb.color
                        Button {
                            withAnimation(Interaction.toggle) {
                                config.update { $0.translation.style.accent = preset }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(swatch)
                                    .frame(width: 20, height: 20)
                                if selected {
                                    Circle()
                                        .strokeBorder(theme.token(.popover), lineWidth: 2)
                                        .frame(width: 16, height: 16)
                                    Circle()
                                        .strokeBorder(swatch, lineWidth: 1.5)
                                        .frame(width: 26, height: 26)
                                }
                            }
                            .frame(width: 28, height: 28)
                        }
                        .buttonStyle(SnapPressStyle(scale: 0.9))
                        .help(preset.title)
                    }
                }
            }

            Rectangle().fill(theme.token(.border)).frame(height: 1)

            // 字体风格
            VStack(alignment: .leading, spacing: 6) {
                Text("文字字体")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                SnapSegmented(
                    items: TranslationFontFamily.allCases,
                    selection: Binding(
                        get: { typography.fontFamily },
                        set: { value in config.update { $0.translation.style.fontFamily = value } }
                    ),
                    theme: theme,
                    title: \.title
                )
            }

            // 原文字号
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("原文字号")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                    Text("\(Int(typography.sourceFontSize.rounded())) pt")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.token(.foreground))
                }
                SnapSlider(
                    value: Binding(
                        get: { typography.sourceFontSize },
                        set: { value in config.update { $0.translation.style.sourceFontSize = (value * 2).rounded() / 2 } }
                    ),
                    in: 11...18,
                    theme: theme,
                    width: 252
                )
            }

            // 译文字号
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("译文字号")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                    Text(String(format: "%.1f pt", typography.targetFontSize))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.token(.foreground))
                }
                SnapSlider(
                    value: Binding(
                        get: { typography.targetFontSize },
                        set: { value in config.update { $0.translation.style.targetFontSize = (value * 2).rounded() / 2 } }
                    ),
                    in: 12...22,
                    theme: theme,
                    width: 252
                )
            }

            // 行距
            VStack(alignment: .leading, spacing: 6) {
                Text("段落行距")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                SnapSegmented(
                    items: [3.0, 5.0, 8.0],
                    selection: Binding(
                        get: {
                            if typography.lineSpacing <= 3.5 { return 3.0 }
                            if typography.lineSpacing >= 7.0 { return 8.0 }
                            return 5.0
                        },
                        set: { value in config.update { $0.translation.style.lineSpacing = value } }
                    ),
                    theme: theme
                ) { value in
                    value <= 3.5 ? "紧凑" : value >= 7.0 ? "宽松" : "舒适"
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(theme.token(.popover))
        .foregroundStyle(theme.token(.foreground))
    }

    // MARK: - 译文段落卡片 / 流畅阅读行

    private func blockRow(_ block: TranslationDocumentSession.BlockItem) -> some View {
        let isHovered = hoveredBlockID == block.id
        let isEditing = editingBlockID == block.id
        let isSelected = isOrganizing && selectedBlockIDs.contains(block.id)
        let copyKey = block.id.uuidString
        let showsActions = !isEditing && !isOrganizing && (isHovered || copiedTag == copyKey)

        return HStack(alignment: .top, spacing: 10) {
            if isOrganizing {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? accentColor : theme.token(.background).opacity(0.6))
                        .frame(width: 17, height: 17)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isSelected ? accentColor : theme.token(.mutedForeground).opacity(0.45),
                            lineWidth: 1.2
                        )
                        .frame(width: 17, height: 17)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .padding(.top, showBilingual ? 12 : 10)
                .padding(.leading, 11)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Group {
                if isEditing {
                    blockInlineEditor(for: block)
                        .padding(12)
                } else if showBilingual {
                    // 双语对照卡片：独立呼吸卡片 + 左侧自定义高亮竖线原文引用 + 下方清晰译文
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 9) {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(isHovered || isSelected ? accentColor : accentColor.opacity(0.45))
                                .frame(width: 2.5)
                                .padding(.vertical, 2)

                            Text(block.sourceText)
                                .font(.system(size: typography.sourceFontSize, design: fontDesign))
                                .foregroundStyle(theme.token(.mutedForeground).opacity(0.92))
                                .lineSpacing(max(2, typography.lineSpacing * 0.7))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        blockPhaseView(block)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, isOrganizing ? 2 : 13)
                    .padding(.trailing, 13)
                    .padding(.vertical, 11)
                } else {
                    // 纯译文极简阅读流：全宽大呼吸感排版
                    blockPhaseView(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, isOrganizing ? 2 : 12)
                        .padding(.trailing, 12)
                        .padding(.vertical, 8)
                }
            }
            .allowsHitTesting(!isOrganizing)
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentColor.opacity(theme.isDark ? 0.16 : 0.12))
            } else if showBilingual || isEditing || isOrganizing {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isHovered || isEditing
                            ? theme.token(.muted).opacity(theme.isDark ? 0.78 : 0.90)
                            : theme.token(.muted).opacity(theme.isDark ? 0.42 : 0.52)
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accentColor.opacity(theme.isDark ? 0.11 : 0.09))
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.75), lineWidth: 1.2)
                    .allowsHitTesting(false)
            } else if showBilingual || isEditing || isOrganizing {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered || isEditing
                            ? accentColor.opacity(0.55)
                            : theme.token(.border).opacity(0.75),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.32), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsActions {
                HStack(spacing: 2) {
                    floatingRowAction("在原图定位", icon: "scope") {
                        hoveredBlockID = block.id
                        scrollToBlockID = block.id
                    }
                    floatingRowAction("编辑译文或原文", icon: "pencil") {
                        if let translated = block.phase.translatedText {
                            editingTargetText = true
                            editingBlockDraft = translated
                        } else {
                            editingTargetText = false
                            editingBlockDraft = block.sourceText
                        }
                        withAnimation(Interaction.toggle) { editingBlockID = block.id }
                    }
                    if let translated = block.phase.translatedText {
                        floatingRowAction(
                            "复制此段译文",
                            icon: copiedTag == copyKey ? "checkmark" : "doc.on.doc",
                            highlighted: copiedTag == copyKey
                        ) {
                            copyText(translated, tag: copyKey)
                        }
                    }
                    floatingRowAction("删除此段冗余文字", icon: "trash", destructive: true) {
                        withAnimation(Interaction.panel) {
                            if hoveredBlockID == block.id { hoveredBlockID = nil }
                            if scrollToBlockID == block.id { scrollToBlockID = nil }
                            docSession.remove(blockID: block.id)
                        }
                    }
                }
                .padding(3)
                .background(theme.token(.popover), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.token(.border), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .padding(7)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
            }
        }
        .animation(Interaction.hover, value: isHovered)
        .animation(Interaction.hover, value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            if isOrganizing {
                toggleBlockSelection(block.id)
            } else if !isEditing && NSEvent.modifierFlags.contains(.command) {
                enterOrganizeMode(initialSelection: block.id)
            }
        }
        .onHover { inside in
            if inside {
                hoveredBlockID = block.id
            } else if hoveredBlockID == block.id {
                hoveredBlockID = nil
            }
        }
    }

    private func blockInlineEditor(for block: TranslationDocumentSession.BlockItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    miniPillToggle("编辑译文", icon: "pencil.line", selected: editingTargetText) {
                        guard !editingTargetText else { return }
                        editingTargetText = true
                        editingBlockDraft = block.phase.translatedText ?? ""
                    }
                    miniPillToggle("改原文重译", icon: "arrow.triangle.2.circlepath", selected: !editingTargetText) {
                        guard editingTargetText else { return }
                        editingTargetText = false
                        editingBlockDraft = block.sourceText
                    }
                }
                .padding(2)
                .background(theme.token(.background).opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer()
                Button {
                    withAnimation(Interaction.panel) {
                        editingBlockID = nil
                        docSession.remove(blockID: block.id)
                    }
                } label: {
                    Label("删除整段", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.token(.destructive))
                }
                .buttonStyle(.plain)
            }

            inlineEditor(
                text: $editingBlockDraft,
                hint: editingTargetText ? "直接增删或润色译文（清空保存可删除该段）" : "修改识别原文后将重新翻译此段",
                commitTitle: editingTargetText ? "保存译文" : "重新翻译",
                allowEmptyCommit: editingTargetText,
                onCancel: {
                    withAnimation(Interaction.toggle) { editingBlockID = nil }
                },
                onCommit: {
                    let next = editingBlockDraft
                    let isTarget = editingTargetText
                    withAnimation(Interaction.toggle) { editingBlockID = nil }
                    if isTarget {
                        docSession.updateTranslatedText(blockID: block.id, editedTranslation: next)
                    } else {
                        docSession.retranslate(blockID: block.id, editedText: next)
                    }
                }
            )
        }
    }

    private func floatingRowAction(
        _ title: String,
        icon: String,
        highlighted: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(
                    highlighted ? Color.green
                        : destructive ? theme.token(.destructive).opacity(0.9)
                        : theme.token(.foreground).opacity(0.82)
                )
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(SnapPressStyle(scale: 0.9))
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func blockPhaseView(_ block: TranslationDocumentSession.BlockItem) -> some View {
        switch block.phase {
        case .idle:
            if showBilingual {
                HStack(spacing: 6) {
                    Text("待翻译")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.token(.background).opacity(0.6), in: Capsule())
                    if !isOrganizing {
                        Button("翻译此段") {
                            docSession.startPending(for: [block.id], allowDownload: false)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(accentColor)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(block.sourceText)
                        .font(.system(size: typography.sourceFontSize, design: fontDesign))
                        .foregroundStyle(theme.token(.foreground).opacity(0.75))
                        .lineSpacing(max(2.5, typography.lineSpacing * 0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("待翻译")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.token(.mutedForeground))
                        if !isOrganizing {
                            Button("翻译此段") {
                                docSession.startPending(for: [block.id], allowDownload: false)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(accentColor)
                        }
                    }
                }
            }
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在翻译…")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.token(.mutedForeground))
            }
            .padding(.vertical, 2)
        case .languageDownload:
            Text("等待下载语言包")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.token(.mutedForeground))
        case .translated(let result):
            Text(result)
                .font(.system(size: typography.targetFontSize, design: fontDesign))
                .foregroundStyle(theme.token(.foreground).opacity(theme.isDark ? 0.94 : 1.0))
                .lineSpacing(typography.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.destructive))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                SnapButton("重试", theme: theme, variant: .outline, size: .sm) {
                    docSession.retry(blockID: block.id)
                }
            }
        }
    }

    private func inlineEditor(
        text: Binding<String>,
        hint: String = "修改识别原文后将重新翻译此段",
        commitTitle: String = "重新翻译",
        allowEmptyCommit: Bool = false,
        onCancel: @escaping () -> Void,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: text)
                .font(.system(size: typography.targetFontSize, design: fontDesign))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 62, maxHeight: 150)
                .background(theme.token(.background), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.65), lineWidth: 1)
                )

            HStack(spacing: 6) {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .lineLimit(1)
                Spacer()
                SnapButton("取消", theme: theme, variant: .ghost, size: .sm, action: onCancel)
                SnapButton(
                    commitTitle,
                    theme: theme,
                    variant: .primary,
                    size: .sm,
                    isEnabled: allowEmptyCommit || !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: onCommit
                )
            }
        }
    }

    // MARK: - 原图点读模式的可拖拽、可缩放、可固定译文浮卡

    private func floatingResultCard(
        _ focus: TranslationReadingSession.Focus,
        currentOrigin: CGPoint,
        currentSize: CGSize,
        viewport: CGSize
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // 可拖动标题栏 + 固定 / 样式 / 编辑 / 复制 / 收起按钮
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: focus.trigger == .selection ? "text.cursor" : "character.bubble")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(focus.trigger == .selection ? "划词译文" : "句意译文")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.token(.foreground))
                    if reading.isPinned {
                        Text("已固定")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(accentColor.opacity(0.14), in: Capsule())
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("translationOverlayCanvas"))
                        .onChanged { value in
                            if floatDragStartOrigin == nil {
                                floatDragStartOrigin = currentOrigin
                                reading.isInteracting = true
                                reading.isPinned = true
                            }
                            let base = floatDragStartOrigin ?? currentOrigin
                            let next = CGPoint(
                                x: base.x + value.translation.width,
                                y: base.y + value.translation.height
                            )
                            floatCardOrigin = clampedFloatCardOrigin(next, size: currentSize, viewport: viewport)
                        }
                        .onEnded { _ in
                            floatDragStartOrigin = nil
                            reading.isInteracting = false
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(Interaction.toggle) {
                        floatCardOrigin = nil
                        floatCardCustomHeight = false
                        floatCardWidth = 360
                        floatCardHeight = 220
                    }
                }
                .help("拖动标题栏移动浮卡，双击恢复默认位置与尺寸")

                // 固定 / 取消固定
                Button {
                    withAnimation(Interaction.toggle) {
                        reading.isPinned.toggle()
                        if reading.isPinned && floatCardOrigin == nil {
                            floatCardOrigin = currentOrigin
                        } else if !reading.isPinned {
                            floatCardOrigin = nil
                        }
                    }
                } label: {
                    Image(systemName: reading.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(reading.isPinned ? accentColor : theme.token(.mutedForeground))
                        .frame(width: 24, height: 24)
                        .background(
                            reading.isPinned ? accentColor.opacity(0.15) : theme.token(.muted),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(reading.isPinned ? accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(SnapPressStyle(scale: 0.92))
                .help(reading.isPinned ? "取消固定（移开鼠标后将自动收起）" : "固定浮卡（移开鼠标不消失，可继续点读其他句子）")

                // 样式定制（Aa）
                Button {
                    floatStylePopoverOpen.toggle()
                    reading.isConfiguring = floatStylePopoverOpen
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(floatStylePopoverOpen ? accentColor : theme.token(.mutedForeground))
                        .frame(width: 24, height: 24)
                        .background(
                            floatStylePopoverOpen ? accentColor.opacity(0.15) : theme.token(.muted),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(SnapPressStyle(scale: 0.92))
                .help("调整字体、字号、行距与高亮色")
                .popover(isPresented: $floatStylePopoverOpen, arrowEdge: .bottom) {
                    typographyPopoverContent
                        .environment(\.colorScheme, theme.isDark ? .dark : .light)
                        .onDisappear { reading.isConfiguring = false }
                }

                if !editingFocusText {
                    rowActionIcon("修改原文重译", icon: "pencil") {
                        reading.isConfiguring = true
                        focusDraft = focus.text
                        withAnimation(Interaction.toggle) { editingFocusText = true }
                    }
                }
                if case .translated(let result) = reading.phase {
                    rowActionIcon(
                        "复制译文",
                        icon: copiedTag == "float" ? "checkmark" : "doc.on.doc",
                        highlighted: copiedTag == "float"
                    ) {
                        copyText(result, tag: "float")
                    }
                }
                rowActionIcon("收起", icon: "xmark") {
                    withAnimation(Interaction.panel) {
                        editingFocusText = false
                        floatStylePopoverOpen = false
                        floatCardOrigin = nil
                        reading.isConfiguring = false
                        resetSelection += 1
                        reading.dismiss()
                    }
                }
            }

            if editingFocusText {
                inlineEditor(text: $focusDraft, onCancel: {
                    reading.isConfiguring = false
                    withAnimation(Interaction.toggle) { editingFocusText = false }
                }, onCommit: {
                    let trimmed = focusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    reading.isConfiguring = false
                    withAnimation(Interaction.toggle) { editingFocusText = false }
                    reading.show(trimmed, bounds: focus.bounds, trigger: .selection)
                })
            } else {
                // 原文区（带自定义高亮引导线与原文字号/字体）
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accentColor.opacity(0.6))
                        .frame(width: 2.5)
                        .padding(.vertical, 2)
                    Text(focus.text)
                        .font(.system(size: typography.sourceFontSize, design: fontDesign))
                        .foregroundStyle(theme.token(.mutedForeground).opacity(0.92))
                        .lineSpacing(max(2, typography.lineSpacing * 0.65))
                        .lineLimit(floatCardCustomHeight ? 4 : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("translationSource")

                Rectangle().fill(theme.token(.border)).frame(height: 1)

                if activeProvider == nil {
                    HStack(spacing: 8) {
                        if #available(macOS 15, *) {
                            SnapButton("启用 Apple 离线", theme: theme, variant: .primary, size: .sm) {
                                enableAppleTranslationQuickly()
                            }
                        }
                        SnapButton("配置服务…", theme: theme, variant: .outline, size: .sm) {
                            reading.isConfiguring = true
                            settingsPopoverOpen = true
                        }
                    }
                } else {
                    switch reading.phase {
                    case .waiting:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在翻译…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.token(.mutedForeground))
                        }
                    case .languageDownload:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Apple 设备端翻译需要下载此语言包。")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.token(.mutedForeground))
                            HStack(spacing: 6) {
                                SnapButton("下载并翻译", theme: theme, variant: .primary, size: .sm) {
                                    reading.authorizeDownload()
                                }
                                SnapButton("换服务", theme: theme, variant: .outline, size: .sm) {
                                    reading.isConfiguring = true
                                    settingsPopoverOpen = true
                                }
                            }
                        }
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.token(.destructive))
                                .lineLimit(4)
                            HStack(spacing: 6) {
                                SnapButton("重试", theme: theme, variant: .outline, size: .sm) {
                                    reading.start()
                                }
                                SnapButton("换服务", theme: theme, variant: .ghost, size: .sm) {
                                    reading.isConfiguring = true
                                    settingsPopoverOpen = true
                                }
                            }
                        }
                    case .translated(let result):
                        if floatCardCustomHeight {
                            ScrollView {
                                Text(result)
                                    .font(.system(size: typography.targetFontSize, design: fontDesign))
                                    .foregroundStyle(theme.token(.foreground).opacity(theme.isDark ? 0.94 : 1.0))
                                    .lineSpacing(typography.lineSpacing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("translationResult")
                        } else {
                            ViewThatFits(in: .vertical) {
                                Text(result)
                                    .font(.system(size: typography.targetFontSize, design: fontDesign))
                                    .foregroundStyle(theme.token(.foreground).opacity(theme.isDark ? 0.94 : 1.0))
                                    .lineSpacing(typography.lineSpacing)
                                    .fixedSize(horizontal: false, vertical: true)
                                ScrollView {
                                    Text(result)
                                        .font(.system(size: typography.targetFontSize, design: fontDesign))
                                        .foregroundStyle(theme.token(.foreground).opacity(theme.isDark ? 0.94 : 1.0))
                                        .lineSpacing(typography.lineSpacing)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxHeight: 240, alignment: .topLeading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("translationResult")
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: floatCardCustomHeight ? .infinity : nil, alignment: .topLeading)
        .senPanelStyle(theme: theme, radius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(reading.isPinned ? accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .bottomTrailing) {
            floatCardResizeGrip(currentOrigin: currentOrigin, currentSize: currentSize, viewport: viewport)
        }
    }

    private func floatCardResizeGrip(
        currentOrigin: CGPoint,
        currentSize: CGSize,
        viewport: CGSize
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            Path { path in
                path.move(to: CGPoint(x: 6, y: 14))
                path.addLine(to: CGPoint(x: 14, y: 6))
                path.move(to: CGPoint(x: 10, y: 14))
                path.addLine(to: CGPoint(x: 14, y: 10))
            }
            .stroke(
                floatResizeStartSize != nil ? accentColor : theme.token(.mutedForeground).opacity(0.55),
                style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
            )
            .frame(width: 16, height: 16)
            .padding(3)
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("translationOverlayCanvas"))
                .onChanged { value in
                    if floatResizeStartSize == nil {
                        floatResizeStartSize = currentSize
                        if floatCardOrigin == nil {
                            floatCardOrigin = currentOrigin
                        }
                        reading.isInteracting = true
                        reading.isPinned = true
                    }
                    let base = floatResizeStartSize ?? currentSize
                    let maxW = max(240, viewport.width - currentOrigin.x - 10)
                    let maxH = max(140, viewport.height - currentOrigin.y - 60)
                    let nextW = min(maxW, max(240, base.width + value.translation.width))
                    let nextH = min(maxH, max(140, base.height + value.translation.height))
                    floatCardWidth = Double(nextW)
                    floatCardHeight = Double(nextH)
                    floatCardCustomHeight = true
                }
                .onEnded { _ in
                    floatResizeStartSize = nil
                    reading.isInteracting = false
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(Interaction.toggle) {
                floatCardWidth = 360
                floatCardHeight = 220
                floatCardCustomHeight = false
            }
        }
        .help("拖动右下角调整浮卡大小，双击恢复默认尺寸")
    }

    private func resolvedFloatCardOrigin(anchor: CGRect, size: CGSize, viewport: CGSize) -> CGPoint {
        if let pinnedOrigin = floatCardOrigin {
            return clampedFloatCardOrigin(pinnedOrigin, size: size, viewport: viewport)
        }
        let offset = cardOffset(anchor: anchor, size: size, viewport: viewport)
        return CGPoint(x: offset.width, y: offset.height)
    }

    private func clampedFloatCardOrigin(_ point: CGPoint, size: CGSize, viewport: CGSize) -> CGPoint {
        let margin: CGFloat = 10
        let bottomClearance: CGFloat = 56
        let maxX = max(margin, viewport.width - size.width - margin)
        let maxY = max(margin, viewport.height - bottomClearance - size.height)
        return CGPoint(
            x: max(margin, min(point.x, maxX)),
            y: max(margin, min(point.y, maxY))
        )
    }

    // MARK: - 通用组件与工具方法

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.token(.card))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private func rowActionIcon(
        _ title: String,
        icon: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(highlighted ? Color.green : theme.token(.mutedForeground))
                .frame(width: 24, height: 24)
                .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(SnapPressStyle(scale: 0.92))
        .help(title)
        .accessibilityLabel(title)
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.token(.mutedForeground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(theme.token(.mutedForeground))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.token(.foreground))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            SnapButton("再截一张", theme: theme, variant: .outline, size: .sm, action: onRecapture)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func languageName(for code: String, isSource: Bool) -> String {
        if isSource && code == "auto" { return "自动" }
        return languages.first { $0.code == code }?.name ?? code
    }

    private func copyText(_ text: String, tag: String) {
        guard !text.isEmpty else { return }
        environment.pinTransfer.copy(text)
        environment.toast.success("已复制译文（\(text.count) 字）")
        withAnimation(Interaction.toggle) { copiedTag = tag }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            if copiedTag == tag {
                withAnimation(Interaction.hover) { copiedTag = nil }
            }
        }
    }

    private func cardOffset(anchor: CGRect, size: CGSize, viewport: CGSize) -> CGSize {
        let margin: CGFloat = 10
        let bottomClearance: CGFloat = 56 // 避开底部悬浮条
        let usableHeight = max(size.height + margin * 2, viewport.height - bottomClearance)
        let x = anchor == .zero ? viewport.width - size.width - margin : anchor.minX
        let below = anchor == .zero ? margin : anchor.maxY + 4
        let above = anchor.minY - size.height - 4
        let y: CGFloat
        if below + size.height + margin <= usableHeight {
            y = below
        } else if above >= margin {
            y = above
        } else {
            y = max(margin, min(below, usableHeight - size.height - margin))
        }
        return CGSize(
            width: max(margin, min(x, viewport.width - size.width - margin)),
            height: max(margin, min(y, usableHeight - size.height - margin))
        )
    }

    private func prepareDocument() async {
        if let document {
            docSession.load(document: document, image: image, autoStart: shouldAutoTranslate)
            return
        }
        isRecognizing = true
        recognitionError = nil
        do {
            let result = try await environment.ocr.recognize(
                image,
                options: .init(languages: config.settings.ocr.languages)
            )
            guard !Task.isCancelled else { return }
            document = result
            isRecognizing = false
            docSession.load(document: result, image: image, autoStart: shouldAutoTranslate)
        } catch {
            guard !Task.isCancelled else { return }
            isRecognizing = false
            recognitionError = error.localizedDescription
        }
    }

    private func handleEscape() {
        if editingBlockID != nil {
            withAnimation(Interaction.toggle) { editingBlockID = nil }
        } else if editingFocusText {
            reading.isConfiguring = false
            withAnimation(Interaction.toggle) { editingFocusText = false }
        } else if isOrganizing {
            exitOrganizeMode()
        } else if floatStylePopoverOpen {
            floatStylePopoverOpen = false
            reading.isConfiguring = false
        } else if stylePopoverOpen {
            stylePopoverOpen = false
        } else if settingsPopoverOpen {
            settingsPopoverOpen = false
        } else if reading.focus != nil {
            withAnimation(Interaction.panel) {
                floatCardOrigin = nil
                resetSelection += 1
                reading.dismiss()
            }
        } else {
            onClose()
        }
    }

    // MARK: - 快捷键与空格透视

    private var hiddenShortcuts: some View {
        Group {
            Button("") { withAnimation(Interaction.hover) { zoom = min(5, zoom * 1.25) } }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { withAnimation(Interaction.hover) { zoom = max(0.5, zoom / 1.25) } }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { withAnimation(Interaction.toggle) { zoom = 1 } }
                .keyboardShortcut("0", modifiers: .command)
            if editingBlockID == nil, !editingFocusText, docSession.deletedCount > 0 {
                Button("") {
                    withAnimation(Interaction.panel) {
                        if let restored = docSession.undoLastRemoval() {
                            hoveredBlockID = restored
                            scrollToBlockID = restored
                        }
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func installSpaceMonitor() {
        removeSpaceMonitor()
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == 49 else { return event } // Space
            guard displayMode == .overlay, showOverlayLayer,
                  editingBlockID == nil, !editingFocusText, !settingsPopoverOpen else {
                return event
            }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event
            }
            if event.type == .keyDown {
                if !peekingOriginal { peekingOriginal = true }
            } else if event.type == .keyUp {
                if peekingOriginal { peekingOriginal = false }
            }
            return nil
        }
    }

    private func removeSpaceMonitor() {
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
            self.spaceMonitor = nil
        }
        peekingOriginal = false
    }

    // MARK: - 翻译执行器（单句/划词 + 整图分块批量）

    @ViewBuilder
    private var translationWorkers: some View {
        ZStack {
            if let job = reading.request, let provider = activeProvider, !settingsPopoverOpen {
                singleTranslationWorker(job: job, provider: provider)
            }
            if let batch = docSession.batchJob, let provider = activeProvider, !settingsPopoverOpen {
                batchTranslationWorker(batch: batch, provider: provider)
            }
        }
    }

    @ViewBuilder
    private func singleTranslationWorker(job: TranslationReadingSession.Request,
                                         provider: ScreenshotTranslationProvider) -> some View {
        if provider == .apple {
            if #available(macOS 15, *) {
                AppleSingleTranslationJob(job: job, source: source, target: targetLanguage, reading: reading)
                    .id(job.id)
            } else {
                Color.clear.task(id: job.id) {
                    reading.finish(job.id, result: .failure(TranslationMessage("Apple 设备端翻译需要 macOS 15 或更高版本。")))
                }
            }
        } else {
            Color.clear.task(id: job.id) {
                do {
                    let value = try await TranslationModelClient.translate(
                        job.text,
                        source: source,
                        target: targetLanguage,
                        config: config
                    )
                    guard !Task.isCancelled else { return }
                    reading.finish(job.id, result: .success(value))
                } catch {
                    guard !Task.isCancelled else { return }
                    reading.finish(job.id, result: .failure(error))
                }
            }
        }
    }

    @ViewBuilder
    private func batchTranslationWorker(batch: TranslationDocumentSession.BatchJob,
                                        provider: ScreenshotTranslationProvider) -> some View {
        switch provider {
        case .apple:
            if #available(macOS 15, *) {
                AppleBatchTranslationJob(batch: batch, source: source, target: targetLanguage, session: docSession)
                    .id(batch.id)
            } else {
                Color.clear.task(id: batch.id) {
                    docSession.failJob(batch.id, message: "Apple 设备端翻译需要 macOS 15 或更高版本。")
                }
            }
        case .api:
            Color.clear.task(id: batch.id) {
                await runAPIBatch(batch)
            }
        case .local, .online:
            Color.clear.task(id: batch.id) {
                await runModelBatch(batch)
            }
        }
    }

    private func runAPIBatch(_ batch: TranslationDocumentSession.BatchJob) async {
        let texts = batch.items.map(\.text)
        do {
            let outputs = try await TranslationModelClient.translateBatch(
                texts,
                source: source,
                target: targetLanguage,
                config: config
            )
            guard !Task.isCancelled else { return }
            withAnimation(Interaction.hover) {
                for (index, item) in batch.items.enumerated() {
                    if index < outputs.count {
                        docSession.finishBlock(batch.id, blockID: item.id, result: .success(outputs[index]))
                    } else {
                        docSession.finishBlock(batch.id, blockID: item.id, result: .failure(TranslationMessage("翻译结果条目缺失。")))
                    }
                }
            }
            docSession.completeJob(batch.id)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            docSession.failJob(batch.id, message: error.localizedDescription)
        }
    }

    private func runModelBatch(_ batch: TranslationDocumentSession.BatchJob) async {
        let maxConcurrency = 3
        let currentSource = source
        let currentTarget = targetLanguage
        let configStore = config

        await withTaskGroup(of: (UUID, Result<String, Error>).self) { group in
            var iterator = batch.items.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                guard !Task.isCancelled, let item = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    do {
                        let translated = try await TranslationModelClient.translate(
                            item.text,
                            source: currentSource,
                            target: currentTarget,
                            config: configStore
                        )
                        return (item.id, .success(translated))
                    } catch {
                        return (item.id, .failure(error))
                    }
                }
            }

            while inFlight < maxConcurrency {
                let before = inFlight
                enqueueNext()
                if inFlight == before { break }
            }

            for await (blockID, result) in group {
                inFlight -= 1
                guard !Task.isCancelled else { break }
                withAnimation(Interaction.hover) {
                    docSession.finishBlock(batch.id, blockID: blockID, result: result)
                }
                enqueueNext()
            }
        }
        guard !Task.isCancelled else { return }
        docSession.completeJob(batch.id)
    }
}

private struct TranslationEngineSignature: Equatable {
    let provider: ScreenshotTranslationProvider?
    let targetLanguage: String
    let apiProvider: TranslationAPIProvider
    let apiConfig: TranslationAPIConfiguration?
    let onlineProvider: PrivacyAIProvider
    let modelConfig: PrivacyAIConfiguration?
}

private struct TranslationMessage: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

private struct ResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorHostView { CursorHostView() }
    func updateNSView(_ nsView: CursorHostView, context: Context) {}

    final class CursorHostView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}

@available(macOS 15, *)
private struct AppleSingleTranslationJob: View {
    let job: TranslationReadingSession.Request
    let source: String
    let target: String
    let reading: TranslationReadingSession
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear.task {
            let input = source == "auto" ? nil : Locale.Language(identifier: source)
            let output = Locale.Language(identifier: target)
            do {
                let availability = LanguageAvailability()
                let status: LanguageAvailability.Status
                if let input { status = await availability.status(from: input, to: output) }
                else { status = try await availability.status(for: job.text, to: output) }
                guard !Task.isCancelled else { return }
                switch status {
                case .installed: break
                case .supported where job.allowDownload: break
                case .supported: reading.needsDownload(job.id); return
                default: throw TranslationMessage("Apple 翻译不支持此语言组合，可更改语言或翻译服务。")
                }
                configuration = .init(source: input, target: output)
            } catch {
                if !Task.isCancelled { reading.finish(job.id, result: .failure(error)) }
            }
        }.translationTask(configuration) { session in
            do {
                let response = try await session.translate(job.text)
                guard !Task.isCancelled else { return }
                reading.finish(job.id, result: .success(response.targetText))
            } catch {
                if !Task.isCancelled { reading.finish(job.id, result: .failure(error)) }
            }
        }
    }
}

@available(macOS 15, *)
private struct AppleBatchTranslationJob: View {
    let batch: TranslationDocumentSession.BatchJob
    let source: String
    let target: String
    let session: TranslationDocumentSession
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear.task {
            let input = source == "auto" ? nil : Locale.Language(identifier: source)
            let output = Locale.Language(identifier: target)
            let sampleText = batch.items.map(\.text).joined(separator: "\n")
            do {
                let availability = LanguageAvailability()
                let status: LanguageAvailability.Status
                if let input { status = await availability.status(from: input, to: output) }
                else { status = try await availability.status(for: sampleText, to: output) }
                guard !Task.isCancelled else { return }
                switch status {
                case .installed: break
                case .supported where batch.allowDownload: break
                case .supported: session.markDownloadRequired(batch.id); return
                default:
                    session.failJob(batch.id, message: "Apple 翻译不支持此语言组合，可更改语言或切换翻译服务。")
                    return
                }
                configuration = .init(source: input, target: output)
            } catch {
                if !Task.isCancelled {
                    session.failJob(batch.id, message: error.localizedDescription)
                }
            }
        }.translationTask(configuration) { translator in
            let requests = batch.items.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
            }
            do {
                for try await response in translator.translate(batch: requests) {
                    guard !Task.isCancelled else { return }
                    if let cid = response.clientIdentifier, let blockID = UUID(uuidString: cid) {
                        withAnimation(Interaction.hover) {
                            session.finishBlock(batch.id, blockID: blockID, result: .success(response.targetText))
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                session.completeJob(batch.id)
            } catch {
                if !Task.isCancelled {
                    session.failJob(batch.id, message: error.localizedDescription)
                }
            }
        }
    }
}
