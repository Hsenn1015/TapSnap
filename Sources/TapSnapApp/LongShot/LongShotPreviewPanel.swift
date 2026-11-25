import AppKit
import Combine
import SwiftUI
import TapSnapImageIO
import TapSnapScreen
import TapSnapSystem
import TapSnapTheme
import UniformTypeIdentifiers

/// 液态玻璃长截图工作台：实时拼接悬浮窗 + 结果预览（首尾快捷裁切、右侧迷你小地图、原生拖出发送与居中玻璃浮岛操作栏）。
final class LongShotPreviewPanel: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var content: LongShotPreviewContentView?
    private var targets: [ClosureTarget] = []
    private var onClose: (() -> Void)?
    private var isLive = false
    private var lastScreen: ScreenDescriptor?
    private var isDark = false

    var windowNumber: Int? { window?.windowNumber }

    /// 返回当前首尾裁切后的归一化纵向保留区间（0...1），未裁切时为 `0...1`。
    var verticalCropFraction: ClosedRange<CGFloat> {
        content?.preview.verticalCropFraction ?? (0...1)
    }

    func isUnderPointer(at point: CGPoint, desktopTop: CGFloat) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(CGPoint(x: point.x, y: desktopTop - point.y))
    }

    func showLive(
        on screen: ScreenDescriptor,
        avoiding avoid: CGRect?,
        theme: Theme? = nil,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSelectScrollRegion: (() -> Void)? = nil,
        onToggleAutomaticScroll: (() -> Void)? = nil
    ) {
        close()
        isLive = true
        lastScreen = screen
        isDark = resolveIsDark(theme: theme)
        onClose = onCancel

        let cancelButton = makePillButton("取消", symbol: nil, tone: .ghost, action: onCancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        var buttons: [LiquidGlassPillButton] = [cancelButton]
        if let onSelectScrollRegion {
            buttons.append(makePillButton("滚动区域…", symbol: "viewfinder", tone: .subtle, action: onSelectScrollRegion))
        }
        if let onToggleAutomaticScroll {
            buttons.append(makePillButton("自动滚动", symbol: "arrow.down.circle", tone: .subtle, action: onToggleAutomaticScroll))
        }
        let finishButton = makePillButton("完成", symbol: "checkmark", tone: .accent, action: onFinish)
        finishButton.keyEquivalent = "\r"
        finishButton.keyEquivalentModifierMask = []
        buttons.append(finishButton)

        let view = LongShotPreviewContentView(live: true, isDark: isDark, buttons: buttons)
        view.status.stringValue = "在选区内缓慢向下滚动，结束时点「完成」"
        let window = makeWindow(size: NSSize(width: 430, height: 470), live: true)
        window.title = "正在截取长图"
        install(view, in: window)
        place(window, visible: screen.visibleFrame, avoiding: avoid)
        window.orderFrontRegardless()
    }

    func update(image: CGImage, viewportHeight: CGFloat) {
        guard let content else { return }
        content.updateLiveFrame(image: image, viewportHeight: viewportHeight, followBottomIfAtEnd: isLive)
    }

    func updateStatus(_ message: String, isWarning: Bool = false) {
        content?.status.stringValue = message
        content?.status.textColor = isWarning ? .systemOrange : .secondaryLabelColor
    }

    func setAutomaticScroll(_ active: Bool) {
        guard let btn = content?.buttons.first(where: { ["自动滚动", "暂停滚动"].contains($0.title) }) else { return }
        btn.updateContent(title: active ? "暂停滚动" : "自动滚动",
                          symbol: active ? "pause.circle" : "arrow.down.circle")
    }

    func setFinishing() {
        content?.buttons.first(where: { $0.title == "完成" })?.isEnabled = false
        updateStatus("正在生成长图…")
    }

    func lockScrollRegion() {
        content?.buttons.first(where: { $0.title == "滚动区域…" })?.isEnabled = false
    }

    func showExisting() {
        guard let window else { return }
        if isLive {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showResult(
        _ image: CGImage,
        actions: [(title: String, handler: () -> Void)],
        theme: Theme? = nil,
        privacyEditor: EditController? = nil,
        dragImageProvider: (() -> CGImage?)? = nil,
        onEdit: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        close()
        isLive = false
        isDark = resolveIsDark(theme: theme ?? privacyEditor?.theme)
        self.onClose = onClose

        let closeButton = makePillButton("关闭", symbol: nil, tone: .ghost, action: onClose)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalentModifierMask = []

        var copyAction: (() -> Void)?
        var saveAction: (() -> Void)?
        var secondaryButtons: [LiquidGlassPillButton] = [closeButton]
        var outputButtons: [LiquidGlassPillButton] = []
        var primaryCopyButton: LiquidGlassPillButton?
        var saveButton: LiquidGlassPillButton?

        if let onEdit {
            secondaryButtons.append(makePillButton("编辑", symbol: "pencil.and.outline", tone: .ghost, action: onEdit))
        }

        for entry in actions {
            switch entry.title {
            case "贴图":
                let btn = makePillButton(entry.title, symbol: "pin", tone: .ghost, action: entry.handler)
                secondaryButtons.append(btn)
                outputButtons.append(btn)
            case "保存":
                let btn = makePillButton(entry.title, symbol: "arrow.down.to.line", tone: .subtle, action: entry.handler)
                saveAction = entry.handler
                saveButton = btn
                outputButtons.append(btn)
            case "复制":
                var createdButton: LiquidGlassPillButton?
                let wrapped: () -> Void = {
                    entry.handler()
                    createdButton?.flashSuccess("已复制")
                }
                let btn = makePillButton(entry.title, symbol: "doc.on.doc", shortcut: "⌘C", tone: .accent, action: wrapped)
                createdButton = btn
                copyAction = wrapped
                primaryCopyButton = btn
                outputButtons.append(btn)
            default:
                let btn = makePillButton(entry.title, symbol: nil, tone: .subtle, action: entry.handler)
                secondaryButtons.append(btn)
                outputButtons.append(btn)
            }
        }

        var orderedButtons = secondaryButtons
        if let saveButton { orderedButtons.append(saveButton) }
        if let primaryCopyButton { orderedButtons.append(primaryCopyButton) }

        let view = LongShotPreviewContentView(
            live: false,
            isDark: isDark,
            buttons: orderedButtons,
            outputButtons: outputButtons,
            dragImageProvider: dragImageProvider ?? { [weak self] in
                guard let self else { return image }
                return Self.cropVertically(image, fraction: self.verticalCropFraction)
            }
        )
        view.preview.image = image
        if let privacyEditor { view.installPrivacy(privacyEditor) }
        view.updateDimensionInfo()
        view.status.stringValue = "可开启「首尾裁切」去页眉页脚，或按住「拖出发送」直发"

        let window = makeWindow(size: NSSize(width: 740, height: 720), live: false)
        window.title = "长截图预览"
        if let lsWindow = window as? LongShotWindow {
            lsWindow.onCopy = copyAction
            lsWindow.onSave = saveAction
        }
        install(view, in: window)
        let visible = lastScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        place(window, visible: visible, avoiding: nil, centered: true)
        window.contentMinSize = NSSize(width: min(360, window.contentLayoutRect.width),
                                       height: min(240, window.contentLayoutRect.height))
        view.layoutSubtreeIfNeeded()
        view.scroll.contentView.scroll(to: .zero)
        view.updateMinimap()
        showExisting()
    }

    static func cropVertically(_ image: CGImage, fraction: ClosedRange<CGFloat>) -> CGImage {
        let top = max(0, min(0.45, fraction.lowerBound))
        let bottom = max(top + 0.05, min(1, fraction.upperBound))
        guard top > 0.001 || bottom < 0.999 else { return image }
        let y = Int((CGFloat(image.height) * top).rounded())
        let h = max(1, Int((CGFloat(image.height) * (bottom - top)).rounded()))
        let rect = CGRect(x: 0, y: y, width: image.width, height: min(h, image.height - y))
        return image.cropping(to: rect) ?? image
    }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        content = nil
        targets = []
        onClose = nil
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        close()
        handler?()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        content?.needsLayout = true
    }

    private func resolveIsDark(theme: Theme?) -> Bool {
        if let theme { return theme.isDark }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func makePillButton(
        _ title: String,
        symbol: String?,
        shortcut: String? = nil,
        tone: LiquidGlassPillButton.Tone,
        action: @escaping () -> Void
    ) -> LiquidGlassPillButton {
        let target = ClosureTarget(action)
        targets.append(target)
        let btn = LiquidGlassPillButton(title: title, target: target, action: #selector(ClosureTarget.fire))
        btn.configure(title: title, symbol: symbol, shortcut: shortcut,
                      tone: tone, isDark: isDark, height: 30, horizontalPadding: tone == .accent ? 14 : 10)
        btn.keyEquivalentModifierMask = []
        return btn
    }

    private func install(_ view: LongShotPreviewContentView, in window: NSPanel) {
        view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.delegate = self
        self.window = window
        content = view
    }

    private func makeWindow(size: NSSize, live: Bool) -> NSPanel {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if live { style.insert(.nonactivatingPanel) } else { style.insert(.resizable) }
        let window = LongShotWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: style, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        ScreenCaptureProtection.apply(to: window)
        return window
    }

    private func place(_ window: NSWindow, visible: CGRect, avoiding avoid: CGRect?, centered: Bool = false) {
        let available = visible.insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(window.frame.width, available.width),
                          height: min(window.frame.height, available.height))
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? visible.maxY
        let avoided = avoid.map { CGRect(x: $0.minX, y: desktopTop - $0.maxY,
                                         width: $0.width, height: $0.height) }
        let candidates = [
            CGPoint(x: available.maxX - size.width, y: available.minY),
            CGPoint(x: available.minX, y: available.minY),
            CGPoint(x: available.maxX - size.width, y: available.maxY - size.height),
            CGPoint(x: available.minX, y: available.maxY - size.height),
        ]
        let origin: CGPoint
        if centered {
            origin = CGPoint(x: available.midX - size.width / 2, y: available.midY - size.height / 2)
        } else {
            origin = candidates.min { lhs, rhs in
                func overlap(_ point: CGPoint) -> CGFloat {
                    guard let avoided else { return 0 }
                    let intersection = CGRect(origin: point, size: size).intersection(avoided)
                    return intersection.isNull ? 0 : intersection.width * intersection.height
                }
                return overlap(lhs) < overlap(rhs)
            } ?? candidates[0]
        }
        window.setFrame(CGRect(origin: origin, size: size), display: false)
        content?.needsLayout = true
        content?.layoutSubtreeIfNeeded()
    }
}

private final class LongShotWindow: NSPanel {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if attachedSheet == nil, modifiers == .command, !(firstResponder is NSTextView), !event.isARepeat {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                if let onCopy { onCopy(); return true }
            case "s":
                if let onSave { onSave(); return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 液态玻璃长截图内容视图

private final class LongShotPreviewContentView: NSView {
    let backdrop: LiquidGlassBackdropView
    let scroll = NSScrollView()
    let preview = LongShotPreviewView()
    let info = NSTextField(labelWithString: "等待第一帧")
    let status = NSTextField(wrappingLabelWithString: "")
    let buttons: [LiquidGlassPillButton]
    private let outputButtons: [LiquidGlassPillButton]
    private let mode = NSSegmentedControl(labels: ["适合宽度", "原始像素"],
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let cropToggleButton: LiquidGlassPillButton
    private let topBadgeIsland: LiquidGlassIslandView
    private let topControlsIsland: LiquidGlassIslandView
    private let bottomDockIsland: LiquidGlassIslandView
    private let dragOutChip: LiquidGlassDragOutChip
    private let minimap: LongShotMinimapView
    private let live: Bool
    private let isDark: Bool
    private var privacyBar: NSView?
    private var privacyControl: NSView?
    private var privacyChanges: AnyCancellable?
    private var editChanges: AnyCancellable?
    private var scrollObserver: NSObjectProtocol?
    private var privacyEditor: EditController?

    override var isFlipped: Bool { true }

    init(
        live: Bool,
        isDark: Bool,
        buttons: [LiquidGlassPillButton],
        outputButtons: [LiquidGlassPillButton] = [],
        dragImageProvider: (() -> CGImage?)? = nil
    ) {
        self.live = live
        self.isDark = isDark
        self.buttons = buttons
        self.outputButtons = outputButtons
        self.backdrop = LiquidGlassBackdropView(isDark: isDark)
        self.topBadgeIsland = LiquidGlassIslandView(isDark: isDark, cornerRadius: nil)
        self.topControlsIsland = LiquidGlassIslandView(isDark: isDark, cornerRadius: nil)
        self.bottomDockIsland = LiquidGlassIslandView(isDark: isDark, cornerRadius: nil)
        self.dragOutChip = LiquidGlassDragOutChip(title: "拖出发送", isDark: isDark)
        self.minimap = LongShotMinimapView(isDark: isDark)
        self.cropToggleButton = LiquidGlassPillButton(title: "首尾裁切", target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        addSubview(backdrop)

        info.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        info.textColor = isDark ? NSColor(white: 0.90, alpha: 1) : NSColor(srgbRed: 0.14, green: 0.18, blue: 0.28, alpha: 1)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail

        mode.selectedSegment = 0
        mode.segmentStyle = .capsule
        mode.controlSize = .small
        mode.target = self
        mode.action = #selector(selectPreviewMode)
        mode.isHidden = live

        cropToggleButton.target = self
        cropToggleButton.action = #selector(toggleQuickCrop)
        cropToggleButton.configure(title: "首尾裁切", symbol: "crop", tone: .ghost,
                                   isDark: isDark, height: 24, horizontalPadding: 8)
        cropToggleButton.toolTip = "开启后可直接拖动长图顶部与底部裁剪条去除多余页眉页脚"
        cropToggleButton.isHidden = live

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = preview
        scroll.contentView.postsBoundsChangedNotifications = true
        preview.showsHighlight = live
        preview.isDark = isDark
        preview.onCropChanged = { [weak self] in
            self?.updateDimensionInfo()
            self?.updateMinimap()
        }

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMinimap() }
        }

        minimap.isHidden = live
        minimap.onJumpToFraction = { [weak self] fraction in
            guard let self else { return }
            let maxY = max(0, preview.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: maxY * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            updateMinimap()
        }

        dragOutChip.isHidden = live || dragImageProvider == nil
        dragOutChip.payloadProvider = { [weak self] in
            guard let self, let cgImage = dragImageProvider?() ?? self.preview.image else { return nil }
            let previewThumb = NSImage(cgImage: cgImage, size: CGSize(width: 48, height: 64))
            return LiquidGlassDragOutChip.DragPayload(
                fileType: .png,
                fileName: "\(ImageCodec.defaultFileName()).png",
                previewImage: previewThumb,
                writeFile: { destination in
                    let data = try ImageCodec.encode(cgImage, as: .png)
                    try data.write(to: destination, options: .atomic)
                }
            )
        }

        addSubview(scroll)
        addSubview(minimap)
        addSubview(topBadgeIsland)
        topBadgeIsland.contentContainer.addSubview(info)
        addSubview(status)
        if !live {
            addSubview(topControlsIsland)
            topControlsIsland.contentContainer.addSubview(mode)
            topControlsIsland.contentContainer.addSubview(cropToggleButton)
        }
        addSubview(bottomDockIsland)
        buttons.forEach { bottomDockIsland.contentContainer.addSubview($0) }
        if !live && dragImageProvider != nil {
            bottomDockIsland.contentContainer.addSubview(dragOutChip)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func updateLiveFrame(image: CGImage, viewportHeight: CGFloat, followBottomIfAtEnd: Bool) {
        let followBottom = followBottomIfAtEnd && isAtBottom
        preview.image = image
        preview.highlightHeight = viewportHeight
        updateDimensionInfo()
        // 避免每帧触发全窗口 layoutSubtreeIfNeeded() 重排毛玻璃浮岛，只轻量化更新尺寸徽章和滚动画布高度。
        let sidePad: CGFloat = 12
        let badgeW = min(max(110, info.intrinsicContentSize.width + 22), max(110, bounds.width - sidePad * 2))
        if abs(topBadgeIsland.frame.width - badgeW) > 1 {
            topBadgeIsland.frame = CGRect(x: sidePad, y: 10, width: badgeW, height: 26)
            info.frame = CGRect(x: 11, y: 5, width: badgeW - 22, height: 16)
        }
        layoutImage()
        if followBottom { scrollToBottom() }
        preview.setNeedsDisplay(scroll.documentVisibleRect)
    }

    func updateDimensionInfo() {
        guard let image = preview.image else {
            info.stringValue = "等待第一帧"
            return
        }
        let frac = preview.verticalCropFraction
        let croppedH = max(1, Int((CGFloat(image.height) * (frac.upperBound - frac.lowerBound)).rounded()))
        if croppedH < image.height {
            info.stringValue = "\(image.width) × \(croppedH) 像素（已裁切）"
        } else {
            info.stringValue = "\(image.width) × \(image.height) 像素"
        }
    }

    func updateMinimap() {
        guard !live, let image = preview.image else { return }
        let docH = max(1, preview.frame.height)
        let viewH = scroll.contentSize.height
        let showMap = docH > viewH * 1.15 && bounds.width >= 500
        minimap.isHidden = !showMap
        guard showMap else { return }
        minimap.image = image
        let visibleStart = max(0, min(1, scroll.contentView.bounds.minY / docH))
        let visibleSpan = max(0.06, min(1, viewH / docH))
        minimap.viewportRange = visibleStart...min(1, visibleStart + visibleSpan)
        minimap.cropRange = preview.verticalCropFraction
    }

    func installPrivacy(_ editor: EditController) {
        privacyEditor = editor
        preview.installEditor(editor)
        let bar = NSHostingView(rootView: PrivacyStatusView(controller: editor, privacy: editor.privacy,
                                                           theme: editor.theme, locate: { [weak self] rect in
            self?.preview.scrollToFinding(rect)
        }))
        let button = NSHostingView(rootView: LongShotPrivacyControl(controller: editor))
        privacyBar = bar
        privacyControl = button
        addSubview(bar)
        topControlsIsland.contentContainer.addSubview(button)
        updatePrivacy()
        privacyChanges = editor.privacy.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.updatePrivacy()
        }
        editChanges = editor.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.preview.refreshEditor()
        }
    }

    private func updatePrivacy() {
        guard let privacy = privacyEditor?.privacy else { return }
        let isHidden = privacy.phase == .idle
        if privacyBar?.isHidden != isHidden {
            privacyBar?.isHidden = isHidden
            needsLayout = true
        }
        for button in outputButtons { button.isEnabled = !privacy.blocksOutput }
        dragOutChip.isEnabled = !privacy.blocksOutput
        preview.refreshEditor()
    }

    var isAtBottom: Bool {
        preview.image == nil || preview.frame.maxY - scroll.contentView.bounds.maxY < 8
    }

    func scrollToBottom() {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, preview.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func toggleQuickCrop() {
        preview.isQuickCropping.toggle()
        cropToggleButton.setTone(preview.isQuickCropping ? .accentSoft : .ghost)
        if !preview.isQuickCropping {
            preview.resetQuickCrop()
        }
        updateDimensionInfo()
        updateMinimap()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        let w = bounds.width
        let h = bounds.height
        let sidePad: CGFloat = 12
        let barHeight: CGFloat = privacyBar?.isHidden == false ? 30 : 0

        if live {
            // 实时拼接浮窗：紧凑单行分辨率胶囊 + 状态提示 + 滚动区 + 居中液态玻璃底栏
            let badgeW = min(max(110, info.intrinsicContentSize.width + 22), w - sidePad * 2)
            topBadgeIsland.frame = CGRect(x: sidePad, y: 10, width: badgeW, height: 26)
            info.frame = CGRect(x: 11, y: 5, width: badgeW - 22, height: 16)

            let statusY: CGFloat = 40
            status.frame = CGRect(x: sidePad + 2, y: statusY, width: max(0, w - sidePad * 2 - 4), height: 28)

            let dockH: CGFloat = 44
            let dockY = max(statusY + 30, h - dockH - 10)
            let headerBottom: CGFloat = statusY + 30
            scroll.frame = CGRect(x: sidePad, y: headerBottom, width: max(1, w - sidePad * 2),
                                  height: max(1, dockY - headerBottom - 10))
            layoutBottomDock(y: dockY, height: dockH, showDragChip: false)
        } else {
            // 结果工作台：单行液态玻璃顶栏（左徽章 + 右控制岛），紧致布局
            let isCompact = w < 520
            let topY: CGFloat = 10
            let headerH: CGFloat = 34
            let badgeW = min(max(120, info.intrinsicContentSize.width + 22), isCompact ? w * 0.42 : 210)
            topBadgeIsland.frame = CGRect(x: sidePad, y: topY + 2, width: badgeW, height: 30)
            info.frame = CGRect(x: 11, y: 7, width: badgeW - 22, height: 16)

            let segW: CGFloat = isCompact ? 132 : 148
            let showCropBtn = !isCompact
            cropToggleButton.isHidden = !showCropBtn
            let cropW: CGFloat = showCropBtn ? max(78, cropToggleButton.intrinsicContentSize.width) : 0
            let privW: CGFloat = (privacyControl != nil && !isCompact) ? 94 : 0
            let ctrlSpacing: CGFloat = 6
            var ctrlInnerW = segW + 12
            if showCropBtn { ctrlInnerW += ctrlSpacing + cropW }
            if privW > 0 { ctrlInnerW += ctrlSpacing + privW }
            let controlsW = min(ctrlInnerW, max(120, w - badgeW - sidePad * 2 - 8))
            let controlsX = max(sidePad, w - sidePad - controlsW)
            topControlsIsland.frame = CGRect(x: controlsX, y: topY, width: controlsW, height: headerH)
            var cx: CGFloat = 6
            mode.frame = CGRect(x: cx, y: 5, width: min(segW, max(40, controlsW - 12)), height: 24)
            cx += mode.frame.width + ctrlSpacing
            if showCropBtn {
                cropToggleButton.frame = CGRect(x: cx, y: 5, width: cropW, height: 24)
                cx += cropW + ctrlSpacing
            } else {
                cropToggleButton.frame = CGRect(x: 6, y: 5, width: 1, height: 1)
            }
            if let privacyControl {
                privacyControl.isHidden = privW == 0
                if privW > 0 {
                    privacyControl.frame = CGRect(x: cx, y: 3, width: privW, height: 28)
                } else {
                    privacyControl.frame = CGRect(x: 6, y: 5, width: 1, height: 1)
                }
            }

            // 副提示隐藏在超小窗口下，腾出给画布空间
            let showStatus = h >= 360
            status.isHidden = !showStatus
            let statusH: CGFloat = showStatus ? 18 : 0
            if showStatus {
                status.frame = CGRect(x: sidePad + 4, y: topY + headerH + 4,
                                      width: max(0, w - sidePad * 2 - 8), height: statusH)
            }

            let privacyY = topY + headerH + (showStatus ? statusH + 6 : 6)
            privacyBar?.frame = CGRect(x: sidePad, y: privacyY, width: max(0, w - sidePad * 2), height: barHeight)

            let stageTop = privacyY + barHeight + (barHeight > 0 ? 6 : 2)
            let dockH: CGFloat = 44
            let dockY = max(stageTop + 16, h - dockH - 12)
            let stageH = max(1, dockY - stageTop - 10)

            let minimapW: CGFloat = (w >= 500 && preview.frame.height > stageH * 1.15) ? 46 : 0
            let scrollW = max(1, w - sidePad * 2 - (minimapW > 0 ? minimapW + 10 : 0))
            scroll.frame = CGRect(x: sidePad, y: stageTop, width: scrollW, height: stageH)
            if minimapW > 0 {
                let mapH = min(220, max(90, stageH - 24))
                minimap.frame = CGRect(x: w - sidePad - minimapW, y: stageTop + (stageH - mapH) / 2,
                                       width: minimapW, height: mapH)
            }
            layoutBottomDock(y: dockY, height: dockH, showDragChip: !live && w >= 560)
        }

        layoutImage()
        updateMinimap()
    }

    private func layoutBottomDock(y: CGFloat, height: CGFloat, showDragChip: Bool) {
        let sidePad: CGFloat = 10
        let maxDockW = max(40, bounds.width - sidePad * 2)
        let hasDrag = showDragChip && !live && dragOutChip.payloadProvider != nil
        dragOutChip.isHidden = !hasDrag

        let spacing: CGFloat = bounds.width < 440 ? 4 : 6
        let innerPad: CGFloat = bounds.width < 440 ? 6 : 8

        var items: [NSView] = []
        let dragInsertIndex = max(0, buttons.count - 2)
        for (idx, btn) in buttons.enumerated() {
            if hasDrag && idx == dragInsertIndex {
                items.append(dragOutChip)
            }
            items.append(btn)
        }
        if hasDrag && dragInsertIndex >= buttons.count {
            items.append(dragOutChip)
        }

        let naturalWidths: [CGFloat] = items.map { view in
            if view === dragOutChip { return 86 }
            return max(44, ceil(view.intrinsicContentSize.width))
        }
        let totalSpacing = spacing * CGFloat(max(0, items.count - 1))
        let naturalTotal = naturalWidths.reduce(0, +) + totalSpacing + innerPad * 2
        let dockW = min(maxDockW, naturalTotal)
        let scale = naturalTotal > maxDockW
            ? max(0.4, (maxDockW - innerPad * 2 - totalSpacing) / max(1, naturalWidths.reduce(0, +)))
            : 1.0

        bottomDockIsland.frame = CGRect(x: (bounds.width - dockW) / 2, y: y, width: dockW, height: height)
        var x = innerPad
        for (idx, item) in items.enumerated() {
            let itemW = floor(naturalWidths[idx] * scale)
            let itemH: CGFloat = 30
            item.frame = CGRect(x: x, y: (height - itemH) / 2, width: itemW, height: itemH)
            x += itemW + spacing
        }
    }

    private func layoutImage() {
        guard let image = preview.image else {
            preview.frame = CGRect(origin: .zero, size: scroll.contentSize)
            return
        }
        let scale = mode.selectedSegment == 1
            ? 1 / (window?.backingScaleFactor ?? 1)
            : scroll.contentSize.width / CGFloat(image.width)
        preview.displayScale = scale
        preview.frame = CGRect(x: 0, y: 0,
                               width: max(scroll.contentSize.width, CGFloat(image.width) * scale),
                               height: max(scroll.contentSize.height, CGFloat(image.height) * scale))
        preview.needsDisplay = true
        preview.refreshEditor()
    }

    @objc private func selectPreviewMode() {
        let fraction = scroll.contentView.bounds.minY / max(1, preview.frame.height)
        layoutImage()
        let y = min(max(0, preview.frame.height - scroll.contentSize.height), fraction * preview.frame.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateMinimap()
    }
}

// MARK: - 右侧液态玻璃迷你小地图

private final class LongShotMinimapView: NSView {
    var image: CGImage? {
        didSet {
            if image !== oldValue {
                rebuildThumbnail()
                needsDisplay = true
            }
        }
    }
    var viewportRange: ClosedRange<CGFloat> = 0...0.3 { didSet { needsDisplay = true } }
    var cropRange: ClosedRange<CGFloat> = 0...1 { didSet { needsDisplay = true } }
    var onJumpToFraction: ((CGFloat) -> Void)?

    private let island: LiquidGlassIslandView
    private let isDark: Bool
    private var cachedThumbnail: CGImage?

    override var isFlipped: Bool { true }

    init(isDark: Bool) {
        self.isDark = isDark
        self.island = LiquidGlassIslandView(isDark: isDark, cornerRadius: 12)
        super.init(frame: .zero)
        toolTip = "点击或拖动快速跳转到长图任意位置"
        addSubview(island)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuildThumbnail() {
        guard let image else { cachedThumbnail = nil; return }
        let thumbW = 72
        let thumbH = 360
        guard let ctx = CGContext(data: nil, width: thumbW, height: thumbH, bitsPerComponent: 8,
                                  bytesPerRow: thumbW * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            cachedThumbnail = image
            return
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        cachedThumbnail = ctx.makeImage() ?? image
    }

    override func layout() {
        super.layout()
        island.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inner = bounds.insetBy(dx: 5, dy: 6)
        guard inner.width > 2, inner.height > 2 else { return }

        context.saveGState()
        NSBezierPath(roundedRect: inner, xRadius: 5, yRadius: 5).addClip()
        (isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05)).setFill()
        inner.fill()

        if let thumb = cachedThumbnail ?? image {
            context.saveGState()
            context.interpolationQuality = .low
            context.translateBy(x: inner.minX, y: inner.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(thumb, in: CGRect(origin: .zero, size: inner.size))
            context.restoreGState()
        }

        // 裁切外暗区
        NSColor.black.withAlphaComponent(0.45).setFill()
        if cropRange.lowerBound > 0.001 {
            CGRect(x: inner.minX, y: inner.minY, width: inner.width,
                   height: inner.height * cropRange.lowerBound).fill()
        }
        if cropRange.upperBound < 0.999 {
            let y = inner.minY + inner.height * cropRange.upperBound
            CGRect(x: inner.minX, y: y, width: inner.width, height: inner.maxY - y).fill()
        }
        context.restoreGState()

        // 当前可视窗口框
        let vy = inner.minY + inner.height * viewportRange.lowerBound
        let vh = max(14, inner.height * (viewportRange.upperBound - viewportRange.lowerBound))
        let lens = CGRect(x: inner.minX - 1, y: min(vy, inner.maxY - vh), width: inner.width + 2, height: vh)
        let accent = NSColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1)
        accent.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: lens, xRadius: 4, yRadius: 4).fill()
        accent.setStroke()
        let border = NSBezierPath(roundedRect: lens, xRadius: 4, yRadius: 4)
        border.lineWidth = 1.5
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) { jump(with: event) }
    override func mouseDragged(with event: NSEvent) { jump(with: event) }

    private func jump(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inner = bounds.insetBy(dx: 5, dy: 6)
        guard inner.height > 0 else { return }
        let ratio = max(0, min(1, (p.y - inner.minY) / inner.height))
        onJumpToFraction?(ratio)
    }
}

/// 把闭包挂到 NSButton 上。
final class ClosureTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// 图像按指定比例绘制，支持柔和舞台背景与直接拖动首尾裁切把手。
final class LongShotPreviewView: NSView {
    var image: CGImage?
    var displayScale: CGFloat = 1
    var editorImageRect: CGRect?
    var highlightHeight: CGFloat = 0
    var showsHighlight = false
    var isDark = false { didSet { needsDisplay = true } }
    var isQuickCropping = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onCropChanged: (() -> Void)?

    private var cropTopFraction: CGFloat = 0
    private var cropBottomFraction: CGFloat = 1
    private enum CropDrag { case top, bottom }
    private var activeCropDrag: CropDrag?
    private var editLayer: EditItemLayerView?

    var verticalCropFraction: ClosedRange<CGFloat> {
        isQuickCropping ? (cropTopFraction...cropBottomFraction) : (0...1)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func resetQuickCrop() {
        cropTopFraction = 0
        cropBottomFraction = 1
        needsDisplay = true
    }

    private var imageRect: CGRect {
        if let editorImageRect { return editorImageRect }
        guard let image else { return .zero }
        let width = CGFloat(image.width) * displayScale
        return CGRect(x: max(0, (bounds.width - width) / 2), y: 0,
                      width: width, height: CGFloat(image.height) * displayScale)
    }

    func installEditor(_ editor: EditController, onCanvasPress: (() -> Void)? = nil) {
        let layer = EditItemLayerView()
        layer.controller = editor
        layer.onCanvasPress = onCanvasPress
        layer.scrollsDuringDrag = true
        layer.clipsToBounds = true
        editLayer = layer
        addSubview(layer)
        refreshEditor()
    }

    func refreshEditor() {
        guard let editLayer, let editor = editLayer.controller else { return }
        editLayer.frame = imageRect
        editLayer.displayScale = displayScale * editor.document.scale
        editLayer.updateInteractionState()
        editLayer.needsDisplay = true
        if editor.isCropping, editLayer.window?.firstResponder !== editLayer {
            editLayer.window?.makeFirstResponder(editLayer)
        }
    }

    func scrollToFinding(_ rect: CGRect) {
        let scale = editLayer?.displayScale ?? displayScale
        let scaled = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: imageRect.minX, dy: imageRect.minY)
        scrollToVisible(scaled.insetBy(dx: -14, dy: -14))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let image else { return }
        let rect = imageRect
        let visible = dirtyRect.intersection(rect)
        if !visible.isNull && visible.width > 0 && visible.height > 0 {
            context.saveGState()
            let clip = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            clip.addClip()
            // 仅零拷贝裁出 dirtyRect 可见像素切片绘制，避免主线程重绘上万像素高的整张长图！
            let scaleX = CGFloat(image.width) / max(1, rect.width)
            let scaleY = CGFloat(image.height) / max(1, rect.height)
            let pxMinX = max(0, Int(floor((visible.minX - rect.minX) * scaleX)))
            let pxMinY = max(0, Int(floor((visible.minY - rect.minY) * scaleY)))
            let pxMaxX = min(image.width, Int(ceil((visible.maxX - rect.minX) * scaleX)))
            let pxMaxY = min(image.height, Int(ceil((visible.maxY - rect.minY) * scaleY)))
            let cropW = max(1, pxMaxX - pxMinX)
            let cropH = max(1, pxMaxY - pxMinY)
            let cropRect = CGRect(x: pxMinX, y: pxMinY, width: cropW, height: cropH)
            let drawRect = CGRect(
                x: rect.minX + CGFloat(pxMinX) / scaleX,
                y: rect.minY + CGFloat(pxMinY) / scaleY,
                width: CGFloat(cropW) / scaleX,
                height: CGFloat(cropH) / scaleY
            )
            context.interpolationQuality = showsHighlight ? .medium : .high
            context.translateBy(x: drawRect.minX, y: drawRect.maxY)
            context.scaleBy(x: 1, y: -1)
            if let slice = image.cropping(to: cropRect) {
                context.draw(slice, in: CGRect(origin: .zero, size: drawRect.size))
            } else {
                context.restoreGState()
                context.saveGState()
                clip.addClip()
                context.interpolationQuality = showsHighlight ? .medium : .high
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            }
            context.restoreGState()
        }

        // 细描边
        (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        outline.lineWidth = 1
        outline.stroke()

        // 实时拼接底部绿框
        if showsHighlight, highlightHeight > 0 {
            let height = min(rect.height, highlightHeight * displayScale)
            let highlight = CGRect(x: rect.minX + 1, y: rect.maxY - height + 1,
                                   width: max(0, rect.width - 2), height: max(0, height - 2))
            NSColor.systemGreen.setStroke()
            let path = NSBezierPath(roundedRect: highlight, xRadius: 4, yRadius: 4)
            path.lineWidth = 2
            path.stroke()
        }

        // 首尾快捷裁切遮罩与胶囊手柄
        if isQuickCropping {
            let accent = NSColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1)
            let topY = rect.minY + rect.height * cropTopFraction
            let botY = rect.minY + rect.height * cropBottomFraction
            NSColor(srgbRed: 0.04, green: 0.06, blue: 0.10, alpha: 0.52).setFill()
            if topY > rect.minY {
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: topY - rect.minY).fill()
            }
            if botY < rect.maxY {
                CGRect(x: rect.minX, y: botY, width: rect.width, height: rect.maxY - botY).fill()
            }
            accent.setFill()
            CGRect(x: rect.minX, y: topY - 1, width: rect.width, height: 2).fill()
            CGRect(x: rect.minX, y: botY - 1, width: rect.width, height: 2).fill()

            drawCropHandle(at: CGPoint(x: rect.midX, y: max(rect.minY + 12, topY)), text: "↕ 拖动裁切顶部", accent: accent)
            drawCropHandle(at: CGPoint(x: rect.midX, y: min(rect.maxY - 12, botY)), text: "↕ 拖动裁切底部", accent: accent)
        }
    }

    private func drawCropHandle(at center: CGPoint, text: String, accent: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: center.x - size.width / 2 - 10, y: center.y - 10, width: size.width + 20, height: 20)
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + (20 - size.height) / 2), withAttributes: attrs)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isQuickCropping {
            let local = convert(point, from: superview)
            if cropDragTarget(at: local) != nil { return self }
        }
        return super.hitTest(point)
    }

    private func cropDragTarget(at point: CGPoint) -> CropDrag? {
        guard isQuickCropping else { return nil }
        let rect = imageRect
        guard rect.height > 0 else { return nil }
        let topY = rect.minY + rect.height * cropTopFraction
        let botY = rect.minY + rect.height * cropBottomFraction
        if abs(point.y - topY) <= 18 { return .top }
        if abs(point.y - botY) <= 18 { return .bottom }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let target = cropDragTarget(at: point) {
            activeCropDrag = target
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let target = activeCropDrag else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.height > 0 else { return }
        let fraction = max(0, min(1, (point.y - rect.minY) / rect.height))
        switch target {
        case .top:
            cropTopFraction = min(fraction, min(0.45, cropBottomFraction - 0.08))
        case .bottom:
            cropBottomFraction = max(fraction, max(0.55, cropTopFraction + 0.08))
        }
        needsDisplay = true
        onCropChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        activeCropDrag = nil
        super.mouseUp(with: event)
    }
}

private struct LongShotPrivacyControl: View {
    @ObservedObject var controller: EditController
    @State private var showsTools = false

    var body: some View {
        Button {
            controller.perform(.privacy)
            showsTools.toggle()
        } label: {
            Label("隐私打码", systemImage: "lock.shield")
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("打开打码工具、扫描和规则")
        .popover(isPresented: $showsTools, arrowEdge: .bottom) {
            PrivacyToolPanel(controller: controller, privacy: controller.privacy)
        }
    }
}
