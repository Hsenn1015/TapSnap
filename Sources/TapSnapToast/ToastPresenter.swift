import AppKit
import Combine
import TapSnapTheme
import SwiftUI

/// Toast 的宿主窗口。
///
/// `ToastCenter` 只维护队列，真正把它显示到屏幕上需要这里创建一个不抢焦点的
/// 浮层窗口。之前缺了这一层，所有 toast（包括「截图失败」这类关键错误）都
/// 只是进了队列没人渲染，用户看到的就是「点了没反应」。
@MainActor
public final class ToastPresenter {
    private let center: ToastCenter
    private let theme: () -> Theme
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var hideID: UUID?

    public convenience init(center: ToastCenter = .shared, theme: Theme = .dark) {
        self.init(center: center, theme: { theme })
    }

    public init(center: ToastCenter, theme: @escaping () -> Theme) {
        self.center = center
        self.theme = theme
    }

    public var windowID: CGWindowID? {
        guard let panel, panel.isVisible, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    /// 开始监听队列，有消息就浮出窗口。
    public func install() {
        cancellable = center.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                self?.update(for: messages)
            }
    }

    private func update(for messages: [ToastMessage]) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !messages.isEmpty else {
            guard let panel, panel.isVisible, hideID == nil else { return }
            if reduceMotion {
                panel.orderOut(nil)
                return
            }
            let id = UUID()
            hideID = id
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.hideID == id else { return }
                    panel.orderOut(nil)
                    self.hideID = nil
                }
            }
            return
        }

        guard let screen = activeScreen() else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let root = ToastStackView(messages: messages, theme: theme()) { [weak center] id in
            center?.dismiss(id)
        }
        let host: NSHostingController<ToastStackView>
        if let existing = panel.contentViewController as? NSHostingController<ToastStackView> {
            existing.rootView = root
            host = existing
        } else {
            host = NSHostingController(rootView: root)
            host.sizingOptions = []
            panel.contentViewController = host
        }
        let visible = screen.visibleFrame
        let size = host.sizeThatFits(in: CGSize(width: min(408, visible.width - 24),
                                               height: visible.height - 24))
        let frame = Self.panelFrame(size: size, visible: visible)
        let entering = !panel.isVisible || hideID != nil
        hideID = nil
        panel.setFrame(frame, display: true)
        guard entering else { return }

        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.setFrame(frame.offsetBy(dx: 0, dy: -7), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    static func panelFrame(size: CGSize, visible: CGRect) -> CGRect {
        CGRect(x: visible.midX - size.width / 2, y: visible.minY + 22, width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = "TapSnap 提示"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.sharingType = .none
        return panel
    }

    /// 跟设置窗口一致：按鼠标所在屏幕，而不是 `NSScreen.main`。
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens.first
    }
}
