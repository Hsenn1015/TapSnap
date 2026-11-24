import AppKit
import Combine
import Foundation
import TapSnapActionsBar
import TapSnapConfig
import TapSnapIcons
import TapSnapScreen
import TapSnapSystem
import TapSnapTheme
import SwiftUI

/// 可从外观设置打开的常驻入口；跟随主题与屏幕布局变化。
final class DesktopBarController {
    private let config: ConfigStore
    private var window: NSPanel?
    private let model = DesktopBarModel()
    private var observation: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var currentTheme: Theme = .dark

    init(config: ConfigStore = .shared) { self.config = config }

    func start() {
        guard observation == nil else { return }
        observation = config.$settings.map(\.appearance).removeDuplicates().sink { [weak self] appearance in
            guard let self else { return }
            currentTheme = appearance.useDarkTheme ? .dark : .light
            if appearance.showDesktopBar { show(); updateContent() } else { hide() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self, let window else { return }
            window.setFrame(Self.visibleFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
        }
    }

    func show(on screen: ScreenDescriptor? = nil) {
        guard window == nil else { return }
        let visible = screen.flatMap { target in NSScreen.screens.first { candidate in
            (candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.id
        }}?.visibleFrame ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: CGFloat(model.actions.count) * 32 + 16, height: 36)
        let panel = NSPanel(contentRect: CGRect(x: visible.midX - size.width / 2,
                                               y: visible.maxY - size.height - 8, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ScreenCaptureProtection.apply(to: panel)
        window = panel
        updateContent()
        panel.orderFrontRegardless()
    }

    private func updateContent() {
        guard let window else { return }
        window.contentViewController = NSHostingController(rootView: DesktopBarView(model: model, theme: currentTheme,
            onAction: { action in NotificationCenter.default.post(name: .desktopBarAction, object: action) },
            onHide: { [weak self] in self?.config.update { $0.appearance.showDesktopBar = false } }))
    }

    func hide() { window?.orderOut(nil); window = nil }

    /// 开启演示模式时重建已打开的桌面工具栏，绕过 macOS 对 `.none` 的单向锁定。
    func refreshCaptureProtection() {
        guard let old = window, old.sharingType == .none else { return }
        let savedFrame = old.frame
        window = nil
        show()
        window?.setFrame(savedFrame, display: true)
        old.orderOut(nil)
    }

    static func visibleFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard let screen = screens.first(where: { $0.intersects(frame) }) ?? screens.first else { return frame }
        var result = frame
        result.origin.x = min(max(screen.minX, frame.minX), screen.maxX - frame.width)
        result.origin.y = min(max(screen.minY, frame.minY), screen.maxY - frame.height)
        return result
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}

extension Notification.Name {
    static let desktopBarAction = Notification.Name("com.sensnap.app.desktopBarAction")
}

final class DesktopBarModel: ObservableObject {
    @Published var actions: [ActionKind] = [.captureEntry, .pinEntry, .longShot, .record, .ocr]
}

struct DesktopBarView: View {
    @ObservedObject var model: DesktopBarModel
    var theme: Theme
    var onAction: (ActionKind) -> Void
    var onHide: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.actions, id: \.self) { action in
                IconButton(icon: action.icon, theme: theme) { onAction(action) }
                    .help(action == .crop ? "截图" : action == .pin ? "剪贴板贴图" : action.title)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .senPanelStyle(theme: theme)
        .contextMenu { Button("隐藏桌面工具栏", action: onHide) }
    }
}

extension ActionKind {
    static var captureEntry: ActionKind { .crop }
    static var pinEntry: ActionKind { .pin }
}
