import AppKit
import Combine
import SwiftUI
import TapSnapConfig
import TapSnapOCR
import TapSnapSystem
import TapSnapTheme

@MainActor
final class TranslationPanel: NSObject, NSWindowDelegate {
    private var window: TranslationWindow?
    private var appearanceObservation: AnyCancellable?

    func show(image: CGImage, document: OCRDocument? = nil, captureRect: CGRect? = nil,
              environment: AppEnvironment) {
        close()

        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let anchor = captureRect.map { rect in
            CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        let center = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Self.panelFrame(imageSize: CGSize(width: image.width, height: image.height),
                                    anchor: anchor, center: center, in: visible)

        let panel = TranslationWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let viewer = ScreenshotTranslationView(
            image: image,
            initialDocument: document,
            environment: environment,
            initialPinned: true,
            onTogglePin: { [weak panel] pinned in
                panel?.level = pinned ? .floating : .normal
            },
            onClose: { [weak self] in
                self?.close()
            },
            onRecapture: { [weak self, weak environment] in
                self?.close()
                environment?.captureCoordinator.start(.translate)
            }
        )

        let hosting = NSHostingController(rootView: viewer)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []

        panel.title = "\(AppInfo.displayName) 截图翻译"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.contentViewController = hosting
        panel.contentMinSize = CGSize(width: min(560, visible.width - 28), height: min(320, visible.height - 28))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: environment.theme.isDark ? .darkAqua : .aqua)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setFrame(frame, display: false)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        appearanceObservation = environment.config.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak panel, weak environment] _ in
                guard let panel, let environment else { return }
                panel.appearance = NSAppearance(named: environment.theme.isDark ? .darkAqua : .aqua)
            }

        self.window = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        appearanceObservation?.cancel()
        appearanceObservation = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    static func panelFrame(imageSize: CGSize, anchor: CGRect?, center: CGPoint, in visible: CGRect) -> CGRect {
        let available = visible.insetBy(dx: 14, dy: 14)
        let aspect = imageSize.height > 0 ? imageSize.width / imageSize.height : 1.5
        let isCompactStrip = (anchor?.height ?? imageSize.height) < 150 && aspect > 2.4

        let targetWidth: CGFloat = isCompactStrip ? 740 : 880
        let targetHeight: CGFloat
        if isCompactStrip {
            targetHeight = 380
        } else if aspect < 0.75 {
            targetHeight = 620
        } else {
            targetHeight = 540
        }

        let width = min(available.width, max(560, targetWidth))
        let height = min(available.height, max(340, targetHeight))
        let x = min(max(available.minX, center.x - width / 2), available.maxX - width)
        let y = min(max(available.minY, center.y - height / 2), available.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        appearanceObservation?.cancel()
        appearanceObservation = nil
        closing.contentViewController = nil
        window = nil
    }
}

private final class TranslationWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension AppEnvironment {
    func translateImage(_ image: CGImage, captureRect: CGRect? = nil, document: OCRDocument? = nil) {
        Task { @MainActor in
            translationPanel.show(image: image, document: document, captureRect: captureRect, environment: self)
        }
    }
}
