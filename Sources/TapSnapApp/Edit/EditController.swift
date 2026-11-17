import AppKit
import Combine
import Foundation
import TapSnapActionsBar
import TapSnapCore
import TapSnapOCR
import TapSnapPalette
import TapSnapPrivacy
import TapSnapScreen
import TapSnapTheme
import TapSnapToast
import TapSnapVision
import SwiftUI

/// 截图编辑窗口的控制器。
///
/// 管理画布和工具栏，处理工具切换、撤销重做、复制、保存、贴图和识别。
final class EditController: NSObject, ObservableObject, NSWindowDelegate {
    private static let minimumContentSize = CGSize(width: 288, height: 144)

    @Published private(set) var document: EditDocument
    @Published var selectedTool: ActionKind?
    @Published var canUndo = false
    @Published var canRedo = false
    /// 文档内容每变一次就 +1，画布靠它刷新（`EditDocument` 是引用类型，自己不会发通知）。
    @Published private(set) var revision = 0
    @Published private(set) var textEditingItem: TextItem?
    /// 由画布输入框提交输入法组合文字后结束编辑。
    var onFinishTextEditing: ((Bool) -> Void)?
    var onLocatePrivacyFinding: ((CGRect) -> Void)?
    private var textEditingOriginal: TextEditingState?
    private var textEditingIsNew = false
    @Published var style: EditItemStyle {
        didSet { applyAppearance(previousStyle: oldValue, previousOptions: toolOptions) }
    }
    @Published var toolOptions: EditToolOptions {
        didSet { applyAppearance(previousStyle: style, previousOptions: oldValue) }
    }
    /// 马赛克工具是否自动识别人脸。
    @Published var mosaicAutoDetect: Bool
    @Published var mosaicDetectText = false
    @Published private(set) var isDetectingMosaic = false
    let privacy = PrivacyEditing()

    /// 窗口关闭时回调，让环境释放对控制器的引用。
    var onClose: (() -> Void)?

    let environment: AppEnvironment
    let scrollsLongImage: Bool
    private let undoManager = UndoManager()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private let captureRect: CGRect?
    private let captureScreen: ScreenDescriptor?
    private let outputOptions: ScreenshotOutputOptions?
    private let scanPrivacyOnOpen: Bool
    private let requiresPrivacyReview: Bool
    let reviewedAction: ActionKind?
    private var syncingAppearance = false
    private var styleAdjustment: (item: any EditItem, original: AppearanceState)?
    private var mosaicTasks: [UUID: Task<Void, Never>] = [:]

    init(environment: AppEnvironment, image: CGImage, scale: CGFloat, style: EditItemStyle,
         captureRect: CGRect? = nil, captureScreen: ScreenDescriptor? = nil,
         outputOptions: ScreenshotOutputOptions? = nil, scanPrivacyOnOpen: Bool = false,
         requiresPrivacyReview: Bool = false, reviewedAction: ActionKind? = nil, scrollsLongImage: Bool = false) {
        self.environment = environment
        self.scrollsLongImage = scrollsLongImage
        self.document = EditDocument(baseImage: image, scale: scale)
        self.style = style
        var options = EditToolOptions()
        options.mosaicBlockSize = environment.config.settings.annotate.mosaicBlockSize
        options.magnifierZoom = environment.config.settings.annotate.magnifierZoom
        options.privacyAppearance = environment.config.settings.privacy.appearance
        self.toolOptions = options
        self.captureRect = captureRect
        self.captureScreen = captureScreen
        self.outputOptions = outputOptions
        self.scanPrivacyOnOpen = scanPrivacyOnOpen
        self.requiresPrivacyReview = requiresPrivacyReview
        self.reviewedAction = reviewedAction
        self.mosaicAutoDetect = environment.config.settings.annotate.autoMosaicDetectsFaces
        super.init()
    }

    var theme: Theme { environment.theme }

    var nextSerialIndex: Int {
        (document.items.compactMap { ($0 as? SerialItem)?.index }.max() ?? 0) + 1
    }

    func present() {
        if scanPrivacyOnOpen || requiresPrivacyReview || reviewedAction != nil { scanPrivacy() }
        let window = makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 画布上的快捷键装在窗口级，避免焦点跑到工具栏按钮上就失灵。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.minimumContentSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentViewController = NSHostingController(rootView: EditCanvasView(controller: self))
        window.title = "TapSnap 编辑"
        let image = document.baseImage
        window.subtitle = "\(image.width) × \(image.height)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        applyAppearance(to: window)

        let sourceDisplay = captureScreen.flatMap { source in
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == source.id
            }
        }
        let visible = sourceDisplay?.visibleFrame ?? Self.activeScreenBounds()
        let selection: CGRect?
        if let display = sourceDisplay, let captureRect, let captureScreen {
            selection = Self.captureImageFrame(capture: captureRect, capturedScreen: captureScreen,
                                               screen: display.frame, canvasSize: document.canvasSize)
        } else {
            selection = nil
        }
        // 标题栏占窗口高度，工具栏与边距占内容高度。
        let titlebarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let statusHeight = privacy.phase == .idle ? 0 : PrivacyStatusView.height
        let toolbarHeight = theme.metrics.toolbarHeight
        let size = Self.contentSize(for: document.canvasSize, screen: visible.size, titlebarHeight: titlebarHeight,
                                    toolbarHeight: toolbarHeight + statusHeight, nearCapture: selection != nil,
                                    scrollsLongImage: scrollsLongImage)
        window.setContentSize(size)
        window.contentMinSize = CGSize(width: min(Self.minimumContentSize.width, size.width),
                                       height: min(Self.minimumContentSize.height, size.height))
        if let selection {
            // Align the image using the content size AppKit actually assigned to the window.
            let contentSize = window.contentRect(forFrameRect: window.frame).size
            let content = Self.positionEditor(over: selection, contentSize: contentSize, titlebarHeight: titlebarHeight,
                                              toolbarHeight: toolbarHeight, statusHeight: statusHeight, visible: visible)
            window.setFrameOrigin(window.frameRect(forContentRect: content).origin)
        } else {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        return window
    }

    static func captureImageFrame(capture: CGRect, capturedScreen: ScreenDescriptor, screen: CGRect,
                                  canvasSize: CGSize) -> CGRect? {
        let local = Geometry.localRect(capture, in: capturedScreen.frame).snapped(to: capturedScreen.scale)
        let image = CGRect(x: screen.minX + local.minX, y: screen.maxY - local.minY - canvasSize.height,
                           width: canvasSize.width, height: canvasSize.height)
        return screen.contains(image) ? image : nil
    }

    static func positionEditor(over selection: CGRect, contentSize: CGSize, titlebarHeight: CGFloat,
                               toolbarHeight: CGFloat, statusHeight: CGFloat, visible: CGRect) -> CGRect {
        let centerY = (contentSize.height + toolbarHeight - statusHeight) / 2
        // AppKit places native windows on whole screen points.
        let x = min(max(visible.minX, (selection.midX - contentSize.width / 2).rounded()), visible.maxX - contentSize.width)
        let y = min(max(visible.minY, (selection.midY - centerY).rounded()), visible.maxY - contentSize.height - titlebarHeight)
        return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
    }

    func updateWindowAppearance() {
        if let window { applyAppearance(to: window) }
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(cgColor: EditCanvasView.chromeColor(for: theme).cgColor) ?? .windowBackgroundColor
    }

    /// 返回 true 表示这个事件已被处理掉。
    /// 故意不做 private：单元测试拿真实 `NSEvent` 直接驱动它。
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // 样式面板中的文本输入由 field editor 自己处理删除、撤销和回车。
        if let responder = event.window?.firstResponder as? NSTextView, responder.isEditable { return false }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            perform(event.modifierFlags.contains(.shift) ? .redo : .undo)
            return true
        }
        switch event.keyCode {
        case 51, 117: // Delete / Fn+Delete
            guard let selected = document.selectedItem else { return false }
            remove(selected)
            return true
        case 36, 76: // Return：裁剪模式下应用裁剪
            guard isCropping else { return false }
            toggleCrop()
            return true
        default:
            return false
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 按图片尺寸算窗口大小：默认按点显示（1:1），超出屏幕时等比缩小。
    static func contentSize(for canvas: CGSize, screen: CGSize, titlebarHeight: CGFloat, toolbarHeight: CGFloat,
                            nearCapture: Bool = false, scrollsLongImage: Bool = false) -> CGSize {
        let padding = 2 * EditCanvasView.canvasPadding
        let maxWidth = screen.width * (nearCapture ? 1 : 0.9)
        let maxHeight = screen.height * (nearCapture ? 1 : 0.85) - titlebarHeight
        let widthFit = min(1, (maxWidth - padding) / canvas.width)
        let fit = scrollsLongImage ? widthFit : min(widthFit, (maxHeight - toolbarHeight - padding) / canvas.height)
        let height = canvas.height * fit + padding + toolbarHeight
        return CGSize(width: min(maxWidth, max(minimumContentSize.width, canvas.width * fit + padding)),
                      height: min(maxHeight, nearCapture ? height : max(minimumContentSize.height, height)))
    }

    /// 跟设置窗口一致：按鼠标所在屏幕居中，而不是 `NSScreen.main`。
    private static func activeScreenBounds() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    }

    func close() {
        requestFinishTextEditing(commit: false)
        privacy.cancel()
        cancelMosaicDetection()
        removeKeyMonitor()
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        requestFinishTextEditing(commit: false)
        privacy.cancel()
        cancelMosaicDetection()
        removeKeyMonitor()
        window = nil
        onClose?()
    }

    func cancelFromCanvas() {
        if window != nil, captureRect != nil, document.selectedItem == nil {
            close()
        } else {
            clearSelection()
        }
    }

    // MARK: - 编辑

    /// 画布上画完一笔后调用：文字要补输入，其余直接入栈。
    func add(_ item: any EditItem) {
        if let text = item as? TextItem {
            beginTextEditing(text, isNew: true)
            return
        }
        if let serial = item as? SerialItem {
            serial.index = nextSerialIndex
        }
        if let mosaic = item as? MosaicItem, mosaic.autoDetect {
            addDetectedMosaics(for: mosaic)
            return
        }
        document.append(item)
        registerUndo(for: item)
    }

    /// 识别在后台完成；取消或关闭后不会再把结果写回文档。
    private func addDetectedMosaics(for mosaic: MosaicItem) {
        let id = UUID()
        let image = document.baseImage
        let canvas = document.canvasSize
        let faces = mosaicAutoDetect
        let text = mosaicDetectText
        isDetectingMosaic = true
        updateUndoState()
        mosaicTasks[id] = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AutoMosaicDetector.detect(in: image, faces: faces, text: text) }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.mosaicTasks[id] = nil
            self.isDetectingMosaic = !self.mosaicTasks.isEmpty
            let boxes = (try? result.get()) ?? []
            let rects = AutoMosaicDetector.documentRects(boxes, canvas: canvas, selection: mosaic.bounds)
            let items: [any EditItem] = rects.isEmpty ? [mosaic] : rects.map {
                MosaicItem(bounds: $0, style: mosaic.style, mode: mosaic.mode, blockSize: mosaic.blockSize)
            }
            items.forEach { self.document.append($0) }
            self.registerBatchUndo(items)
            if case .failure = result {
                self.environment.toast.warning("自动识别失败，已遮挡整个框选区域")
            }
        }
    }

    private func cancelMosaicDetection() {
        mosaicTasks.values.forEach { $0.cancel() }
        mosaicTasks.removeAll()
        isDetectingMosaic = false
        updateUndoState()
    }

    private func registerBatchUndo(_ items: [any EditItem]) {
        let ids = items.map(\.id)
        undoManager.registerUndo(withTarget: self) { target in
            ids.forEach { target.document.remove(id: $0) }
            target.undoManager.registerUndo(withTarget: target) { inner in
                items.forEach { inner.document.append($0) }
                inner.registerBatchUndo(items)
            }
            target.revision += 1
            target.updateUndoState()
        }
        revision += 1
        updateUndoState()
    }

    /// 橡皮擦掉的图元，可以撤销回来。
    func remove(_ item: any EditItem) {
        let id = item.id
        guard document.items.contains(where: { $0.id == id }) else { return }
        document.remove(id: id)
        undoManager.registerUndo(withTarget: self) { target in
            target.document.append(item)
            target.undoManager.registerUndo(withTarget: target) { inner in
                inner.remove(item)
            }
            target.revision += 1
            target.updateUndoState()
        }
        revision += 1
        updateUndoState()
    }

    func beginTextEditing(_ item: TextItem, isNew: Bool) {
        if textEditingItem?.id == item.id { return }
        requestFinishTextEditing()
        setStyleEditing(false)
        textEditingOriginal = TextEditingState(item)
        textEditingIsNew = isNew
        if isNew {
            item.bounds.origin.x = min(max(0, item.bounds.minX), max(0, document.canvasSize.width - 24))
            item.bounds.origin.y = min(max(0, item.bounds.minY), max(0, document.canvasSize.height - 24))
        }
        document.selectedItemID = isNew ? nil : item.id
        loadAppearance(from: item)
        let remaining = max(24, document.canvasSize.width - item.bounds.minX)
        item.textContainerWidth = min(remaining, item.textContainerWidth ?? max(item.bounds.width, min(240, remaining)))
        if item.text.isEmpty { item.fitToText() }
        textEditingItem = item
        revision += 1
    }

    func updateEditingText(_ text: String) {
        guard let item = textEditingItem else { return }
        item.text = text
        let remaining = max(24, document.canvasSize.width - item.bounds.minX)
        item.fitToText(maxWidth: min(remaining, item.textContainerWidth ?? remaining))
        revision += 1
    }

    /// 双击已有文字直接在原位置编辑。
    func promptEdit(_ item: TextItem) { beginTextEditing(item, isNew: false) }

    private func requestFinishTextEditing(commit: Bool = true) {
        guard textEditingItem != nil else { return }
        if let onFinishTextEditing { onFinishTextEditing(commit) }
        else { finishTextEditing(commit: commit) }
    }

    func finishTextEditing(commit: Bool = true) {
        guard let item = textEditingItem, let original = textEditingOriginal else { return }
        let isNew = textEditingIsNew
        textEditingOriginal = nil
        textEditingItem = nil
        if !commit {
            original.apply(to: item)
            if !isNew { loadAppearance(from: item) }
        } else if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !isNew {
                original.apply(to: item)
                remove(item)
            }
        } else if isNew {
            document.append(item)
            registerUndo(for: item)
        } else if item.text != original.text || item.style != original.style || item.background != original.background {
            registerTextUndo(item, state: original)
        } else {
            // 只进入再退出文字编辑，不制造空撤销或改变原有换行宽度。
            original.apply(to: item)
        }
        revision += 1
        updateUndoState()
    }

    private struct TextEditingState {
        let text: String
        let bounds: CGRect
        let style: EditItemStyle
        let background: TextItem.BackgroundStyle
        let width: CGFloat?
        init(_ item: TextItem) {
            text = item.text; bounds = item.bounds; style = item.style
            background = item.background; width = item.textContainerWidth
        }
        func apply(to item: TextItem) {
            item.text = text; item.bounds = bounds; item.style = style
            item.background = background; item.textContainerWidth = width
        }
    }

    private func registerTextUndo(_ item: TextItem, state: TextEditingState) {
        undoManager.registerUndo(withTarget: self) { target in
            let current = TextEditingState(item)
            state.apply(to: item)
            target.registerTextUndo(item, state: current)
            if target.document.selectedItemID == item.id { target.loadAppearance(from: item) }
            target.revision += 1
            target.updateUndoState()
        }
    }

    private func registerUndo(for item: any EditItem) {
        let id = item.id
        undoManager.registerUndo(withTarget: self) { target in
            target.document.remove(id: id)
            target.undoManager.registerUndo(withTarget: target) { inner in
                inner.document.append(item)
                inner.registerUndo(for: item)
            }
            target.revision += 1
            target.updateUndoState()
        }
        revision += 1
        updateUndoState()
    }

    private func updateUndoState() {
        canUndo = undoManager.canUndo || isDetectingMosaic
        canRedo = undoManager.canRedo
    }

    // MARK: - 选中与裁剪

    /// 裁剪模式：画布上拖出一个框，按 ⏎ 应用、⎋ 退出。
    @Published private(set) var isCropping = false

    func toggleCrop() {
        isCropping.toggle()
        if isCropping {
            document.cropRect = nil
            selectedTool = nil
        }
        revision += 1
    }

    func updateCropRect(_ rect: CGRect?) {
        document.cropRect = rect
        revision += 1
    }

    func select(_ item: any EditItem) {
        requestFinishTextEditing()
        setStyleEditing(false)
        document.selectedItemID = item.id
        loadAppearance(from: item)
        revision += 1
    }

    var activeItemKind: EditItemKind? {
        textEditingItem?.kind ?? document.selectedItem?.kind ?? selectedTool.flatMap(EditItemFactory.itemKind(for:))
    }

    private func loadAppearance(from item: any EditItem) {
        syncingAppearance = true
        style = item.style
        toolOptions.read(from: item)
        syncingAppearance = false
    }

    private func applyAppearance(previousStyle: EditItemStyle, previousOptions: EditToolOptions) {
        guard !syncingAppearance, let item = (textEditingItem as (any EditItem)?) ?? document.selectedItem,
              previousStyle != style || previousOptions != toolOptions else { return }
        let original = AppearanceState(item, options: previousOptions)
        var updatedStyle = original.style
        if previousStyle.color != style.color { updatedStyle.color = style.color }
        if previousStyle.lineWidth != style.lineWidth { updatedStyle.lineWidth = style.lineWidth }
        if previousStyle.fontSize != style.fontSize { updatedStyle.fontSize = style.fontSize }
        if previousStyle.opacity != style.opacity { updatedStyle.opacity = style.opacity }
        if previousStyle.strokeStyle != style.strokeStyle { updatedStyle.strokeStyle = style.strokeStyle }
        if previousStyle.handDrawnRoughness != style.handDrawnRoughness { updatedStyle.handDrawnRoughness = style.handDrawnRoughness }
        if previousStyle.handDrawnFill != style.handDrawnFill { updatedStyle.handDrawnFill = style.handDrawnFill }
        if previousStyle.strokePattern != style.strokePattern { updatedStyle.strokePattern = style.strokePattern }
        if previousStyle.shapeFill != style.shapeFill { updatedStyle.shapeFill = style.shapeFill }
        if previousStyle.fillColor != style.fillColor { updatedStyle.fillColor = style.fillColor }
        if previousStyle.cornerRadius != style.cornerRadius { updatedStyle.cornerRadius = style.cornerRadius }
        if previousStyle.textFormat != style.textFormat { updatedStyle.textFormat = style.textFormat }
        if previousStyle.textBackgroundColor != style.textBackgroundColor { updatedStyle.textBackgroundColor = style.textBackgroundColor }
        item.style = updatedStyle
        if previousOptions != toolOptions { toolOptions.apply(to: item) }
        if let text = item as? TextItem, original.style.fontSize != updatedStyle.fontSize
            || original.style.textFormat != updatedStyle.textFormat {
            text.fitToText()
        }
        if styleAdjustment?.item.id != item.id && textEditingItem?.id != item.id {
            registerAppearanceUndo(item, state: original)
        }
        revision += 1
        updateUndoState()
    }

    /// 样式滑条实时预览，松手后只记一次撤销。
    func setStyleEditing(_ editing: Bool) {
        if editing {
            guard textEditingItem == nil, styleAdjustment == nil, let item = document.selectedItem else { return }
            styleAdjustment = (item, AppearanceState(item, options: toolOptions))
        } else {
            guard let adjustment = styleAdjustment else { return }
            styleAdjustment = nil
            guard document.items.contains(where: { $0.id == adjustment.item.id }),
                  AppearanceState(adjustment.item, options: toolOptions) != adjustment.original else { return }
            registerAppearanceUndo(adjustment.item, state: adjustment.original)
            updateUndoState()
        }
    }

    private struct AppearanceState: Equatable {
        let style: EditItemStyle
        let options: EditToolOptions
        let textBounds: CGRect?

        init(_ item: any EditItem, options: EditToolOptions) {
            style = item.style
            var options = options
            options.read(from: item)
            self.options = options
            textBounds = (item as? TextItem)?.bounds
        }

        func apply(to item: any EditItem) {
            item.style = style
            options.apply(to: item)
            if let textBounds { item.bounds = textBounds }
        }
    }

    private func registerAppearanceUndo(_ item: any EditItem, state: AppearanceState) {
        undoManager.registerUndo(withTarget: self) { target in
            let current = AppearanceState(item, options: target.toolOptions)
            state.apply(to: item)
            target.registerAppearanceUndo(item, state: current)
            if target.document.selectedItemID == item.id { target.loadAppearance(from: item) }
            target.revision += 1
            target.updateUndoState()
        }
    }

    func clearSelection() {
        requestFinishTextEditing()
        setStyleEditing(false)
        document.selectedItemID = nil
        revision += 1
    }

    /// 画布上挪动/缩放完之后通知刷新。
    func noteDocumentChanged() {
        revision += 1
    }

    /// 拖动/缩放的撤销：把包围盒恢复成拖动前的样子。
    func registerBoundsUndo(for item: any EditItem, original: CGRect, originalTextWidth: CGFloat? = nil) {
        let current = item.bounds
        guard current != original else { return }
        let currentTextWidth = (item as? TextItem)?.textContainerWidth
        let changedWidth = current.width != original.width
        undoManager.registerUndo(withTarget: self) { target in
            item.bounds = original
            if changedWidth { (item as? TextItem)?.textContainerWidth = originalTextWidth }
            target.registerBoundsUndo(for: item, original: current, originalTextWidth: currentTextWidth)
            target.revision += 1
            target.updateUndoState()
        }
        revision += 1
        updateUndoState()
    }

    // MARK: - 工具栏动作

    func perform(_ action: ActionKind) {
        if action.isAnnotationTool {
            requestFinishTextEditing()
            if !action.hasOptionsPanel || EditItemFactory.itemKind(for: action) != activeItemKind {
                clearSelection()
            }
            isCropping = false
            if action == .privacy, document.selectedItem?.kind != .privacy {
                toolOptions.privacyAppearance = environment.config.settings.privacy.appearance
            }
            selectedTool = action == .eraser && selectedTool == action ? nil : action
            return
        }
        requestFinishTextEditing(commit: action != .cancel)
        setStyleEditing(false)
        let effectiveAction = action == .confirm ? reviewedAction ?? action : action
        let settings = environment.config.settings.capture
        let autoCopy = settings.autoCopyToClipboard
        let autoSave = outputOptions?.autoSave ?? settings.autoSaveToFile
        if effectiveAction.exportsImage {
            guard outputReady() else { return }
            let title = effectiveAction == .confirm
                ? (autoSave ? (autoCopy ? "保存并复制" : "保存") : (autoCopy ? "复制" : nil))
                : effectiveAction.title
            if let title, !reviewPrivacyOutput(title) { return }
        }
        switch effectiveAction {
        case .undo:
            if isDetectingMosaic { cancelMosaicDetection(); return }
            undoManager.undo()
            revision += 1
            updateUndoState()
        case .redo:
            undoManager.redo()
            revision += 1
            updateUndoState()
        case .cancel:
            close()
        case .confirm:
            if Self.completeOutputs(autoCopy: autoCopy, autoSave: autoSave,
                                    copy: { self.copyToPasteboard() }, save: { self.save() }) {
                close()
            }
        case .copy:
            if copyToPasteboard(), action == .confirm { close() }
        case .save:
            if save(), action == .confirm { close() }
        case .print:
            printImage()
        case .pin:
            pinToScreen()
        case .ocr:
            recognizeText()
        case .qrCode:
            recognizeQRCode()
        case .crop:
            toggleCrop()
        case .translate:
            if let image = renderedImage() { environment.translateImage(image) }
        case .formula:
            if let image = renderedImage() { environment.recognizeFormula(image) }
        case .tableRecognize:
            if let image = renderedImage() { environment.tableRecognizer.recognize(image) }
        case .longShot, .record:
            let rect = Self.sourceRect(captureRect: captureRect, crop: document.cropRect, canvas: document.canvasSize)
            close()
            environment.captureCoordinator.startFromEditor(action == .longShot ? .longShot : .record,
                                                            rect: rect, screen: captureScreen,
                                                            forcePrivacy: action == .longShot && privacy.phase != .idle)
        default: break
        }
    }

    /// 两套坐标都以左上角为原点；按原始选区比例映射，兼容缩放后的编辑图。
    static func sourceRect(captureRect: CGRect?, crop: CGRect?, canvas: CGSize) -> CGRect? {
        guard let source = captureRect, let crop, canvas.width > 0, canvas.height > 0 else { return captureRect }
        let clipped = crop.standardized.intersection(CGRect(origin: .zero, size: canvas))
        guard !clipped.isEmpty, !clipped.isNull else { return source }
        return CGRect(x: source.minX + clipped.minX / canvas.width * source.width,
                      y: source.minY + clipped.minY / canvas.height * source.height,
                      width: clipped.width / canvas.width * source.width,
                      height: clipped.height / canvas.height * source.height)
    }

    /// 保存失败时保留编辑窗口；用户可以改目录后重试，不会丢掉标注。
    static func completeOutputs(autoCopy: Bool, autoSave: Bool, copy: () -> Bool, save: () -> Bool) -> Bool {
        if autoSave && !save() { return false }
        if autoCopy && !copy() { return false }
        return true
    }

    // MARK: - 输出

    func scanPrivacy() {
        requestFinishTextEditing()
        startPrivacyScan()
    }

    func scanPrivacy(using configuration: PrivacyAIConfiguration, image: Bool, key: String?) {
        requestFinishTextEditing()
        let document = document
        let transform = CGAffineTransform(scaleX: document.scale, y: document.scale)
        let fullImage = CGRect(x: 0, y: 0, width: document.baseImage.width, height: document.baseImage.height)
        let region = document.cropRect?.applying(transform).integral.intersection(fullImage) ?? fullImage
        let masks = document.privacyPixelBounds
        startPrivacyScan(image ? .image(configuration, key: key, region: region, masks: masks) : .text(configuration, key: key))
    }

    private func startPrivacyScan(_ modelScan: PrivacyEditing.ModelScan? = nil) {
        if privacy.phase == .idle, captureRect != nil, let window, let visible = window.screen?.visibleFrame {
            // Make room above the canvas when the status row first appears.
            var frame = window.frame
            frame.size.height = min(frame.height + PrivacyStatusView.height, visible.height)
            frame.origin.y = min(frame.minY, visible.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        privacy.scan(document.baseImage, settings: environment.config.settings.privacy, modelScan: modelScan) { [weak self] in
            self?.addPrivacyFindings($0)
        }
    }

    func documentRect(for finding: PrivacyFinding) -> CGRect {
        finding.bounds.applying(CGAffineTransform(scaleX: 1 / document.scale, y: 1 / document.scale))
    }

    var privacySuggestions: [PrivacyFinding] {
        guard requiresPrivacyReview else { return privacy.suggestions }
        return privacy.uncoveredFindings(in: document.outputPixelBounds, coveredBy: document.privacyPixelBounds)
    }

    func applyPrivacySuggestion(_ id: UUID) {
        guard let finding = privacySuggestions.first(where: { $0.id == id }) else { return }
        privacy.markHandled([finding])
        let mask = PrivacyMaskItem(bounds: documentRect(for: finding), appearance: toolOptions.privacyAppearance)
        add(mask)
        select(mask)
    }

    func applyAllPrivacySuggestions() {
        let findings = privacySuggestions
        privacy.markHandled(findings)
        addPrivacyFindings(findings)
    }

    private func addPrivacyFindings(_ findings: [PrivacyFinding]) {
        guard !findings.isEmpty else { return }
        let previousSelection = document.selectedItemID
        let appearance = environment.config.settings.privacy.appearance
        let items = findings.map { PrivacyMaskItem(bounds: documentRect(for: $0), appearance: appearance) }
        items.forEach { document.append($0) }
        document.selectedItemID = previousSelection
        registerBatchUndo(items)
    }

    func updatePrivacyAppearance(_ appearance: PrivacyMaskAppearance) {
        toolOptions.privacyAppearance = appearance
        if document.selectedItem?.kind != .privacy {
            environment.config.update { $0.privacy.appearance = appearance }
        }
    }

    private func outputReady() -> Bool {
        guard !privacy.blocksOutput else {
            environment.toast.info("正在扫描隐私内容，请稍候")
            return false
        }
        guard !isDetectingMosaic else {
            environment.toast.info("正在识别打码区域，请稍候")
            return false
        }
        return true
    }

    private func reviewPrivacyOutput(_ title: String) -> Bool {
        guard requiresPrivacyReview else { return true }
        let pending = privacySuggestions
        let incomplete = !privacy.hasCompletedLocalScan
        guard !pending.isEmpty || incomplete else { return true }
        guard let window, window.isVisible else { return false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = pending.isEmpty ? "隐私检查未完成" : "还有 \(pending.count) 处未遮盖"
        if incomplete {
            alert.informativeText = "本机识别未完成，图片可能还有尚未发现的敏感内容。请先手动检查。"
        } else {
            alert.informativeText = "可以遮盖这些位置后继续，或回到图片逐处检查。"
        }
        let approve = alert.addButton(withTitle: pending.isEmpty ? "已检查，继续\(title)" :
                                        (incomplete ? "已检查，打码并\(title)" : "全部打码并\(title)"))
        approve.keyEquivalent = ""
        let review = alert.addButton(withTitle: pending.isEmpty ? "返回检查" : "逐处检查")
        review.keyEquivalent = "\r"
        alert.window.appearance = window.appearance
        let response = alert.runModal()
        guard self.window === window, window.isVisible else { return false }
        guard response == .alertFirstButtonReturn else {
            if !pending.isEmpty { privacy.showsSuggestions = true }
            return false
        }
        applyAllPrivacySuggestions()
        return true
    }

    func renderedImage() -> CGImage? {
        guard outputReady() else { return nil }
        guard !requiresPrivacyReview || privacySuggestions.isEmpty else { return nil }
        requestFinishTextEditing()
        do { return try document.render() }
        catch { environment.toast.error("渲染失败：\(error.localizedDescription)"); return nil }
    }

    @discardableResult
    private func copyToPasteboard() -> Bool {
        guard let image = renderedImage() else { return false }
        return environment.pinTransfer.copy(image)
    }

    @discardableResult
    private func save() -> Bool {
        guard let image = renderedImage() else { return false }
        return environment.saveScreenshot(image, formatOverride: outputOptions?.format)
    }

    /// 打印当前合成结果。
    private func printImage() {
        guard let image = renderedImage() else { return }
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / document.scale, height: CGFloat(image.height) / document.scale)
        )
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: nsImage.size))
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let operation = NSPrintOperation(view: imageView, printInfo: .shared)
        operation.showsPrintPanel = true
        operation.run()
    }

    private func pinToScreen() {
        guard let image = renderedImage() else { return }
        environment.pinGroups.show(image, scale: document.scale)
        close()
    }

    private func recognizeText() {
        guard let image = renderedImage() else { return }
        environment.ocrCoordinator.recognize(image)
    }

    /// 识别图里的二维码 / 条形码，结果直接进剪贴板。
    private func recognizeQRCode() {
        guard let image = renderedImage() else { return }
        Task.detached { [environment] in
            let results = BarcodeDetector().detect(in: image)
            await MainActor.run {
                guard !results.isEmpty else {
                    environment.toast.warning("没有识别到二维码")
                    return
                }
                let payload = results.map(\.payload).joined(separator: "\n")
                environment.pinTransfer.copy(payload)
                environment.toast.success(
                    results.count == 1
                        ? "已复制：\(results[0].payload)"
                        : "识别到 \(results.count) 个码，已全部复制"
                )
            }
        }
    }
}

extension CGSize {
    var asRect: CGRect {
        CGRect(origin: .zero, size: self)
    }
}
