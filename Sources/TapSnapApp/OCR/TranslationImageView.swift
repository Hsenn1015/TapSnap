import AppKit
import CoreText
import SwiftUI
import TapSnapOCR
import VisionKit

struct TranslationOverlayItem: Equatable {
    let id: UUID
    let normalizedBounds: CGRect
    let text: String
    let lineCount: Int
    let backdrop: TranslationBlockBackdrop
}

struct TranslationImageView: NSViewRepresentable {
    let image: CGImage
    let document: OCRDocument?
    let zoom: CGFloat
    let onHover: (String?, CGRect) -> Void
    let onSelection: (String?, CGRect) -> Void
    var onSelectionUnavailable: (String) -> Void = { _ in }
    var onZoomChange: ((CGFloat) -> Void)?
    var onBlockClick: ((UUID) -> Void)?
    var resetSelection = 0
    var recognitionLanguages: [String] = []
    var highlightedBlockID: UUID?
    var scrollToBlockID: UUID?
    var overlayItems: [TranslationOverlayItem] = []
    var showsTranslationOverlay = false
    var peekingOriginal = false
    var hoverEnabled = true
    var accentNSColor: NSColor = .controlAccentColor

    func makeNSView(context: Context) -> TranslationImageViewport { TranslationImageViewport(frame: .zero) }

    func updateNSView(_ view: TranslationImageViewport, context: Context) {
        view.onHover = onHover
        view.onSelection = onSelection
        view.onSelectionUnavailable = onSelectionUnavailable
        view.onZoomChange = onZoomChange
        view.onBlockClick = onBlockClick
        view.hoverEnabled = hoverEnabled
        view.update(image: image, document: document, zoom: zoom, reset: resetSelection, languages: recognitionLanguages)
        view.updateHighlights(
            highlightedBlockID: highlightedBlockID,
            scrollToBlockID: scrollToBlockID,
            overlayItems: overlayItems,
            showsOverlay: showsTranslationOverlay,
            peekingOriginal: peekingOriginal,
            accentColor: accentNSColor
        )
    }

    static func dismantleNSView(_ view: TranslationImageViewport, coordinator: ()) { view.stop() }
}

/// Hover uses OCR paragraph order, so a sentence that wraps across two image rows has one translation.
struct TranslationImageSentence {
    let text: String
    let regions: [CGRect]

    static func sentences(in block: OCRTextBlock) -> [Self] {
        let paragraph = block.paragraphText
        var remaining = paragraph.startIndex..<paragraph.endIndex
        let rows = block.lines.compactMap { line -> (OCRTextLine, Range<String.Index>)? in
            guard !line.text.isEmpty, let range = paragraph.range(of: line.text, range: remaining) else { return nil }
            remaining = range.upperBound..<paragraph.endIndex
            return (line, range)
        }
        var result: [Self] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: .bySentences) { _, range, _, _ in
            let text = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let regions = rows.compactMap { line, row -> CGRect? in
                guard range.overlaps(row), !line.normalizedBounds.isEmpty else { return nil }
                let overlap = range.clamped(to: row)
                if overlap == row { return line.normalizedBounds }
                // Vision supplies a row box. For two sentences sharing a row, approximate the
                // boundary with glyph advances. Exact drag-selection is handled by Live Text.
                let string = NSAttributedString(string: line.text, attributes: [.font: NSFont.systemFont(ofSize: 16)])
                let layout = CTLineCreateWithAttributedString(string as CFAttributedString)
                let width = CGFloat(CTLineGetTypographicBounds(layout, nil, nil, nil))
                guard width > 0 else { return nil }
                let offsets = NSRange(overlap, in: paragraph)
                let start = offsets.location - NSRange(row, in: paragraph).location
                let left = CTLineGetOffsetForStringIndex(layout, start, nil) / width
                let right = CTLineGetOffsetForStringIndex(layout, start + offsets.length, nil) / width
                let bounds = line.normalizedBounds
                return CGRect(x: bounds.minX + min(left, right) * bounds.width, y: bounds.minY,
                              width: abs(right - left) * bounds.width, height: bounds.height)
            }
            if !regions.isEmpty { result.append(Self(text: text, regions: regions)) }
        }
        return result
    }
}

private final class TranslationImageContainer: NSView {
    override var isFlipped: Bool { true }
}

private final class TranslationHoverHighlight: NSView {
    var regions: [CGRect] = [] { didSet { if oldValue != regions { needsDisplay = true } } }
    var linkedRegion: CGRect? { didSet { if oldValue != linkedRegion { needsDisplay = true } } }
    var accentColor: NSColor = .controlAccentColor { didSet { if oldValue != accentColor { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let linkedRegion, let rect = OCRSourceViewport.region(linkedRegion, in: bounds) {
            let expanded = rect.insetBy(dx: -3, dy: -2)
            let path = NSBezierPath(roundedRect: expanded, xRadius: 5, yRadius: 5)
            accentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 2.5
            path.stroke()
            accentColor.withAlphaComponent(0.90).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        for region in regions {
            guard let rect = OCRSourceViewport.region(region, in: bounds) else { continue }
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1.5), xRadius: 4, yRadius: 4)
            accentColor.withAlphaComponent(0.18).setFill()
            path.fill()
            accentColor.withAlphaComponent(0.62).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// 在原图对应位置直接绘制融合背景色的译文块，支持按住 Space 透视原图。
private final class TranslationInlineOverlayView: NSView {
    var items: [TranslationOverlayItem] = [] { didSet { if oldValue != items { needsDisplay = true } } }
    var highlightedID: UUID? { didSet { if oldValue != highlightedID { needsDisplay = true } } }
    var accentColor: NSColor = .controlAccentColor { didSet { if oldValue != accentColor { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty, !bounds.isEmpty else { return }
        for item in items {
            guard let rawRect = OCRSourceViewport.region(item.normalizedBounds, in: bounds),
                  rawRect.width >= 10, rawRect.height >= 8 else { continue }

            let padX: CGFloat = min(5, max(2, rawRect.height * 0.10))
            let padY: CGFloat = min(3, max(1.5, rawRect.height * 0.08))
            var cardRect = rawRect.insetBy(dx: -padX, dy: -padY)
            cardRect = cardRect.intersection(bounds.insetBy(dx: 2, dy: 2))
            guard cardRect.width >= 10, cardRect.height >= 8 else { continue }

            let radius = min(6, max(3, cardRect.height * 0.18))
            let bgPath = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)

            let bg = item.backdrop.background
            let nsBg = NSColor(srgbRed: bg.red, green: bg.green, blue: bg.blue, alpha: 0.96)
            nsBg.setFill()
            bgPath.fill()

            let isHighlighted = item.id == highlightedID
            if isHighlighted {
                accentColor.withAlphaComponent(0.92).setStroke()
                bgPath.lineWidth = 1.6
            } else {
                let border = item.backdrop.isDark
                    ? NSColor.white.withAlphaComponent(0.14)
                    : NSColor.black.withAlphaComponent(0.09)
                border.setStroke()
                bgPath.lineWidth = 0.75
            }
            bgPath.stroke()

            let textRect = cardRect.insetBy(dx: padX, dy: padY * 0.7)
            guard textRect.width > 4, textRect.height > 4 else { continue }

            let textColor = item.backdrop.isDark
                ? NSColor(white: 0.96, alpha: 1)
                : NSColor(white: 0.10, alpha: 1)
            let (attributed, textHeight) = fittedAttributedText(
                item.text,
                in: textRect.size,
                estimatedLines: item.lineCount,
                color: textColor
            )
            let drawY = textRect.minY + max(0, (textRect.height - textHeight) * 0.5)
            let drawRect = CGRect(x: textRect.minX, y: drawY, width: textRect.width, height: min(textRect.height, textHeight + 2))
            attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func fittedAttributedText(
        _ text: String,
        in size: CGSize,
        estimatedLines: Int,
        color: NSColor
    ) -> (NSAttributedString, CGFloat) {
        let baseLineHeight = size.height / CGFloat(max(1, estimatedLines))
        let maxFont = min(28, max(10, baseLineHeight * 0.78))
        let minFont: CGFloat = 9
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(1, min(3, maxFont * 0.12))

        var candidate = maxFont
        while candidate >= minFont {
            let font = NSFont.systemFont(ofSize: candidate, weight: candidate >= 18 ? .semibold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let measured = attributed.boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            if measured.height <= size.height + 1.5 || candidate <= minFont {
                return (attributed, ceil(measured.height))
            }
            candidate -= max(0.75, (maxFont - minFont) / 8)
        }
        let fallback = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: minFont), .foregroundColor: color, .paragraphStyle: paragraph]
        )
        return (fallback, size.height)
    }
}

final class TranslationImageViewport: NSScrollView, ImageAnalysisOverlayViewDelegate {
    private let canvas = TranslationImageContainer()
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let highlight = TranslationHoverHighlight()
    private let translationOverlay = TranslationInlineOverlayView()
    private let analyzer = ImageAnalyzer()
    private var image: CGImage?
    private var blocks: [OCRTextBlock] = []
    private var lines: [OCRTextLine] = []
    private var sentences: [TranslationImageSentence] = []
    private var hoverDocumentID: UUID?
    private var lastScrollBlockID: UUID?
    private var zoom: CGFloat = 1
    private var reset = 0
    private var showsOverlay = false
    private var trackedArea: NSTrackingArea?
    private var analysisTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var hovered: (text: String, rect: CGRect)?
    private var selectionText: String?
    private var selectionPoint: CGPoint?
    private var selectionRect = CGRect.null
    private var isPanning = false
    private var panOrigin: CGPoint = .zero
    private var panClipOrigin: CGPoint = .zero
    var hoverEnabled = true {
        didSet { if !hoverEnabled { clearHover() } }
    }
    var onHover: (String?, CGRect) -> Void = { _, _ in }
    var onSelection: (String?, CGRect) -> Void = { _, _ in }
    var onSelectionUnavailable: (String) -> Void = { _ in }
    var onZoomChange: ((CGFloat) -> Void)?
    var onBlockClick: ((UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        documentView = canvas
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.setAccessibilityLabel("翻译原图")
        canvas.addSubview(imageView)

        highlight.frame = imageView.bounds
        highlight.autoresizingMask = [.width, .height]
        imageView.addSubview(highlight)

        translationOverlay.frame = imageView.bounds
        translationOverlay.autoresizingMask = [.width, .height]
        translationOverlay.wantsLayer = true
        translationOverlay.alphaValue = 0
        translationOverlay.isHidden = true
        imageView.addSubview(translationOverlay)

        overlay.frame = imageView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
        overlay.delegate = self
        imageView.addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: CGImage, document: OCRDocument?, zoom: CGFloat, reset: Int, languages: [String] = []) {
        if self.image !== image {
            stop()
            self.image = image
            blocks = []
            lines = []
            sentences = []
            hoverDocumentID = nil
            lastScrollBlockID = nil
            selectionText = nil
            selectionPoint = nil
            selectionRect = .null
            hovered = nil
            highlight.regions = []
            highlight.linkedRegion = nil
            overlay.analysis = nil
            imageView.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            startAnalysis(image, languages: document?.languages ?? languages)
        }
        if hoverDocumentID != document?.blocks.first?.id {
            hoverDocumentID = document?.blocks.first?.id
            blocks = document?.blocks ?? []
            lines = document?.originalLines ?? []
            sentences = document?.blocks.flatMap(TranslationImageSentence.sentences) ?? []
            geometryDidChange()
        }
        if self.reset != reset {
            self.reset = reset
            hovered = nil
            highlight.regions = []
            selectionText = nil
            selectionPoint = nil
            selectionRect = .null
            selectionTask?.cancel()
            overlay.resetSelection()
        }
        self.zoom = zoom
        resizeImage()
    }

    func updateHighlights(
        highlightedBlockID: UUID?,
        scrollToBlockID: UUID?,
        overlayItems: [TranslationOverlayItem],
        showsOverlay: Bool,
        peekingOriginal: Bool,
        accentColor: NSColor = .controlAccentColor
    ) {
        let linked = highlightedBlockID.flatMap { id in blocks.first(where: { $0.id == id })?.normalizedBounds }
        highlight.linkedRegion = linked
        highlight.accentColor = accentColor
        translationOverlay.items = overlayItems
        translationOverlay.highlightedID = highlightedBlockID
        translationOverlay.accentColor = accentColor

        self.showsOverlay = showsOverlay
        let visible = showsOverlay && !overlayItems.isEmpty
        let targetAlpha: CGFloat = (visible && !peekingOriginal) ? 1 : 0
        if visible && translationOverlay.isHidden {
            translationOverlay.isHidden = false
        }
        if abs(translationOverlay.alphaValue - targetAlpha) > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                translationOverlay.animator().alphaValue = targetAlpha
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.translationOverlay.alphaValue <= 0.01 && !self.showsOverlay {
                        self.translationOverlay.isHidden = true
                    }
                }
            }
        } else if !visible {
            translationOverlay.isHidden = true
        }
        overlay.isHidden = visible && !peekingOriginal

        if let scrollToBlockID, scrollToBlockID != lastScrollBlockID,
           let bounds = blocks.first(where: { $0.id == scrollToBlockID })?.normalizedBounds,
           let rect = OCRSourceViewport.region(bounds, in: imageView.frame) {
            lastScrollBlockID = scrollToBlockID
            canvas.scrollToVisible(rect.insetBy(dx: -20, dy: -20))
        } else if scrollToBlockID == nil {
            lastScrollBlockID = nil
        }
    }

    func stop() {
        analysisTask?.cancel()
        selectionTask?.cancel()
        geometryTask?.cancel()
    }

    private func startAnalysis(_ image: CGImage, languages: [String]) {
        let analyzer = self.analyzer
        analysisTask = Task { @MainActor [weak self] in
            if ImageAnalyzer.isSupported {
                var config = ImageAnalyzer.Configuration(.text)
                config.locales = languages.filter { ImageAnalyzer.supportedTextRecognitionLanguages.contains($0) }
                if let result = try? await analyzer.analyze(image, orientation: .up, configuration: config),
                   result.hasResults(for: .text), !Task.isCancelled {
                    self?.overlay.analysis = result
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.onSelectionUnavailable("系统选字暂不可用，可将鼠标停在原文上翻译。")
        }
    }

    override func layout() {
        super.layout()
        resizeImage()
    }

    private func resizeImage() {
        guard let image else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let pixels = CGSize(width: image.width, height: image.height)
        let fit = min(viewport.width / pixels.width, viewport.height / pixels.height)
        let layout = CanvasLayout(canvas: pixels, in: viewport, zoom: fit * zoom)
        let rect = CGRect(origin: layout.origin, size: layout.fitted)
        let size = CGSize(width: max(rect.width, viewport.width), height: max(rect.height, viewport.height))
        guard canvas.frame.size != size || imageView.frame != rect else { return }
        canvas.setFrameSize(size)
        imageView.frame = rect
        geometryDidChange()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        geometryDidChange()
    }

    // MARK: - 触控板捏合与滚轮缩放

    override func magnify(with event: NSEvent) {
        let next = min(5, max(0.5, zoom * (1 + event.magnification)))
        if abs(next - zoom) > 0.005 {
            zoom = next
            resizeImage()
            onZoomChange?(next)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && abs(event.scrollingDeltaY) > 0.01 {
            let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.08 : 1 / 1.08
            let next = min(5, max(0.5, zoom * factor))
            if abs(next - zoom) > 0.005 {
                zoom = next
                resizeImage()
                onZoomChange?(next)
            }
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: - 鼠标点击联动与放大拖拽平移

    override func mouseDown(with event: NSEvent) {
        let point = normalizedPoint(at: event.locationInWindow)
        if let block = blocks.first(where: { $0.normalizedBounds.contains(point) }) {
            onBlockClick?(block.id)
        }
        if zoom > 1.01, (showsOverlay || !overlay.hasInteractiveItem(at: overlay.convert(event.locationInWindow, from: nil))) {
            isPanning = true
            panOrigin = event.locationInWindow
            panClipOrigin = contentView.bounds.origin
            NSCursor.closedHand.push()
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            let current = event.locationInWindow
            let dx = current.x - panOrigin.x
            let dy = current.y - panOrigin.y
            let target = CGPoint(x: panClipOrigin.x - dx, y: panClipOrigin.y + dy)
            contentView.scroll(to: constrainedClipOrigin(target))
            reflectScrolledClipView(contentView)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            NSCursor.pop()
            return
        }
        super.mouseUp(with: event)
    }

    private func constrainedClipOrigin(_ point: CGPoint) -> CGPoint {
        let maxX = max(0, canvas.frame.width - contentView.bounds.width)
        let maxY = max(0, canvas.frame.height - contentView.bounds.height)
        return CGPoint(x: min(max(0, point.x), maxX), y: min(max(0, point.y), maxY))
    }

    private func geometryDidChange() {
        guard hovered != nil || selectionText != nil else { return }
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            if let text = selectionText, let point = selectionPoint {
                publishSelection(text, at: point)
            } else if let position = window?.mouseLocationOutsideOfEventStream {
                hover(at: position)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackedArea { removeTrackingArea(trackedArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        trackedArea = area
        addTrackingArea(area)
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseEntered(with event: NSEvent) { hover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { clearHover() }

    private func clearHover() {
        guard hovered != nil else { return }
        hovered = nil
        highlight.regions = []
        onHover(nil, .zero)
    }

    /// All callbacks use top-left points within the visible scroll viewport, not image pixels.
    private func viewportRect(_ rect: CGRect) -> CGRect {
        let visible = canvas.visibleRect
        return rect.offsetBy(dx: -visible.minX, dy: -visible.minY)
    }

    private func normalizedPoint(at windowLocation: CGPoint) -> CGPoint {
        let point = canvas.convert(windowLocation, from: nil)
        let frame = imageView.frame
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: 1 - (point.y - frame.minY) / frame.height)
    }

    private func publishSelection(_ text: String, at point: CGPoint) {
        let frame = imageView.frame
        let row = Self.selectedRow(for: text, near: point, imageSize: frame.size, lines: lines, sentences: sentences)
        let anchor = row.flatMap { OCRSourceViewport.region($0, in: frame) }
            ?? CGRect(x: frame.minX + min(max(point.x, 0), 1) * frame.width,
                      y: frame.minY + (1 - min(max(point.y, 0), 1)) * frame.height, width: 1, height: 1)
        let rect = viewportRect(anchor)
        guard text != selectionText || rect != selectionRect else { return }
        selectionText = text
        selectionPoint = point
        selectionRect = rect
        onSelection(text, rect)
    }

    // Live Text exposes the selected string but not its display rect. Match the OCR row so
    // the card can avoid the full original line even after a keyboard selection or scrolling.
    static func selectedRow(for text: String, near point: CGPoint, imageSize: CGSize,
                            lines: [OCRTextLine], sentences: [TranslationImageSentence]) -> CGRect? {
        func normalize(_ string: String) -> String {
            string.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let needle = normalize(text)
        guard !needle.isEmpty else { return nil }
        var matches = lines.filter { normalize($0.text).contains(needle) }
        if matches.isEmpty {
            let fragments = text.split(whereSeparator: \.isNewline).map { normalize(String($0)) }.filter { !$0.isEmpty }
            let regions = sentences.filter { normalize($0.text).contains(needle) }.flatMap(\.regions)
            matches = lines.filter { line in
                let row = normalize(line.text)
                return !row.isEmpty && (needle.contains(row) || fragments.contains(where: row.contains)
                    || regions.contains { $0.intersects(line.normalizedBounds) })
            }
        }
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, point.x - rect.maxX, 0) * imageSize.width
            let dy = max(rect.minY - point.y, point.y - rect.maxY, 0) * imageSize.height
            return dx * dx + dy * dy
        }
        return matches.map(\.normalizedBounds).filter { !$0.isEmpty }.min { distance($0) < distance($1) }
    }

    private func hover(at location: CGPoint) {
        guard hoverEnabled, !showsOverlay, (NSEvent.pressedMouseButtons & 1) == 0,
              selectionText == nil, !overlay.hasActiveTextSelection, !imageView.frame.isEmpty,
              canvas.visibleRect.contains(canvas.convert(location, from: nil)) else { clearHover(); return }
        let point = normalizedPoint(at: location)
        for sentence in sentences {
            guard let region = sentence.regions.first(where: { $0.contains(point) }),
                  let rect = OCRSourceViewport.region(region, in: imageView.frame) else { continue }
            let viewport = viewportRect(rect)
            if hovered?.text != sentence.text || hovered?.rect != viewport {
                hovered = (sentence.text, viewport)
                highlight.regions = sentence.regions
                onHover(sentence.text, viewport)
            }
            return
        }
        clearHover()
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        let begin = overlayView.hasInteractiveItem(at: point) || overlayView.hasActiveTextSelection
        if begin, NSEvent.pressedMouseButtons & 1 != 0 { clearHover() }
        return begin
    }

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            // Live Text can notify for every glyph during a drag. Read the committed range once.
            while NSEvent.pressedMouseButtons & 1 != 0 {
                do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            }
            guard !Task.isCancelled, let self, !imageView.frame.isEmpty else { return }
            let text = overlay.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                if selectionText != nil {
                    selectionText = nil
                    selectionPoint = nil
                    selectionRect = .null
                    onSelection(nil, .zero)
                }
                return
            }
            let location = window?.mouseLocationOutsideOfEventStream ?? .zero
            let point = normalizedPoint(at: location)
            clearHover()
            publishSelection(text, at: point)
        }
    }
}
