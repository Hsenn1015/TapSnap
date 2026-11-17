import AppKit

/// 贴图外的光晕单独绘制，贴图本身仍使用原来的窗口尺寸。
final class PinHaloPanel: NSPanel {
    static let padding: CGFloat = 22

    static func frame(around pinFrame: NSRect) -> NSRect {
        pinFrame.insetBy(dx: -padding, dy: -padding)
    }

    init(pinFrame: NSRect) {
        let frame = Self.frame(around: pinFrame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        contentView = PinHaloView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PinHaloView: NSView {
    private static let mint = CGColor(red: 0.25, green: 0.83, blue: 0.77, alpha: 0.22)
    private static let lavender = CGColor(red: 0.61, green: 0.50, blue: 0.95, alpha: 0.22)

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let padding = PinHaloPanel.padding
        let opening = bounds.insetBy(dx: padding, dy: padding)
        guard !opening.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }
        // 保留矩形开口，透明图片的像素也不会被光晕染色。
        context.addRect(bounds)
        context.addRect(opening)
        context.clip(using: .evenOdd)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let (left, right) = opening.divided(atDistance: opening.width / 2, from: .minXEdge)
        context.setShadow(offset: .zero, blur: 11, color: Self.mint)
        context.fill(left)
        context.setShadow(offset: .zero, blur: 11, color: Self.lavender)
        context.fill(right)
    }
}
