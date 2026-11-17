import AppKit
import Combine
import Foundation
import TapSnapActionsBar
import TapSnapConfig
import TapSnapTheme

/// 悬浮球以屏幕坐标拖动，边缘吸附后淡化；右键提供常用入口。
final class ToolBallController: ObservableObject {
    static let shared = ToolBallController()
    var onCapture: (() -> Void)?
    private var window: NSPanel?
    private var observation: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private var currentTheme: Theme = .dark
    private var hovering = false
    private let defaultsKey = "toolball.frame"
    private let visibleKey = "toolball.visible"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    @Published private(set) var isVisible = false

    func start(config: ConfigStore = .shared) {
        guard observation == nil else { return }
        observation = config.$settings.map(\.appearance.useDarkTheme).removeDuplicates().sink { [weak self] dark in
            guard let self else { return }
            currentTheme = dark ? .dark : .light
            (window?.contentView as? ToolBallView)?.theme = currentTheme
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self, let window else { return }; moveWindow(to: window.frame.origin)
        }
        if defaults.bool(forKey: visibleKey) { show() }
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard window == nil else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let visible = screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fallback = CGRect(x: visible.maxX - 76, y: visible.midY - 26, width: 52, height: 52)
        let saved = defaults.string(forKey: defaultsKey).map(NSRectFromString)
        let initial = saved.flatMap { $0.width > 0 && $0.height > 0 && $0.origin.x.isFinite && $0.origin.y.isFinite ? $0 : nil } ?? fallback
        let frame = Self.snapped(CGRect(origin: initial.origin, size: CGSize(width: 52, height: 52)), screens: screens)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        let view = ToolBallView(frame: CGRect(origin: .zero, size: frame.size), theme: currentTheme)
        view.onCapture = { [weak self] in self?.onCapture?() }
        view.onHide = { [weak self] in self?.hide() }
        view.onDragEnd = { [weak self] origin in self?.moveWindow(to: origin) }
        view.onHover = { [weak self] hovering in self?.hovering = hovering; self?.updateOpacity() }
        panel.contentView = view
        window = panel
        updateOpacity()
        panel.orderFrontRegardless()
        isVisible = true
        defaults.set(true, forKey: visibleKey)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        isVisible = false
        defaults.set(false, forKey: visibleKey)
    }

    private func moveWindow(to origin: CGPoint) {
        guard let window else { return }
        let frame = Self.snapped(CGRect(origin: origin, size: window.frame.size), screens: NSScreen.screens.map(\.visibleFrame))
        window.setFrame(frame, display: true)
        defaults.set(NSStringFromRect(frame), forKey: defaultsKey)
        updateOpacity()
    }

    private func updateOpacity() {
        guard let window else { return }
        let edge = Self.isNearEdge(window.frame, screens: NSScreen.screens.map(\.visibleFrame))
        window.alphaValue = hovering || !edge ? 1 : 0.48
    }

    static func snapped(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard let screen = screens.first(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                ?? screens.first(where: { $0.intersects(frame) }) ?? screens.first else { return frame }
        var result = frame
        result.origin.x = min(max(screen.minX + 8, frame.minX), screen.maxX - frame.width - 8)
        result.origin.y = min(max(screen.minY + 8, frame.minY), screen.maxY - frame.height - 8)
        if abs(result.minX - screen.minX) < 40 { result.origin.x = screen.minX + 8 }
        else if abs(result.maxX - screen.maxX) < 40 { result.origin.x = screen.maxX - frame.width - 8 }
        if abs(result.minY - screen.minY) < 40 { result.origin.y = screen.minY + 8 }
        else if abs(result.maxY - screen.maxY) < 40 { result.origin.y = screen.maxY - frame.height - 8 }
        return result
    }

    static func isNearEdge(_ frame: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { screen in
            screen.intersects(frame) && (abs(frame.minX - screen.minX) <= 10 || abs(frame.maxX - screen.maxX) <= 10
                                        || abs(frame.minY - screen.minY) <= 10 || abs(frame.maxY - screen.maxY) <= 10)
        }
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}

final class ToolBallView: NSView {
    var theme: Theme { didSet { needsDisplay = true } }
    var onCapture: (() -> Void)?
    var onHide: (() -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var dragged = false
    private var hover = false

    init(frame: CGRect, theme: Theme) {
        self.theme = theme
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityLabel("TapSnap 悬浮球：点击截图，右键显示功能菜单")
        setAccessibilityRole(.button)
        toolTip = "点击截图 · 右键更多功能 · 拖动移动"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true; onHover?(false) }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        NSColor(theme.token(hover ? .accent : .popover)).setFill(); circle.fill()
        NSColor(theme.token(.border)).setStroke(); circle.lineWidth = 1; circle.stroke()
        let path = NSBezierPath()
        for (x, y, dx, dy) in [(17.0, 17.0, 7.0, 7.0), (35, 17, -7, 7), (17, 35, 7, -7), (35, 35, -7, -7)] {
            path.move(to: CGPoint(x: x, y: y + dy)); path.line(to: CGPoint(x: x, y: y)); path.line(to: CGPoint(x: x + dx, y: y))
        }
        NSColor(theme.token(.foreground)).setStroke(); path.lineWidth = 2; path.lineCapStyle = .round; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        let delta = CGPoint(x: point.x - startMouse.x, y: point.y - startMouse.y)
        if hypot(delta.x, delta.y) > 3 { dragged = true }
        if dragged { window?.setFrameOrigin(CGPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?(window?.frame.origin ?? startOrigin) } else { onCapture?() }
    }
    override func accessibilityPerformPress() -> Bool { onCapture?(); return true }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [("截图", ActionKind.crop), ("剪贴板贴图", .pin), ("长截图", .longShot), ("录屏", .record), ("文字识别", .ocr)] {
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏悬浮球", action: #selector(hideBall), keyEquivalent: "")
        hide.target = self; menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ActionKind(rawValue: raw) else { return }
        NotificationCenter.default.post(name: .desktopBarAction, object: action)
    }
    @objc private func hideBall() { onHide?() }
}
