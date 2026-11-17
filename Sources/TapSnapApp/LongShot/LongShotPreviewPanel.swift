import AppKit
import Combine
import SwiftUI
import TapSnapScreen

/// 操作栏固定在窗口内，图像单独滚动；预览缩放不会改变导出像素。
final class LongShotPreviewPanel: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var content: LongShotPreviewContentView?
    private var targets: [ClosureTarget] = []
    private var onClose: (() -> Void)?
    private var isLive = false
    private var lastScreen: ScreenDescriptor?

    var windowNumber: Int? { window?.windowNumber }

    func isUnderPointer(at point: CGPoint, desktopTop: CGFloat) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(CGPoint(x: point.x, y: desktopTop - point.y))
    }

    func showLive(
        on screen: ScreenDescriptor,
        avoiding avoid: CGRect?,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSelectScrollRegion: (() -> Void)? = nil,
        onToggleAutomaticScroll: (() -> Void)? = nil
    ) {
        close()
        isLive = true
        lastScreen = screen
        onClose = onCancel
        var buttons = [button("取消", action: onCancel), button("完成", action: onFinish)]
        buttons[0].keyEquivalent = "\u{1b}"
        buttons[1].keyEquivalent = "\r"
        if let onSelectScrollRegion { buttons.append(button("滚动区域…", action: onSelectScrollRegion)) }
        if let onToggleAutomaticScroll { buttons.append(button("自动滚动", action: onToggleAutomaticScroll)) }
        let view = LongShotPreviewContentView(live: true, buttons: buttons)
        view.status.stringValue = "在选区内缓慢向下滚动，结束时点「完成」"
        let window = makeWindow(size: NSSize(width: 400, height: 440), live: true)
        window.title = "正在截取长图"
        install(view, in: window)
        place(window, visible: screen.visibleFrame, avoiding: avoid)
        window.orderFrontRegardless()
    }

    func update(image: CGImage, viewportHeight: CGFloat) {
        guard let content else { return }
        let followBottom = isLive && content.isAtBottom
        content.preview.image = image
        content.preview.highlightHeight = viewportHeight
        content.info.stringValue = "\(image.width) × \(image.height) 像素"
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        content.preview.needsDisplay = true
        if followBottom { content.scrollToBottom() }
    }

    func updateStatus(_ message: String, isWarning: Bool = false) {
        content?.status.stringValue = message
        content?.status.textColor = isWarning ? .systemOrange : .secondaryLabelColor
    }

    func setAutomaticScroll(_ active: Bool) {
        content?.buttons.first(where: { ["自动滚动", "暂停滚动"].contains($0.title) })?.title = active ? "暂停滚动" : "自动滚动"
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
        privacyEditor: EditController? = nil,
        onEdit: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        close()
        isLive = false
        self.onClose = onClose
        let closeButton = button("关闭", action: onClose)
        closeButton.keyEquivalent = "\u{1b}"
        let outputButtons = actions.map { button($0.title, action: $0.handler) }
        var buttons = [closeButton] + outputButtons
        if let onEdit { buttons.append(button("编辑", action: onEdit)) }
        let view = LongShotPreviewContentView(live: false, buttons: buttons, outputButtons: outputButtons)
        view.preview.image = image
        if let privacyEditor { view.installPrivacy(privacyEditor) }
        view.info.stringValue = "\(image.width) × \(image.height) 像素"
        view.status.stringValue = "滚动查看整张长图；切换「原始像素」检查文字和接缝"
        let window = makeWindow(size: NSSize(width: 680, height: 680), live: false)
        window.title = "长截图预览"
        install(view, in: window)
        let visible = lastScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        place(window, visible: visible, avoiding: nil, centered: true)
        window.contentMinSize = NSSize(width: min(360, window.contentLayoutRect.width),
                                       height: min(240, window.contentLayoutRect.height))
        view.layoutSubtreeIfNeeded()
        view.scroll.contentView.scroll(to: .zero)
        showExisting()
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

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let target = ClosureTarget(action)
        targets.append(target)
        let button = NSButton(title: title, target: target, action: #selector(ClosureTarget.fire))
        button.bezelStyle = .rounded
        return button
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
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        return window
    }

    private func place(_ window: NSWindow, visible: CGRect, avoiding avoid: CGRect?, centered: Bool = false) {
        let available = visible.insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(window.frame.width, available.width),
                          height: min(window.frame.height, available.height))
        // 选区使用 CGDisplay 的左上原点；窗口和 visibleFrame 使用 AppKit 的左下原点。
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class LongShotPreviewContentView: NSView {
    let scroll = NSScrollView()
    let preview = LongShotPreviewView()
    let info = NSTextField(labelWithString: "等待第一帧")
    let status = NSTextField(wrappingLabelWithString: "")
    let buttons: [NSButton]
    private let outputButtons: [NSButton]
    private let mode = NSSegmentedControl(labels: ["适合宽度", "原始像素"],
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let live: Bool
    private var privacyBar: NSView?
    private var privacyControl: NSView?
    private var privacyChanges: AnyCancellable?
    private var editChanges: AnyCancellable?
    private var privacyEditor: EditController?
    override var isFlipped: Bool { true }

    init(live: Bool, buttons: [NSButton], outputButtons: [NSButton] = []) {
        self.live = live
        self.buttons = buttons
        self.outputButtons = outputButtons
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        info.font = .systemFont(ofSize: 12, weight: .medium)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(selectPreviewMode)
        mode.isHidden = live
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.documentView = preview
        preview.showsHighlight = live
        [info, status, mode, scroll].forEach(addSubview)
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        addSubview(button)
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
        preview.refreshEditor()
    }

    var isAtBottom: Bool {
        preview.image == nil || preview.frame.maxY - scroll.contentView.bounds.maxY < 8
    }

    func scrollToBottom() {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, preview.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = privacyBar?.isHidden == false ? 30 : 0
        let header: CGFloat = live ? 68 : 96 + barHeight
        let footer: CGFloat = 52
        info.frame = CGRect(x: 12, y: 10, width: max(0, bounds.width - 24), height: 18)
        status.frame = CGRect(x: 12, y: 31, width: max(0, bounds.width - 24), height: 30)
        mode.frame = CGRect(x: 12, y: 64, width: 194, height: 25)
        privacyControl?.frame = CGRect(x: max(214, bounds.width - 134), y: 61, width: 122, height: 30)
        privacyBar?.frame = CGRect(x: 0, y: 96, width: bounds.width, height: barHeight)
        scroll.frame = CGRect(x: 0, y: header, width: bounds.width,
                              height: max(1, bounds.height - header - footer))
        let count = CGFloat(buttons.count)
        let width = min(96, max(1, (bounds.width - 24 - 8 * (count - 1)) / max(1, count)))
        let start = bounds.width - 12 - count * width - (count - 1) * 8
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: start + CGFloat(index) * (width + 8),
                                  y: bounds.height - 39, width: width, height: 28)
        }
        layoutImage()
    }

    private func layoutImage() {
        guard let image = preview.image else {
            preview.frame = CGRect(origin: .zero, size: scroll.contentSize)
            return
        }
        // 原始像素：一张图像像素对应一个物理屏幕像素，包括 Retina 屏。
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
    }
}

/// 把闭包挂到 NSButton 上。
final class ClosureTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// 图像按指定比例绘制，滚动范围由外层 NSScrollView 管理。
final class LongShotPreviewView: NSView {
    var image: CGImage?
    var displayScale: CGFloat = 1
    var highlightHeight: CGFloat = 0
    var showsHighlight = false
    private var editLayer: EditItemLayerView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var imageRect: CGRect {
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
        context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        context.fill(dirtyRect)
        guard let image else { return }
        let rect = imageRect
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
        guard showsHighlight, highlightHeight > 0 else { return }
        let height = min(rect.height, highlightHeight * displayScale)
        let highlight = CGRect(x: rect.minX + 1, y: rect.maxY - height + 1,
                               width: max(0, rect.width - 2), height: max(0, height - 2))
        context.setStrokeColor(NSColor.systemGreen.cgColor)
        context.setLineWidth(2)
        context.stroke(highlight)
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
        }
        .help("打开打码工具、扫描和规则")
        .popover(isPresented: $showsTools, arrowEdge: .bottom) {
            PrivacyToolPanel(controller: controller, privacy: controller.privacy)
        }
    }
}
