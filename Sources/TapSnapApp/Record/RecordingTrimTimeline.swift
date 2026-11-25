import AppKit
import TapSnapMedia

/// 液态玻璃裁剪时间轴：圆润胶片轨、柔和强调色双把手、拖动实时时间浮标。
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
    var isDark: Bool = true { didSet { needsDisplay = true } }
    var accentColor = NSColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1) {
        didSet { needsDisplay = true }
    }

    private var target: Target?
    private var grabOffset: CGFloat = 0
    private var track: CGRect { bounds.insetBy(dx: 11, dy: 6) }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, track.width > 0, track.height > 0 else { return }

        // 1. 胶片底槽
        context.saveGState()
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8)
        trackPath.addClip()
        let baseFill = isDark
            ? NSColor(srgbRed: 0.14, green: 0.17, blue: 0.24, alpha: 0.92)
            : NSColor(srgbRed: 0.86, green: 0.89, blue: 0.94, alpha: 0.95)
        baseFill.setFill()
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
            if index < thumbnails.count - 1 {
                (isDark ? NSColor.black.withAlphaComponent(0.28) : NSColor.white.withAlphaComponent(0.35)).setFill()
                CGRect(x: slot.maxX - 0.5, y: slot.minY, width: 1, height: slot.height).fill()
            }
        }

        // 2. 裁剪外侧暗化遮罩
        if let range {
            let left = x(at: range.start), right = x(at: range.end)
            NSColor(srgbRed: 0.04, green: 0.06, blue: 0.10, alpha: isDark ? 0.64 : 0.48).setFill()
            CGRect(x: track.minX, y: track.minY, width: max(0, left - track.minX), height: track.height).fill()
            CGRect(x: right, y: track.minY, width: max(0, track.maxX - right), height: track.height).fill()
        }
        context.restoreGState()

        // 细边框让浅色录制画面也有边界感
        let border = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
        border.setStroke()
        let borderPath = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        borderPath.lineWidth = 1
        borderPath.stroke()

        guard let range else { return }
        let left = x(at: range.start), right = x(at: range.end)

        // 3. 选中区间上下光条
        accentColor.setFill()
        CGRect(x: left, y: track.minY, width: max(0, right - left), height: 2.5).fill()
        CGRect(x: left, y: track.maxY - 2.5, width: max(0, right - left), height: 2.5).fill()

        // 4. 液态玻璃圆角双把手（带白色防滑握条）
        let handleWidth: CGFloat = 10
        for (index, handleX) in [left - handleWidth, right].enumerated() {
            let handle = CGRect(x: handleX, y: track.minY, width: handleWidth, height: track.height)
            let isActive = (index == 0 && target == .start) || (index == 1 && target == .end)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 4,
                              color: NSColor.black.withAlphaComponent(0.24).cgColor)
            (isActive ? accentColor.blended(withFraction: 0.16, of: .white) ?? accentColor : accentColor).setFill()
            NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4).fill()
            context.restoreGState()

            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: CGRect(x: handle.midX - 0.9, y: handle.midY - 6, width: 1.8, height: 12),
                         xRadius: 0.9, yRadius: 0.9).fill()
        }

        // 5. 播放头（高对比细线 + 顶部圆珠）
        let position = x(at: playhead)
        let headColor = isDark ? NSColor.white : NSColor(srgbRed: 0.08, green: 0.11, blue: 0.18, alpha: 1)
        let haloColor = isDark ? NSColor.black.withAlphaComponent(0.50) : NSColor.white.withAlphaComponent(0.82)
        haloColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: position - 2, y: track.minY - 2, width: 4, height: track.height + 4),
                     xRadius: 2, yRadius: 2).fill()
        headColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: position - 1, y: track.minY - 2, width: 2, height: track.height + 4),
                     xRadius: 1, yRadius: 1).fill()

        let bead = CGRect(x: position - 4, y: track.maxY - 2, width: 8, height: 8)
        haloColor.setFill()
        NSBezierPath(ovalIn: bead.insetBy(dx: -1, dy: -1)).fill()
        headColor.setFill()
        NSBezierPath(ovalIn: bead).fill()

        // 6. 拖动把手时的实时时间浮标
        if let target, target == .start || target == .end {
            let activeTime = target == .start ? range.start : range.end
            let badgeText = String(format: "%.2fs", activeTime) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = badgeText.size(withAttributes: attrs)
            let pillW = textSize.width + 10
            let pillH: CGFloat = 17
            let anchorX = target == .start ? left : right
            let pillX = min(max(2, anchorX - pillW / 2), bounds.width - pillW - 2)
            let pillRect = CGRect(x: pillX, y: track.midY - pillH / 2, width: pillW, height: pillH)
            NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.90).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            badgeText.draw(at: CGPoint(x: pillRect.minX + 5, y: pillRect.minY + (pillH - textSize.height) / 2),
                           withAttributes: attrs)
        }
    }

    override func resetCursorRects() {
        guard isEnabled, let range else { return }
        addCursorRect(track, cursor: .crosshair)
        for time in [range.start, range.end] {
            addCursorRect(CGRect(x: x(at: time) - 10, y: track.minY, width: 20, height: track.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let range else { return }
        let point = convert(event.locationInWindow, from: nil)
        let left = x(at: range.start), right = x(at: range.end)
        let startDistance = abs(point.x - left), endDistance = abs(point.x - right)
        if min(startDistance, endDistance) <= 10 {
            let isStart = startDistance <= endDistance
            target = isStart ? .start : .end
            grabOffset = point.x - (isStart ? left : right)
        } else {
            target = .playhead
            grabOffset = 0
        }
        scrub(to: point.x, interactive: true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(to: convert(event.locationInWindow, from: nil).x, interactive: true)
    }

    override func mouseUp(with event: NSEvent) {
        scrub(to: convert(event.locationInWindow, from: nil).x, interactive: false)
        target = nil
        needsDisplay = true
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
