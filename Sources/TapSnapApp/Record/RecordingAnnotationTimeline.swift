import AppKit
import TapSnapMedia

/// 标注沿用裁剪时间轴的横坐标，时间重叠的标注分别显示在不同的行。
@MainActor
final class RecordingAnnotationTimeline: NSView {
    var duration: TimeInterval = 0 { didSet { refresh() } }
    var playhead: TimeInterval = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    var trimRange: RecordingTimeRange? { didSet { needsDisplay = true } }
    var annotations: [RecordingAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            arrangeClips()
        }
    }
    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            revealSelection()
            refresh()
        }
    }
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                drag = nil
                isScrubbing = false
            }
            refresh()
        }
    }
    var accentColor = NSColor.controlAccentColor { didSet { needsDisplay = true } }
    var minimumDuration: TimeInterval = 1.0 / 60
    var onSelect: ((UUID) -> Void)?
    var onSeek: ((TimeInterval, Bool) -> Void)?
    var onPreviewRange: ((UUID, RecordingTimeRange) -> Void)?
    var onChangeRange: ((UUID, RecordingTimeRange) -> Void)?

    private struct Clip {
        let annotation: RecordingAnnotation
        let row: Int
    }

    private enum DragTarget { case start, end, body }

    private struct Drag {
        let clip: Clip
        let target: DragTarget
        let origin: CGFloat
        let selectOnClick: Bool
        var range: RecordingTimeRange

        var edgeTime: TimeInterval? {
            switch target {
            case .start: return range.start
            case .end: return range.end
            case .body: return nil
            }
        }
    }

    private let rowHeight: CGFloat = 22
    private let maxVisibleRows = 3
    private var clips: [Clip] = []
    private var rowCount = 1
    private var rowOffset: CGFloat = 0
    private var drag: Drag?
    private var isScrubbing = false
    private var track: CGRect { bounds.insetBy(dx: 11, dy: 3) }
    private var visibleRowCount: Int { min(maxVisibleRows, rowCount) }
    private var maxRowOffset: CGFloat { max(0, CGFloat(rowCount) * rowHeight - max(0, track.height)) }
    private var selection: Clip? { clips.first { $0.annotation.id == selectedID } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
        CGSize(width: NSView.noIntrinsicMetric, height: CGFloat(visibleRowCount) * rowHeight + 6)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("标注时间轴")
        toolTip = "点按标注跳转，拖动中间移动整段，拖动两端调整时长"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            rowOffset = min(rowOffset, maxRowOffset)
            revealSelection()
            refresh()
        }
    }

    private func arrangeClips() {
        let sorted = annotations.enumerated().sorted { lhs, rhs in
            let first = lhs.element.range.start, second = rhs.element.range.start
            return first == second ? lhs.offset < rhs.offset : first < second
        }.map(\.element)
        let previous = Dictionary(uniqueKeysWithValues: clips.map { ($0.annotation.id, $0) })
        var rows = [[Clip]](repeating: [], count: rowCount)
        var changed: [RecordingAnnotation] = []
        // 先让时间未变的标注留在原行，再给改动或新增的标注排位置。
        for annotation in sorted {
            if let clip = previous[annotation.id], clip.annotation.range == annotation.range {
                rows[clip.row].append(Clip(annotation: annotation, row: clip.row))
            } else {
                changed.append(annotation)
            }
        }
        for annotation in changed {
            let range = annotation.range
            func fits(_ row: [Clip]) -> Bool {
                row.allSatisfy { $0.annotation.range.end <= range.start || range.end <= $0.annotation.range.start }
            }
            let preferred = previous[annotation.id]?.row
            let row = preferred.flatMap { fits(rows[$0]) ? $0 : nil } ?? rows.firstIndex(where: fits) ?? rows.count
            if row == rows.count { rows.append([]) }
            rows[row].append(Clip(annotation: annotation, row: row))
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        clips = rows.flatMap { $0.sorted { $0.annotation.range.start < $1.annotation.range.start } }
        rowCount = max(1, rows.count)
        rowOffset = min(rowOffset, maxRowOffset)
        revealSelection()
        invalidateIntrinsicContentSize()
        refresh()
    }

    private func revealSelection() {
        guard let selection, track.height > 0 else { return }
        let start = CGFloat(selection.row) * rowHeight
        rowOffset = min(maxRowOffset, max(start + rowHeight - track.height, min(start, rowOffset)))
    }

    private func refresh() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard track.width > 0, track.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        // 无标注时彻底保持透明，避免底部出现突兀的灰色空块。
        guard !clips.isEmpty else { return }
        context.saveGState()
        let background = NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7)
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        background.fill()
        background.addClip()
        for clip in clips where frame(for: clip).intersects(track) {
            draw(clip)
        }
        if let trimRange {
            NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
            let start = x(at: trimRange.start), end = x(at: trimRange.end)
            CGRect(x: track.minX, y: track.minY, width: start - track.minX, height: track.height).fill()
            CGRect(x: end, y: track.minY, width: track.maxX - end, height: track.height).fill()
        }
        if let selection, frame(for: selection).intersects(track) {
            for handle in handles(for: selection) {
                accentColor.setFill()
                NSBezierPath(roundedRect: handle.mark, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        if duration > 0 {
            let position = x(at: drag?.edgeTime ?? playhead)
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            CGRect(x: position - 0.5, y: track.minY, width: 1, height: track.height).fill()
        }
        context.restoreGState()
        if maxRowOffset > 0 {
            let height = track.height * track.height / (CGFloat(rowCount) * rowHeight)
            let y = track.minY + (track.height - height) * rowOffset / maxRowOffset
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: CGRect(x: track.maxX + 4, y: y, width: 3, height: height),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func draw(_ clip: Clip) {
        let rect = frame(for: clip)
        let selected = clip.annotation.id == selectedID
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (selected ? accentColor.withAlphaComponent(0.24) : accentColor.withAlphaComponent(0.10)).setFill()
        body.fill()
        (selected ? accentColor : accentColor.withAlphaComponent(0.32)).setStroke()
        body.stroke()
        guard rect.width >= 21 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (clip.annotation.kind.title as NSString).draw(in: rect.insetBy(dx: 6, dy: 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    private func frame(for clip: Clip) -> CGRect {
        let range = drag.flatMap { $0.clip.annotation.id == clip.annotation.id ? $0.range : nil } ?? clip.annotation.range
        let left = x(at: range.start), right = x(at: range.end)
        let width = min(track.width, max(5, right - left))
        let origin = min(max(track.minX, (left + right - width) / 2), track.maxX - width)
        return CGRect(x: origin, y: track.minY + CGFloat(clip.row) * rowHeight - rowOffset + 2, width: width, height: rowHeight - 4)
    }

    private func handles(for clip: Clip) -> [(target: DragTarget, mark: CGRect, hit: CGRect)] {
        let rect = frame(for: clip)
        // 短色条也保留中间的拖动区域，两端可以从色条外侧抓住。
        let inside = min(4, rect.width / 3)
        return [(DragTarget.start, rect.minX), (.end, rect.maxX)].map { target, x in
            let mark = CGRect(x: x - 1.5, y: rect.minY + 3, width: 3, height: rect.height - 6)
            let hit = CGRect(x: target == .start ? x - 5 : x - inside, y: rect.minY,
                             width: 5 + inside, height: rect.height)
                .intersection(bounds.insetBy(dx: 0, dy: 3))
            return (target, mark, hit)
        }
    }

    override func resetCursorRects() {
        guard isEnabled, duration > 0, track.width > 0 else { return }
        addCursorRect(track, cursor: .crosshair)
        for clip in clips {
            let rect = frame(for: clip).intersection(track)
            guard !rect.isEmpty else { continue }
            addCursorRect(rect, cursor: .openHand)
            for handle in handles(for: clip) {
                let hit = clip.annotation.id == selectedID ? handle.hit : handle.hit.intersection(rect)
                if !hit.isEmpty { addCursorRect(hit, cursor: .resizeLeftRight) }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, duration > 0, track.width > 0, window?.makeFirstResponder(nil) != false else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 先命中实际色条，避免邻接色条被已选标注的外侧手柄抢走鼠标事件。
        if let clip = clips.last(where: { frame(for: $0).intersection(track).contains(point) }) {
            let target = handles(for: clip).first { $0.hit.contains(point) }?.target ?? .body
            beginDrag(clip, target: target, at: point.x)
        } else if let selection, let handle = handles(for: selection).first(where: { $0.hit.contains(point) }) {
            beginDrag(selection, target: handle.target, at: point.x)
        } else if track.contains(point) {
            isScrubbing = true
            onSeek?(time(at: point.x), true)
        }
    }

    private func beginDrag(_ clip: Clip, target: DragTarget, at x: CGFloat) {
        let alreadySelected = selectedID == clip.annotation.id
        drag = Drag(clip: clip, target: target, origin: x,
                    selectOnClick: alreadySelected && target == .body, range: clip.annotation.range)
        if !alreadySelected { onSelect?(clip.annotation.id) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, duration > 0, track.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if drag != nil {
            updateDrag(at: x)
        } else if isScrubbing {
            onSeek?(time(at: x), true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if let drag, track.width > 0, x != drag.origin || drag.range != drag.clip.annotation.range {
            updateDrag(at: x)
        }
        let finished = drag
        let wasScrubbing = isScrubbing
        drag = nil
        isScrubbing = false
        refresh()
        if let finished, finished.range != finished.clip.annotation.range {
            onChangeRange?(finished.clip.annotation.id, finished.range)
        } else if let finished, finished.selectOnClick, abs(x - finished.origin) < 3 {
            onSelect?(finished.clip.annotation.id)
        } else if wasScrubbing, track.width > 0 {
            onSeek?(time(at: x), false)
        }
    }

    private func updateDrag(at x: CGFloat) {
        guard var drag else { return }
        let delta = duration * Double((x - drag.origin) / track.width)
        let original = drag.clip.annotation.range
        let minimum = min(original.duration, minimumDuration)
        let start: TimeInterval
        let end: TimeInterval
        switch drag.target {
        case .start:
            start = min(max(0, original.start + delta), original.end - minimum)
            end = original.end
        case .end:
            start = original.start
            end = max(min(duration, original.end + delta), original.start + minimum)
        case .body:
            let shift = abs(x - drag.origin) < 3 ? 0 : min(max(-original.start, delta), duration - original.end)
            start = original.start + shift
            end = original.end + shift
        }
        guard let range = try? RecordingTimeRange(start: start, end: end), range != drag.range else { return }
        drag.range = range
        self.drag = drag
        needsDisplay = true
        onPreviewRange?(drag.clip.annotation.id, range)
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxRowOffset > 0, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? 1 : rowHeight
        rowOffset = min(max(0, rowOffset - event.scrollingDeltaY * step), maxRowOffset)
        refresh()
    }

    private func x(at time: TimeInterval) -> CGFloat {
        track.minX + track.width * (duration > 0 ? min(1, max(0, time / duration)) : 0)
    }

    private func time(at x: CGFloat) -> TimeInterval {
        duration * Double(min(1, max(0, (x - track.minX) / track.width)))
    }
}
