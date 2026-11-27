import AppKit
import CoreText
import Foundation
import SwiftUI
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapScreen
import TapSnapSystem
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
        // 默认不让覆盖层本身被截进图里；开启演示模式后允许被录屏/截屏捕获。
        ScreenCaptureProtection.apply(to: self)
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
    private var synchronizedDrag = false
    private var displaysToolbar = true
    private var dragBounds: CGRect { desktopDragBounds ?? bounds }
    var quickToolbarTheme: Theme = .dark { didSet { updateBar() } }
    var quickToolbarToolTip: (ActionKind) -> String = { $0.title } { didSet { hideQuickToolbarTip() } }
    var config: ConfigStore?
    var quickConfirmationCopies = true { didSet { updateBar() } }
    var quickConfirmationAction: ActionKind = .copy
    var confirmationTitle = "确认 ⏎" { didSet { updateBar() } }
    /// 测试可覆盖此值模拟 Dock / 菜单栏占用的可见区。
    var visibleBarBoundsOverride: CGRect?
    /// 上一次截图的选区（视图坐标）；在尚未框选时按 R 可一键恢复。
    var lastSelectionRect: CGRect?

    /// 该屏的冻结截图，铺在压暗层下面。
    var screenImage: CGImage? { didSet { updateBar() } }
    /// 普通截图和直接贴图显示即将输出的那一帧；滚动及录制等选区继续透出实时桌面。
    var showsFrozenSelection = false

    /// 后台检测出来的界面元素框（视图坐标）。
    var snapRegions: [SelectionSnapRegion] = [] { didSet { refreshSnapPreview() } }
    var accessibilitySnapLookup: (@Sendable (CGPoint) -> CGRect?)?
    /// 窗口模式使用系统给出的前后顺序，不能按面积选到后方窗口。
    var windowRegions: [CGRect] = []
    var selectsWindows = false { didSet { updateResizeHandleVisibility() } }
    /// 为 true 时松手立即确认选区，不展示工具栏与缩放手柄（用于极速取字等直出流程）。
    var confirmsOnRelease = false {
        didSet {
            updateResizeHandleVisibility()
            updateBar()
        }
    }
    /// 非 nil 时启用「截图秒译」专属框选外观，并在松手后立即触发翻译，无需二次确认。
    var quickTranslateStyle: QuickTranslateStyle? {
        didSet {
            updateResizeHandleVisibility()
            if let style = quickTranslateStyle {
                borderConfiguration = Self.quickTranslateBorderConfiguration(for: style)
            }
            updateBar()
            needsDisplay = true
            controlsView.needsDisplay = true
        }
    }

    private func updateResizeHandleVisibility() {
        borderView.showsResizeHandles = !selectsWindows && quickTranslateStyle == nil && !confirmsOnRelease
    }
    /// 截图秒译目标语言显示名（如「简体中文」「英语」）。
    var quickTranslateTargetLanguage: String = "简体中文" {
        didSet { controlsView.needsDisplay = true }
    }
    /// 框选期间按 Tab 循环切换目标语言，返回新的语言显示名。
    var onCycleQuickTranslateLanguage: (() -> String)?
    private var pointerInsideView = false
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
    var borderConfiguration: SelectionBorderConfiguration {
        get { borderView.configuration }
        set { borderView.configuration = newValue }
    }
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

    func synchronizeSelection(_ rect: CGRect?, showToolbar: Bool, dragging: Bool = false) {
        receivingSelection = true
        synchronizedDrag = dragging
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
    private var sizeEditor: SelectionSizeEditorView?
    private var hoveredEditorButton: EditorDockHover?
    private var editorHoverTip: DispatchWorkItem?

    private struct EditorDockHover: Equatable {
        let title: String
        let button: CGRect
        let toolbar: CGRect
    }

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
        dismissSizeEditor(commit: false)
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

    override func cursorUpdate(with event: NSEvent) {
        guard pendingAction == nil else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseTracking = area
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard pendingAction == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        pointerInsideView = bounds.contains(point)
        if quickTranslateStyle != nil, !isDragging {
            controlsView.needsDisplay = true
        }
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
            updateCursor(at: point)
            return
        }
        updateCursor(at: point)
        guard !lockedWindowSelection else { return }
        if barLayout()?.background.contains(point) == true { return }
        selection = Self.windowRegion(at: point, regions: windowRegions, bounds: bounds)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        pointerInsideView = false
        if quickTranslateStyle != nil { controlsView.needsDisplay = true }
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
        if quickTranslateStyle != nil, bounds.contains(point) {
            cursor = point
            pointerInsideView = true
            controlsView.needsDisplay = true
        }
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

        if let sizeEditor, !sizeEditor.isHidden {
            if sizeEditor.frame.contains(point) { return }
            dismissSizeEditor(commit: true)
        }
        if let action = barButton(at: point) {
            pressedBarButton = action
            setBarHover(action, showsTip: false)
            updateBarFeedback()
            return
        }
        // 工具栏的留白也不能穿透并开始一个新选区。
        if barLayout()?.background.contains(point) == true || quickToolbarLayout()?.background.contains(point) == true { return }
        if canEditSizeLabel, let selection, let labelRect = sizeLabelRect(for: selection), labelRect.contains(point) {
            openSizeEditor(near: labelRect, selection: selection)
            return
        }
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
                updateCursor(at: point)
                needsDisplay = true
                return
            }
            if SelectionBorderView.outlineRect(for: selection, in: bounds).contains(point) {
                mode = .moving(start: point, rect: selection)
                updateCursor(at: point)
                needsDisplay = true
                return
            }
        }

        // 锁住按下时看到的范围，后台识别结果不会在松手前改掉目标。
        pressedSnap = snapPreview.flatMap { $0.contains(point) ? $0 : nil } ?? snapTarget(at: point)
        clearSnapPreview()
        mode = .creating(anchor: point)
        selection = CGRect(origin: point, size: .zero)
        updateCursor(at: point)
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
        updateCursor(at: point)
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
        var completedQuickCreate = false
        if case .creating(let anchor) = mode {
            if max(dragDistance, anchor.distance(to: point)) < 4 {
                selection = pressedSnap
            } else {
                let rect = Self.rect(from: anchor, to: point).intersection(dragBounds)
                selection = rect.width >= 2 && rect.height >= 2 ? rect : nil
            }
            pressedSnap = nil
            completedQuickCreate = quickTranslateStyle != nil || confirmsOnRelease
        }
        mode = .idle
        onSelectionChange?(selection, cursor, false)
        if completedQuickCreate, let selected = selection, selected.width >= 4, selected.height >= 4 {
            performBarAction(.confirm)
            return
        }
        setBarHover(barButton(at: point))
        updateCursor(at: point)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditingSize { return super.performKeyEquivalent(with: event) }
        return handleDockShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard pendingAction == nil else { return }
        if isEditingSize {
            if event.keyCode == 53 { dismissSizeEditor(commit: false); return }
            super.keyDown(with: event)
            return
        }
        if handleArrowKey(event) { return }
        if selection == nil, !isDragging, !selectsWindows, !confirmsOnRelease, quickTranslateStyle == nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           event.keyCode == 15, let last = lastSelectionRect {
            let restored = Self.clamp(last, to: dragBounds)
            if restored.width >= 2, restored.height >= 2 {
                clearSnapPreview()
                selection = restored
                onSelectionChange?(selection, cursor, false)
                needsDisplay = true
                return
            }
        }
        if handleDockShortcut(event) { return }
        switch event.keyCode {
        case 48: // Tab — 截图秒译期间快速切换目标语言
            if quickTranslateStyle != nil, let updated = onCycleQuickTranslateLanguage?() {
                quickTranslateTargetLanguage = updated
                return
            }
            super.keyDown(with: event)
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

    var isEditingSize: Bool { sizeEditor?.isHidden == false }

    private var activePixelScale: CGFloat {
        if let selectionScale, selectionScale > 0 { return selectionScale }
        if let image = screenImage, bounds.width > 0 {
            return max(1, CGFloat(image.width) / bounds.width)
        }
        return 1
    }

    private var canEditSizeLabel: Bool {
        showsSizeLabel && screenImage != nil && !isDragging && !selectsWindows && !confirmsOnRelease && quickTranslateStyle == nil
    }

    @discardableResult
    func applyPixelSize(width: Int, height: Int) -> Bool {
        guard let current = selection, width >= 2, height >= 2, !selectsWindows else { return false }
        let scale = max(1, activePixelScale)
        let logicalWidth = min(dragBounds.width, CGFloat(width) / scale)
        let logicalHeight = min(dragBounds.height, CGFloat(height) / scale)
        guard logicalWidth >= 1, logicalHeight >= 1 else { return false }
        let proposed = CGRect(
            x: current.minX,
            y: current.maxY - logicalHeight,
            width: logicalWidth,
            height: logicalHeight
        )
        selection = Self.clamp(proposed, to: dragBounds)
        onSelectionChange?(selection, cursor, false)
        needsDisplay = true
        return true
    }

    @discardableResult
    func nudgeSelection(dx: CGFloat, dy: CGFloat, resize: Bool) -> Bool {
        guard let current = selection, !isDragging, !selectsWindows, !confirmsOnRelease, quickTranslateStyle == nil else {
            return false
        }
        let updated: CGRect
        if resize {
            let minSide = 2 / max(1, activePixelScale)
            let maxWidth = max(minSide, dragBounds.maxX - current.minX)
            let maxHeight = max(minSide, current.maxY - dragBounds.minY)
            let newWidth = min(maxWidth, max(minSide, current.width + dx))
            let newHeight = min(maxHeight, max(minSide, current.height - dy))
            updated = Self.clamp(
                CGRect(x: current.minX, y: current.maxY - newHeight, width: newWidth, height: newHeight),
                to: dragBounds
            )
        } else {
            updated = Self.clamp(current.offsetBy(dx: dx, dy: dy), to: dragBounds)
        }
        selection = updated
        onSelectionChange?(selection, cursor, false)
        needsDisplay = true
        return true
    }

    private func handleArrowKey(_ event: NSEvent) -> Bool {
        guard selection != nil, !isDragging, !selectsWindows, !confirmsOnRelease, quickTranslateStyle == nil else {
            return false
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: NSEvent.ModifierFlags = [.shift, .option, .numericPad, .function]
        guard mods.subtracting(allowed).isEmpty else { return false }
        let multiplier: CGFloat = mods.contains(.shift) ? 10 : 1
        let step = multiplier / max(1, activePixelScale)
        let resize = mods.contains(.option)
        switch event.keyCode {
        case 123: return nudgeSelection(dx: -step, dy: 0, resize: resize) // Left
        case 124: return nudgeSelection(dx: step, dy: 0, resize: resize)  // Right
        case 125: return nudgeSelection(dx: 0, dy: -step, resize: resize) // Down
        case 126: return nudgeSelection(dx: 0, dy: step, resize: resize)  // Up
        default: return false
        }
    }

    private func openSizeEditor(near labelRect: CGRect, selection: CGRect) {
        let scale = max(1, activePixelScale)
        let pixelWidth = max(2, Int((selection.width * scale).rounded()))
        let pixelHeight = max(2, Int((selection.height * scale).rounded()))
        let editor = sizeEditor ?? SelectionSizeEditorView(frame: .zero)
        if sizeEditor == nil {
            editor.onApply = { [weak self] width, height in
                self?.applyPixelSize(width: width, height: height)
                self?.dismissSizeEditor(commit: false)
            }
            editor.onCancel = { [weak self] in
                self?.dismissSizeEditor(commit: false)
            }
            sizeEditor = editor
            addSubview(editor)
        }
        let area = barBounds.insetBy(dx: 8, dy: 8)
        let size = SelectionSizeEditorView.preferredSize
        let x = min(max(area.minX, labelRect.minX), area.maxX - size.width)
        let y = min(max(area.minY, labelRect.minY - 4), area.maxY - size.height)
        editor.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        editor.configure(width: pixelWidth, height: pixelHeight)
        editor.isHidden = false
        editor.focusWidthField()
    }

    func dismissSizeEditor(commit: Bool) {
        guard let editor = sizeEditor, !editor.isHidden else { return }
        if commit, let parsed = editor.parsedDimensions() {
            applyPixelSize(width: parsed.width, height: parsed.height)
        }
        editor.isHidden = true
        window?.makeFirstResponder(self)
    }

    private func handleDockShortcut(_ event: NSEvent) -> Bool {
        guard let action = OperationShortcut.matching(event, in: config?.settings ?? Settings(),
                                                      selection: true)?.selectionAction else { return false }
        if onQuickAction != nil {
            return event.isARepeat || performQuickAction(action) || action == .copy
        }
        guard action == .copy, onCopy != nil else { return false }
        if !event.isARepeat, barLayout()?.buttons.contains(where: { $0.action == .copy }) == true {
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

    @discardableResult
    func performQuickAction(_ action: ActionKind) -> Bool {
        let canUseMirroredSelection = !displaysToolbar && OperationShortcut.action(action).selectionAction != nil
        guard pendingAction == nil, let onQuickAction, let selection, !isDragging, !synchronizedDrag,
              quickToolbarLayout() != nil || canUseMirroredSelection else { return false }
        switch action {
        case .cancel: performBarAction(.cancel)
        case .confirm where !quickConfirmationCopies: performBarAction(.confirm)
        case .undo, .redo: return false
        default:
            if window?.isVisible == true {
                pendingAction = .confirm
                // 贴图在本次事件里直接交接，避免工具栏先闪出一次禁用状态。
                if action != .pin { updateBar() }
            }
            onQuickAction(action == .confirm ? quickConfirmationAction : action, selection)
        }
        return true
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

        let dimAlpha: CGFloat = switch quickTranslateStyle {
        case .editorial: 0.20
        case .some: 0.30
        case .none: 0.35
        }
        context.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        guard let visible = selection ?? snapPreview, visible.width > 0, visible.height > 0 else {
            context.fill(bounds)
            return
        }
        if showsFrozenSelection, screenImage != nil {
            context.addRect(bounds)
            context.addRect(visible)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
            context.clear(visible)
        }
        if selection == nil {
            let snapColor: NSColor = quickTranslateStyle != nil
                ? NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.92)
                : NSColor(quickToolbarTheme.highlight)
            context.setStrokeColor(snapColor.cgColor)
            context.stroke(visible.insetBy(dx: 1, dy: 1), width: 2)
        }
    }

    fileprivate func drawControls(in context: CGContext) {
        if let qtStyle = quickTranslateStyle {
            if let selection, selection.width > 0, selection.height > 0 {
                if selection.intersects(bounds) {
                    drawQuickTranslateSelectionChrome(style: qtStyle, selection: selection, in: context)
                }
            } else if pointerInsideView {
                drawQuickTranslateCursorBadge(style: qtStyle, at: cursor, in: context)
            }
            return
        }
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

    static func quickTranslateBorderConfiguration(for style: QuickTranslateStyle) -> SelectionBorderConfiguration {
        switch style {
        case .cleanCard:
            return SelectionBorderConfiguration(style: .liquidGlass, motion: .diagonalGlint, palette: .glacier)
        case .liquidGlass:
            return SelectionBorderConfiguration(style: .liquidGlass, motion: .diagonalGlint, palette: .titaniumIce)
        case .editorial:
            return SelectionBorderConfiguration(style: .editorial, motion: .silkyDash, palette: .linearIndigo)
        case .inlineBilingual:
            return SelectionBorderConfiguration(style: .liquidGlass, motion: .dualSlide, palette: .warmPearl)
        case .dynamicBubble:
            return SelectionBorderConfiguration(style: .liquidGlass, motion: .dewdropPulse, palette: .seasalt)
        }
    }

    private func drawQuickTranslateSelectionChrome(
        style: QuickTranslateStyle,
        selection: CGRect,
        in context: CGContext
    ) {
        let outline = SelectionBorderView.outlineRect(for: selection, in: bounds)
        let scale = selectionScale ?? screenImage.map { CGFloat($0.width) / max(1, bounds.width) } ?? 1
        let dimsText = "\(Int((selection.width * scale).rounded()))×\(Int((selection.height * scale).rounded()))"
        let calmBlue = NSColor(srgbRed: 0.14, green: 0.54, blue: 1.0, alpha: 1)
        let graphiteFill = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.88)
        let subtleRim = NSColor.white.withAlphaComponent(0.22)

        switch style {
        case .cleanCard:
            let topText = "译  截图秒译 · → \(quickTranslateTargetLanguage)"
            drawQuickTranslatePill(
                text: topText,
                preferredOrigin: CGPoint(x: outline.minX, y: outline.maxY + 8),
                fallbackOrigin: CGPoint(x: outline.minX + 8, y: outline.maxY - 30),
                fill: graphiteFill,
                stroke: subtleRim,
                dotColor: calmBlue,
                textColor: .white,
                fontSize: 11.5,
                context: context
            )
            let bottomText = "松手即译 · \(dimsText)"
            let bottomSize = measureQuickTranslatePill(text: bottomText, fontSize: 10.5, hasDot: false)
            drawQuickTranslatePill(
                text: bottomText,
                preferredOrigin: CGPoint(x: outline.maxX - bottomSize.width, y: outline.minY - bottomSize.height - 8),
                fallbackOrigin: CGPoint(x: outline.maxX - bottomSize.width - 8, y: outline.minY + 8),
                fill: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.78),
                stroke: NSColor.white.withAlphaComponent(0.18),
                dotColor: nil,
                textColor: NSColor.white.withAlphaComponent(0.90),
                fontSize: 10.5,
                context: context
            )

        case .liquidGlass:
            let topText = "译  截图秒译 · → \(quickTranslateTargetLanguage)"
            drawQuickTranslatePill(
                text: topText,
                preferredOrigin: CGPoint(x: outline.minX, y: outline.maxY + 8),
                fallbackOrigin: CGPoint(x: outline.minX + 8, y: outline.maxY - 30),
                fill: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.21, alpha: 0.86),
                stroke: NSColor(srgbRed: 0.34, green: 0.72, blue: 0.98, alpha: 0.65),
                dotColor: NSColor(srgbRed: 0.24, green: 0.72, blue: 0.98, alpha: 1),
                textColor: .white,
                fontSize: 11.5,
                context: context
            )
            let bottomText = "松手即译 · \(dimsText)"
            let bottomSize = measureQuickTranslatePill(text: bottomText, fontSize: 10.5, hasDot: false)
            drawQuickTranslatePill(
                text: bottomText,
                preferredOrigin: CGPoint(x: outline.maxX - bottomSize.width, y: outline.minY - bottomSize.height - 8),
                fallbackOrigin: CGPoint(x: outline.maxX - bottomSize.width - 8, y: outline.minY + 8),
                fill: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.21, alpha: 0.76),
                stroke: NSColor.white.withAlphaComponent(0.22),
                dotColor: nil,
                textColor: NSColor(srgbRed: 0.88, green: 0.93, blue: 1.0, alpha: 0.94),
                fontSize: 10.5,
                context: context
            )

        case .editorial:
            drawEditorialCornerBrackets(around: outline, in: context)
            let ribbonText = "译 · 松手即译 → \(quickTranslateTargetLanguage)"
            let ribbonSize = measureQuickTranslatePill(text: ribbonText, fontSize: 11, hasDot: false)
            drawQuickTranslatePill(
                text: ribbonText,
                preferredOrigin: CGPoint(x: outline.midX - ribbonSize.width / 2, y: outline.maxY + 10),
                fallbackOrigin: CGPoint(x: outline.midX - ribbonSize.width / 2, y: outline.maxY - ribbonSize.height - 8),
                fill: NSColor(srgbRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.90),
                stroke: NSColor(srgbRed: 0.45, green: 0.56, blue: 0.96, alpha: 0.58),
                dotColor: nil,
                textColor: .white,
                fontSize: 11,
                context: context
            )

        case .inlineBilingual:
            let topText = "译  双语取词 · → \(quickTranslateTargetLanguage)"
            drawQuickTranslatePill(
                text: topText,
                preferredOrigin: CGPoint(x: outline.minX, y: outline.maxY + 8),
                fallbackOrigin: CGPoint(x: outline.minX + 8, y: outline.maxY - 30),
                fill: NSColor(srgbRed: 0.14, green: 0.12, blue: 0.09, alpha: 0.86),
                stroke: NSColor(srgbRed: 0.94, green: 0.68, blue: 0.28, alpha: 0.72),
                dotColor: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.28, alpha: 1),
                textColor: .white,
                fontSize: 11.5,
                context: context
            )
            let hintText = "Tab 切换语言 · 松手即译"
            let hintSize = measureQuickTranslatePill(text: hintText, fontSize: 10.5, hasDot: false)
            drawQuickTranslatePill(
                text: hintText,
                preferredOrigin: CGPoint(x: outline.minX, y: outline.minY - hintSize.height - 8),
                fallbackOrigin: CGPoint(x: outline.minX + 8, y: outline.minY + 8),
                fill: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.80),
                stroke: NSColor.white.withAlphaComponent(0.22),
                dotColor: nil,
                textColor: NSColor.white.withAlphaComponent(0.92),
                fontSize: 10.5,
                context: context
            )

        case .dynamicBubble:
            let topText = "秒译 · → \(quickTranslateTargetLanguage) · 松手出词"
            let topSize = measureQuickTranslatePill(text: topText, fontSize: 11, hasDot: true)
            drawQuickTranslatePill(
                text: topText,
                preferredOrigin: CGPoint(x: outline.midX - topSize.width / 2, y: outline.maxY + 10),
                fallbackOrigin: CGPoint(x: outline.midX - topSize.width / 2, y: outline.maxY - topSize.height - 8),
                fill: NSColor(srgbRed: 0.07, green: 0.11, blue: 0.13, alpha: 0.90),
                stroke: NSColor(srgbRed: 0.22, green: 0.78, blue: 0.58, alpha: 0.65),
                dotColor: NSColor(srgbRed: 0.22, green: 0.80, blue: 0.60, alpha: 1),
                textColor: .white,
                fontSize: 11,
                context: context
            )
            drawDynamicBubbleOrb(near: CGPoint(x: outline.maxX + 10, y: outline.minY - 10), in: context)
        }
    }

    private func drawQuickTranslateCursorBadge(
        style: QuickTranslateStyle,
        at point: CGPoint,
        in context: CGContext
    ) {
        let calmBlue = NSColor(srgbRed: 0.14, green: 0.54, blue: 1.0, alpha: 1)
        let graphiteFill = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.88)
        let subtleRim = NSColor.white.withAlphaComponent(0.22)
        let (text, fill, stroke, dot): (String, NSColor, NSColor, NSColor?) = switch style {
        case .cleanCard:
            ("译 截图秒译 · → \(quickTranslateTargetLanguage) · Tab", graphiteFill, subtleRim, calmBlue)
        case .liquidGlass:
            (
                "译 截图秒译 · → \(quickTranslateTargetLanguage) · Tab",
                NSColor(srgbRed: 0.09, green: 0.12, blue: 0.21, alpha: 0.86),
                NSColor(srgbRed: 0.34, green: 0.72, blue: 0.98, alpha: 0.65),
                NSColor(srgbRed: 0.24, green: 0.72, blue: 0.98, alpha: 1)
            )
        case .editorial:
            (
                "译 拖选文字即译 · → \(quickTranslateTargetLanguage)",
                NSColor(srgbRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.88),
                NSColor(srgbRed: 0.45, green: 0.56, blue: 0.96, alpha: 0.60),
                nil
            )
        case .inlineBilingual:
            (
                "译 双语秒译 · → \(quickTranslateTargetLanguage) · Tab",
                NSColor(srgbRed: 0.14, green: 0.12, blue: 0.09, alpha: 0.86),
                NSColor(srgbRed: 0.94, green: 0.68, blue: 0.28, alpha: 0.72),
                NSColor(srgbRed: 0.96, green: 0.72, blue: 0.28, alpha: 1)
            )
        case .dynamicBubble:
            (
                "秒译 · → \(quickTranslateTargetLanguage) · Tab",
                NSColor(srgbRed: 0.07, green: 0.11, blue: 0.13, alpha: 0.90),
                NSColor(srgbRed: 0.22, green: 0.78, blue: 0.58, alpha: 0.65),
                NSColor(srgbRed: 0.22, green: 0.80, blue: 0.60, alpha: 1)
            )
        }
        let pillSize = measureQuickTranslatePill(text: text, fontSize: 11, hasDot: dot != nil)
        var origin = CGPoint(x: point.x + 16, y: point.y - pillSize.height - 14)
        if origin.x + pillSize.width > bounds.maxX - 10 {
            origin.x = point.x - pillSize.width - 16
        }
        if origin.y < 10 {
            origin.y = point.y + 16
        }
        drawQuickTranslatePill(
            text: text,
            preferredOrigin: origin,
            fallbackOrigin: origin,
            fill: fill,
            stroke: stroke,
            dotColor: dot,
            textColor: .white,
            fontSize: 11,
            context: context
        )
    }

    private func measureQuickTranslatePill(text: String, fontSize: CGFloat, hasDot: Bool) -> CGSize {
        let measured = measure(text, fontSize: fontSize, color: .white)
        let dotExtra: CGFloat = hasDot ? 12 : 0
        return CGSize(width: ceil(measured.width) + 18 + dotExtra, height: max(22, ceil(measured.height) + 10))
    }

    private func drawQuickTranslatePill(
        text: String,
        preferredOrigin: CGPoint,
        fallbackOrigin: CGPoint,
        fill: NSColor,
        stroke: NSColor,
        dotColor: NSColor?,
        textColor: NSColor,
        fontSize: CGFloat,
        context: CGContext
    ) {
        let hasDot = dotColor != nil
        let size = measureQuickTranslatePill(text: text, fontSize: fontSize, hasDot: hasDot)
        let preferredRect = CGRect(origin: preferredOrigin, size: size)
        let rawOrigin: CGPoint = bounds.insetBy(dx: 8, dy: 8).contains(preferredRect) ? preferredOrigin : fallbackOrigin
        let clampedX = min(max(8, rawOrigin.x), max(8, bounds.maxX - size.width - 8))
        let clampedY = min(max(8, rawOrigin.y), max(8, bounds.maxY - size.height - 8))
        let rect = CGRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
        let radius = rect.height / 2

        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.32).cgColor)
        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        var textX = rect.minX + 9
        if let dotColor {
            let dotRect = CGRect(x: textX, y: rect.midY - 3, width: 6, height: 6)
            context.setFillColor(dotColor.cgColor)
            context.fillEllipse(in: dotRect)
            textX += 12
        }
        let measured = measure(text, fontSize: fontSize, color: textColor)
        let textY = rect.minY + (rect.height - measured.height) / 2
        drawText(text, at: CGPoint(x: textX, y: textY), fontSize: fontSize, color: textColor, context: context)
        context.restoreGState()
    }

    private func drawEditorialCornerBrackets(around outline: CGRect, in context: CGContext) {
        let arm: CGFloat = min(16, max(8, min(outline.width, outline.height) * 0.25))
        let inset: CGFloat = -4
        let r = outline.insetBy(dx: inset, dy: inset)
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.maxY - arm), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + arm, y: r.maxY)),
            (CGPoint(x: r.maxX - arm, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - arm)),
            (CGPoint(x: r.minX, y: r.minY + arm), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + arm, y: r.minY)),
            (CGPoint(x: r.maxX - arm, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + arm)),
        ]
        for (p1, corner, p2) in corners {
            context.move(to: p1)
            context.addLine(to: corner)
            context.addLine(to: p2)
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawDynamicBubbleOrb(near center: CGPoint, in context: CGContext) {
        let diameter: CGFloat = 24
        let cx = min(max(diameter / 2 + 8, center.x), bounds.maxX - diameter / 2 - 8)
        let cy = min(max(diameter / 2 + 8, center.y), bounds.maxY - diameter / 2 - 8)
        let orbRect = CGRect(x: cx - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.30).cgColor)
        context.setFillColor(NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.92).cgColor)
        context.fillEllipse(in: orbRect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: orbRect.insetBy(dx: 0.7, dy: 0.7))
        let glyph = "译"
        let m = measure(glyph, fontSize: 11.5, color: .white)
        drawText(
            glyph,
            at: CGPoint(x: orbRect.midX - m.width / 2, y: orbRect.midY - m.height / 2),
            fontSize: 11.5,
            color: .white,
            context: context
        )
        context.restoreGState()
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

    func sizeLabelRect(for selection: CGRect) -> CGRect? {
        guard let image = screenImage else { return nil }
        let scale = selectionScale ?? CGFloat(image.width) / max(1, bounds.width)
        let text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        let measured = measure(text, fontSize: 11, color: .white)
        let outline = SelectionBorderView.outlineRect(for: selection, in: bounds)
        let origin = CGPoint(
            x: min(max(8, outline.minX), bounds.maxX - measured.width - 8),
            y: min(outline.maxY + 6, bounds.maxY - measured.height - 6)
        )
        return CGRect(
            x: origin.x - 4,
            y: origin.y - 2,
            width: measured.width + 8,
            height: measured.height + 4
        )
    }

    private func sizeLabel(_ selection: CGRect, context: CGContext) {
        guard let image = screenImage, let box = sizeLabelRect(for: selection) else { return }
        let scale = selectionScale ?? CGFloat(image.width) / max(1, bounds.width)
        let text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        let origin = CGPoint(x: box.minX + 4, y: box.minY + 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
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
        if let override = visibleBarBoundsOverride {
            let clipped = override.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? bounds : clipped
        }
        guard let window, let screen = window.screen else { return bounds }
        let visible = convert(window.convertFromScreen(screen.visibleFrame), from: nil).intersection(bounds)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }

    func quickToolbarLayout() -> (background: CGRect, actions: ActionsBarLayout)? {
        guard quickTranslateStyle == nil, !confirmsOnRelease, displaysToolbar, onQuickAction != nil, !isDragging, (!selectsWindows || lockedWindowSelection),
              let selected = selection, selected.width >= 1, selected.height >= 1 else { return nil }
        let selection = SelectionBorderView.outlineRect(for: selected, in: bounds).intersection(bounds)
        let area = barBounds.insetBy(dx: 8, dy: 8)
        let thickness = quickToolbarTheme.metrics.toolbarHeight
        let gap: CGFloat = 8 // 超过描边外侧的手柄命中范围。
        // 小选区也给常用输出按钮留够空间，窄屏再收纳低频工具。
        let defaultWidth = thickness * 9 + ActionsBarLayout.buttonSize + ActionsBarLayout.spacing
        let widthLimit = min(area.width, max(selection.width, defaultWidth))
        let actions = SelectionToolbar.layout(
            availableWidth: widthLimit,
            pinned: SelectionToolbar.pinnedActions(from: config?.settings.capture.selectionToolbarActions),
            singleScreen: bounds.contains(selected),
            copiesOnConfirm: quickConfirmationCopies
        )
        let width = actions.width
        guard width <= area.width, thickness <= area.height else { return nil }
        let x = min(max(area.minX, selected.midX - width / 2), area.maxX - width)
        let below = selection.minY - thickness - gap
        let preferredY: CGFloat
        if below >= area.minY {
            preferredY = below
        } else {
            // 下方放不下时优先翻到选区上方，并给左上角尺寸标签留出空间。
            let above = selection.maxY + (showsSizeLabel && screenImage != nil ? 28 : gap)
            preferredY = above + thickness <= area.maxY ? above : selected.minY + gap
        }
        let y = min(max(area.minY, preferredY), area.maxY - thickness)
        return (CGRect(x: x, y: y, width: width, height: thickness), actions)
    }

    func barLayout() -> (background: CGRect, buttons: [(action: BarButton, rect: CGRect)], primaryAction: BarButton)? {
        guard quickTranslateStyle == nil, !confirmsOnRelease, displaysToolbar, onQuickAction == nil, !isDragging, (!selectsWindows || lockedWindowSelection),
              let selected = selection, selected.width >= 1, selected.height >= 1 else { return nil }
        let selection = SelectionBorderView.outlineRect(for: selected, in: bounds)
        let area = barBounds.insetBy(dx: 8, dy: 8)
        var actions: [BarButton] = [.cancel]
        if onLongShot != nil { actions.append(.longShot) }
        if onRecord != nil { actions.append(.record) }
        actions.append(.confirm)
        let primaryAction: BarButton = onCopy == nil ? .confirm : .copy
        if onCopy != nil { actions.append(.copy) }
        let buttonWidth: CGFloat = min(64, max(1, area.width - 16))
        let columns = min(actions.count, max(1, Int((area.width - 8) / (buttonWidth + 4))))
        let rows = (actions.count + columns - 1) / columns
        let width = CGFloat(columns) * (buttonWidth + 4) + 8
        let height = CGFloat(rows) * 36 + 4
        let gap: CGFloat = 10
        let x = min(max(area.minX, selection.midX - width / 2), area.maxX - width)
        var y = selection.minY - height - gap
        if y < area.minY {
            let above = selection.maxY + (showsSizeLabel && screenImage != nil ? 28 : gap)
            // 上方需要留出尺寸标签；全屏等没有外部空间的选区，把工具栏放在内部下方。
            y = above + height <= area.maxY ? above : selection.minY + gap
        }
        y = min(max(area.minY, y), area.maxY - height)

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
        if actions.showsAnnotationDivider { x += divider }
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
            self.actionBar.showTip(for: action, at: rect, within: self.barBounds)
        }
        hoverTip = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func updateCursor(at point: CGPoint) {
        guard window?.isVisible == true else { return }
        cursorForPoint(point).set()
    }

    func cursorForPoint(_ point: CGPoint) -> NSCursor {
        switch mode {
        case .creating:
            return .crosshair
        case .moving:
            return .closedHand
        case .resizing(let handle, _):
            return Self.cursor(for: handle)
        case .idle:
            break
        }

        if let editorDock, !editorDock.isHidden, editorDock.frame.contains(point) {
            return editorDockHover(at: point) == nil ? .arrow : .pointingHand
        }
        if barButton(at: point) != nil {
            return .pointingHand
        }
        if barLayout()?.background.contains(point) == true || quickToolbarLayout()?.background.contains(point) == true {
            return .arrow
        }
        if canEditSizeLabel, let selection, let labelRect = sizeLabelRect(for: selection), labelRect.contains(point) {
            return .pointingHand
        }
        if !selectsWindows, let selection, selection.width >= 1, selection.height >= 1 {
            if let handle = handleHit(at: point, in: selection) {
                return Self.cursor(for: handle)
            }
            if SelectionBorderView.outlineRect(for: selection, in: bounds).contains(point) {
                return .openHand
            }
        }
        return .crosshair
    }

    private static let diagonalNWSECursor: NSCursor = makeDiagonalCursor(nwse: true)
    private static let diagonalNESWCursor: NSCursor = makeDiagonalCursor(nwse: false)

    private static func cursor(for handle: Handle) -> NSCursor {
        if #available(macOS 15, *) {
            switch handle {
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
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return diagonalNWSECursor
        case .topRight, .bottomLeft: return diagonalNESWCursor
        }
    }

    private static func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: nwse ? -.pi / 4 : .pi / 4)

            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: -7.5, y: 0))
            arrow.addLine(to: CGPoint(x: -3.2, y: 3.8))
            arrow.addLine(to: CGPoint(x: -3.2, y: 1.3))
            arrow.addLine(to: CGPoint(x: 3.2, y: 1.3))
            arrow.addLine(to: CGPoint(x: 3.2, y: 3.8))
            arrow.addLine(to: CGPoint(x: 7.5, y: 0))
            arrow.addLine(to: CGPoint(x: 3.2, y: -3.8))
            arrow.addLine(to: CGPoint(x: 3.2, y: -1.3))
            arrow.addLine(to: CGPoint(x: -3.2, y: -1.3))
            arrow.addLine(to: CGPoint(x: -3.2, y: -3.8))
            arrow.closeSubpath()

            ctx.setLineJoin(.round)
            ctx.setLineWidth(2.2)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addPath(arrow)
            ctx.strokePath()

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(arrow)
            ctx.fillPath()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
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
        if let direct = handleRects(for: rect)
            .first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(point) })?.0 {
            return direct
        }
        // 整条边框线上任意位置均可直接拖拽缩放，无需精准点中小圆点。
        let outline = SelectionBorderView.outlineRect(for: rect, in: bounds)
        let tolerance: CGFloat = 4.5
        let outer = outline.insetBy(dx: -tolerance, dy: -tolerance)
        let inner = outline.insetBy(dx: tolerance, dy: tolerance)
        guard outer.contains(point), !inner.contains(point) else { return nil }

        let nearLeft = abs(point.x - outline.minX) <= tolerance
        let nearRight = abs(point.x - outline.maxX) <= tolerance
        let nearTop = abs(point.y - outline.maxY) <= tolerance
        let nearBottom = abs(point.y - outline.minY) <= tolerance

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        if nearRight { return .right }
        return nil
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

/// 点击选区左上角尺寸胶囊后弹出的轻量像素宽高编辑器。
private final class SelectionSizeEditorView: NSView, NSTextFieldDelegate {
    static let preferredSize = CGSize(width: 176, height: 30)

    var onApply: ((Int, Int) -> Void)?
    var onCancel: (() -> Void)?

    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let multiplyLabel = NSTextField(labelWithString: "×")
    private let applyButton = NSButton(title: "确定", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.96).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        for field in [widthField, heightField] {
            field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            field.alignment = .right
            field.isBordered = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
            field.delegate = self
            addSubview(field)
        }
        widthField.placeholderString = "宽"
        heightField.placeholderString = "高"
        widthField.nextKeyView = heightField
        heightField.nextKeyView = widthField

        multiplyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        multiplyLabel.textColor = .white.withAlphaComponent(0.75)
        multiplyLabel.alignment = .center
        addSubview(multiplyLabel)

        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .mini
        applyButton.font = .systemFont(ofSize: 11, weight: .medium)
        applyButton.target = self
        applyButton.action = #selector(confirmClicked)
        addSubview(applyButton)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        widthField.frame = CGRect(x: 6, y: 4, width: 52, height: 22)
        multiplyLabel.frame = CGRect(x: 59, y: 7, width: 12, height: 16)
        heightField.frame = CGRect(x: 72, y: 4, width: 52, height: 22)
        applyButton.frame = CGRect(x: 128, y: 5, width: 42, height: 20)
    }

    func configure(width: Int, height: Int) {
        widthField.stringValue = "\(width)"
        heightField.stringValue = "\(height)"
    }

    func focusWidthField() {
        window?.makeFirstResponder(widthField)
        widthField.selectText(nil)
    }

    func parsedDimensions() -> (width: Int, height: Int)? {
        let w = Int(widthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let h = Int(heightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let w, let h, w >= 2, h >= 2 else { return nil }
        return (w, h)
    }

    @objc private func confirmClicked() {
        if let dims = parsedDimensions() {
            onApply?(dims.width, dims.height)
        } else {
            onCancel?()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirmClicked()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
