import AppKit
import CoreText
import Foundation
import SwiftUI
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapScreen
import TapSnapTheme

/// 截图覆盖层的老式无边框面板。
///
/// 每块屏幕有一个全屏覆盖窗口，显示冻结画面并接收选区交互。
final class SelectionOverlayWindow: NSPanel {
    init(screen: ScreenDescriptor) {
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let frame = screen.appKitFrame(primaryDisplayHeight: desktopTop)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        // 覆盖层铺在别人的窗口上，App 失活也不能收起来。
        hidesOnDeactivate = false
        // 让覆盖层本身不被截进图里。
        sharingType = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { (contentView as? SelectionOverlayView)?.hideQuickToolbarTip() }
        super.sendEvent(event)
    }
}

/// 覆盖层上的交互视图。
///
/// 拖出选区后**不立刻结束**，而是留下八个手柄可以微调，按 ⏎ 或双击确认、
/// ⎋ 取消。普通截图入口还会在选区旁显示输出和标注操作。
final class SelectionOverlayView: NSView {
    /// 确认/取消时回调，nil 表示取消。
    var onFinish: ((CGRect?) -> Void)?
    /// 仅截图编辑入口提供这些回调，其他框选用途仍然只有确认/取消。
    var onCopy: ((CGRect) -> Void)? { didSet { updateBar() } }
    var onLongShot: ((CGRect) -> Void)? { didSet { updateBar() } }
    var onRecord: ((CGRect) -> Void)? { didSet { updateBar() } }
    var onQuickAction: ((ActionKind, CGRect) -> Void)? { didSet { updateBar() } }
    var desktopDragBounds: CGRect?
    var selectionScale: CGFloat?
    var onSelectionChange: ((CGRect?, CGPoint, Bool) -> Void)?
    private var receivingSelection = false
    private var displaysToolbar = true
    private var dragBounds: CGRect { desktopDragBounds ?? bounds }
    var quickToolbarTheme: Theme = .dark { didSet { updateBar() } }
    var quickToolbarToolTip: (ActionKind) -> String = { $0.title } { didSet { hideQuickToolbarTip() } }
    var quickConfirmationCopies = true { didSet { updateBar() } }
    var confirmationTitle = "确认 ⏎" { didSet { updateBar() } }

    /// 该屏的冻结截图，铺在压暗层下面。
    var screenImage: CGImage? { didSet { updateBar() } }

    /// 后台检测出来的界面元素框（视图坐标）。
    var snapRegions: [SelectionSnapRegion] = [] { didSet { refreshSnapPreview() } }
    var accessibilitySnapLookup: (@Sendable (CGPoint) -> CGRect?)?
    /// 窗口模式使用系统给出的前后顺序，不能按面积选到后方窗口。
    var windowRegions: [CGRect] = []
    var selectsWindows = false { didSet { borderView.showsResizeHandles = !selectsWindows } }
    private var lockedWindowSelection = false
    private var mouseTracking: NSTrackingArea?
    private var snapPointer: CGPoint?
    private var accessibilitySnap: CGRect?
    private var snapLookupPoint: CGPoint?
    private var snapLookupTask: Task<Void, Never>?
    private(set) var snapPreview: CGRect? { didSet { if oldValue != snapPreview { needsDisplay = true } } }
    private var pressedSnap: CGRect?

    var showsMagnifier = true
    var showsSizeLabel = true { didSet { updateBar() } }
    var borderStyle: SelectionBorderStyle {
        get { borderView.style }
        set { borderView.style = newValue }
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Mode {
        case idle
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, rect: CGRect)
        case resizing(handle: Handle, rect: CGRect)
    }

    enum BarButton: Hashable { case confirm, cancel, copy, longShot, record }

    private var mode: Mode = .idle { didSet { updateBar() } }
    private var selection: CGRect? {
        didSet {
            borderView.selectionRect = selection
            updateBar()
            if !receivingSelection { onSelectionChange?(selection, cursor, isDragging) }
        }
    }
    private var cursor: CGPoint = .zero

    func synchronizeSelection(_ rect: CGRect?, showToolbar: Bool) {
        receivingSelection = true
        displaysToolbar = showToolbar
        if selection != rect { selection = rect } else { updateBar() }
        receivingSelection = false
        needsDisplay = true
    }
    private var dragDistance: CGFloat = 0
    private let borderView = SelectionBorderView(frame: .zero)
    private let controlsView = SelectionControlsView(frame: .zero)
    private let actionBar = SelectionActionBar(frame: .zero)
    private var editorDock: SelectionEditorDockHost?
    private var editorDockActions: ActionsBarLayout?
    private let editorDockTip = SelectionEditorDockTip(frame: .zero)
    private var hoveredEditorButton: EditorDockHover?
    private var editorHoverTip: DispatchWorkItem?

    private struct EditorDockHover: Equatable {
        let title: String
        let button: CGRect
        let toolbar: CGRect
    }

    private static let captureModes: [ActionKind] = [.longShot, .record]
    private static let dockModel = ActionsBarModel(outputActions: captureModes + ActionsBarModel.defaultOutputActions)
    private static let copyConfirmationDockModel = ActionsBarModel(
        outputActions: captureModes + [.edit] + ActionsBarModel.defaultOutputActions.filter { $0 != .copy }
    )
    private static let dockPriority: Set<ActionKind> = [.copy, .edit, .pin, .save]
    private var pressedBarButton: BarButton?
    private var hoveredBarButton: BarButton?
    private var hoverTip: DispatchWorkItem?
    private var pendingAction: BarButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        borderView.showsResizeHandles = true
        controlsView.owner = self
        actionBar.isHidden = true
        for child in [borderView, controlsView] {
            child.wantsLayer = true
            child.frame = bounds
            child.autoresizingMask = [.width, .height]
            addSubview(child)
        }
        addSubview(actionBar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stopBorderAnimation() {
        clearSnapPreview()
        hoverTip?.cancel()
        hoverTip = nil
        hideQuickToolbarTip()
        borderView.stopAnimating()
    }

    private static let magnifierSize: CGFloat = 120
    /// 放大镜里显示光标周围多少点。
    private static let magnifierSample: CGFloat = 24

    override var acceptsFirstResponder: Bool { true }
    // 快捷键唤起时应用可能仍在后台，第一次按下就应开始框选。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        updateBar()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseTracking = area
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard pendingAction == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let editorDock, !editorDock.isHidden, editorDock.frame.contains(point) {
            let hover = editorDockHover(at: point)
            setEditorDockHover(hover)
            if window?.isVisible == true { (hover == nil ? NSCursor.arrow : .pointingHand).set() }
            return
        }
        hideQuickToolbarTip()
        setBarHover(barButton(at: point))
        if !selectsWindows {
            previewSnap(at: point)
            return
        }
        guard !lockedWindowSelection else { return }
        if barLayout()?.background.contains(point) == true { return }
        selection = Self.windowRegion(at: point, regions: windowRegions, bounds: bounds)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        clearSnapPreview()
        hideQuickToolbarTip()
        setBarHover(nil)
        NSCursor.arrow.set()
    }

    static func windowRegion(at point: CGPoint, regions: [CGRect], bounds: CGRect) -> CGRect? {
        guard let region = regions.first(where: { $0.contains(point) }) else { return nil }
        let clipped = region.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    func previewSnap(at point: CGPoint) {
        guard !selectsWindows, selection == nil, !isDragging, bounds.contains(point) else {
            clearSnapPreview()
            return
        }
        snapPointer = point
        if accessibilitySnap?.contains(point) != true { accessibilitySnap = nil }
        refreshSnapPreview()
        guard accessibilitySnap == nil, let lookup = accessibilitySnapLookup,
              snapLookupPoint.map({ $0.distance(to: point) > 3 }) ?? true else { return }

        snapLookupPoint = point
        snapLookupTask?.cancel()
        snapLookupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { lookup(point) }.value
            guard !Task.isCancelled, let self, let pointer = self.snapPointer,
                  let frame = result, frame.contains(pointer) else { return }
            self.accessibilitySnap = frame
            self.refreshSnapPreview()
        }
    }

    private func refreshSnapPreview() {
        guard let point = snapPointer else { return }
        snapPreview = accessibilitySnap ?? snapTarget(at: point)
    }

    private func snapTarget(at point: CGPoint) -> CGRect? {
        SelectionSnap.target(at: point, in: bounds, windows: windowRegions, detected: snapRegions)
    }

    private func clearSnapPreview() {
        snapLookupTask?.cancel()
        snapLookupTask = nil
        snapLookupPoint = nil
        snapPointer = nil
        accessibilitySnap = nil
        snapPreview = nil
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        guard pendingAction == nil else { return }
        hideQuickToolbarTip()
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        dragDistance = 0

        if let action = barButton(at: point) {
            pressedBarButton = action
            setBarHover(action, showsTip: false)
            updateBarFeedback()
            return
        }
        // 工具栏的留白也不能穿透并开始一个新选区。
        if barLayout()?.background.contains(point) == true || quickToolbarLayout()?.background.contains(point) == true { return }
        if event.clickCount == 2, let selection, selection.contains(point) {
            performBarAction(.confirm)
            return
        }
        if selectsWindows {
            selection = Self.windowRegion(at: point, regions: windowRegions, bounds: bounds)
            lockedWindowSelection = selection != nil
            updateBar()
            needsDisplay = true
            return
        }
        if let selection {
            if let handle = handleHit(at: point, in: selection) {
                mode = .resizing(handle: handle, rect: selection)
                needsDisplay = true
                return
            }
            if SelectionBorderView.outlineRect(for: selection, in: bounds).contains(point) {
                mode = .moving(start: point, rect: selection)
                needsDisplay = true
                return
            }
        }

        // 锁住按下时看到的范围，后台识别结果不会在松手前改掉目标。
        pressedSnap = snapPreview.flatMap { $0.contains(point) ? $0 : nil } ?? snapTarget(at: point)
        clearSnapPreview()
        mode = .creating(anchor: point)
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard pendingAction == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if pressedBarButton != nil {
            setBarHover(barButton(at: point), showsTip: false)
            return
        }
        guard !selectsWindows else { return }
        cursor = point
        dragDistance = max(dragDistance, point.distance(to: startPoint(of: mode) ?? point))

        switch mode {
        case .creating(let anchor):
            selection = Self.rect(from: anchor, to: point).intersection(dragBounds)
        case .moving(let start, let rect):
            selection = Self.clamp(rect.offsetBy(dx: point.x - start.x, dy: point.y - start.y), to: dragBounds)
        case .resizing(let handle, let rect):
            let outline = SelectionBorderView.outlineRect(for: rect, in: bounds)
            var edgePoint = point
            switch handle {
            case .topLeft, .left, .bottomLeft: edgePoint.x += rect.minX - outline.minX
            case .topRight, .right, .bottomRight: edgePoint.x -= outline.maxX - rect.maxX
            default: break
            }
            switch handle {
            case .topLeft, .top, .topRight: edgePoint.y -= outline.maxY - rect.maxY
            case .bottomLeft, .bottom, .bottomRight: edgePoint.y += rect.minY - outline.minY
            default: break
            }
            selection = Self.clamp(Self.resized(rect, handle: handle, to: edgePoint), to: dragBounds)
        case .idle:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pendingAction == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if let pressed = pressedBarButton {
            pressedBarButton = nil
            if barButton(at: point) == pressed {
                performBarAction(pressed)
            } else {
                setBarHover(barButton(at: point))
                updateBarFeedback()
            }
            return
        }
        guard !selectsWindows else { return }
        if case .creating(let anchor) = mode {
            if max(dragDistance, anchor.distance(to: point)) < 4 {
                selection = pressedSnap
            } else {
                let rect = Self.rect(from: anchor, to: point).intersection(dragBounds)
                selection = rect.width >= 2 && rect.height >= 2 ? rect : nil
            }
            pressedSnap = nil
        }
        mode = .idle
        onSelectionChange?(selection, cursor, false)
        setBarHover(barButton(at: point))
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCopyShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard pendingAction == nil else { return }
        if handleCopyShortcut(event) { return }
        switch event.keyCode {
        case 53: // Esc
            performBarAction(.cancel)
        case 36, 76: // Return / Enter
            if !isDragging {
                if selection == nil { onFinish?(nil) }
                else { performBarAction(.confirm) }
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func handleCopyShortcut(_ event: NSEvent) -> Bool {
        guard onQuickAction != nil || onCopy != nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
        if onQuickAction != nil {
            performQuickAction(.copy)
        } else if barLayout()?.buttons.contains(where: { $0.action == .copy }) == true {
            performBarAction(.copy)
        }
        return true
    }

    private func performBarAction(_ action: BarButton) {
        guard pendingAction == nil else { return }
        if action == .cancel {
            onFinish?(nil)
            return
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        if window?.isVisible == true {
            pendingAction = action
            pressedBarButton = nil
            setBarHover(nil, showsTip: false)
            updateBarFeedback()
            if onQuickAction != nil { updateBar() }
        }
        switch action {
        case .confirm: onFinish?(selection)
        case .copy: onCopy?(selection)
        case .longShot: onLongShot?(selection)
        case .record: onRecord?(selection)
        case .cancel: break
        }
    }

    func performQuickAction(_ action: ActionKind) {
        guard pendingAction == nil, let onQuickAction, let selection, !isDragging,
              quickToolbarLayout() != nil || (action == .copy && !displaysToolbar) else { return }
        switch action {
        case .cancel: performBarAction(.cancel)
        case .confirm where !quickConfirmationCopies: performBarAction(.confirm)
        case .undo, .redo: return
        default:
            if window?.isVisible == true {
                pendingAction = .confirm
                updateBar()
            }
            onQuickAction(action == .confirm ? .copy : action, selection)
        }
    }

    private func startPoint(of mode: Mode) -> CGPoint? {
        switch mode {
        case .creating(let anchor): return anchor
        case .moving(let start, _): return start
        case .resizing: return nil
        case .idle: return nil
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        controlsView.needsDisplay = true

        if let screenImage {
            context.interpolationQuality = .high
            context.draw(screenImage, in: bounds)
        }

        // 全屏压暗，选区内挖空。
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(bounds)

        guard let visible = selection ?? snapPreview, visible.width > 0, visible.height > 0 else { return }

        context.setBlendMode(.clear)
        context.fill(visible)
        context.setBlendMode(.normal)
        if selection == nil {
            context.setStrokeColor(NSColor(quickToolbarTheme.highlight).cgColor)
            context.stroke(visible.insetBy(dx: 1, dy: 1), width: 2)
        }
    }

    fileprivate func drawControls(in context: CGContext) {
        guard let selection, selection.width > 0, selection.height > 0 else {
            if isDragging { drawMagnifier(in: context, at: cursor) }
            return
        }

        if showsSizeLabel, selection.intersects(bounds) {
            sizeLabel(selection, context: context)
        }
        if isDragging {
            drawMagnifier(in: context, at: cursor)
        }
    }

    private var isDragging: Bool {
        if case .idle = mode { return false }
        return true
    }

    /// 在 y 向上的视图坐标里画一行文字，返回它占的尺寸。
    ///
    /// 不用 `NSAttributedString.size()/draw(at:)`：那条路走 AppKit 的字体桥接，
    /// 在覆盖层这种非激活窗口的绘制上下文里会往字典里塞 nil 字体直接崩。
    /// 统一走 CoreText，和编辑器里那条画字路径保持一致。
    @discardableResult
    private func drawText(
        _ text: String,
        at origin: CGPoint,
        fontSize: CGFloat,
        color: NSColor,
        context: CGContext
    ) -> CGSize {
        let attributed = AnnotateDrawing.attributedText(
            text,
            fontSize: fontSize,
            color: color.cgColor,
            bold: false
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.saveGState()
        context.textPosition = CGPoint(x: origin.x - bounds.minX, y: origin.y - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private func sizeLabel(_ selection: CGRect, context: CGContext) {
        guard let image = screenImage else { return }
        let scale = selectionScale ?? CGFloat(image.width) / max(1, bounds.width)
        let text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        let measured = measure(text, fontSize: 11, color: .white)
        let outline = SelectionBorderView.outlineRect(for: selection, in: bounds)

        let origin = CGPoint(
            x: min(max(8, outline.minX), bounds.maxX - measured.width - 8),
            y: min(outline.maxY + 6, bounds.maxY - measured.height - 6)
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(
            roundedRect: CGRect(
                x: origin.x - 4,
                y: origin.y - 2,
                width: measured.width + 8,
                height: measured.height + 4
            ),
            xRadius: 4,
            yRadius: 4
        ).fill()
        drawText(text, at: origin, fontSize: 11, color: .white, context: context)
    }

    private func measure(_ text: String, fontSize: CGFloat, color: NSColor) -> CGSize {
        let attributed = AnnotateDrawing.attributedText(
            text,
            fontSize: fontSize,
            color: color.cgColor,
            bold: false
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(width: bounds.width, height: bounds.height)
    }

    /// 光标跟随的放大镜：取光标周围一小块放大，顺带显示像素颜色。
    private func drawMagnifier(in context: CGContext, at point: CGPoint) {
        guard showsMagnifier, let image = screenImage else { return }

        let side = Self.magnifierSize
        var origin = CGPoint(x: point.x + 24, y: point.y - side - 24)
        if origin.x + side > bounds.maxX - 8 { origin.x = point.x - side - 24 }
        if origin.x < 8 { origin.x = 8 }
        if origin.y < 8 { origin.y = point.y + 24 }
        if origin.y + side > bounds.maxY - 8 { origin.y = bounds.maxY - side - 8 }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))

        let scale = CGFloat(image.width) / max(1, bounds.width)
        let samplePixels = Self.magnifierSample * scale
        let sourceRect = CGRect(
            x: point.x * scale - samplePixels / 2,
            y: (bounds.height - point.y) * scale - samplePixels / 2,
            width: samplePixels,
            height: samplePixels
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        if let crop = image.cropping(to: sourceRect.intersection(imageBounds)) {
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(crop, in: box)
            context.restoreGState()
        }

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.stroke(box)
        // 十字线
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
        context.stroke(CGRect(x: box.midX, y: box.minY, width: 0, height: box.height))
        context.stroke(CGRect(x: box.minX, y: box.midY, width: box.width, height: 0))

        if let color = pixelColor(at: point) {
            drawHexLabel(color.hex, below: box, context: context)
        }
    }

    private func drawHexLabel(_ hex: String, below box: CGRect, context: CGContext) {
        let measured = measure(hex, fontSize: 10, color: .white)
        let origin = CGPoint(
            x: min(max(8, box.midX - measured.width / 2), bounds.maxX - measured.width - 12),
            y: max(8, box.minY - measured.height - 6)
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(
            roundedRect: CGRect(
                x: origin.x - 4,
                y: origin.y - 2,
                width: measured.width + 8,
                height: measured.height + 4
            ),
            xRadius: 3,
            yRadius: 3
        ).fill()
        drawText(hex, at: origin, fontSize: 10, color: .white, context: context)
    }

    // MARK: - 布局与命中

    private var barBounds: CGRect {
        guard onQuickAction != nil, let window, let screen = window.screen else { return bounds }
        let visible = convert(window.convertFromScreen(screen.visibleFrame), from: nil).intersection(bounds)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }

    func quickToolbarLayout() -> (background: CGRect, actions: ActionsBarLayout)? {
        guard displaysToolbar, onQuickAction != nil, !isDragging, (!selectsWindows || lockedWindowSelection),
              let selected = selection, selected.width >= 1, selected.height >= 1 else { return nil }
        let selection = SelectionBorderView.outlineRect(for: selected, in: bounds).intersection(bounds)
        let area = barBounds.insetBy(dx: 8, dy: 8)
        let thickness = quickToolbarTheme.metrics.toolbarHeight
        let gap: CGFloat = 8 // 超过描边外侧的手柄命中范围。
        // 小选区也给常用输出按钮留够空间，窄屏再收纳低频工具。
        let widthLimit = min(area.width, max(selection.width, thickness * 9))
        var model = quickConfirmationCopies ? Self.copyConfirmationDockModel : Self.dockModel
        let fixedModes: Set<ActionKind> = bounds.contains(selected) ? Set(Self.captureModes) : []
        if fixedModes.isEmpty {
            model.outputActions.removeAll(where: Self.captureModes.contains)
            model.overflow.removeAll(where: Self.captureModes.contains)
        }
        var actions = model.layout(availableWidth: widthLimit, priorityOutputs: Self.dockPriority,
                                   fixedOutputs: quickConfirmationCopies ? fixedModes.union([.edit]) : fixedModes,
                                   showsHistory: false)
        if quickConfirmationCopies, actions.width > widthLimit {
            actions = model.layout(availableWidth: widthLimit, priorityOutputs: Self.dockPriority,
                                   fixedOutputs: fixedModes, showsHistory: false)
        }
        let width = actions.width
        guard width <= area.width, thickness <= area.height else { return nil }
        let x = min(max(area.minX, selected.midX - width / 2), area.maxX - width)
        let below = selection.minY - thickness - gap
        let preferredY = below >= area.minY ? below : selected.minY + gap
        let y = min(max(area.minY, preferredY), area.maxY - thickness)
        return (CGRect(x: x, y: y, width: width, height: thickness), actions)
    }

    func barLayout() -> (background: CGRect, buttons: [(action: BarButton, rect: CGRect)], primaryAction: BarButton)? {
        guard displaysToolbar, onQuickAction == nil, !isDragging, (!selectsWindows || lockedWindowSelection),
              let selected = selection, selected.width >= 1, selected.height >= 1 else { return nil }
        let selection = SelectionBorderView.outlineRect(for: selected, in: bounds)
        var actions: [BarButton] = [.cancel]
        if onLongShot != nil { actions.append(.longShot) }
        if onRecord != nil { actions.append(.record) }
        actions.append(.confirm)
        let primaryAction: BarButton = onCopy == nil ? .confirm : .copy
        if onCopy != nil { actions.append(.copy) }
        let buttonWidth: CGFloat = min(64, max(1, bounds.width - 32))
        let columns = min(actions.count, max(1, Int((bounds.width - 24) / (buttonWidth + 4))))
        let rows = (actions.count + columns - 1) / columns
        let width = CGFloat(columns) * (buttonWidth + 4) + 8
        let height = CGFloat(rows) * 36 + 4
        let gap: CGFloat = 10
        let x = min(max(8, selection.midX - width / 2), bounds.maxX - width - 8)
        var y = selection.minY - height - gap
        if y < 8 {
            let above = selection.maxY + (showsSizeLabel && screenImage != nil ? 28 : gap)
            // 上方需要留出尺寸标签；全屏等没有外部空间的选区，把工具栏放在内部下方。
            y = above + height <= bounds.maxY - 8 ? above : selection.minY + gap
        }
        y = min(max(8, y), bounds.maxY - height - 8)

        let buttons = actions.enumerated().map { index, action in
            (action: action, rect: CGRect(x: x + 6 + CGFloat(index % columns) * (buttonWidth + 4),
                                         y: y + height - 36 - CGFloat(index / columns) * 36,
                                         width: buttonWidth, height: 32))
        }
        return (CGRect(x: x, y: y, width: width, height: height), buttons, primaryAction)
    }

    private func barButton(at point: CGPoint) -> BarButton? {
        guard let layout = barLayout() else { return nil }
        return layout.buttons.first { $0.rect.contains(point) }?.action
    }

    private func updateBar() {
        if let layout = quickToolbarLayout() {
            actionBar.isHidden = true
            let toolbar = ActionsBarView(theme: quickToolbarTheme, resolvedLayout: layout.actions,
                                         showsHistory: false, showsToolTips: false,
                                         confirmationTitle: confirmationTitle, cancellationTitle: "取消框选 Esc",
                                         toolTip: { [weak self] action in self?.editorDockToolTip(for: action) ?? action.title }
            ) { [weak self] action in self?.performQuickAction(action) }
            let root = AnyView(toolbar
                .disabled(pendingAction != nil)
                .background(EditCanvasView.chromeColor(for: quickToolbarTheme).color, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(quickToolbarTheme.token(.border)).allowsHitTesting(false) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("标注工具栏"))
            let host = editorDock ?? SelectionEditorDockHost(rootView: root)
            if editorDock == nil {
                host.sizingOptions = []
                editorDock = host
                addSubview(host)
                addSubview(editorDockTip, positioned: .above, relativeTo: host)
            } else {
                host.rootView = root
            }
            host.appearance = NSAppearance(named: quickToolbarTheme.isDark ? .darkAqua : .aqua)
            if host.frame != layout.background || editorDockActions != layout.actions { hideQuickToolbarTip() }
            editorDockActions = layout.actions
            host.frame = layout.background
            host.isHidden = false
            return
        }
        editorDock?.isHidden = true
        editorDockActions = nil
        hideQuickToolbarTip()
        guard let layout = barLayout() else {
            if !actionBar.isHidden {
                actionBar.isHidden = true
                setBarHover(nil, showsTip: false)
            }
            return
        }
        let moved = actionBar.frame != layout.background
        actionBar.update(frame: layout.background, buttons: layout.buttons, primaryAction: layout.primaryAction,
                         confirmationTitle: confirmationTitle)
        actionBar.isHidden = false
        updateBarFeedback()
        if moved, hoveredBarButton != nil {
            setBarHover(nil, showsTip: false)
        }
    }

    private func editorDockToolTip(for action: ActionKind) -> String {
        switch action {
        case .copy: return "复制 ⌘C"
        case .edit: return "编辑 ⏎"
        case .cancel: return "取消框选 Esc"
        case .confirm: return confirmationTitle
        default: return quickToolbarToolTip(action)
        }
    }

    private func editorDockHover(at point: CGPoint) -> EditorDockHover? {
        guard let toolbar = editorDock?.frame, let actions = editorDockActions else { return nil }
        let size = ActionsBarLayout.buttonSize
        let spacing = ActionsBarLayout.spacing
        let divider = ActionsBarLayout.dividerWidth + spacing
        var x = toolbar.minX + ActionsBarLayout.horizontalPadding
        func hit(_ title: @autoclosure () -> String) -> EditorDockHover? {
            let rect = CGRect(x: x, y: toolbar.midY - size / 2, width: size, height: size)
            x += size + spacing
            return rect.contains(point) ? EditorDockHover(title: title(), button: rect, toolbar: toolbar) : nil
        }
        for action in actions.annotationTools {
            if let match = hit(editorDockToolTip(for: action)) { return match }
        }
        x += divider
        for action in actions.outputActions {
            if let match = hit(editorDockToolTip(for: action)) { return match }
        }
        if !actions.overflow.isEmpty, let match = hit("更多工具与操作") { return match }
        x += divider
        if let match = hit(editorDockToolTip(for: .cancel)) { return match }
        x += ActionsBarLayout.confirmLeadingPadding
        return hit(editorDockToolTip(for: .confirm))
    }

    func hideQuickToolbarTip() { setEditorDockHover(nil) }

    private func setEditorDockHover(_ hover: EditorDockHover?) {
        guard hover != hoveredEditorButton else { return }
        hoveredEditorButton = hover
        editorHoverTip?.cancel()
        editorHoverTip = nil
        editorDockTip.isHidden = true
        guard let hover else { return }
        // 覆盖层层级高于系统提示窗，在覆盖层内显示与编辑器同色的提示。
        let work = DispatchWorkItem { [weak self] in
            guard let self, hoveredEditorButton == hover, pendingAction == nil,
                  editorDock?.isHidden == false else { return }
            editorDockTip.show(hover.title, button: hover.button, toolbar: hover.toolbar,
                               within: barBounds, theme: quickToolbarTheme)
        }
        editorHoverTip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updateBarFeedback() {
        actionBar.updateFeedback(hovered: hoveredBarButton, pressed: pressedBarButton, pending: pendingAction)
    }

    private func setBarHover(_ action: BarButton?, showsTip: Bool = true) {
        if window?.isVisible == true {
            (action == nil ? NSCursor.crosshair : NSCursor.pointingHand).set()
        }
        guard action != hoveredBarButton || !showsTip else { return }
        hoveredBarButton = action
        hoverTip?.cancel()
        hoverTip = nil
        actionBar.hideTip()
        updateBarFeedback()
        guard let action, showsTip, pressedBarButton == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredBarButton == action, self.pendingAction == nil,
                  let rect = self.barLayout()?.buttons.first(where: { $0.action == action })?.rect else { return }
            self.actionBar.showTip(for: action, at: rect, within: self.bounds)
        }
        hoverTip = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func handleRects(for rect: CGRect) -> [(Handle, CGRect)] {
        let outline = SelectionBorderView.outlineRect(for: rect, in: bounds)
        let size = SelectionBorderView.handleSize
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
        }
        return [
            (.topLeft, box(outline.minX, outline.maxY)),
            (.top, box(outline.midX, outline.maxY)),
            (.topRight, box(outline.maxX, outline.maxY)),
            (.right, box(outline.maxX, outline.midY)),
            (.bottomRight, box(outline.maxX, outline.minY)),
            (.bottom, box(outline.midX, outline.minY)),
            (.bottomLeft, box(outline.minX, outline.minY)),
            (.left, box(outline.minX, outline.midY)),
        ]
    }

    private func handleHit(at point: CGPoint, in rect: CGRect) -> Handle? {
        handleRects(for: rect)
            .first { $0.1.insetBy(dx: -3, dy: -3).contains(point) }?
            .0
    }

    // MARK: - 几何

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
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(bounds.minX, result.minX), bounds.maxX - result.width)
        result.origin.y = min(max(bounds.minY, result.minY), bounds.maxY - result.height)
        return result
    }

    /// 取屏幕截图里某个视图坐标处的像素颜色。
    private func pixelColor(at point: CGPoint) -> RGBAColor? {
        guard let image = screenImage else { return nil }
        let scale = CGFloat(image.width) / max(1, bounds.width)
        let x = Int(point.x * scale)
        let y = Int((bounds.height - point.y) * scale)
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBAColor(
            red: Double(bytes[0]) / 255,
            green: Double(bytes[1]) / 255,
            blue: Double(bytes[2]) / 255
        )
    }
}

private final class SelectionEditorDockHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class SelectionEditorDockTip: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        addSubview(label)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, button: CGRect, toolbar: CGRect, within area: CGRect, theme: Theme) {
        let visible = area.insetBy(dx: 6, dy: 6)
        let horizontalPadding: CGFloat = 9
        let verticalPadding: CGFloat = 5
        let availableWidth = visible.width - horizontalPadding * 2
        guard availableWidth > 0, let cell = label.cell else { return }

        label.stringValue = text
        // 使用绘制单元的尺寸，保留文字实际占用的边距。
        let textWidth = min(availableWidth, ceil(cell.cellSize.width))
        let textHeight = ceil(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: visible.height)).height)
        let width = textWidth + horizontalPadding * 2
        let height = max(26, textHeight + verticalPadding * 2)
        guard height <= visible.height else { return }
        let x = min(max(visible.minX, button.midX - width / 2), visible.maxX - width)
        let above = toolbar.maxY + 6
        let y = above + height <= visible.maxY ? above : max(visible.minY, toolbar.minY - height - 6)
        frame = CGRect(x: x, y: y, width: width, height: height)
        label.frame = CGRect(x: horizontalPadding, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        label.textColor = color(theme.rgb(.popoverForeground))
        layer?.backgroundColor = color(theme.rgb(.popover)).cgColor
        layer?.borderColor = color(theme.rgb(.border)).cgColor
        isHidden = false
    }

    private func color(_ value: RGBAColor) -> NSColor {
        NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }
}

/// 光晕上方的交互提示，鼠标仍由 SelectionOverlayView 统一处理。
private final class SelectionControlsView: NSView {
    weak var owner: SelectionOverlayView?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        owner?.drawControls(in: context)
    }
}
