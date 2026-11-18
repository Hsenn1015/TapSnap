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
/// 用 SwiftUI 显示底图，绘制、选择、移动、缩放和裁剪由 NSView 覆盖层按文档坐标处理。
struct EditCanvasView: View {
    static let canvasPadding: CGFloat = 6

    @ObservedObject var controller: EditController
    @ObservedObject private var config: ConfigStore
    @ObservedObject private var privacy: PrivacyEditing
    @State private var openStyle: ActionKind?

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
                        controller.onLocatePrivacyFinding?(rect)
                    })
                }
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Self.canvasPadding)
                    .background(RGBAColor(rgb: theme.isDark ? 0x191b20 : 0xdde1e7).color)
                toolbar(theme, width: max(1, proxy.size.width - 16))
                    .frame(maxWidth: .infinity)
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

    @ViewBuilder private var canvas: some View {
        if controller.scrollsLongImage {
            LongShotEditorCanvas(controller: controller, onCanvasPress: { openStyle = nil })
        } else {
            fixedCanvas
        }
    }

    private var fixedCanvas: some View {
        GeometryReader { proxy in
            let layout = CanvasLayout(canvas: controller.document.canvasSize, in: proxy.size)
            ZStack {
                Image(decorative: controller.document.baseImage, scale: controller.document.scale)
                    .resizable()
                    .interpolation(.high)

                EditItemOverlay(
                    controller: controller,
                    displayScale: layout.scale,
                    revision: controller.revision,
                    onCanvasPress: { openStyle = nil }
                )
            }
            .frame(width: layout.fitted.width, height: layout.fitted.height)
            .clipped()
            .offset(x: layout.origin.x, y: layout.origin.y)
        }
    }
}

/// 复用长图预览的滚动画布和标注层，图和标注始终使用同一套坐标。
private struct LongShotEditorCanvas: NSViewRepresentable {
    @ObservedObject var controller: EditController
    let onCanvasPress: () -> Void

    func makeNSView(context: Context) -> LongShotEditorScrollView {
        let view = LongShotEditorScrollView(frame: .zero)
        view.canvas.image = controller.document.baseImage
        view.canvas.installEditor(controller, onCanvasPress: onCanvasPress)
        controller.onLocatePrivacyFinding = { [weak view] rect in view?.canvas.scrollToFinding(rect) }
        return view
    }

    func updateNSView(_ view: LongShotEditorScrollView, context: Context) {
        view.canvas.refreshEditor()
    }
}

private final class LongShotEditorScrollView: NSScrollView {
    let canvas = LongShotPreviewView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        borderType = .noBorder
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        drawsBackground = false
        documentView = canvas
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let image = canvas.image, contentSize.width > 0 else { return }
        let scale = contentSize.width / CGFloat(image.width)
        let size = CGSize(width: contentSize.width, height: CGFloat(image.height) * scale)
        guard canvas.frame.size != size else { return }
        let imageY = contentView.bounds.minY / canvas.displayScale
        canvas.displayScale = scale
        canvas.setFrameSize(size)
        contentView.scroll(to: CGPoint(x: 0, y: min(imageY * scale, max(0, size.height - contentSize.height))))
        reflectScrolledClipView(contentView)
        canvas.needsDisplay = true
        canvas.refreshEditor()
    }
}

/// 画布上「图片实际占多大、从哪开始」的换算。
struct CanvasLayout {
    let scale: CGFloat
    let origin: CGPoint
    let fitted: CGSize

    init(canvas: CGSize, in size: CGSize) {
        guard canvas.width > 0, canvas.height > 0, size.width > 0, size.height > 0 else {
            scale = 1
            origin = .zero
            fitted = .zero
            return
        }
        let factor = min(size.width / canvas.width, size.height / canvas.height)
        scale = factor
        fitted = CGSize(width: canvas.width * factor, height: canvas.height * factor)
        origin = CGPoint(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
    }

    /// 视图坐标 -> 文档坐标。
    func documentPoint(for point: CGPoint) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
}

struct EditItemOverlay: NSViewRepresentable {
    let controller: EditController
    let displayScale: CGFloat
    let revision: Int
    var onCanvasPress: () -> Void = {}

    func makeNSView(context: Context) -> EditItemLayerView {
        let view = EditItemLayerView()
        view.controller = controller
        view.onCanvasPress = onCanvasPress
        return view
    }

    func updateNSView(_ view: EditItemLayerView, context: Context) {
        view.controller = controller
        view.onCanvasPress = onCanvasPress
        view.displayScale = displayScale
        view.updateInteractionState()
        view.needsDisplay = true
        if controller.isCropping, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
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
        if event.clickCount == 2,
           let item = controller.document.item(at: point) as? TextItem {
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
        if let item = controller.document.item(at: point),
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
        let tolerance = 4 / max(displayScale, 0.1)
        for item in controller.document.items where item.hitTest(point, tolerance: tolerance) {
            controller.remove(item)
        }
    }

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
