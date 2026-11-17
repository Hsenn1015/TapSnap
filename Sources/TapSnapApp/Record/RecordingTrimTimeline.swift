import AppKit
import TapSnapMedia

/// 一条时间轴：左右手柄裁剪，点击或拖动中间的画面可查找帧。
@MainActor
final class RecordingTrimTimeline: NSView {
    enum Target { case start, end, playhead }

    var duration: TimeInterval = 0
    var range: RecordingTimeRange? { didSet { needsDisplay = true } }
    var playhead: TimeInterval = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    var thumbnails = [CGImage?](repeating: nil, count: 8) { didSet { needsDisplay = true } }
    var isEnabled = false {
        didSet {
            if !isEnabled { target = nil }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onScrub: ((Target, TimeInterval, Bool) -> Void)?
    var accentColor = NSColor(srgbRed: 0.40, green: 0.86, blue: 0.74, alpha: 1) {
        didSet { needsDisplay = true }
    }

    private var target: Target?
    private var grabOffset: CGFloat = 0
    private var track: CGRect { bounds.insetBy(dx: 11, dy: 4) }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, track.width > 0, track.height > 0 else { return }
        context.saveGState()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).addClip()
        NSColor(white: 0.15, alpha: 1).setFill()
        track.fill()

        let width = track.width / CGFloat(thumbnails.count)
        for (index, image) in thumbnails.enumerated() {
            let slot = CGRect(x: track.minX + CGFloat(index) * width, y: track.minY, width: width, height: track.height)
            if let image {
                context.saveGState()
                context.clip(to: slot)
                let size = CGSize(width: image.width, height: image.height)
                let scale = max(slot.width / size.width, slot.height / size.height)
                let drawn = CGSize(width: size.width * scale, height: size.height * scale)
                context.draw(image, in: CGRect(x: slot.midX - drawn.width / 2, y: slot.midY - drawn.height / 2,
                                               width: drawn.width, height: drawn.height))
                context.restoreGState()
            }
            NSColor.black.withAlphaComponent(0.3).setFill()
            CGRect(x: slot.maxX - 1, y: slot.minY, width: 1, height: slot.height).fill()
        }

        if let range {
            let left = x(at: range.start), right = x(at: range.end)
            NSColor.black.withAlphaComponent(0.72).setFill()
            CGRect(x: track.minX, y: track.minY, width: left - track.minX, height: track.height).fill()
            CGRect(x: right, y: track.minY, width: track.maxX - right, height: track.height).fill()
        }
        context.restoreGState()

        guard let range else { return }
        let left = x(at: range.start), right = x(at: range.end)
        accentColor.setFill()
        for y in [track.minY, track.maxY - 2] {
            CGRect(x: left, y: y, width: right - left, height: 2).fill()
        }
        for x in [left - 9, right] {
            let handle = CGRect(x: x, y: track.minY, width: 9, height: track.height)
            accentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: CGRect(x: handle.midX - 0.75, y: handle.midY - 5, width: 1.5, height: 10),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }
        let position = x(at: playhead)
        NSColor.black.withAlphaComponent(0.55).setFill()
        CGRect(x: position - 2, y: track.minY - 2, width: 4, height: track.height + 4).fill()
        NSColor.white.setFill()
        CGRect(x: position - 1, y: track.minY - 2, width: 2, height: track.height + 4).fill()
    }

    override func resetCursorRects() {
        guard isEnabled, let range else { return }
        addCursorRect(track, cursor: .crosshair)
        for time in [range.start, range.end] {
            addCursorRect(CGRect(x: x(at: time) - 9, y: track.minY, width: 18, height: track.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let range else { return }
        let point = convert(event.locationInWindow, from: nil)
        let left = x(at: range.start), right = x(at: range.end)
        let startDistance = abs(point.x - left), endDistance = abs(point.x - right)
        if min(startDistance, endDistance) <= 9 {
            let isStart = startDistance <= endDistance
            target = isStart ? .start : .end
            grabOffset = point.x - (isStart ? left : right)
        } else {
            target = .playhead
            grabOffset = 0
        }
        scrub(to: point.x, interactive: true)
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(to: convert(event.locationInWindow, from: nil).x, interactive: true)
    }

    override func mouseUp(with event: NSEvent) {
        scrub(to: convert(event.locationInWindow, from: nil).x, interactive: false)
        target = nil
        window?.invalidateCursorRects(for: self)
    }

    private func scrub(to x: CGFloat, interactive: Bool) {
        guard isEnabled, let target, track.width > 0 else { return }
        let fraction = (x - grabOffset - track.minX) / track.width
        onScrub?(target, duration * min(1, max(0, fraction)), interactive)
    }

    private func x(at time: TimeInterval) -> CGFloat {
        track.minX + track.width * (duration > 0 ? min(1, max(0, time / duration)) : 0)
    }
}
