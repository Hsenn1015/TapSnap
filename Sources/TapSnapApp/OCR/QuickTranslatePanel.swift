import AppKit
import AVFoundation
import Combine
import CoreServices
import NaturalLanguage
import SwiftUI
import TapSnapConfig
import TapSnapOCR
import TapSnapPrivacy
import TapSnapSystem
import TapSnapTheme
import TapSnapUI
import Translation

/// 截图秒译悬停浮卡控制器。
///
/// 拖选松手后直接在选区旁弹出轻量译文浮卡，支持 5 套克制耐看的原生 macOS 视觉风格、
/// 内容自适应尺寸、四边四角零抖动缩放、1:1 丝滑拖动、文本排版定制、语音朗读与即时改字重译。
@MainActor
final class QuickTranslatePanel: NSObject, NSWindowDelegate {
    struct PopoverPlacement: Equatable {
        let frame: CGRect
        let placedAbove: Bool
        let arrowOffsetX: CGFloat
    }

    enum ResizeEdge: Hashable {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private var window: QuickTranslateWindow?
    private var highlightWindow: QuickTranslateHighlightWindow?
    private var viewModel: QuickTranslateViewModel?
    private var appearanceObservation: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?

    private var anchorAppKitRect: CGRect = .zero
    private var visibleScreenRect: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var lastCardSize: CGSize = CGSize(width: 392, height: 228)
    private var userMovedManually = false
    private var overlayOriginalActive = false
    private var isResizing = false
    private var resizeStartCardFrame: CGRect = .zero

    /// 外留边量，确保柔和多层阴影、顶/底尖角和灵动气泡外侧豆子都在窗口内自然消散，绝不出现方正裁切框。
    static let windowInset: CGFloat = 36
    /// 灵动气泡样式右侧竖排豆子按钮宽度 + 间距。
    static let dynamicBubbleBeansReserve: CGFloat = 34

    func show(image: CGImage, captureRect: CGRect, environment: AppEnvironment) {
        close()

        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let anchor = CGRect(
            x: captureRect.minX,
            y: screenHeight - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        anchorAppKitRect = anchor
        visibleScreenRect = visible
        userMovedManually = false
        overlayOriginalActive = false
        isResizing = false

        let initialStyle = environment.config.settings.translation.quickTranslateStyle
        lastCardSize = Self.defaultCardSize(for: initialStyle, compactLoading: initialStyle == .dynamicBubble)

        let placement = Self.popoverFrame(
            for: anchor,
            cardSize: lastCardSize,
            in: visible,
            overlayOriginal: false
        )

        let model = QuickTranslateViewModel(
            image: image,
            captureRect: captureRect,
            visibleScreenRect: visible,
            environment: environment,
            placedAbove: placement.placedAbove,
            arrowOffsetX: placement.arrowOffsetX,
            onExpandFullWindow: { [weak self, weak environment] img, rect, doc in
                self?.close()
                environment?.translateImage(img, captureRect: rect, document: doc)
            },
            onRecapture: { [weak self, weak environment] in
                self?.close()
                environment?.captureCoordinator.start(.quickTranslate)
            },
            onOpenSettings: { [weak self, weak environment] in
                self?.close()
                environment?.openSettings(section: .translation)
            },
            onClose: { [weak self] in
                self?.close()
            },
            onStyleOrModeChanged: { [weak self] style, overlayOriginal in
                self?.handleModeChange(style: style, overlayOriginal: overlayOriginal)
            },
            onBeginResize: { [weak self] in
                self?.beginManualResize()
            },
            onDragResize: { [weak self] edge, delta in
                self?.updateManualResize(edge: edge, delta: delta)
            },
            onEndResize: { [weak self] in
                self?.endManualResize()
            },
            onResetAutoSize: { [weak self] in
                self?.resetToAdaptiveSize()
            },
            onManualMove: { [weak self] in
                self?.markManuallyMoved()
            }
        )
        self.viewModel = model

        let rootView = QuickTranslatePopoverView(
            model: model,
            onMeasuredSize: { [weak self] measured in
                self?.updateCardSize(measured)
            }
        )

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []

        let windowFrame = placement.frame.insetBy(dx: -Self.windowInset, dy: -Self.windowInset)
        let panel = QuickTranslateWindow(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: environment.theme.isDark ? .darkAqua : .aqua)
        panel.delegate = self
        ScreenCaptureProtection.apply(to: panel)
        panel.setFrame(windowFrame, display: false)

        appearanceObservation = environment.config.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak panel, weak environment] _ in
                guard let panel, let environment else { return }
                panel.appearance = NSAppearance(named: environment.theme.isDark ? .darkAqua : .aqua)
            }

        self.window = panel
        updateHighlightWindow(for: initialStyle, overlayOriginal: false)
        installDismissMonitors()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        model.start()
    }

    func close() {
        removeDismissMonitors()
        appearanceObservation?.cancel()
        appearanceObservation = nil
        viewModel?.cancel()
        viewModel = nil
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    // MARK: - 几何、内容自适应与手动调尺寸

    static func defaultCardSize(for style: QuickTranslateStyle, compactLoading: Bool) -> CGSize {
        switch style {
        case .cleanCard:
            return CGSize(width: 392, height: 224)
        case .liquidGlass:
            return CGSize(width: 320, height: 132)
        case .editorial:
            return CGSize(width: 288, height: 102)
        case .inlineBilingual:
            return CGSize(width: 348, height: 138)
        case .dynamicBubble:
            return compactLoading ? CGSize(width: 236, height: 46) : CGSize(width: 344, height: 168)
        }
    }

    static func minimumCardSize(for style: QuickTranslateStyle) -> CGSize {
        switch style {
        case .cleanCard:
            return CGSize(width: 318, height: 196)
        case .liquidGlass:
            return CGSize(width: 286, height: 112)
        case .editorial:
            return CGSize(width: 244, height: 88)
        case .inlineBilingual:
            return CGSize(width: 316, height: 120)
        case .dynamicBubble:
            return CGSize(width: 284, height: 168)
        }
    }

    static func maximumCardSize(in visible: CGRect) -> CGSize {
        CGSize(
            width: min(760, max(320, visible.width - 36)),
            height: min(680, max(240, visible.height - 48))
        )
    }

    static func autoMaximumBodyHeight(in visible: CGRect) -> CGFloat {
        min(360, max(150, floor(visible.height * 0.44)))
    }

    /// 按文本长度、行数与当前译文字号智能估算卡片理想宽度：单词紧凑、句子适中、长段自动展宽。
    static func adaptiveCardWidth(
        for style: QuickTranslateStyle,
        sourceText: String?,
        translatedText: String?,
        hasDictionary: Bool,
        showsBilingual: Bool,
        anchorWidth: CGFloat,
        overlayOriginal: Bool,
        targetFontSize: CGFloat = 14.5,
        in visible: CGRect
    ) -> CGFloat {
        let minAutoWidth: CGFloat = switch style {
        case .cleanCard: 356
        case .liquidGlass: 316
        case .editorial: 258
        case .inlineBilingual: 346
        case .dynamicBubble: 296
        }
        let maxAutoWidth = min(580, max(minAutoWidth, visible.width - 48))
        let fontScale = max(0.85, min(1.55, targetFontSize / 14.5))

        func estimatedLineWidth(_ text: String, cjkWidth: CGFloat, asciiWidth: CGFloat) -> (longestLine: CGFloat, totalMass: CGFloat, lineCount: Int) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var maxLine: CGFloat = 0
            var total: CGFloat = 0
            for line in lines {
                var w: CGFloat = 0
                for scalar in line.unicodeScalars {
                    w += scalar.isASCII ? asciiWidth : cjkWidth
                }
                maxLine = max(maxLine, w)
                total += w
            }
            return (maxLine, total, max(1, lines.count))
        }

        let horizontalChrome: CGFloat = (style == .dynamicBubble ? dynamicBubbleBeansReserve : 0) + (style == .cleanCard ? 52 : 34)
        var desiredContentWidth: CGFloat = 0

        if let translatedText, !translatedText.isEmpty {
            let metrics = estimatedLineWidth(translatedText, cjkWidth: 14.2 * fontScale, asciiWidth: 7.7 * fontScale)
            let fromLongest = metrics.longestLine + horizontalChrome
            let fromMass: CGFloat
            if metrics.totalMass <= 210 * fontScale && metrics.lineCount == 1 {
                fromMass = fromLongest
            } else if metrics.totalMass <= 720 * fontScale {
                fromMass = max(336, min(444, ceil(metrics.totalMass / 2.2) + horizontalChrome))
            } else {
                fromMass = max(444, min(maxAutoWidth, ceil(metrics.totalMass / 3.4) + horizontalChrome))
            }
            desiredContentWidth = max(min(fromLongest, maxAutoWidth), fromMass)
        } else if let sourceText, !sourceText.isEmpty {
            let metrics = estimatedLineWidth(sourceText, cjkWidth: 12.2, asciiWidth: 6.9)
            desiredContentWidth = min(maxAutoWidth, max(minAutoWidth, metrics.longestLine + horizontalChrome))
        }

        if (showsBilingual || style == .cleanCard), let sourceText, !sourceText.isEmpty {
            let srcMetrics = estimatedLineWidth(sourceText, cjkWidth: 12.2, asciiWidth: 6.9)
            let srcDesired = min(maxAutoWidth, max(minAutoWidth, ceil(min(srcMetrics.longestLine, srcMetrics.totalMass / 2.2)) + horizontalChrome + 12))
            desiredContentWidth = max(desiredContentWidth, srcDesired)
        }

        if hasDictionary, let sourceText {
            let dictDesired = CGFloat(sourceText.count) * 8.2 + 170 + horizontalChrome
            desiredContentWidth = max(desiredContentWidth, min(420, dictDesired))
        }

        var result = max(minAutoWidth, min(maxAutoWidth, ceil(desiredContentWidth)))
        if overlayOriginal {
            let anchorTarget = min(maxAutoWidth, max(minAutoWidth, ceil(anchorWidth + 16)))
            result = max(result, anchorTarget)
        }
        return result
    }

    /// 拖拽任意边或角缩放卡片时，锚定对侧边界并夹紧在屏幕安全区与最小/最大尺寸之间。
    static func resizedCardFrame(
        from startFrame: CGRect,
        edge: ResizeEdge,
        delta: CGSize,
        minSize: CGSize,
        maxSize: CGSize,
        within visible: CGRect
    ) -> CGRect {
        let safe = visible.insetBy(dx: 12, dy: 12)
        var minX = startFrame.minX
        var maxX = startFrame.maxX
        var minY = startFrame.minY
        var maxY = startFrame.maxY

        let adjustsLeft = edge == .left || edge == .topLeft || edge == .bottomLeft
        let adjustsRight = edge == .right || edge == .topRight || edge == .bottomRight
        let adjustsTop = edge == .top || edge == .topLeft || edge == .topRight
        let adjustsBottom = edge == .bottom || edge == .bottomLeft || edge == .bottomRight

        if adjustsRight {
            let limit = min(maxSize.width, safe.maxX - startFrame.minX)
            let clamped = min(max(minSize.width, startFrame.width + delta.width), max(minSize.width, limit))
            maxX = startFrame.minX + clamped
        } else if adjustsLeft {
            let limit = min(maxSize.width, startFrame.maxX - safe.minX)
            let clamped = min(max(minSize.width, startFrame.width - delta.width), max(minSize.width, limit))
            minX = startFrame.maxX - clamped
        }

        if adjustsTop {
            let limit = min(maxSize.height, safe.maxY - startFrame.minY)
            let clamped = min(max(minSize.height, startFrame.height + delta.height), max(minSize.height, limit))
            maxY = startFrame.minY + clamped
        } else if adjustsBottom {
            let limit = min(maxSize.height, startFrame.maxY - safe.minY)
            let clamped = min(max(minSize.height, startFrame.height - delta.height), max(minSize.height, limit))
            minY = startFrame.maxY - clamped
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func popoverFrame(
        for anchor: CGRect,
        cardSize: CGSize,
        in visible: CGRect,
        overlayOriginal: Bool
    ) -> PopoverPlacement {
        let safe = visible.insetBy(dx: 12, dy: 12)
        let width = min(safe.width, max(180, cardSize.width))
        let height = min(safe.height, max(44, cardSize.height))

        if overlayOriginal {
            let targetWidth = min(safe.width, max(width, min(anchor.width + 16, 580)))
            let x = min(max(safe.minX, anchor.midX - targetWidth / 2), safe.maxX - targetWidth)
            let y = min(max(safe.minY, anchor.midY - height / 2), safe.maxY - height)
            let frame = CGRect(x: x, y: y, width: targetWidth, height: height)
            let arrowX = min(max(24, anchor.midX - frame.minX), max(24, frame.width - 24))
            return PopoverPlacement(frame: frame, placedAbove: false, arrowOffsetX: arrowX)
        }

        let gap: CGFloat = 10
        let x = min(max(safe.minX, anchor.midX - width / 2), safe.maxX - width)
        let belowY = anchor.minY - gap - height
        let aboveY = anchor.maxY + gap

        let placedAbove: Bool
        let y: CGFloat
        if belowY >= safe.minY {
            placedAbove = false
            y = belowY
        } else if aboveY + height <= safe.maxY {
            placedAbove = true
            y = aboveY
        } else {
            let spaceBelow = anchor.minY - safe.minY
            let spaceAbove = safe.maxY - anchor.maxY
            placedAbove = spaceAbove > spaceBelow
            y = min(max(safe.minY, placedAbove ? aboveY : belowY), safe.maxY - height)
        }

        let frame = CGRect(x: x, y: y, width: width, height: height)
        let arrowX = min(max(24, anchor.midX - frame.minX), max(24, frame.width - 24))
        return PopoverPlacement(frame: frame, placedAbove: placedAbove, arrowOffsetX: arrowX)
    }

    private func updateCardSize(_ measured: CGSize) {
        guard !isResizing, viewModel?.isManuallyResized != true else { return }
        guard measured.width >= 80, measured.height >= 36 else { return }
        let maxSize = Self.maximumCardSize(in: visibleScreenRect)
        let clamped = CGSize(
            width: min(max(180, ceil(measured.width)), maxSize.width),
            height: min(max(44, ceil(measured.height)), maxSize.height)
        )
        guard abs(clamped.width - lastCardSize.width) > 1.5 || abs(clamped.height - lastCardSize.height) > 1.5 else {
            return
        }
        lastCardSize = clamped
        repositionWindow(animated: true)
    }

    private func beginManualResize() {
        guard let window, let model = viewModel else { return }
        isResizing = true
        let currentCardFrame = window.frame.insetBy(dx: Self.windowInset, dy: Self.windowInset)
        resizeStartCardFrame = currentCardFrame
        model.manualCardSize = currentCardFrame.size
    }

    private func updateManualResize(edge: ResizeEdge, delta: CGSize) {
        guard isResizing, let window, let model = viewModel else { return }
        let minSize = Self.minimumCardSize(for: model.style)
        let maxSize = Self.maximumCardSize(in: visibleScreenRect)
        let nextCardFrame = Self.resizedCardFrame(
            from: resizeStartCardFrame,
            edge: edge,
            delta: delta,
            minSize: minSize,
            maxSize: maxSize,
            within: visibleScreenRect
        )
        lastCardSize = nextCardFrame.size
        model.manualCardSize = nextCardFrame.size
        model.arrowOffsetX = min(
            max(24, anchorAppKitRect.midX - nextCardFrame.minX),
            max(24, nextCardFrame.width - 24)
        )
        let nextWindowFrame = nextCardFrame.insetBy(dx: -Self.windowInset, dy: -Self.windowInset)
        window.setFrame(nextWindowFrame, display: true)
    }

    private func endManualResize() {
        isResizing = false
        userMovedManually = true
    }

    private func markManuallyMoved() {
        if !overlayOriginalActive {
            userMovedManually = true
        }
    }

    private func resetToAdaptiveSize() {
        guard let model = viewModel else { return }
        isResizing = false
        model.manualCardSize = nil
        let adaptiveW = model.adaptiveWidth
        lastCardSize = CGSize(width: adaptiveW, height: min(lastCardSize.height, Self.autoMaximumBodyHeight(in: visibleScreenRect) + 180))
        repositionWindow(animated: true)
    }

    private func handleModeChange(style: QuickTranslateStyle, overlayOriginal: Bool) {
        overlayOriginalActive = overlayOriginal
        if overlayOriginal {
            userMovedManually = false
            viewModel?.manualCardSize = nil
        } else if let manual = viewModel?.manualCardSize {
            let minSize = Self.minimumCardSize(for: style)
            let adjusted = CGSize(width: max(manual.width, minSize.width), height: max(manual.height, minSize.height))
            viewModel?.manualCardSize = adjusted
            lastCardSize = adjusted
        }
        updateHighlightWindow(for: style, overlayOriginal: overlayOriginal)
        repositionWindow(animated: true)
    }

    private func repositionWindow(animated: Bool) {
        guard let window, let model = viewModel else { return }
        let targetFrame: CGRect
        if userMovedManually && !overlayOriginalActive {
            let currentCard = window.frame.insetBy(dx: Self.windowInset, dy: Self.windowInset)
            let newCard = CGRect(
                x: currentCard.minX,
                y: currentCard.maxY - lastCardSize.height,
                width: lastCardSize.width,
                height: lastCardSize.height
            )
            let safe = visibleScreenRect.insetBy(dx: 12, dy: 12)
            let clampedX = min(max(safe.minX, newCard.minX), safe.maxX - newCard.width)
            let clampedY = min(max(safe.minY, newCard.minY), safe.maxY - newCard.height)
            targetFrame = CGRect(x: clampedX, y: clampedY, width: newCard.width, height: newCard.height)
                .insetBy(dx: -Self.windowInset, dy: -Self.windowInset)
        } else {
            let placement = Self.popoverFrame(
                for: anchorAppKitRect,
                cardSize: lastCardSize,
                in: visibleScreenRect,
                overlayOriginal: overlayOriginalActive
            )
            model.placedAbove = placement.placedAbove
            model.arrowOffsetX = placement.arrowOffsetX
            targetFrame = placement.frame.insetBy(dx: -Self.windowInset, dy: -Self.windowInset)
        }

        guard targetFrame != window.frame else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    private func updateHighlightWindow(for style: QuickTranslateStyle, overlayOriginal: Bool) {
        let shouldShow = !overlayOriginal && (style == .inlineBilingual || style == .editorial)
        guard shouldShow, anchorAppKitRect.width >= 6, anchorAppKitRect.height >= 6 else {
            highlightWindow?.orderOut(nil)
            highlightWindow = nil
            return
        }
        let padded = anchorAppKitRect.insetBy(dx: -3, dy: -3)
        let highlight = highlightWindow ?? QuickTranslateHighlightWindow(contentRect: padded)
        highlight.setFrame(padded, display: false)
        highlight.updateAppearance(for: style)
        ScreenCaptureProtection.apply(to: highlight)
        highlight.orderFrontRegardless()
        highlightWindow = highlight
    }

    // MARK: - 失焦 / Esc 自动关闭

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissIfUnpinnedOutside()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.window else { return event }
            if let eventWindow = event.window {
                if eventWindow === panel {
                    let clickPoint = NSEvent.mouseLocation
                    let cardFrame = panel.frame.insetBy(dx: Self.windowInset - 4, dy: Self.windowInset - 4)
                    if !cardFrame.contains(clickPoint) {
                        self.dismissIfUnpinnedOutside()
                    }
                } else {
                    let className = NSStringFromClass(type(of: eventWindow))
                    if !className.contains("Menu") && !className.contains("Popover") && !className.contains("NSPopup") {
                        self.dismissIfUnpinnedOutside()
                    }
                }
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window != nil else { return event }
            if event.keyCode == 53 { // Esc
                if self.viewModel?.isTypographyPopoverOpen == true {
                    self.viewModel?.isTypographyPopoverOpen = false
                    return nil
                }
                if self.viewModel?.isEditingSource == true {
                    self.viewModel?.isEditingSource = false
                    return nil
                }
                self.close()
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
    }

    private func dismissIfUnpinnedOutside() {
        guard let window, let model = viewModel,
              !model.isPinned, !model.isTypographyPopoverOpen, !isResizing else { return }
        let clickPoint = NSEvent.mouseLocation
        let cardFrame = window.frame.insetBy(dx: Self.windowInset - 4, dy: Self.windowInset - 4)
        if !cardFrame.contains(clickPoint) {
            close()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === window else { return }
        if !overlayOriginalActive && !isResizing {
            userMovedManually = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        close()
    }
}

// MARK: - 窗口子类

private final class QuickTranslateWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class QuickTranslateHighlightWindow: NSPanel {
    private let highlightView = QuickTranslateHighlightView(frame: .zero)

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        highlightView.frame = CGRect(origin: .zero, size: contentRect.size)
        highlightView.autoresizingMask = [.width, .height]
        contentView = highlightView
    }

    func updateAppearance(for style: QuickTranslateStyle) {
        highlightView.style = style
        highlightView.needsDisplay = true
    }
}

private final class QuickTranslateHighlightView: NSView {
    var style: QuickTranslateStyle = .inlineBilingual
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let insetRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: insetRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        switch style {
        case .inlineBilingual:
            ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 0.14).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor(srgbRed: 0.96, green: 0.70, blue: 0.22, alpha: 0.68).cgColor)
            ctx.setLineWidth(1.4)
            ctx.addPath(path)
            ctx.strokePath()
        case .editorial:
            ctx.setFillColor(NSColor(srgbRed: 0.34, green: 0.62, blue: 0.98, alpha: 0.10).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor(srgbRed: 0.34, green: 0.62, blue: 0.98, alpha: 0.50).cgColor)
            ctx.setLineWidth(1.2)
            ctx.addPath(path)
            ctx.strokePath()
        default:
            break
        }
    }
}

// MARK: - 朗读器

@MainActor
private final class QuickTranslateSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String?) {
        stop()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: cleaned)
        if let code = languageCode, let voice = AVSpeechSynthesisVoice(language: Self.bcp47(for: code)) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.onFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.onFinished?()
        }
    }

    private static func bcp47(for code: String) -> String {
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        default: return code
        }
    }
}

// MARK: - ViewModel

@MainActor
final class QuickTranslateViewModel: ObservableObject {
    enum InlineDisplayMode: String, CaseIterable {
        case translationOnly
        case bilingual
        case overlayOriginal

        var title: String {
            switch self {
            case .translationOnly: return "仅译文"
            case .bilingual: return "双语对照"
            case .overlayOriginal: return "覆盖原文"
            }
        }
    }

    enum SpeechTarget: Equatable {
        case source, translation
    }

    struct AppleRequest: Identifiable {
        let id = UUID()
        let text: String
        let source: String
        let target: String
        let allowDownload: Bool
    }

    enum Phase: Equatable {
        case recognizing
        case translating(sourceText: String)
        case translated(sourceText: String, translatedText: String, dictionarySummary: String?)
        case needsDownload(sourceText: String)
        case needsConfiguration(sourceText: String)
        case empty
        case failed(sourceText: String?, message: String)
    }

    let image: CGImage
    let captureRect: CGRect
    let visibleScreenRect: CGRect
    let environment: AppEnvironment

    @Published private(set) var phase: Phase = .recognizing
    @Published private(set) var appleRequest: AppleRequest?
    @Published var style: QuickTranslateStyle
    @Published var sourceLanguage: String = "auto"
    @Published var targetLanguage: String
    @Published private(set) var detectedLanguageCode: String?
    @Published var editableSourceText: String = ""
    @Published var isEditingSource = false
    @Published var isResultExpanded = true
    @Published var inlineMode: InlineDisplayMode = .bilingual
    @Published var showOriginal = false
    @Published var isPinned = false
    @Published var copied = false
    @Published var copiedSource = false
    @Published var speakingTarget: SpeechTarget?
    @Published var placedAbove: Bool
    @Published var arrowOffsetX: CGFloat
    @Published var manualCardSize: CGSize?
    @Published var typography: TranslationTypographyStyle
    @Published var isTypographyPopoverOpen = false

    private(set) var document: OCRDocument?
    private var recognizedText: String = ""
    private var dictionarySummary: String?
    private var activeTask: Task<Void, Never>?
    private var copiedResetTask: Task<Void, Never>?
    private var copiedSourceResetTask: Task<Void, Never>?
    private var typographyObservation: AnyCancellable?
    private var currentRequestID: UUID?
    private let speaker = QuickTranslateSpeaker()

    private let onExpandFullWindow: @MainActor (CGImage, CGRect, OCRDocument?) -> Void
    private let onRecapture: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onClose: @MainActor () -> Void
    private let onStyleOrModeChanged: @MainActor (QuickTranslateStyle, Bool) -> Void
    private let onBeginResize: @MainActor () -> Void
    private let onDragResize: @MainActor (QuickTranslatePanel.ResizeEdge, CGSize) -> Void
    private let onEndResize: @MainActor () -> Void
    private let onResetAutoSize: @MainActor () -> Void
    private let onManualMove: @MainActor () -> Void

    init(
        image: CGImage,
        captureRect: CGRect,
        visibleScreenRect: CGRect,
        environment: AppEnvironment,
        placedAbove: Bool,
        arrowOffsetX: CGFloat,
        onExpandFullWindow: @escaping @MainActor (CGImage, CGRect, OCRDocument?) -> Void,
        onRecapture: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void,
        onStyleOrModeChanged: @escaping @MainActor (QuickTranslateStyle, Bool) -> Void,
        onBeginResize: @escaping @MainActor () -> Void,
        onDragResize: @escaping @MainActor (QuickTranslatePanel.ResizeEdge, CGSize) -> Void,
        onEndResize: @escaping @MainActor () -> Void,
        onResetAutoSize: @escaping @MainActor () -> Void,
        onManualMove: @escaping @MainActor () -> Void
    ) {
        self.image = image
        self.captureRect = captureRect
        self.visibleScreenRect = visibleScreenRect
        self.environment = environment
        self.placedAbove = placedAbove
        self.arrowOffsetX = arrowOffsetX
        self.style = environment.config.settings.translation.quickTranslateStyle
        self.targetLanguage = environment.config.settings.translation.targetLanguage
        self.typography = environment.config.settings.translation.style
        self.onExpandFullWindow = onExpandFullWindow
        self.onRecapture = onRecapture
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.onStyleOrModeChanged = onStyleOrModeChanged
        self.onBeginResize = onBeginResize
        self.onDragResize = onDragResize
        self.onEndResize = onEndResize
        self.onResetAutoSize = onResetAutoSize
        self.onManualMove = onManualMove

        self.speaker.onFinished = { [weak self] in
            self?.speakingTarget = nil
        }

        self.typographyObservation = environment.config.$settings
            .map(\.translation.style)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updated in
                self?.typography = updated
            }
    }

    var theme: Theme { environment.theme }
    var isManuallyResized: Bool { manualCardSize != nil }
    var autoMaxBodyHeight: CGFloat {
        if style == .cleanCard {
            return min(280, max(140, floor(visibleScreenRect.height * 0.34)))
        }
        return QuickTranslatePanel.autoMaximumBodyHeight(in: visibleScreenRect)
    }

    var fontDesign: Font.Design {
        switch typography.fontFamily {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }

    /// 克制的系统蓝色（默认强调色，当用户在排版中切换其他强调色时联动）。
    var systemBlue: Color {
        theme.isDark
            ? Color(red: 0.24, green: 0.56, blue: 1.0)
            : Color(red: 0.04, green: 0.48, blue: 1.0)
    }

    var accentColor: Color {
        typography.accent == .amber ? systemBlue : typography.accent.rgb.color
    }

    func updateTypography(_ transform: (inout TranslationTypographyStyle) -> Void) {
        var next = typography
        transform(&next)
        typography = next
        environment.config.update { $0.translation.style = next }
    }

    var effectiveProvider: ScreenshotTranslationProvider? {
        if let configured = environment.config.settings.translation.provider {
            return configured
        }
        if #available(macOS 15, *) {
            return .apple
        }
        return nil
    }

    var providerBadgeText: String {
        switch effectiveProvider {
        case .apple: return "Apple 翻译"
        case .api: return environment.config.settings.translation.apiProvider.title
        case .local: return "本地模型"
        case .online: return environment.config.settings.translation.onlineProvider.title
        case .none: return "未配置引擎"
        }
    }

    var sourceLanguageName: String {
        sourceLanguage == "auto" ? "自动检测" : CaptureCoordinator.quickTranslateLanguageName(for: sourceLanguage)
    }

    var targetLanguageName: String {
        targetLanguage == "auto" ? "自动选择" : CaptureCoordinator.quickTranslateLanguageName(for: targetLanguage)
    }

    var detectedLanguageName: String? {
        detectedLanguageCode.map { CaptureCoordinator.quickTranslateLanguageName(for: $0) }
    }

    /// 当目标语言设为「自动选择」时，中文自动译英文，其他语言自动译简体中文。
    var resolvedTargetLanguage: String {
        guard targetLanguage == "auto" else { return targetLanguage }
        let src = sourceLanguage == "auto" ? (detectedLanguageCode ?? "en") : sourceLanguage
        return src.hasPrefix("zh") ? "en" : "zh-Hans"
    }

    var resolvedTargetLanguageName: String {
        CaptureCoordinator.quickTranslateLanguageName(for: resolvedTargetLanguage)
    }

    var isOverlayOriginal: Bool {
        style == .inlineBilingual && inlineMode == .overlayOriginal
    }

    var isLoading: Bool {
        switch phase {
        case .recognizing, .translating: return true
        default: return false
        }
    }

    var translatedText: String? {
        if case .translated(_, let translated, _) = phase { return translated }
        return nil
    }

    var currentSourceText: String {
        switch phase {
        case .translated(let src, _, _), .translating(let src), .needsDownload(let src), .needsConfiguration(let src):
            return src
        case .failed(let src, _):
            return src ?? recognizedText
        default:
            return recognizedText
        }
    }

    var adaptiveWidth: CGFloat {
        let sourceText: String?
        let translated: String?
        let hasDict: Bool
        switch phase {
        case .recognizing, .empty:
            sourceText = nil
            translated = nil
            hasDict = false
        case .translating(let src), .needsDownload(let src), .needsConfiguration(let src):
            sourceText = src
            translated = nil
            hasDict = false
        case .translated(let src, let dst, let dict):
            sourceText = src
            translated = dst
            hasDict = dict != nil
        case .failed(let src, let message):
            sourceText = src
            translated = message
            hasDict = false
        }
        let showsBilingual = (style == .inlineBilingual && inlineMode == .bilingual) || showOriginal
        return QuickTranslatePanel.adaptiveCardWidth(
            for: style,
            sourceText: sourceText,
            translatedText: translated,
            hasDictionary: hasDict,
            showsBilingual: showsBilingual,
            anchorWidth: captureRect.width,
            overlayOriginal: isOverlayOriginal,
            targetFontSize: typography.targetFontSize,
            in: visibleScreenRect
        )
    }

    var activeCardWidth: CGFloat {
        manualCardSize?.width ?? adaptiveWidth
    }

    var activeCardHeight: CGFloat? {
        manualCardSize?.height
    }

    func beginResize() { onBeginResize() }
    func dragResize(edge: QuickTranslatePanel.ResizeEdge, delta: CGSize) { onDragResize(edge, delta) }
    func endResize() { onEndResize() }
    func resetAutoSize() { onResetAutoSize() }
    func markManuallyMoved() { onManualMove() }

    func start() {
        activeTask?.cancel()
        speaker.stop()
        speakingTarget = nil
        phase = .recognizing
        let ocrLanguages = environment.config.settings.ocr.languages
        let img = image
        let ocr = environment.ocr
        activeTask = Task { @MainActor [weak self] in
            do {
                let result = try await ocr.recognize(img, options: OCRService.Options(languages: ocrLanguages))
                guard !Task.isCancelled, let self else { return }
                self.document = result
                let text = OCRResultDisplayMode.paragraphs.copyText(in: result)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.phase = .empty
                    return
                }
                self.recognizedText = text
                self.editableSourceText = text
                self.detectedLanguageCode = Self.detectLanguageCode(for: text)
                self.dictionarySummary = Self.lookupDictionarySummary(for: text)
                self.translateRecognizedText(allowDownload: false)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.phase = .failed(sourceText: nil, message: "文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    func commitEditedSourceAndRetranslate() {
        isEditingSource = false
        let trimmed = editableSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recognizedText else { return }
        recognizedText = trimmed
        detectedLanguageCode = Self.detectLanguageCode(for: trimmed)
        dictionarySummary = Self.lookupDictionarySummary(for: trimmed)
        translateRecognizedText(allowDownload: false)
    }

    func translateRecognizedText(allowDownload: Bool) {
        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .empty
            return
        }
        activeTask?.cancel()
        appleRequest = nil
        guard let provider = effectiveProvider else {
            phase = .needsConfiguration(sourceText: text)
            return
        }

        let source = sourceLanguage
        let target = resolvedTargetLanguage
        phase = .translating(sourceText: text)

        if provider == .apple {
            if #available(macOS 15, *) {
                let req = AppleRequest(text: text, source: source, target: target, allowDownload: allowDownload)
                currentRequestID = req.id
                appleRequest = req
            } else {
                phase = .needsConfiguration(sourceText: text)
            }
            return
        }

        let config = environment.config
        let requestID = UUID()
        currentRequestID = requestID
        activeTask = Task { @MainActor [weak self] in
            do {
                var latest = ""
                for try await partial in TranslationModelClient.translateStream(
                    text,
                    source: source,
                    target: target,
                    config: config
                ) {
                    guard !Task.isCancelled, let self, self.currentRequestID == requestID else { return }
                    latest = partial
                    let cleaned = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        self.phase = .translated(
                            sourceText: text,
                            translatedText: cleaned,
                            dictionarySummary: self.dictionarySummary
                        )
                    }
                }
                guard !Task.isCancelled, let self, self.currentRequestID == requestID else { return }
                let finalTrimmed = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalTrimmed.isEmpty {
                    self.phase = .translated(
                        sourceText: text,
                        translatedText: finalTrimmed,
                        dictionarySummary: self.dictionarySummary
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.currentRequestID == requestID else { return }
                self.phase = .failed(sourceText: text, message: error.localizedDescription)
            }
        }
    }

    func finishAppleRequest(_ id: UUID, result: Result<String, Error>) {
        guard currentRequestID == id else { return }
        appleRequest = nil
        switch result {
        case .success(let output):
            phase = .translated(
                sourceText: recognizedText,
                translatedText: output.trimmingCharacters(in: .whitespacesAndNewlines),
                dictionarySummary: dictionarySummary
            )
        case .failure(let error):
            phase = .failed(sourceText: recognizedText, message: error.localizedDescription)
        }
    }

    func markAppleDownloadRequired(_ id: UUID) {
        guard currentRequestID == id else { return }
        appleRequest = nil
        phase = .needsDownload(sourceText: recognizedText)
    }

    func selectStyle(_ newStyle: QuickTranslateStyle) {
        guard style != newStyle else { return }
        style = newStyle
        environment.config.update { $0.translation.quickTranslateStyle = newStyle }
        onStyleOrModeChanged(newStyle, isOverlayOriginal)
    }

    func selectInlineMode(_ newMode: InlineDisplayMode) {
        guard inlineMode != newMode else { return }
        inlineMode = newMode
        onStyleOrModeChanged(style, isOverlayOriginal)
    }

    func selectSourceLanguage(_ code: String) {
        guard sourceLanguage != code else { return }
        sourceLanguage = code
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    func selectTargetLanguage(_ code: String) {
        guard targetLanguage != code else { return }
        targetLanguage = code
        if code != "auto" {
            environment.config.update { $0.translation.targetLanguage = code }
        }
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    func selectAppleTranslation() {
        objectWillChange.send()
        environment.config.update { $0.translation.provider = .apple }
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    func selectAPIProvider(_ apiProvider: TranslationAPIProvider) {
        objectWillChange.send()
        environment.config.update {
            $0.translation.provider = .api
            $0.translation.apiProvider = apiProvider
        }
        TranslationModelClient.prewarm(config: environment.config)
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    func selectOnlineModel(_ onlineProvider: PrivacyAIProvider) {
        objectWillChange.send()
        environment.config.update {
            $0.translation.provider = .online
            $0.translation.onlineProvider = onlineProvider
        }
        TranslationModelClient.prewarm(config: environment.config)
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    func selectLocalModel() {
        objectWillChange.send()
        environment.config.update { $0.translation.provider = .local }
        TranslationModelClient.prewarm(config: environment.config)
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    var activeAPIProvider: TranslationAPIProvider? {
        effectiveProvider == .api ? environment.config.settings.translation.apiProvider : nil
    }

    var activeOnlineProvider: PrivacyAIProvider? {
        effectiveProvider == .online ? environment.config.settings.translation.onlineProvider : nil
    }

    func swapLanguages() {
        let effectiveSource = sourceLanguage == "auto" ? (detectedLanguageCode ?? "en") : sourceLanguage
        let effectiveTarget = resolvedTargetLanguage
        guard effectiveSource != effectiveTarget else { return }
        sourceLanguage = effectiveTarget
        targetLanguage = effectiveSource
        environment.config.update { $0.translation.targetLanguage = effectiveSource }
        if !recognizedText.isEmpty {
            translateRecognizedText(allowDownload: false)
        }
    }

    func toggleSpeak(_ target: SpeechTarget) {
        if speakingTarget == target {
            speaker.stop()
            speakingTarget = nil
            return
        }
        switch target {
        case .source:
            let text = currentSourceText
            guard !text.isEmpty else { return }
            let lang = sourceLanguage == "auto" ? detectedLanguageCode : sourceLanguage
            speakingTarget = .source
            speaker.speak(text, languageCode: lang)
        case .translation:
            guard let text = translatedText, !text.isEmpty else { return }
            speakingTarget = .translation
            speaker.speak(text, languageCode: resolvedTargetLanguage)
        }
    }

    func copySourceText() {
        let text = currentSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        environment.pinTransfer.copy(text)
        copiedSource = true
        copiedSourceResetTask?.cancel()
        copiedSourceResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.copiedSource = false
        }
    }

    func copyTranslation() {
        guard let text = translatedText, !text.isEmpty else { return }
        environment.pinTransfer.copy(text)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func expandToFullWindow() {
        onExpandFullWindow(image, captureRect, document)
    }

    func recapture() {
        onRecapture()
    }

    func openSettings() {
        onOpenSettings()
    }

    func close() {
        onClose()
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        copiedResetTask?.cancel()
        copiedResetTask = nil
        copiedSourceResetTask?.cancel()
        copiedSourceResetTask = nil
        typographyObservation?.cancel()
        typographyObservation = nil
        speaker.stop()
        speakingTarget = nil
        appleRequest = nil
        currentRequestID = nil
    }

    /// 本地毫秒级语种检测（macOS 原生 NaturalLanguage）。
    static func detectLanguageCode(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        switch dominant {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .french: return "fr"
        case .german: return "de"
        case .spanish: return "es"
        default: return dominant.rawValue
        }
    }

    /// 单词或极短英文词组时，调用 macOS 本地词典提取音标/词性摘要（零网络延迟）。
    static func lookupDictionarySummary(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 30, !trimmed.contains("\n") else { return nil }
        let words = trimmed.split(separator: " ")
        guard words.count <= 2 else { return nil }
        let allowed = CharacterSet.letters.union(.init(charactersIn: "-' "))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        let range = CFRange(location: 0, length: trimmed.utf16.count)
        guard let raw = DCSCopyTextDefinition(nil, trimmed as CFString, range)?.takeRetainedValue() as String? else {
            return nil
        }
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 {
            let phonetic = parts[1]
            let pos = parts.count >= 3 ? parts[2].split(separator: " ").first.map(String.init) : nil
            if let pos, !pos.isEmpty {
                return "/\(phonetic)/ · \(pos)"
            }
            if !phonetic.isEmpty {
                return "/\(phonetic)/"
            }
        }
        return nil
    }
}

// MARK: - SwiftUI 浮卡视图（5 套克制耐看原生风格）

private struct QuickTranslatePopoverView: View {
    @ObservedObject var model: QuickTranslateViewModel
    let onMeasuredSize: (CGSize) -> Void
    @State private var measuredBodyHeight: CGFloat = 42
    @State private var measuredSourceHeight: CGFloat = 34

    private var isDark: Bool { model.theme.isDark }

    var body: some View {
        ZStack {
            Group {
                switch model.style {
                case .cleanCard:
                    cleanBentoCard
                case .liquidGlass:
                    liquidGlassCard
                case .editorial:
                    editorialCard
                case .inlineBilingual:
                    inlineBilingualCard
                case .dynamicBubble:
                    dynamicBubbleCard
                }
            }
            .fixedSize(horizontal: false, vertical: !model.isManuallyResized)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: QuickTranslateCardSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(QuickTranslateCardSizeKey.self) { size in
                onMeasuredSize(size)
            }
            .padding(QuickTranslatePanel.windowInset)
            .background {
                if #available(macOS 15, *), let req = model.appleRequest {
                    QuickTranslateAppleJob(request: req, model: model)
                        .id(req.id)
                }
            }
        }
        .animation(model.isManuallyResized ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: model.style)
        .animation(model.isManuallyResized ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: model.isLoading)
        .animation(model.isManuallyResized ? nil : .easeOut(duration: 0.16), value: model.showOriginal)
        .animation(model.isManuallyResized ? nil : .easeOut(duration: 0.16), value: model.inlineMode)
        .animation(model.isManuallyResized ? nil : .easeOut(duration: 0.16), value: model.isResultExpanded)
    }

    private var cardResizeOverlay: some View {
        QuickTranslateResizeOverlay(
            onBegin: { model.beginResize() },
            onDrag: { edge, delta in model.dragResize(edge: edge, delta: delta) },
            onEnd: { model.endResize() },
            onDoubleClickCorner: { model.resetAutoSize() }
        )
    }

    private var cardDragBackground: some View {
        QuickTranslateDragSurface { model.markManuallyMoved() }
    }

    private var topDragGrabber: some View {
        HStack {
            Spacer(minLength: 0)
            Capsule()
                .fill(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12))
                .frame(width: 28, height: 3)
            Spacer(minLength: 0)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .background(cardDragBackground)
    }

    private var resizeCornerGrip: some View {
        QuickTranslateResizeGripMark(color: secondaryTextColor)
            .padding(.trailing, 5)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
    }

    // MARK: - 样式 1（默认）：极简分块卡片（参考 Bob 原生 macOS 风格）

    private var cleanBentoCard: some View {
        let cardWidth = model.activeCardWidth
        let cardHeight = model.activeCardHeight
        let cornerRadius: CGFloat = 13
        let typo = model.typography

        return VStack(alignment: .leading, spacing: 8) {
            // 1. 极简顶栏：左侧图钉（钉住变系统蓝）+ 右侧单色功能图标，整行可拖动
            HStack(spacing: 4) {
                Button {
                    model.isPinned.toggle()
                } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(model.isPinned ? model.accentColor : secondaryTextColor)
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.isPinned ? (isDark ? Color.white.opacity(0.08) : Color.white) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    model.isPinned ? hairlineBorderColor : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(model.isPinned ? "取消置顶钉住" : "钉住窗口（点外部不关闭）")

                Spacer(minLength: 8)

                if model.isManuallyResized {
                    plainToolbarIcon(symbol: "arrow.down.right.and.arrow.up.left", help: "恢复按内容自适应大小") {
                        model.resetAutoSize()
                    }
                }
                plainTypographyButton
                plainToolbarIcon(symbol: "scissors", help: "重新框选秒译") {
                    model.recapture()
                }
                plainToolbarIcon(symbol: "arrow.up.left.and.arrow.down.right", help: "展开完整翻译大窗") {
                    model.expandToFullWindow()
                }
                plainStyleSwitcherMenu
                plainToolbarIcon(symbol: "xmark", help: "关闭 Esc") {
                    model.close()
                }
            }
            .padding(.horizontal, 2)
            .background(cardDragBackground)

            // 2. 原文分块卡片（浅灰圆角块，支持行内修改重译、朗读、复制与识别语种标签）
            VStack(alignment: .leading, spacing: 8) {
                if model.phase == .recognizing {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.70)
                        Text("正在识别选区文字…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(secondaryTextColor)
                    }
                    .padding(.vertical, 4)
                } else if model.phase == .empty {
                    Text("选区内未识别到文字")
                        .font(.system(size: 12.5))
                        .foregroundStyle(secondaryTextColor)
                        .padding(.vertical, 4)
                } else if model.isEditingSource {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $model.editableSourceText)
                            .font(.system(size: typo.sourceFontSize, design: model.fontDesign))
                            .foregroundStyle(primaryTextColor)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 44, maxHeight: 110)
                        HStack(spacing: 6) {
                            Spacer()
                            Button("取消") {
                                model.editableSourceText = model.currentSourceText
                                model.isEditingSource = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryTextColor)
                            Button("重新翻译") {
                                model.commitEditedSourceAndRetranslate()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(model.accentColor)
                            .controlSize(.mini)
                        }
                    }
                } else {
                    let sourceTextView = Text(model.currentSourceText)
                        .font(.system(size: typo.sourceFontSize, weight: .regular, design: model.fontDesign))
                        .foregroundStyle(primaryTextColor)
                        .lineSpacing(max(2.5, typo.lineSpacing * 0.72))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: QuickTranslateSourceHeightKey.self, value: proxy.size.height)
                            }
                        )

                    let maxSourceH: CGFloat = if let cardHeight {
                        max(120, floor((cardHeight - 165) * 0.45))
                    } else {
                        min(210, max(120, floor(model.visibleScreenRect.height * 0.25)))
                    }
                    let naturalSourceH = ceil(measuredSourceHeight) + 4
                    let fittedSourceH = min(max(22, naturalSourceH), maxSourceH)
                    ScrollView(.vertical, showsIndicators: naturalSourceH > maxSourceH + 1) {
                        sourceTextView
                            .padding(.bottom, 2)
                    }
                    .frame(height: fittedSourceH)
                    .clipped()
                    .onPreferenceChange(QuickTranslateSourceHeightKey.self) { h in
                        if h > 1, abs(h - measuredSourceHeight) > 0.5 {
                            measuredSourceHeight = h
                        }
                    }
                }

                // 原文块底部操作：朗读 + 复制 + 已识别语种胶囊 + 改字图标
                if !model.currentSourceText.isEmpty && !model.isEditingSource {
                    HStack(spacing: 8) {
                        microMonoIcon(
                            symbol: model.speakingTarget == .source ? "speaker.wave.2.fill" : "speaker.wave.2",
                            active: model.speakingTarget == .source,
                            help: model.speakingTarget == .source ? "停止朗读" : "朗读原文"
                        ) { model.toggleSpeak(.source) }

                        microMonoIcon(
                            symbol: model.copiedSource ? "checkmark" : "doc.on.doc",
                            active: model.copiedSource,
                            help: model.copiedSource ? "已复制原文" : "复制原文"
                        ) { model.copySourceText() }

                        if let detected = model.detectedLanguageName {
                            HStack(spacing: 3) {
                                Text("已识别")
                                    .foregroundStyle(secondaryTextColor)
                                Text(detected)
                                    .foregroundStyle(model.accentColor)
                                    .fontWeight(.medium)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(bentoChipFillColor, in: Capsule())
                        }

                        Spacer(minLength: 4)

                        microMonoIcon(symbol: "pencil", active: false, help: "编辑原文并重新翻译") {
                            model.editableSourceText = model.currentSourceText
                            model.isEditingSource = true
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bentoSectionFillColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 3. 对称语言切换条：自动检测 ▾   ⇄   自动选择 / 目标语言 ▾
            HStack(spacing: 0) {
                sourceLanguageMenu
                    .frame(maxWidth: .infinity)

                Button {
                    model.swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("互换源语言与目标语言")

                bentoTargetLanguageMenu
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 32)
            .background(bentoSectionFillColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            // 4. 译文结果分块卡片（引擎标题 + 可折叠 + 正文 + 朗读/复制）
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    providerPickerMenu(prominent: true)
                    if model.targetLanguage == "auto", model.translatedText != nil {
                        Text("→ \(model.resolvedTargetLanguageName)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(secondaryTextColor)
                    }
                    Spacer()
                    Button {
                        model.isResultExpanded.toggle()
                    } label: {
                        Image(systemName: model.isResultExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(secondaryTextColor)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.isResultExpanded ? "收起译文" : "展开译文")
                }

                if model.isResultExpanded {
                    translationBodyView(forceBilingual: false, suppressInlineOriginal: true)
                        .frame(maxWidth: .infinity, maxHeight: model.isManuallyResized ? .infinity : nil, alignment: .topLeading)

                    if model.translatedText != nil {
                        HStack(spacing: 8) {
                            microMonoIcon(
                                symbol: model.speakingTarget == .translation ? "speaker.wave.2.fill" : "speaker.wave.2",
                                active: model.speakingTarget == .translation,
                                help: model.speakingTarget == .translation ? "停止朗读" : "朗读译文"
                            ) { model.toggleSpeak(.translation) }

                            microMonoIcon(
                                symbol: model.copied ? "checkmark" : "doc.on.doc",
                                active: model.copied,
                                help: model.copied ? "已复制译文" : "复制译文"
                            ) { model.copyTranslation() }

                            if model.copied {
                                Text("已复制")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(model.accentColor)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: model.isManuallyResized ? .infinity : nil, alignment: .topLeading)
            .background(bentoSectionFillColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(bentoOuterSurfaceColor)
                cardDragBackground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) { resizeCornerGrip }
        .overlay { cardResizeOverlay }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hairlineBorderColor, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(isDark ? 0.34 : 0.11), radius: 14, x: 0, y: 7)
        .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.05), radius: 3, x: 0, y: 1.5)
    }

    // MARK: - 样式 2：液态玻璃语义胶囊

    private var liquidGlassCard: some View {
        let cardWidth = model.activeCardWidth
        let cardHeight = model.activeCardHeight.map { max(96, $0 - 7) }
        let cornerRadius: CGFloat = 16
        return VStack(spacing: 0) {
            if !model.placedAbove {
                caretView(pointingUp: true, fill: glassSurfaceColor, stroke: Color(red: 0.22, green: 0.70, blue: 0.96).opacity(0.36))
                    .frame(width: cardWidth, height: 7, alignment: .leading)
                    .padding(.leading, max(18, min(cardWidth - 30, model.arrowOffsetX - 6)))
                    .offset(y: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                topDragGrabber

                HStack(spacing: 6) {
                    Text("译")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.16, green: 0.66, blue: 0.96), Color(red: 0.42, green: 0.40, blue: 0.96)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Circle()
                        )
                    languageMenu
                    providerPickerMenu(prominent: false)

                    Spacer(minLength: 4)

                    if model.isManuallyResized {
                        iconActionButton(symbol: "arrow.down.right.and.arrow.up.left", help: "恢复按内容自适应大小") {
                            model.resetAutoSize()
                        }
                    }
                    typographyPopoverButton
                    styleSwitcherMenu
                    iconToggleButton(
                        symbol: model.isPinned ? "pin.fill" : "pin",
                        active: model.isPinned,
                        help: model.isPinned ? "取消钉住" : "钉住浮卡（点外部不关闭）"
                    ) { model.isPinned.toggle() }
                    iconActionButton(symbol: "xmark", help: "关闭 Esc") { model.close() }
                }
                .background(cardDragBackground)

                translationBodyView(forceBilingual: false, suppressInlineOriginal: false)
                    .frame(maxWidth: .infinity, maxHeight: model.isManuallyResized ? .infinity : nil, alignment: .topLeading)

                HStack(spacing: 6) {
                    if case .translated = model.phase {
                        microChipButton(
                            title: model.showOriginal ? "隐藏原文" : "原文",
                            symbol: "text.quote",
                            active: model.showOriginal
                        ) { model.showOriginal.toggle() }
                    }
                    microChipButton(title: "朗读", symbol: model.speakingTarget == .translation ? "speaker.wave.2.fill" : "speaker.wave.2", active: model.speakingTarget == .translation) {
                        model.toggleSpeak(.translation)
                    }
                    microChipButton(title: "展开大窗", symbol: "arrow.up.left.and.arrow.down.right") {
                        model.expandToFullWindow()
                    }
                    Spacer(minLength: 4)
                    if model.translatedText != nil {
                        copyPrimaryButton
                    }
                }
                .background(cardDragBackground)
            }
            .padding(.horizontal, 14)
            .padding(.top, 5)
            .padding(.bottom, 12)
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
            .background {
                ZStack {
                    QuickTranslateVisualEffectBackground(
                        cornerRadius: cornerRadius,
                        isDark: isDark,
                        material: .hudWindow
                    )
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(glassTintColor)
                    cardDragBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) { resizeCornerGrip }
            .overlay { cardResizeOverlay }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(red: 0.24, green: 0.72, blue: 0.98).opacity(isDark ? 0.42 : 0.34),
                                Color(red: 0.44, green: 0.42, blue: 0.96).opacity(isDark ? 0.30 : 0.22),
                                Color.white.opacity(isDark ? 0.16 : 0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(isDark ? 0.30 : 0.10), radius: 14, x: 0, y: 7)
            .shadow(color: Color.black.opacity(isDark ? 0.20 : 0.05), radius: 3.5, x: 0, y: 1.5)

            if model.placedAbove {
                caretView(pointingUp: false, fill: glassSurfaceColor, stroke: Color(red: 0.44, green: 0.42, blue: 0.96).opacity(0.30))
                    .frame(width: cardWidth, height: 7, alignment: .leading)
                    .padding(.leading, max(18, min(cardWidth - 30, model.arrowOffsetX - 6)))
                    .offset(y: -1)
            }
        }
    }

    // MARK: - 样式 3：聚光取词取景器（无顶栏，第 1 行即译文）

    private var editorialCard: some View {
        let cardWidth = model.activeCardWidth
        let cardHeight = model.activeCardHeight
        let cornerRadius: CGFloat = 13
        return HStack(spacing: 0) {
            LinearGradient(
                colors: [Color(red: 0.24, green: 0.72, blue: 0.98), Color(red: 0.42, green: 0.42, blue: 0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 3.0)

            VStack(alignment: .leading, spacing: 7) {
                topDragGrabber

                translationBodyView(forceBilingual: false, suppressInlineOriginal: false)
                    .frame(maxWidth: .infinity, maxHeight: model.isManuallyResized ? .infinity : nil, alignment: .topLeading)

                HStack(spacing: 5) {
                    languageMenu
                    providerPickerMenu(prominent: false)
                    if case .translated = model.phase {
                        microTextButton(model.showOriginal ? "收起原文" : "原文") {
                            model.showOriginal.toggle()
                        }
                    }
                    Spacer(minLength: 4)
                    if model.isManuallyResized {
                        iconActionButton(symbol: "arrow.down.right.and.arrow.up.left", help: "恢复按内容自适应大小") {
                            model.resetAutoSize()
                        }
                    }
                    typographyPopoverButton
                    styleSwitcherMenu
                    iconActionButton(symbol: "arrow.up.left.and.arrow.down.right", help: "展开翻译大窗") {
                        model.expandToFullWindow()
                    }
                    iconToggleButton(
                        symbol: model.isPinned ? "pin.fill" : "pin",
                        active: model.isPinned,
                        help: model.isPinned ? "取消钉住" : "钉住浮卡"
                    ) { model.isPinned.toggle() }
                    if model.translatedText != nil {
                        copyPrimaryButton
                    }
                }
                .background(cardDragBackground)
            }
            .padding(.horizontal, 13)
            .padding(.top, 4)
            .padding(.bottom, 11)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(bentoOuterSurfaceColor)
                cardDragBackground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) { resizeCornerGrip }
        .overlay { cardResizeOverlay }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hairlineBorderColor, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(isDark ? 0.30 : 0.10), radius: 14, x: 0, y: 7)
        .shadow(color: Color.black.opacity(isDark ? 0.20 : 0.05), radius: 3.5, x: 0, y: 1.5)
    }

    // MARK: - 样式 4：原地双语高亮卡（支持仅译文 / 双语对照 / 覆盖原文）

    private var inlineBilingualCard: some View {
        let cardWidth = model.activeCardWidth
        let cardHeight = model.activeCardHeight
        let cornerRadius: CGFloat = 15
        return VStack(alignment: .leading, spacing: 8) {
            topDragGrabber

            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(QuickTranslateViewModel.InlineDisplayMode.allCases, id: \.self) { mode in
                        let selected = model.inlineMode == mode
                        Button {
                            model.selectInlineMode(mode)
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? (isDark ? Color.black : Color.white) : secondaryTextColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    selected
                                        ? AnyShapeStyle(
                                            LinearGradient(
                                                colors: [Color(red: 0.96, green: 0.70, blue: 0.24), Color(red: 0.92, green: 0.56, blue: 0.20)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        : AnyShapeStyle(Color.clear),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    Capsule().fill(bentoSectionFillColor)
                )

                Spacer(minLength: 4)
                if model.isManuallyResized {
                    iconActionButton(symbol: "arrow.down.right.and.arrow.up.left", help: "恢复按内容自适应大小") {
                        model.resetAutoSize()
                    }
                }
                typographyPopoverButton
                styleSwitcherMenu
                iconToggleButton(
                    symbol: model.isPinned ? "pin.fill" : "pin",
                    active: model.isPinned,
                    help: model.isPinned ? "取消钉住" : "钉住浮卡"
                ) { model.isPinned.toggle() }
                iconActionButton(symbol: "xmark", help: "关闭 Esc") { model.close() }
            }
            .background(cardDragBackground)

            translationBodyView(forceBilingual: model.inlineMode == .bilingual, suppressInlineOriginal: false)
                .frame(maxWidth: .infinity, maxHeight: model.isManuallyResized ? .infinity : nil, alignment: .topLeading)

            HStack(spacing: 6) {
                languageMenu
                providerPickerMenu(prominent: false)
                if model.inlineMode == .overlayOriginal {
                    Text("已覆盖原选区")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 0.92, green: 0.60, blue: 0.16))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.13), in: Capsule())
                }
                Spacer(minLength: 4)
                microChipButton(title: "展开大窗", symbol: "arrow.up.left.and.arrow.down.right") {
                    model.expandToFullWindow()
                }
                if model.translatedText != nil {
                    copyPrimaryButton
                }
            }
            .background(cardDragBackground)
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 12)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background {
            ZStack {
                QuickTranslateVisualEffectBackground(
                    cornerRadius: cornerRadius,
                    isDark: isDark,
                    material: .popover
                )
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        model.isOverlayOriginal
                            ? bentoOuterSurfaceColor
                            : (isDark ? Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.86) : Color.white.opacity(0.90))
                    )
                cardDragBackground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) { resizeCornerGrip }
        .overlay { cardResizeOverlay }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 0.96, green: 0.70, blue: 0.24).opacity(isDark ? 0.52 : 0.48),
                            Color(red: 0.24, green: 0.70, blue: 0.96).opacity(isDark ? 0.34 : 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.05
                )
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(isDark ? 0.30 : 0.10), radius: 14, x: 0, y: 7)
        .shadow(color: Color.black.opacity(isDark ? 0.20 : 0.05), radius: 3.5, x: 0, y: 1.5)
    }

    // MARK: - 样式 5：灵动岛气泡卡（加载药丸展开气泡 + 外侧竖排动作豆）

    private var dynamicBubbleCard: some View {
        let bubbleWidth = max(230, model.activeCardWidth - QuickTranslatePanel.dynamicBubbleBeansReserve)
        let bubbleHeight = model.activeCardHeight
        let cornerRadius: CGFloat = 17
        let mintAccent = Color(red: 0.18, green: 0.78, blue: 0.58)
        return Group {
            if model.isLoading {
                HStack(spacing: 9) {
                    Circle()
                        .fill(mintAccent)
                        .frame(width: 7.5, height: 7.5)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.70)
                    Text(model.phase == .recognizing ? "正在识别文字…" : "秒译 → \(model.resolvedTargetLanguageName)…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background {
                    ZStack {
                        Capsule().fill(Color(red: 0.08, green: 0.10, blue: 0.12).opacity(0.95))
                        cardDragBackground
                    }
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(mintAccent.opacity(0.45), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .shadow(color: Color.black.opacity(0.32), radius: 12, x: 0, y: 6)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 7) {
                        topDragGrabber

                        HStack(spacing: 6) {
                            Circle()
                                .fill(mintAccent)
                                .frame(width: 6, height: 6)
                            languageMenu
                            providerPickerMenu(prominent: false)
                            Spacer(minLength: 4)
                            if model.isManuallyResized {
                                iconActionButton(symbol: "arrow.down.right.and.arrow.up.left", help: "恢复按内容自适应大小") {
                                    model.resetAutoSize()
                                }
                            }
                            typographyPopoverButton
                        }
                        .background(cardDragBackground)

                        translationBodyView(forceBilingual: false, suppressInlineOriginal: false)
                            .frame(maxWidth: .infinity, maxHeight: model.isManuallyResized ? .infinity : nil, alignment: .topLeading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
                    .frame(width: bubbleWidth, height: bubbleHeight, alignment: .topLeading)
                    .frame(minHeight: bubbleHeight == nil ? 168 : nil, alignment: .topLeading)
                    .background {
                        ZStack {
                            QuickTranslateVisualEffectBackground(
                                cornerRadius: cornerRadius,
                                isDark: isDark,
                                material: .hudWindow
                            )
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(isDark ? Color(red: 0.09, green: 0.11, blue: 0.13).opacity(0.86) : Color.white.opacity(0.92))
                            cardDragBackground
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(alignment: .bottomTrailing) { resizeCornerGrip }
                    .overlay { cardResizeOverlay }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        mintAccent.opacity(isDark ? 0.46 : 0.38),
                                        Color(red: 0.22, green: 0.70, blue: 0.94).opacity(isDark ? 0.32 : 0.26)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.05
                            )
                            .allowsHitTesting(false)
                    }
                    .shadow(color: Color.black.opacity(isDark ? 0.30 : 0.10), radius: 14, x: 0, y: 7)
                    .shadow(color: Color.black.opacity(isDark ? 0.20 : 0.05), radius: 3.5, x: 0, y: 1.5)

                    VStack(spacing: 5) {
                        if model.translatedText != nil {
                            beanButton(
                                symbol: model.copied ? "checkmark" : "doc.on.doc",
                                tint: model.copied ? model.accentColor : nil,
                                help: model.copied ? "已复制" : "复制译文"
                            ) { model.copyTranslation() }
                        }
                        if case .translated = model.phase {
                            beanButton(
                                symbol: "text.quote",
                                tint: model.showOriginal ? model.accentColor : nil,
                                help: model.showOriginal ? "隐藏原文" : "查看原文"
                            ) { model.showOriginal.toggle() }
                        }
                        beanButton(
                            symbol: model.isPinned ? "pin.fill" : "pin",
                            tint: model.isPinned ? model.accentColor : nil,
                            help: model.isPinned ? "取消钉住" : "钉住浮卡"
                        ) { model.isPinned.toggle() }
                        beanButton(symbol: "arrow.up.left.and.arrow.down.right", help: "展开翻译大窗") {
                            model.expandToFullWindow()
                        }
                        Menu {
                            ForEach(QuickTranslateStyle.allCases, id: \.self) { item in
                                Button {
                                    model.selectStyle(item)
                                } label: {
                                    if item == model.style {
                                        Label(item.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(item.displayName)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(secondaryTextColor)
                                .frame(width: 25, height: 25)
                                .background(beanFillColor, in: Circle())
                                .overlay(Circle().strokeBorder(hairlineBorderColor, lineWidth: 1))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 25, height: 25)
                        .help("切换秒译样式")

                        beanButton(symbol: "xmark", help: "关闭 Esc") { model.close() }
                    }
                }
            }
        }
    }

    // MARK: - 共享内容体与小组件

    @ViewBuilder
    private func translationBodyView(forceBilingual: Bool, suppressInlineOriginal: Bool) -> some View {
        let typo = model.typography
        switch model.phase {
        case .recognizing:
            loadingSkeletonView(label: "正在识别选区文字…")

        case .translating(let sourceText):
            VStack(alignment: .leading, spacing: 6) {
                loadingSkeletonView(label: "正在翻译为\(model.resolvedTargetLanguageName)…")
                if !suppressInlineOriginal {
                    Text(sourceText)
                        .font(.system(size: max(11, typo.sourceFontSize - 1), design: model.fontDesign))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(2)
                }
            }

        case .translated(let sourceText, let translatedText, let dictSummary):
            let bodyContent = VStack(alignment: .leading, spacing: 8) {
                if let dictSummary {
                    HStack(spacing: 6) {
                        if !suppressInlineOriginal {
                            Text(sourceText)
                                .font(.system(size: max(11.5, typo.sourceFontSize), weight: .semibold, design: model.fontDesign))
                                .foregroundStyle(primaryTextColor)
                        }
                        Text(dictSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.accentColor)
                    }
                }

                if !suppressInlineOriginal && (forceBilingual || model.showOriginal) {
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(model.accentColor.opacity(0.55))
                            .frame(width: 2.5)
                        Text(sourceText)
                            .font(.system(size: typo.sourceFontSize, weight: .regular, design: model.fontDesign))
                            .foregroundStyle(secondaryTextColor)
                            .lineSpacing(max(2, typo.lineSpacing * 0.65))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Text(translatedText)
                    .font(.system(size: typo.targetFontSize, weight: .regular, design: model.fontDesign))
                    .foregroundStyle(primaryTextColor)
                    .lineSpacing(typo.lineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: QuickTranslateBodyHeightKey.self, value: proxy.size.height)
                }
            )

            Group {
                if model.isManuallyResized {
                    ScrollView(.vertical, showsIndicators: true) {
                        bodyContent
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    let fittedHeight = min(max(22, ceil(measuredBodyHeight)), model.autoMaxBodyHeight)
                    let needsScroll = measuredBodyHeight > model.autoMaxBodyHeight + 1
                    ScrollView(.vertical, showsIndicators: needsScroll) {
                        bodyContent
                    }
                    .frame(height: fittedHeight)
                }
            }
            .onPreferenceChange(QuickTranslateBodyHeightKey.self) { height in
                if height > 1, abs(height - measuredBodyHeight) > 0.5 {
                    measuredBodyHeight = height
                }
            }

        case .needsDownload(let sourceText):
            VStack(alignment: .leading, spacing: 8) {
                Text("需要下载 Apple「\(model.resolvedTargetLanguageName)」离线语言包后才能秒译。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(primaryTextColor)
                if !suppressInlineOriginal, !sourceText.isEmpty {
                    Text(sourceText)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("下载语言包并翻译") {
                        model.translateRecognizedText(allowDownload: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.accentColor)
                    .controlSize(.small)
                    Button("切换翻译引擎") { model.openSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

        case .needsConfiguration(let sourceText):
            VStack(alignment: .leading, spacing: 8) {
                Text("尚未配置可用的翻译服务。")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(primaryTextColor)
                if !suppressInlineOriginal, !sourceText.isEmpty {
                    Text("已识别：\(sourceText)")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(2)
                }
                Button("前往设置配置翻译服务") { model.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(model.accentColor)
                    .controlSize(.small)
            }

        case .empty:
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(secondaryTextColor)
                Text("选区内未识别到可翻译文字")
                    .font(.system(size: 12.5))
                    .foregroundStyle(secondaryTextColor)
            }
            .padding(.vertical, 4)

        case .failed(let sourceText, let message):
            VStack(alignment: .leading, spacing: 7) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                if !suppressInlineOriginal, let sourceText, !sourceText.isEmpty {
                    Text(sourceText)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("重试") {
                        if sourceText != nil {
                            model.translateRecognizedText(allowDownload: false)
                        } else {
                            model.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.accentColor)
                    .controlSize(.small)
                    Button("翻译设置") { model.openSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func loadingSkeletonView(label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.70)
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(secondaryTextColor.opacity(0.14))
                .frame(height: 10)
            RoundedRectangle(cornerRadius: 4)
                .fill(secondaryTextColor.opacity(0.09))
                .frame(width: 200, height: 10)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 语言菜单、排版弹窗与控件

    private var sourceLanguageMenu: some View {
        Menu {
            Button {
                model.selectSourceLanguage("auto")
            } label: {
                if model.sourceLanguage == "auto" {
                    Label("自动检测", systemImage: "checkmark")
                } else {
                    Text("自动检测")
                }
            }
            Divider()
            ForEach(TranslationServiceSettingsView.supportedLanguages, id: \.code) { lang in
                Button {
                    model.selectSourceLanguage(lang.code)
                } label: {
                    if lang.code == model.sourceLanguage {
                        Label(lang.name, systemImage: "checkmark")
                    } else {
                        Text(lang.name)
                    }
                }
            }
        } label: {
            Text("\(model.sourceLanguageName) ▾")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primaryTextColor)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("选择源语言")
    }

    private var bentoTargetLanguageMenu: some View {
        Menu {
            Button {
                model.selectTargetLanguage("auto")
            } label: {
                if model.targetLanguage == "auto" {
                    Label("自动选择", systemImage: "checkmark")
                } else {
                    Text("自动选择")
                }
            }
            Divider()
            ForEach(TranslationServiceSettingsView.supportedLanguages, id: \.code) { lang in
                Button {
                    model.selectTargetLanguage(lang.code)
                } label: {
                    if lang.code == model.targetLanguage {
                        Label(lang.name, systemImage: "checkmark")
                    } else {
                        Text(lang.name)
                    }
                }
            }
        } label: {
            Text("\(model.targetLanguageName) ▾")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primaryTextColor)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("选择目标语言")
    }

    private func providerPickerMenu(prominent: Bool) -> some View {
        Menu {
            if #available(macOS 15, *) {
                Button {
                    model.selectAppleTranslation()
                } label: {
                    if model.effectiveProvider == .apple {
                        Label("Apple 离线翻译", systemImage: "checkmark")
                    } else {
                        Text("Apple 离线翻译")
                    }
                }
            }

            Divider()

            Section("翻译 API") {
                ForEach(TranslationAPIProvider.allCases, id: \.self) { api in
                    Button {
                        model.selectAPIProvider(api)
                    } label: {
                        if model.activeAPIProvider == api {
                            Label(api.title, systemImage: "checkmark")
                        } else {
                            Text(api.title)
                        }
                    }
                }
            }

            Divider()

            Section("AI 大模型") {
                ForEach([PrivacyAIProvider.deepSeek, .qwen, .custom], id: \.self) { online in
                    Button {
                        model.selectOnlineModel(online)
                    } label: {
                        if model.activeOnlineProvider == online {
                            Label(online.title, systemImage: "checkmark")
                        } else {
                            Text(online.title)
                        }
                    }
                }
                Button {
                    model.selectLocalModel()
                } label: {
                    if model.effectiveProvider == .local {
                        Label("本机模型", systemImage: "checkmark")
                    } else {
                        Text("本机模型")
                    }
                }
            }

            Divider()

            Button("配置翻译服务与密钥…") {
                model.openSettings()
            }
        } label: {
            if prominent {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(model.accentColor)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isDark ? Color.white.opacity(0.08) : Color.white)
                        )
                    Text("\(model.providerBadgeText) ▾")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            } else {
                Text("\(model.providerBadgeText) ▾")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(secondaryTextColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(bentoSectionFillColor))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("随时切换翻译服务并立即重译")
    }

    private var languageMenu: some View {
        Menu {
            Button {
                model.selectTargetLanguage("auto")
            } label: {
                if model.targetLanguage == "auto" {
                    Label("自动选择", systemImage: "checkmark")
                } else {
                    Text("自动选择")
                }
            }
            Divider()
            ForEach(TranslationServiceSettingsView.supportedLanguages, id: \.code) { lang in
                Button {
                    model.selectTargetLanguage(lang.code)
                } label: {
                    if lang.code == model.targetLanguage {
                        Label(lang.name, systemImage: "checkmark")
                    } else {
                        Text(lang.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("→ \(model.targetLanguageName)")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(primaryTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(bentoSectionFillColor))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换目标语言")
    }

    private var plainTypographyButton: some View {
        Button {
            model.isTypographyPopoverOpen.toggle()
        } label: {
            Text("Aa")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(model.isTypographyPopoverOpen ? model.accentColor : secondaryTextColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("自定义字体、字号、行距与强调色")
        .popover(isPresented: $model.isTypographyPopoverOpen, arrowEdge: .bottom) {
            typographyPopoverContent
                .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }

    private var plainStyleSwitcherMenu: some View {
        Menu {
            ForEach(QuickTranslateStyle.allCases, id: \.self) { item in
                Button {
                    model.selectStyle(item)
                } label: {
                    if item == model.style {
                        Label(item.displayName, systemImage: "checkmark")
                    } else {
                        Text(item.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .help("切换秒译卡片风格（5 套）")
    }

    private var typographyPopoverButton: some View {
        Button {
            model.isTypographyPopoverOpen.toggle()
        } label: {
            Text("Aa")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(model.isTypographyPopoverOpen ? model.accentColor : secondaryTextColor)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        model.isTypographyPopoverOpen
                            ? model.accentColor.opacity(0.14)
                            : bentoSectionFillColor
                    )
                )
        }
        .buttonStyle(.plain)
        .help("自定义字体、字号、行距与强调色")
        .popover(isPresented: $model.isTypographyPopoverOpen, arrowEdge: .bottom) {
            typographyPopoverContent
                .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }

    private var typographyPopoverContent: some View {
        let style = model.typography
        let theme = model.theme
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("文本样式设置")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if style != .default {
                    Button("恢复默认") {
                        model.updateTypography { $0 = .default }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("强调色")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                    Text(style.accent.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
                HStack(spacing: 9) {
                    ForEach(TranslationAccentPreset.allCases, id: \.self) { preset in
                        let selected = style.accent == preset
                        let swatch = preset.rgb.color
                        Button {
                            model.updateTypography { $0.accent = preset }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(swatch)
                                    .frame(width: 18, height: 18)
                                if selected {
                                    Circle()
                                        .strokeBorder(theme.token(.popover), lineWidth: 2)
                                        .frame(width: 14, height: 14)
                                    Circle()
                                        .strokeBorder(swatch, lineWidth: 1.5)
                                        .frame(width: 24, height: 24)
                                }
                            }
                            .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(preset.title)
                    }
                }
            }

            Rectangle().fill(theme.token(.border)).frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("文字字体")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                SnapSegmented(
                    items: TranslationFontFamily.allCases,
                    selection: Binding(
                        get: { model.typography.fontFamily },
                        set: { value in model.updateTypography { $0.fontFamily = value } }
                    ),
                    theme: theme,
                    title: \.title
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("译文字号")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                    Text(String(format: "%.1f pt", style.targetFontSize))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.token(.foreground))
                }
                SnapSlider(
                    value: Binding(
                        get: { model.typography.targetFontSize },
                        set: { value in model.updateTypography { $0.targetFontSize = (value * 2).rounded() / 2 } }
                    ),
                    in: 12...22,
                    theme: theme,
                    width: 244
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("原文字号")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                    Text(String(format: "%.1f pt", style.sourceFontSize))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.token(.foreground))
                }
                SnapSlider(
                    value: Binding(
                        get: { model.typography.sourceFontSize },
                        set: { value in model.updateTypography { $0.sourceFontSize = (value * 2).rounded() / 2 } }
                    ),
                    in: 11...18,
                    theme: theme,
                    width: 244
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("段落行距")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                SnapSegmented(
                    items: [3.0, 5.0, 8.0],
                    selection: Binding(
                        get: {
                            if model.typography.lineSpacing <= 3.5 { return 3.0 }
                            if model.typography.lineSpacing >= 7.0 { return 8.0 }
                            return 5.0
                        },
                        set: { value in model.updateTypography { $0.lineSpacing = value } }
                    ),
                    theme: theme
                ) { value in
                    value <= 3.5 ? "紧凑" : value >= 7.0 ? "宽松" : "舒适"
                }
            }
        }
        .padding(14)
        .frame(width: 272)
        .background(theme.token(.popover))
        .foregroundStyle(theme.token(.foreground))
    }

    private var styleSwitcherMenu: some View {
        Menu {
            ForEach(QuickTranslateStyle.allCases, id: \.self) { item in
                Button {
                    model.selectStyle(item)
                } label: {
                    if item == model.style {
                        Label(item.displayName, systemImage: "checkmark")
                    } else {
                        Text(item.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(bentoSectionFillColor))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .help("切换秒译样式（5 套）")
    }

    private var copyPrimaryButton: some View {
        Button {
            model.copyTranslation()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                Text(model.copied ? "已复制" : "复制译文")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(model.copied ? .white : (isDark ? Color.black : Color.white))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                model.copied
                    ? model.accentColor
                    : (isDark ? Color(red: 0.92, green: 0.93, blue: 0.96) : Color(red: 0.13, green: 0.15, blue: 0.19)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func plainToolbarIcon(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func microMonoIcon(symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(active ? model.accentColor : secondaryTextColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func microChipButton(title: String, symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(active ? model.accentColor : secondaryTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(active ? model.accentColor.opacity(0.12) : bentoSectionFillColor)
            )
        }
        .buttonStyle(.plain)
    }

    private func microTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func iconActionButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(bentoSectionFillColor))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconToggleButton(symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(active ? model.accentColor : secondaryTextColor)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(active ? model.accentColor.opacity(0.14) : bentoSectionFillColor)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func beanButton(symbol: String, tint: Color? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint ?? secondaryTextColor)
                .frame(width: 25, height: 25)
                .background(beanFillColor, in: Circle())
                .overlay(Circle().strokeBorder(tint?.opacity(0.55) ?? hairlineBorderColor, lineWidth: 1))
                .shadow(color: Color.black.opacity(isDark ? 0.28 : 0.10), radius: 5, x: 0, y: 2.5)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func caretView(pointingUp: Bool, fill: Color, stroke: Color) -> some View {
        QuickTranslateCaretShape(pointingUp: pointingUp)
            .fill(fill)
            .overlay(QuickTranslateCaretShape(pointingUp: pointingUp).stroke(stroke, lineWidth: 1))
            .frame(width: 12, height: 7)
    }

    // MARK: - 统一克制的 macOS 原生色板

    private var primaryTextColor: Color {
        isDark ? Color(red: 0.94, green: 0.95, blue: 0.97) : Color(red: 0.11, green: 0.13, blue: 0.16)
    }

    private var secondaryTextColor: Color {
        isDark ? Color(red: 0.62, green: 0.65, blue: 0.71) : Color(red: 0.42, green: 0.45, blue: 0.51)
    }

    private var bentoOuterSurfaceColor: Color {
        isDark ? Color(red: 0.118, green: 0.122, blue: 0.141) : Color.white
    }

    private var bentoSectionFillColor: Color {
        isDark ? Color(red: 0.157, green: 0.165, blue: 0.192) : Color(red: 0.955, green: 0.958, blue: 0.966)
    }

    private var bentoChipFillColor: Color {
        isDark ? Color(red: 0.21, green: 0.22, blue: 0.26) : Color(red: 0.905, green: 0.914, blue: 0.932)
    }

    private var hairlineBorderColor: Color {
        isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.11)
    }

    private var glassTintColor: Color {
        isDark ? Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.76) : Color.white.opacity(0.84)
    }

    private var glassSurfaceColor: Color {
        isDark ? Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.95) : Color.white.opacity(0.96)
    }

    private var beanFillColor: Color {
        isDark ? Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.95) : Color.white.opacity(0.96)
    }
}

private struct QuickTranslateCaretShape: Shape {
    let pointingUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointingUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

private struct QuickTranslateCardSizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 {
            value = next
        }
    }
}

private struct QuickTranslateBodyHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct QuickTranslateSourceHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

/// 卡片右下角极简双斜线缩放提示纹样。
private struct QuickTranslateResizeGripMark: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: size.width - 7.5, y: size.height - 1.5))
            p.addLine(to: CGPoint(x: size.width - 1.5, y: size.height - 7.5))
            p.move(to: CGPoint(x: size.width - 4.0, y: size.height - 1.5))
            p.addLine(to: CGPoint(x: size.width - 1.5, y: size.height - 4.0))
            ctx.stroke(p, with: .color(color.opacity(0.42)), style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
        }
        .frame(width: 10, height: 10)
    }
}

/// 覆盖在浮卡四边与四角的 AppKit 零抖动缩放层。
private struct QuickTranslateResizeOverlay: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (QuickTranslatePanel.ResizeEdge, CGSize) -> Void
    let onEnd: () -> Void
    let onDoubleClickCorner: () -> Void

    func makeNSView(context: Context) -> ResizePerimeterView {
        let view = ResizePerimeterView()
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClickCorner = onDoubleClickCorner
        return view
    }

    func updateNSView(_ nsView: ResizePerimeterView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
        nsView.onDoubleClickCorner = onDoubleClickCorner
    }

    final class ResizePerimeterView: NSView {
        var onBegin: (() -> Void)?
        var onDrag: ((QuickTranslatePanel.ResizeEdge, CGSize) -> Void)?
        var onEnd: (() -> Void)?
        var onDoubleClickCorner: (() -> Void)?

        private var trackingArea: NSTrackingArea?
        private var activeEdge: QuickTranslatePanel.ResizeEdge?
        private var dragStartMouse: CGPoint = .zero

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return edge(at: local) != nil ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            if let edge = edge(at: local) {
                Self.cursor(for: edge).set()
            } else {
                NSCursor.arrow.set()
            }
        }

        override func cursorUpdate(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            if activeEdge == nil {
                NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            guard let edge = edge(at: local) else { return }
            if event.clickCount == 2, Self.isCorner(edge) {
                onDoubleClickCorner?()
                return
            }
            activeEdge = edge
            dragStartMouse = NSEvent.mouseLocation
            Self.cursor(for: edge).set()
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let edge = activeEdge else { return }
            let now = NSEvent.mouseLocation
            let delta = CGSize(width: now.x - dragStartMouse.x, height: now.y - dragStartMouse.y)
            Self.cursor(for: edge).set()
            onDrag?(edge, delta)
        }

        override func mouseUp(with event: NSEvent) {
            guard activeEdge != nil else { return }
            activeEdge = nil
            onEnd?()
            let local = convert(event.locationInWindow, from: nil)
            if let edge = edge(at: local) {
                Self.cursor(for: edge).set()
            } else {
                NSCursor.arrow.set()
            }
        }

        private func edge(at p: CGPoint) -> QuickTranslatePanel.ResizeEdge? {
            guard bounds.contains(p) else { return nil }
            let corner: CGFloat = 14
            let strip: CGFloat = 6

            let nearLeft = p.x <= strip
            let nearRight = p.x >= bounds.width - strip
            let nearBottom = p.y <= strip
            let nearTop = p.y >= bounds.height - strip

            let inCornerLeft = p.x <= corner
            let inCornerRight = p.x >= bounds.width - corner
            let inCornerBottom = p.y <= corner
            let inCornerTop = p.y >= bounds.height - corner

            if inCornerRight && inCornerBottom { return .bottomRight }
            if inCornerLeft && inCornerBottom { return .bottomLeft }
            if inCornerRight && inCornerTop { return .topRight }
            if inCornerLeft && inCornerTop { return .topLeft }
            if nearRight { return .right }
            if nearLeft { return .left }
            if nearBottom { return .bottom }
            if nearTop { return .top }
            return nil
        }

        private static func isCorner(_ edge: QuickTranslatePanel.ResizeEdge) -> Bool {
            switch edge {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            default: return false
            }
        }

        private static func cursor(for edge: QuickTranslatePanel.ResizeEdge) -> NSCursor {
            if #available(macOS 15, *) {
                switch edge {
                case .left, .right:
                    return .frameResize(position: .left, directions: .all)
                case .top, .bottom:
                    return .frameResize(position: .top, directions: .all)
                case .topLeft, .bottomRight:
                    return .frameResize(position: .topLeft, directions: .all)
                case .topRight, .bottomLeft:
                    return .frameResize(position: .topRight, directions: .all)
                }
            }
            switch edge {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .bottomRight, .topRight, .bottomLeft: return .crosshair
            }
        }
    }
}

/// 真实圆角遮罩的 AppKit 毛玻璃背景，彻底消除无边框浮窗上 SwiftUI Material 溢出的方正暗角。
private struct QuickTranslateVisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let isDark: Bool
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> RoundedVisualEffectView {
        let view = RoundedVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: RoundedVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: RoundedVisualEffectView) {
        view.material = material
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.updateCornerRadius(cornerRadius)
    }

    final class RoundedVisualEffectView: NSVisualEffectView {
        private var currentRadius: CGFloat = -1

        func updateCornerRadius(_ radius: CGFloat) {
            guard abs(currentRadius - radius) > 0.25 else { return }
            currentRadius = radius
            layer?.cornerRadius = radius
            maskImage = Self.roundedMaskImage(cornerRadius: radius)
        }

        private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
            let r = max(1, ceil(cornerRadius))
            let side = r * 2 + 2
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
                return true
            }
            image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
            image.resizingMode = .stretch
            return image
        }
    }
}

/// AppKit 直接驱动的窗口拖动背景面：在 `.nonactivatingPanel` 无边框浮窗上 1:1 丝滑拖动。
private struct QuickTranslateDragSurface: NSViewRepresentable {
    let onDragStart: () -> Void

    func makeNSView(context: Context) -> DragMoveView {
        let view = DragMoveView()
        view.onDragStart = onDragStart
        return view
    }

    func updateNSView(_ nsView: DragMoveView, context: Context) {
        nsView.onDragStart = onDragStart
    }

    final class DragMoveView: NSView {
        var onDragStart: (() -> Void)?
        private var isDraggingWindow = false
        private var dragStartMouse: CGPoint = .zero
        private var windowStartOrigin: CGPoint = .zero

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            isDraggingWindow = true
            dragStartMouse = NSEvent.mouseLocation
            windowStartOrigin = window.frame.origin
            NSCursor.closedHand.set()
            onDragStart?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDraggingWindow, let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - dragStartMouse.x
            let dy = now.y - dragStartMouse.y
            window.setFrameOrigin(CGPoint(x: windowStartOrigin.x + dx, y: windowStartOrigin.y + dy))
            NSCursor.closedHand.set()
        }

        override func mouseUp(with event: NSEvent) {
            guard isDraggingWindow else { return }
            isDraggingWindow = false
            NSCursor.arrow.set()
        }
    }
}

@available(macOS 15, *)
private struct QuickTranslateAppleJob: View {
    let request: QuickTranslateViewModel.AppleRequest
    let model: QuickTranslateViewModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear.task {
            let input = request.source == "auto" ? nil : Locale.Language(identifier: request.source)
            let output = Locale.Language(identifier: request.target)
            do {
                let availability = LanguageAvailability()
                let status: LanguageAvailability.Status
                if let input {
                    status = await availability.status(from: input, to: output)
                } else {
                    status = try await availability.status(for: request.text, to: output)
                }
                guard !Task.isCancelled else { return }
                switch status {
                case .installed: break
                case .supported where request.allowDownload: break
                case .supported:
                    model.markAppleDownloadRequired(request.id)
                    return
                default:
                    model.finishAppleRequest(
                        request.id,
                        result: .failure(QuickTranslateError("Apple 翻译不支持此语言组合，可切换目标语言或翻译引擎。"))
                    )
                    return
                }
                configuration = .init(source: input, target: output)
            } catch {
                if !Task.isCancelled {
                    model.finishAppleRequest(request.id, result: .failure(error))
                }
            }
        }.translationTask(configuration) { session in
            do {
                let response = try await session.translate(request.text)
                guard !Task.isCancelled else { return }
                model.finishAppleRequest(request.id, result: .success(response.targetText))
            } catch {
                if !Task.isCancelled {
                    model.finishAppleRequest(request.id, result: .failure(error))
                }
            }
        }
    }
}

private struct QuickTranslateError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

extension AppEnvironment {
    func quickTranslateImage(_ image: CGImage, captureRect: CGRect) {
        Task { @MainActor in
            quickTranslatePanel.show(image: image, captureRect: captureRect, environment: self)
        }
    }
}
