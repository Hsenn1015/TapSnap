import AppKit
import TapSnapConfig
import TapSnapScreen
import TapSnapSystem

/// 录制区域提示，不接收焦点或鼠标事件。
@MainActor
final class RecordingRegionOverlay: NSPanel {
    private let borderView: SelectionBorderView

    var isPaused: Bool {
        get { borderView.isPaused }
        set { borderView.isPaused = newValue }
    }

    init(rect: CGRect, screen: ScreenDescriptor, borderConfiguration: SelectionBorderConfiguration) {
        // 屏幕描述使用左上原点，AppKit 的全局和视图坐标使用左下原点。
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let frame = screen.appKitFrame(primaryDisplayHeight: desktopTop)
        borderView = SelectionBorderView(frame: CGRect(origin: .zero, size: frame.size))
        borderView.configuration = borderConfiguration
        borderView.selectionRect = CGRect(x: rect.minX, y: frame.height - rect.maxY,
                                          width: rect.width, height: rect.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .floating
        ScreenCaptureProtection.apply(to: self)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = borderView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        borderView.stopAnimating()
        super.close()
    }
}
