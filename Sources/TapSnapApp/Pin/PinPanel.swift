import AppKit
import Foundation
import TapSnapCore
import TapSnapSystem
import TapSnapTheme

/// 一个贴图面板。
///
/// 无边框、非激活窗口，支持置顶、鼠标穿透、滚轮缩放、右键菜单和可配置的双击关闭。
final class PinPanel: NSPanel, NSWindowDelegate {
    var onFrameChanged: ((CGRect) -> Void)?
    private var halo: PinHaloPanel?
    private var haloEnabled = false

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .floating
        animationBehavior = .utilityWindow
        // NSPanel 默认随 App 失活隐藏；贴图必须一直贴着，不然切个 App 就没了。
        hidesOnDeactivate = false
        // 贴图自身不应出现在截图结果里。
        sharingType = .none
        delegate = self
    }

    func windowDidMove(_ notification: Notification) { onFrameChanged?(frame) }
    func windowDidResize(_ notification: Notification) {
        if let halo { halo.setFrame(PinHaloPanel.frame(around: frame), display: true) }
        onFrameChanged?(frame)
    }

    func updateHalo(enabled: Bool) {
        haloEnabled = enabled
        guard enabled, isVisible else {
            removeHalo()
            return
        }

        let halo = self.halo ?? PinHaloPanel(pinFrame: frame)
        if halo.level != level { halo.level = level }
        if halo.alphaValue != alphaValue { halo.alphaValue = alphaValue }
        if self.halo == nil {
            self.halo = halo
            addChildWindow(halo, ordered: .below)
        }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        updateHalo(enabled: haloEnabled)
    }

    override func orderOut(_ sender: Any?) {
        removeHalo()
        super.orderOut(sender)
    }

    private func removeHalo() {
        guard let halo else { return }
        self.halo = nil
        removeChildWindow(halo)
        halo.close()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 贴图视图（显示图片 + 处理滚轮缩放/右键菜单/双击关闭）。
final class PinImageView: NSView {
    var item: PinItem {
        didSet { needsDisplay = true }
    }
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onRotate: ((Bool) -> Void)?
    var onFlip: ((Bool) -> Void)?
    var onScaleChange: ((CGFloat) -> Void)?
    var onOpacityChange: ((Double) -> Void)?
    var onToggleClickThrough: (() -> Void)?
    var onToggleAlwaysOnTop: (() -> Void)?
    var onMoveToGroup: ((String?) -> Void)?
    var groupChoices: (() -> [String])?
    var doubleClickToClose = false

    init(item: PinItem) {
        self.item = item
        super.init(frame: CGRect(origin: .zero, size: item.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(item.image, in: bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        // 滚轮缩放贴图，按住 Option 滚动可调整透明度。
        if event.modifierFlags.contains(.option) {
            let delta = Double(event.scrollingDeltaY) / 200
            onOpacityChange?(min(max(item.opacity + delta, 0.1), 1))
        } else {
            let factor = 1 + (event.scrollingDeltaY / 200)
            let newScale = min(max(item.scale * factor, 0.1), 8)
            onScaleChange?(newScale)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, doubleClickToClose {
            onClose?()
            return
        }
        window?.performDrag(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    /// 点中贴图后按 Delete / 退格删掉它，Esc 也能关。
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117, 53:
            onClose?()
        default:
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [
            ("复制", #selector(copyAction)),
            ("另存为…", #selector(saveAction)),
            ("向左旋转", #selector(rotateLeftAction)),
            ("向右旋转", #selector(rotateRightAction)),
            ("水平翻转", #selector(flipHorizontalAction)),
            ("垂直翻转", #selector(flipVerticalAction)),
            ("关闭", #selector(closeAction)),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for (title, action, checked) in [
            ("保持置顶", #selector(toggleTopAction), item.isAlwaysOnTop),
            ("鼠标穿透（在贴图分组中恢复）", #selector(toggleClickThroughAction), item.isClickThrough),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.state = checked ? .on : .off
            menu.addItem(entry)
        }
        let groupMenu = NSMenu()
        for name in [""] + (groupChoices?() ?? []) {
            let entry = NSMenuItem(title: name.isEmpty ? "默认分组" : name, action: #selector(moveGroupAction(_:)), keyEquivalent: "")
            entry.representedObject = name
            entry.target = self
            entry.state = (item.group ?? "") == name ? .on : .off
            groupMenu.addItem(entry)
        }
        let groupEntry = NSMenuItem(title: "移到分组", action: nil, keyEquivalent: "")
        groupEntry.submenu = groupMenu
        menu.addItem(groupEntry)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleTopAction() { onToggleAlwaysOnTop?() }
    @objc private func toggleClickThroughAction() { onToggleClickThrough?() }
    @objc private func moveGroupAction(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        onMoveToGroup?(name?.isEmpty == false ? name : nil)
    }
    @objc private func copyAction() { onCopy?() }
    @objc private func closeAction() { onClose?() }
    @objc private func saveAction() { onSave?() }
    @objc private func rotateLeftAction() { onRotate?(false) }
    @objc private func rotateRightAction() { onRotate?(true) }
    @objc private func flipHorizontalAction() { onFlip?(true) }
    @objc private func flipVerticalAction() { onFlip?(false) }
}
