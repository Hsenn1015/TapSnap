import AppKit
import TapSnapActionsBar
import TapSnapCore
import TapSnapConfig
import TapSnapPalette
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 编辑画布。
///
/// 滚动画布统一显示底图和标注，交互按文档坐标处理。
struct EditCanvasView: View {
    static let canvasPadding: CGFloat = 6
    private static let zoomControlsWidth: CGFloat = 94

    @ObservedObject var controller: EditController
    @ObservedObject private var config: ConfigStore
    @ObservedObject private var privacy: PrivacyEditing
    @State private var openStyle: ActionKind?
    @State private var zoomPercent = 100

    init(controller: EditController) {
        self.controller = controller
        self.config = controller.environment.config
        self.privacy = controller.privacy
    }

    var body: some View {
        let theme: Theme = config.settings.appearance.useDarkTheme ? .dark : .light
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if controller.isCropping {
                    Picker("裁剪比例", selection: $controller.cropAspect) {
                        ForEach(EditController.CropAspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).fixedSize().padding(.vertical, 3)
                }
                if privacy.phase != .idle {
                    PrivacyStatusView(controller: controller, privacy: privacy, theme: theme, locate: { rect in
                        controller.canvasViewport?.canvas.scrollToFinding(rect)
                    })
                }
                EditorCanvas(controller: controller, onCanvasPress: { openStyle = nil }, onZoom: { zoomPercent = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Self.canvasPadding)
                    .background(RGBAColor(rgb: theme.isDark ? 0x191b20 : 0xdde1e7).color)
                HStack(spacing: 0) {
                    toolbar(theme, width: max(1, proxy.size.width - Self.zoomControlsWidth - 8))
                        .frame(maxWidth: .infinity)
                    zoomControls(theme)
                }
                .padding(.trailing, 8)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.token(.foreground).opacity(0.12))
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Self.chromeColor(for: theme).color)
        .onChange(of: theme.isDark) { _, _ in controller.updateWindowAppearance() }
        .onChange(of: controller.selectedTool) { _, tool in
            if openStyle != tool { openStyle = nil }
        }
        .sheet(item: $controller.imageOutput) { request in
            EditorImageOutputView(controller: controller, request: request)
        }
    }

    private func toolbar(_ theme: Theme, width: CGFloat) -> some View {
        ActionsBarView(
            theme: theme,
            model: ActionsBarModel(overflow: [.exportImage, .combineImages] + ActionsBarModel.defaultOverflow),
            selectedTool: controller.activeItemKind.flatMap(EditItemFactory.action(for:)) ?? controller.selectedTool,
            canUndo: controller.canUndo,
            canRedo: controller.canRedo,
            openStyle: $openStyle,
            annotationOptions: { action in
                if action == .privacy {
                    return AnyView(PrivacyToolPanel(controller: controller, privacy: privacy))
                }
                return AnyView(EditStylePanel(controller: controller, theme: theme, action: action).id(action))
            },
            availableWidth: width,
            confirmationTitle: controller.reviewedAction?.title ?? "完成",
            isOutputBlocked: privacy.blocksOutput,
            toolTip: { ActionsBarModel().toolTip(for: $0, config: config) }
        ) { controller.perform($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标注工具栏")
        .accessibilityIdentifier("editor-toolbar")
    }

    static func chromeColor(for theme: Theme) -> RGBAColor {
        RGBAColor(rgb: theme.isDark ? 0x24262b : 0xeceef2)
    }

    private func zoomControls(_ theme: Theme) -> some View {
        let fitTitle = controller.scrollsLongImage ? "适合宽度" : "适合窗口"
        let percent = zoomPercent == 0 ? "<1%" : "\(zoomPercent)%"
        let step = EditorCanvasViewport.zoomStep
        return HStack(spacing: 0) {
            Button { controller.canvasViewport?.zoom(by: 1 / step) } label: {
                Image(systemName: "minus").frame(width: 24, height: 28)
            }
            .accessibilityLabel("缩小画布")
            .help(OperationShortcut.zoomOut.displayTitle(in: config.settings))
            Button { controller.canvasViewport?.fitImage() } label: {
                Text(percent)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 42, height: 28)
            }
            .accessibilityLabel(fitTitle)
            .accessibilityValue(percent)
            .help(OperationShortcut.fitImage.displayTitle(in: config.settings, title: fitTitle))
            Button { controller.canvasViewport?.zoom(by: step) } label: {
                Image(systemName: "plus").frame(width: 24, height: 28)
            }
            .accessibilityLabel("放大画布")
            .help(OperationShortcut.zoomIn.displayTitle(in: config.settings))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.token(.foreground))
        .frame(width: Self.zoomControlsWidth)
    }
}

private struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var controller: EditController
    let onCanvasPress: () -> Void
    let onZoom: (Int) -> Void

    func makeNSView(context: Context) -> EditorCanvasViewport {
        let view = EditorCanvasViewport(controller: controller, onCanvasPress: onCanvasPress)
        view.onZoom = { percent in
            // 布局也会改变适合窗口的比例，等这一轮 SwiftUI 更新完成后再更新按钮。
            DispatchQueue.main.async { onZoom(percent) }
        }
        controller.canvasViewport = view
        return view
    }

    func updateNSView(_ view: EditorCanvasViewport, context: Context) {
        view.canvas.refreshEditor()
    }
}

final class EditorCanvasViewport: NSScrollView {
    static let zoomStep: CGFloat = 1.25

    let canvas = LongShotPreviewView()
    var onZoom: ((Int) -> Void)?
    private let imageSize: CGSize
    private let imageScale: CGFloat
    private let fitsWidth: Bool
    private var layoutSize: CGSize = .zero
    private var imageLayout: CanvasLayout?
    private var manualScale: CGFloat?
    private var lastPercent: Int?

    init(controller: EditController, onCanvasPress: @escaping () -> Void) {
        imageSize = controller.document.canvasSize
        imageScale = controller.document.scale
        fitsWidth = controller.scrollsLongImage
        super.init(frame: .zero)
        borderType = .noBorder
        scrollerStyle = .overlay
        autohidesScrollers = true
        drawsBackground = false
        canvas.editorImageRect = .zero
        canvas.image = controller.document.baseImage
        canvas.installEditor(controller, onCanvasPress: onCanvasPress)
        documentView = canvas
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard contentView.bounds.size != layoutSize else { return }
        let oldAnchor = anchor(in: layoutSize, atTop: fitsWidth && manualScale == nil)
        let point = imageLayout?.documentPoint(for: offset(oldAnchor, by: contentView.bounds.origin))
        applyLayout(keeping: point, at: anchor(in: contentView.bounds.size, atTop: fitsWidth && manualScale == nil))
    }

    func zoom(by factor: CGFloat, at location: CGPoint? = nil) {
        layoutSubtreeIfNeeded()
        guard let imageLayout else { return }
        let fit = CanvasLayout(canvas: imageSize, in: layoutSize, fitsWidth: fitsWidth).scale
        let scale = min(max(8, fit), max(min(0.1, fit), imageLayout.scale * factor))
        guard scale != imageLayout.scale else { return }
        let target = location ?? anchor(in: layoutSize)
        let point = imageLayout.documentPoint(for: offset(target, by: contentView.bounds.origin))
        manualScale = scale
        applyLayout(keeping: point, at: target)
    }

    func fitImage() {
        let top = anchor(in: layoutSize, atTop: true)
        let point = fitsWidth ? imageLayout?.documentPoint(for: offset(top, by: contentView.bounds.origin)) : nil
        manualScale = nil
        applyLayout(keeping: point, at: top)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
        guard event.scrollingDeltaY != 0, event.momentumPhase.isEmpty else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 20 : event.scrollingDeltaY
        zoom(by: pow(Self.zoomStep, min(3, max(-3, step))), at: viewportPoint(for: event))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: viewportPoint(for: event))
    }

    private func viewportPoint(for event: NSEvent) -> CGPoint {
        let point = contentView.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
    }

    private func applyLayout(keeping point: CGPoint?, at target: CGPoint) {
        let size = contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        layoutSize = size
        let next = CanvasLayout(canvas: imageSize, in: size, zoom: manualScale, fitsWidth: fitsWidth)
        imageLayout = next
        canvas.displayScale = next.scale / imageScale
        canvas.editorImageRect = CGRect(origin: next.origin, size: next.fitted)
        let extent = CGSize(width: max(size.width, next.fitted.width), height: max(size.height, next.fitted.height))
        canvas.setFrameSize(extent)
        let scrollsHorizontally = extent.width > size.width + 0.01
        let scrollsVertically = extent.height > size.height + 0.01
        if hasHorizontalScroller != scrollsHorizontally { hasHorizontalScroller = scrollsHorizontally }
        if hasVerticalScroller != scrollsVertically { hasVerticalScroller = scrollsVertically }
        let proposed = point.map { CGPoint(x: next.origin.x + $0.x * next.scale - target.x,
                                          y: next.origin.y + $0.y * next.scale - target.y) } ?? .zero
        contentView.scroll(to: CGPoint(x: min(max(0, proposed.x), extent.width - size.width),
                                       y: min(max(0, proposed.y), extent.height - size.height)))
        reflectScrolledClipView(contentView)
        canvas.needsDisplay = true
        canvas.refreshEditor()
        let percent = Int((next.scale * 100).rounded())
        if percent != lastPercent {
            lastPercent = percent
            onZoom?(percent)
        }
    }

    private func anchor(in size: CGSize, atTop: Bool = false) -> CGPoint {
        CGPoint(x: size.width / 2, y: atTop ? 0 : size.height / 2)
    }

    private func offset(_ point: CGPoint, by origin: CGPoint) -> CGPoint {
        CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }
}

/// 画布上「图片实际占多大、从哪开始」的换算。
struct CanvasLayout {
    let scale: CGFloat
    let origin: CGPoint
    let fitted: CGSize

    init(canvas: CGSize, in size: CGSize, zoom: CGFloat? = nil, fitsWidth: Bool = false) {
        guard canvas.width > 0, canvas.height > 0, size.width > 0, size.height > 0 else {
            scale = 1
            origin = .zero
            fitted = .zero
            return
        }
        let widthFit = size.width / canvas.width
        let factor = zoom ?? (fitsWidth ? widthFit : min(widthFit, size.height / canvas.height))
        scale = factor
        fitted = CGSize(width: canvas.width * factor, height: canvas.height * factor)
        origin = CGPoint(x: max(0, (size.width - fitted.width) / 2),
                         y: fitsWidth ? 0 : max(0, (size.height - fitted.height) / 2))
    }

    /// 视图坐标 -> 文档坐标。
    func documentPoint(for point: CGPoint) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
}

/// 画标注、处理鼠标。
///
/// 坐标约定和 `EditDocument.render()` 完全一致：原点左上、y 向下、单位点。
final class EditItemLayerView: NSView {
    weak var controller: EditController?
    var onCanvasPress: (() -> Void)?
    var displayScale: CGFloat = 1
    var scrollsDuringDrag = false

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Mode {
        case idle
        case creating(kind: EditItemKind, start: CGPoint)
        case moving(item: any EditItem, start: CGPoint, original: CGRect)
        case resizing(item: any EditItem, handle: Handle, original: CGRect, originalTextWidth: CGFloat?)
        case cropping(start: CGPoint)
        case erasing
        case polygon
    }

    private var mode: Mode = .idle
    private var hoverPoint: CGPoint?
    private var sketchPoints: [CGPoint] = []
    private var polygonPoints: [CGPoint] = []
    private var creatingEnd: CGPoint = .zero
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var inlineTextEditor: InlineTextEditorView?
    private var inlineTextItemID: UUID?
    private var textClickMonitor: Any?
    private struct CursorState: Equatable {
        let tool: ActionKind?
        let cropping: Bool
        let style: EditItemStyle
        let scale: CGFloat
        let serialIndex: Int
        let serialFormat: SerialItem.Format
    }
    private var cursorState: CursorState?
    private(set) var annotationCursor: NSCursor = .arrow

    private static let handleSize: CGFloat = 7

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 一挂到窗口上就抢焦点，这样不用先点一下画布也能 ⌘Z / Delete。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        updateInteractionState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: annotationCursor)
    }

    /// 工具、颜色、缩放或撤销重做变化时，刷新当前序号光标，不修改文档。
    func updateInteractionState() {
        guard let controller else { return }
        synchronizeTextEditor()
        let state = CursorState(tool: controller.selectedTool, cropping: controller.isCropping,
                                style: controller.style, scale: displayScale,
                                serialIndex: controller.nextSerialIndex, serialFormat: controller.toolOptions.serialFormat)
        guard cursorState != state else { return }
        if cursorState?.tool != state.tool || cursorState?.cropping != state.cropping {
            cancelDraft()
        }
        cursorState = state
        if state.tool == .serialNumber, !state.cropping, state.scale > 0 {
            let side = 22 * state.scale
            let image = NSImage(size: CGSize(width: side, height: side), flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.saveGState()
                context.scaleBy(x: state.scale, y: state.scale)
                EditItemFactory.makeSerial(at: CGPoint(x: 11, y: 11), index: state.serialIndex,
                                           style: state.style, format: state.serialFormat).draw(in: context, scale: 1)
                context.restoreGState()
                return true
            }
            annotationCursor = NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
        } else if state.tool == .text, !state.cropping {
            annotationCursor = .iBeam
        } else {
            annotationCursor = state.tool?.isAnnotationTool == true || state.cropping ? .crosshair : .arrow
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func synchronizeTextEditor() {
        guard let controller else { return }
        guard let item = controller.textEditingItem else {
            removeTextEditor()
            return
        }
        let isNewEditor = inlineTextItemID != item.id
        if isNewEditor {
            removeTextEditor()
            let editor = InlineTextEditorView()
            editor.onTextChanged = { [weak self] text in
                guard let self else { return }
                self.controller?.updateEditingText(text)
                self.synchronizeTextEditor()
                self.needsDisplay = true
            }
            editor.onFinish = { [weak self] commit in self?.finishInlineText(commit: commit) }
            inlineTextEditor = editor
            inlineTextItemID = item.id
            addSubview(editor)
            controller.onFinishTextEditing = { [weak self, weak controller] commit in
                if let self, self.inlineTextEditor != nil { self.finishInlineText(commit: commit) }
                else { controller?.finishTextEditing(commit: commit) }
            }
            textClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let editor = self.inlineTextEditor, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                // The style button/popover may temporarily take focus while editing the same text.
                if self.bounds.contains(point), !editor.frame.contains(point) { self.finishInlineText(commit: true) }
                return event
            }
        }
        inlineTextEditor?.configure(item: item, displayScale: displayScale, initial: isNewEditor)
        if isNewEditor, let editor = inlineTextEditor { window?.makeFirstResponder(editor) }
    }

    private func finishInlineText(commit: Bool) {
        guard let controller else { return }
        guard let editor = inlineTextEditor else { controller.finishTextEditing(commit: commit); return }
        editor.finalizeComposition(commit: commit)
        controller.finishTextEditing(commit: commit)
        removeTextEditor()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func removeTextEditor() {
        if let textClickMonitor { NSEvent.removeMonitor(textClickMonitor) }
        textClickMonitor = nil
        if inlineTextEditor != nil { controller?.onFinishTextEditing = nil }
        inlineTextEditor?.removeFromSuperview()
        inlineTextEditor = nil
        inlineTextItemID = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeTextEditor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit { if let textClickMonitor { NSEvent.removeMonitor(textClickMonitor) } }

    private func cancelDraft() {
        if case .creating = mode { mode = .idle }
        if case .polygon = mode { mode = .idle }
        sketchPoints = []
        polygonPoints = []
        creatingEnd = .zero
        needsDisplay = true
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        onCanvasPress?()
        updateInteractionState()
        if inlineTextEditor != nil { finishInlineText(commit: true) }
        window?.makeFirstResponder(self)
        let point = docPoint(event)
        hoverPoint = point

        if controller.isCropping {
            mode = .cropping(start: point)
            return
        }
        if controller.selectedTool == .eraser {
            mode = .erasing
            erase(at: point)
            return
        }
        if controller.selectedTool == .polygon {
            if event.clickCount == 2 {
                finishPolygon()
                return
            }
            polygonPoints.append(point)
            mode = .polygon
            needsDisplay = true
            return
        }
        // 序号是连续盖章工具，鼠标上的下一序号应直接落点，不误拖已有图元。
        if controller.selectedTool == .serialNumber {
            controller.clearSelection()
            creatingEnd = point
            mode = .creating(kind: .serialNumber, start: point)
            needsDisplay = true
            return
        }
        let hit = controller.document.item(at: point, tolerance: hitTolerance)
        if event.clickCount == 2, let item = hit as? TextItem {
            controller.beginTextEditing(item, isNew: false)
            synchronizeTextEditor()
            return
        }
        if let selected = controller.document.selectedItem,
           controller.document.canResizeSelectedItem,
           let handle = handleHit(at: point, in: selected.bounds) {
            mode = .resizing(item: selected, handle: handle, original: selected.bounds,
                             originalTextWidth: (selected as? TextItem)?.textContainerWidth)
            needsDisplay = true
            return
        }
        if let item = hit,
           controller.selectedTool != .privacy || item.kind == .privacy {
            controller.select(item)
            mode = .moving(item: item, start: point, original: item.bounds)
            needsDisplay = true
            return
        }
        if let tool = controller.selectedTool,
           let kind = EditItemFactory.itemKind(for: tool) {
            controller.clearSelection()
            sketchPoints = [point]
            creatingEnd = point
            mode = .creating(kind: kind, start: point)
            needsDisplay = true
            return
        }
        controller.clearSelection()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return }
        if scrollsDuringDrag { _ = autoscroll(with: event) }
        let point = docPoint(event)
        hoverPoint = point

        switch mode {
        case .creating(let kind, _):
            if kind.usesSketchPoints {
                if sketchPoints.last != point { sketchPoints.append(point) }
            } else {
                creatingEnd = point
            }
        case .moving(let item, let start, let original):
            let dx = point.x - start.x
            let dy = point.y - start.y
            item.bounds = original.offsetBy(dx: dx, dy: dy)
            controller.noteDocumentChanged()
        case .resizing(let item, let handle, let original, _):
            item.bounds = Self.resized(original, handle: handle, to: point)
            if let text = item as? TextItem, item.bounds.width != original.width {
                let width = max(24, item.bounds.width)
                text.fitToText(maxWidth: width)
                text.bounds.size.width = width
            }
            controller.noteDocumentChanged()
        case .cropping(let start):
            let area = Self.rect(from: start, to: point).intersection(CGRect(origin: .zero, size: controller.document.canvasSize))
            let rect = area.isEmpty ? .zero : controller.cropAspect.fit(area, anchoredAt: start)
            controller.updateCropRect(rect.width > 4 && rect.height > 4 ? rect : nil)
        case .erasing:
            erase(at: point)
        case .polygon:
            break
        case .idle:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        defer {
            mode = .idle
            sketchPoints = []
            needsDisplay = true
            updateInteractionState()
        }

        switch mode {
        case .creating(let kind, let start):
            let end = docPoint(event)
            creatingEnd = end
            if kind == .privacy, start.distance(to: end) <= 2,
               let finding = controller.privacySuggestions.last(where: { controller.documentRect(for: $0).contains(end) }) {
                controller.applyPrivacySuggestion(finding.id)
                return
            }
            if kind.usesSketchPoints, sketchPoints.last != end { sketchPoints.append(end) }
            guard acceptsClick(kind) || start.distance(to: end) > 2 || sketchPoints.count > 2 else { return }

            let item = makeCreationItem(kind: kind, start: start, end: end)
            if let item {
                if let mosaic = item as? MosaicItem {
                    mosaic.autoDetect = controller.mosaicAutoDetect || controller.mosaicDetectText
                }
                controller.add(item)
            }
        case .moving(let item, _, let original):
            controller.registerBoundsUndo(for: item, original: original)
        case .resizing(let item, _, let original, let originalTextWidth):
            controller.registerBoundsUndo(for: item, original: original, originalTextWidth: originalTextWidth)
        case .cropping, .erasing, .polygon, .idle:
            break
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = docPoint(event)
        if !polygonPoints.isEmpty { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        if !polygonPoints.isEmpty { needsDisplay = true }
    }

    private func acceptsClick(_ kind: EditItemKind) -> Bool {
        [.serialNumber, .text, .magnifier, .watermark, .highlight].contains(kind)
    }

    private func makeCreationItem(kind: EditItemKind, start: CGPoint, end: CGPoint) -> (any EditItem)? {
        guard let controller else { return nil }
        switch kind {
        case .pen: return PenItem(points: sketchPoints, style: controller.style)
        case .pathTag: return PathTagItem(points: sketchPoints, style: controller.style)
        case .highlight: return HighlightItem(points: sketchPoints, style: controller.style)
        case .text:
            guard let text = EditItemFactory.make(kind: .text, from: start, to: end,
                style: controller.style, options: controller.toolOptions) as? TextItem else { return nil }
            let rect = Self.rect(from: start, to: end)
            if rect.width >= 24 {
                text.bounds = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(24, rect.height))
                text.textContainerWidth = rect.width
            }
            return text
        case .serialNumber:
            return EditItemFactory.makeSerial(at: end, index: controller.nextSerialIndex, style: controller.style, format: controller.toolOptions.serialFormat)
        case .privacy:
            let clipped = Self.rect(from: start, to: end)
                .intersection(CGRect(origin: .zero, size: controller.document.canvasSize))
            guard !clipped.isNull else { return nil }
            return EditItemFactory.make(kind: kind, from: clipped.origin, to: CGPoint(x: clipped.maxX, y: clipped.maxY),
                                        style: controller.style, options: controller.toolOptions)
        default: return EditItemFactory.make(kind: kind, from: start, to: end, style: controller.style, options: controller.toolOptions)
        }
    }

    /// 橡皮：擦掉指针下的图元（可撤销）。
    private func erase(at point: CGPoint) {
        guard let controller else { return }
        for item in controller.document.items where item.hitTest(point, tolerance: hitTolerance) {
            controller.remove(item)
        }
    }

    private var hitTolerance: CGFloat { 4 / max(displayScale, 0.1) }

    /// 多边形：⌘ 双击或 ⏎ 闭合。
    private func finishPolygon() {
        guard let controller else { return }
        let points = polygonPoints
        polygonPoints = []
        mode = .idle
        needsDisplay = true
        guard points.count >= 3 else { return }
        controller.add(PolygonItem(points: points, style: controller.style))
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }

        if controller.handleKeyEvent(event) { return }
        switch event.keyCode {
        case 51, 117:
            if !polygonPoints.isEmpty {
                polygonPoints.removeLast()
                needsDisplay = true
            }
        case 53: // Esc
            if case .creating = mode {
                cancelDraft()
            } else if !polygonPoints.isEmpty {
                cancelDraft()
            } else if controller.isCropping {
                controller.updateCropRect(nil)
                controller.toggleCrop()
            } else {
                controller.cancelFromCanvas()
            }
        case 36, 76: // Return
            if controller.isCropping {
                controller.toggleCrop()
            } else if !polygonPoints.isEmpty {
                finishPolygon()
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let controller,
              let context = NSGraphicsContext.current?.cgContext,
              displayScale > 0
        else { return }

        let document = controller.document
        context.saveGState()
        context.scaleBy(x: displayScale, y: displayScale)

        let dirty = dirtyRect.applying(CGAffineTransform(scaleX: 1 / displayScale, y: 1 / displayScale))
        document.drawItems(in: context, excluding: controller.textEditingItem?.id, dirtyRect: dirty)
        drawPrivacySuggestions(controller, context: context, dirtyRect: dirty)

        if let selected = document.selectedItem, selected.id != controller.textEditingItem?.id {
            drawSelection(selected, context: context, resizable: document.canResizeSelectedItem)
        }
        drawCreationPreview(context)
        drawPolygonPreview(context)
        drawCrop(context)

        context.restoreGState()
    }

    private func drawPrivacySuggestions(_ controller: EditController, context: CGContext, dirtyRect: CGRect) {
        context.saveGState()
        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineDash(phase: 0, lengths: [4 / displayScale, 3 / displayScale])
        for finding in controller.privacySuggestions {
            let rect = controller.documentRect(for: finding)
            guard rect.intersects(dirtyRect) else { continue }
            let focused = controller.privacy.focusedID == finding.id
            context.stroke(rect, width: (focused ? 2.5 : 1) / displayScale)
        }
        context.restoreGState()
    }

    private func drawSelection(_ item: any EditItem, context: CGContext, resizable: Bool) {
        let bounds = item.bounds
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1 / displayScale)
        context.setLineDash(phase: 0, lengths: [4 / displayScale, 3 / displayScale])
        context.stroke(bounds)
        context.setLineDash(phase: 0, lengths: [])

        guard resizable, let controller, !controller.isCropping else { return }
        context.setFillColor(NSColor.white.cgColor)
        for (_, rect) in handleRects(for: bounds) {
            context.fill(rect)
            context.stroke(rect)
        }
    }

    private func drawCreationPreview(_ context: CGContext) {
        guard case .creating(let kind, let start) = mode else { return }
        // 序号由带数字的鼠标图标预览，避免与半透明草稿重复叠色。
        guard kind != .serialNumber else { return }
        let end = kind.usesSketchPoints ? (sketchPoints.last ?? start) : creatingEnd
        guard acceptsClick(kind) || start.distance(to: end) > 2 || sketchPoints.count > 2,
              let item = makeCreationItem(kind: kind, start: start, end: end) else { return }
        drawPreview(item, in: context)
    }

    private func drawPreview(_ item: any EditItem, in context: CGContext) {
        guard let document = controller?.document else { return }
        context.saveGState()
        context.beginPath()
        context.setLineDash(phase: 0, lengths: [])
        if let mask = item.privacyMask {
            mask.prepareBackground(source: document.baseImage, scale: document.scale, excluding: document.privacyPixelBounds)
            mask.draw(in: context, scale: document.scale)
            context.restoreGState()
            return
        }
        if item is MagnifierItem || item is MosaicItem {
            guard let image = try? document.sourceForEffects() else {
                context.restoreGState()
                return
            }
            item.prepare(source: image, scale: document.scale)
        } else {
            item.prepare(source: document.baseImage, scale: document.scale)
        }
        item.draw(in: context, scale: document.scale)
        context.restoreGState()
    }

    /// 多边形逐点连线预览；有已落的点和正在悬停的位置。
    private func drawPolygonPreview(_ context: CGContext) {
        guard !polygonPoints.isEmpty, let controller else { return }
        var points = polygonPoints
        if let hoverPoint, hoverPoint != points.last { points.append(hoverPoint) }
        if points.count >= 3 {
            drawPreview(PolygonItem(points: points, style: controller.style), in: context)
        } else if points.count == 2 {
            drawPreview(LineItem(start: points[0], end: points[1], style: controller.style), in: context)
        }
        context.saveGState()
        context.setFillColor(controller.style.resolvedColor)
        let radius = 3 / max(displayScale, 0.1)
        for point in polygonPoints {
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        context.restoreGState()
    }

    private func drawCrop(_ context: CGContext) {
        guard let controller else { return }

        // 没在裁剪模式但设了裁剪框：只描个虚边，提醒导出会按它裁。
        guard controller.isCropping else {
            guard let crop = controller.document.cropRect else { return }
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1 / displayScale)
            context.setLineDash(phase: 0, lengths: [4 / displayScale, 3 / displayScale])
            context.stroke(crop)
            context.restoreGState()
            return
        }
        let canvas = controller.document.canvasSize.asRect

        if let crop = controller.document.cropRect {
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            // 四个方向压暗，中间留空。
            for rect in [
                CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: crop.minY - canvas.minY),
                CGRect(x: canvas.minX, y: crop.maxY, width: canvas.width, height: canvas.maxY - crop.maxY),
                CGRect(x: canvas.minX, y: crop.minY, width: crop.minX - canvas.minX, height: crop.height),
                CGRect(x: crop.maxX, y: crop.minY, width: canvas.maxX - crop.maxX, height: crop.height),
            ] where rect.width > 0 && rect.height > 0 {
                context.fill(rect)
            }
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5 / displayScale)
            context.stroke(crop)

            let hint = AnnotateDrawing.attributedText(
                "按 ⏎ 应用裁剪",
                fontSize: 11 / displayScale,
                color: NSColor.white.cgColor
            )
            AnnotateDrawing.drawCentered(
                hint,
                in: CGRect(x: crop.midX - 70, y: crop.maxY + 4 / displayScale, width: 140, height: 16 / displayScale),
                context: context
            )
        }
    }

    // MARK: - 坐标与几何

    private func docPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        guard displayScale > 0 else { return point }
        return CGPoint(x: point.x / displayScale, y: point.y / displayScale)
    }

    private func handleRects(for rect: CGRect) -> [(Handle, CGRect)] {
        let size = Self.handleSize / max(displayScale, 0.1)
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
        }
        // y 向下：视觉上的「上」是 minY。
        return [
            (.topLeft, box(rect.minX, rect.minY)),
            (.top, box(rect.midX, rect.minY)),
            (.topRight, box(rect.maxX, rect.minY)),
            (.right, box(rect.maxX, rect.midY)),
            (.bottomRight, box(rect.maxX, rect.maxY)),
            (.bottom, box(rect.midX, rect.maxY)),
            (.bottomLeft, box(rect.minX, rect.maxY)),
            (.left, box(rect.minX, rect.midY)),
        ]
    }

    private func handleHit(at point: CGPoint, in rect: CGRect) -> Handle? {
        handleRects(for: rect)
            .first { $0.1.insetBy(dx: -4 / displayScale, dy: -4 / displayScale).contains(point) }?
            .0
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }
}
