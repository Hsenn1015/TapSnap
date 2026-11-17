import AppKit
import TapSnapMedia

/// 接收视频画面上的标注手势，坐标使用相对于实际画面的左上角比例。
@MainActor
final class RecordingAnnotationCanvas: NSView {
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { updateInteraction() } } }
    var tool: RecordingAnnotation.Kind? {
        didSet {
            guard tool != oldValue else { return }
            gesture = nil
            pathPoints.removeAll(keepingCapacity: true)
            updateInteraction()
        }
    }
    var style: RecordingAnnotation.Style? {
        didSet { if style != oldValue { needsDisplay = true } }
    }
    var isInteractionEnabled = false {
        didSet {
            guard isInteractionEnabled != oldValue else { return }
            if !isInteractionEnabled {
                gesture = nil
                pathPoints.removeAll(keepingCapacity: true)
            }
            updateInteraction()
        }
    }
    var selectedAnnotation: RecordingAnnotation? {
        didSet { if selectedAnnotation != oldValue { updateInteraction() } }
    }
    var visibleAnnotations: [RecordingAnnotation] = [] {
        didSet { if visibleAnnotations != oldValue { updateInteraction() } }
    }

    var onCreate: ((RecordingAnnotation.Kind, CGPoint, CGPoint) -> Void)?
    var onCreatePath: ((RecordingAnnotation.Kind, [CGPoint]) -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onEditText: ((UUID) -> Void)?
    var onChangeGeometry: ((UUID, CGPoint, CGPoint, [CGPoint]) -> Void)?

    private enum Handle: Equatable {
        case corner(left: Bool, top: Bool)
        case start, end
    }

    private enum Adjustment {
        case move
        case resize(Handle)
    }

    private enum Gesture {
        case creating(RecordingAnnotation.Kind, start: CGPoint, end: CGPoint)
        case drawingPath(RecordingAnnotation.Kind)
        case adjusting(RecordingAnnotation, Adjustment, anchor: CGPoint, end: CGPoint)
    }

    private var gesture: Gesture? { didSet { needsDisplay = true } }
    private var pathPoints: [CGPoint] = []
    private static let handleSize: CGFloat = 7
    private static let minimumSize: CGFloat = 3

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updateInteraction() }
    }

    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled, !isHidden else { return nil }
        let local = convert(point, from: superview)
        if bounds.contains(local), let selection = selectedAnnotation, handle(at: local, for: selection) != nil { return self }
        guard videoRect.contains(local) else { return nil }
        if tool != nil { return self }
        return annotation(at: local) == nil ? nil : self
    }

    override func resetCursorRects() {
        guard isInteractionEnabled, !videoRect.isEmpty else { return }
        if let tool {
            addCursorRect(videoRect, cursor: tool == .text ? .iBeam : .crosshair)
        }
        for annotation in visibleAnnotations {
            let rect = selectionRect(for: annotation)
            if !rect.isEmpty { addCursorRect(rect, cursor: .openHand) }
        }
        if let selection = selectedAnnotation {
            for (_, rect) in handleRects(for: selection) {
                let hit = rect.insetBy(dx: -4, dy: -4).intersection(bounds)
                if !hit.isEmpty { addCursorRect(hit, cursor: .crosshair) }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard isInteractionEnabled else { return }
        let point = normalizedPoint(local)
        if let selection = selectedAnnotation, let handle = handle(at: local, for: selection) {
            gesture = .adjusting(selection, .resize(handle), anchor: point, end: point)
            return
        }
        guard videoRect.contains(local) else { return }
        let hit = annotation(at: local)
        if let hit, hit.kind == .text, event.clickCount == 2, let onEditText {
            onEditText(hit.id)
        } else if let annotation = hit {
            onSelect?(annotation.id)
            gesture = .adjusting(annotation, .move, anchor: point, end: point)
            NSCursor.closedHand.set()
        } else if let tool, tool == .pen || tool == .highlight {
            pathPoints = [point]
            gesture = .drawingPath(tool)
        } else if let tool {
            gesture = .creating(tool, start: point, end: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        extendGesture(to: normalizedPoint(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        extendGesture(to: normalizedPoint(convert(event.locationInWindow, from: nil)), includingRelease: true)
        let completed = gesture
        gesture = nil
        defer { pathPoints.removeAll(keepingCapacity: true) }
        switch completed {
        case let .creating(kind, start, end):
            let dx = abs(end.x - start.x) * videoRect.width
            let dy = abs(end.y - start.y) * videoRect.height
            switch kind {
            case .text:
                onCreate?(kind, start, start)
            case .arrow, .line:
                if hypot(dx, dy) >= Self.minimumSize { onCreate?(kind, start, end) }
            case .rectangle, .ellipse, .mask:
                if dx >= Self.minimumSize, dy >= Self.minimumSize { onCreate?(kind, start, end) }
            case .pen, .highlight:
                break
            }
        case let .drawingPath(kind):
            if !pathPoints.isEmpty { onCreatePath?(kind, pathPoints) }
        case let .adjusting(annotation, adjustment, anchor, end):
            if case .move = adjustment { NSCursor.openHand.set() }
            let adjusted = adjustedAnnotation(annotation, by: adjustment, anchor: anchor, end: end)
            if adjusted != annotation {
                onChangeGeometry?(adjusted.id, adjusted.startPoint, adjusted.endPoint, adjusted.points)
            }
        case nil:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let frame = videoRect
        guard !frame.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        var annotations = visibleAnnotations
        var selection = selectedAnnotation
        switch gesture {
        case let .creating(kind, start, end):
            if kind != .text, let draft = draftAnnotation(kind, from: start, to: end) {
                annotations.append(draft)
            }
        case let .drawingPath(kind):
            if let start = pathPoints.first, let end = pathPoints.last,
               let draft = draftAnnotation(kind, from: start, to: end, points: pathPoints) {
                annotations.append(draft)
            }
        case let .adjusting(annotation, adjustment, anchor, end):
            let adjusted = adjustedAnnotation(annotation, by: adjustment, anchor: anchor, end: end)
            if let index = annotations.firstIndex(where: { $0.id == adjusted.id }) {
                annotations[index] = adjusted
            }
            selection = adjusted
        case nil:
            break
        }
        drawAnnotations(annotations, in: context)
        if let selection, isInteractionEnabled { drawSelection(selection, in: context) }
    }

    private func updateInteraction() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func draftAnnotation(_ kind: RecordingAnnotation.Kind, from start: CGPoint, to end: CGPoint,
                                 points: [CGPoint] = []) -> RecordingAnnotation? {
        guard let range = try? RecordingTimeRange(start: 0, end: 1) else { return nil }
        return RecordingAnnotation(kind: kind, startPoint: start, endPoint: end, range: range,
                                   style: style, points: points)
    }

    private func extendGesture(to point: CGPoint, includingRelease: Bool = false) {
        switch gesture {
        case let .creating(kind, start, _): gesture = .creating(kind, start: start, end: point)
        case .drawingPath:
            guard let last = pathPoints.last, last != point else { return }
            let frame = videoRect
            let distance = hypot((point.x - last.x) * frame.width, (point.y - last.y) * frame.height)
            guard distance >= 1 || includingRelease else { return }
            pathPoints.append(point)
            needsDisplay = true
        case let .adjusting(annotation, adjustment, anchor, _):
            gesture = .adjusting(annotation, adjustment, anchor: anchor, end: point)
        case nil: break
        }
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint {
        let frame = videoRect
        guard !frame.isEmpty else { return .zero }
        return CGPoint(x: min(1, max(0, (point.x - frame.minX) / frame.width)),
                       y: min(1, max(0, (point.y - frame.minY) / frame.height)))
    }

    private func annotationRect(for annotation: RecordingAnnotation) -> CGRect {
        let frame = videoRect
        guard !frame.isEmpty else { return .zero }
        var bounds = RecordingAnnotationRenderer.bounds(of: annotation, size: videoSize)
        if annotation.kind == .line {
            let radius = RecordingAnnotationRenderer.lineWidth(of: annotation, size: videoSize) / 2
            bounds = bounds.insetBy(dx: -radius, dy: -radius)
        }
        return bounds
            .applying(.init(scaleX: frame.width / videoSize.width, y: frame.height / videoSize.height))
            .offsetBy(dx: frame.minX, dy: frame.minY)
    }

    private func selectionRect(for annotation: RecordingAnnotation) -> CGRect {
        annotationRect(for: annotation).insetBy(dx: -4, dy: -4).intersection(videoRect)
    }

    private func annotation(at point: CGPoint) -> RecordingAnnotation? {
        // 命中顺序与渲染顺序一致，重叠时选择最上层的标注。
        visibleAnnotations.reversed().first { annotation in
            guard selectionRect(for: annotation).contains(point) else { return false }
            switch annotation.kind {
            case .line, .pen, .highlight:
                return hitStroke(of: annotation, at: point)
            default:
                return true
            }
        }
    }

    private func hitStroke(of annotation: RecordingAnnotation, at point: CGPoint) -> Bool {
        let frame = videoRect
        let points = annotation.points.isEmpty ? [annotation.startPoint, annotation.endPoint] : annotation.points
        guard let first = points.first else { return false }
        let width = RecordingAnnotationRenderer.lineWidth(of: annotation, size: videoSize) * frame.width / videoSize.width
        let tolerance = width / 2 + 4
        func position(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
        }
        var start = position(first)
        if hypot(point.x - start.x, point.y - start.y) <= tolerance { return true }
        for next in points.dropFirst() {
            let end = position(next)
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            if lengthSquared > 0 {
                let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
                let fraction = min(1, max(0, projection))
                if hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy)) <= tolerance {
                    return true
                }
            }
            start = end
        }
        return false
    }

    private func handleRects(for annotation: RecordingAnnotation) -> [(Handle, CGRect)] {
        let frame = videoRect
        let half = Self.handleSize / 2
        func handleRect(_ point: CGPoint) -> CGRect {
            CGRect(x: frame.minX + point.x * frame.width - half,
                   y: frame.minY + point.y * frame.height - half,
                   width: Self.handleSize, height: Self.handleSize)
        }
        switch annotation.kind {
        case .arrow, .line:
            return [(.start, handleRect(annotation.startPoint)), (.end, handleRect(annotation.endPoint))]
        case .rectangle, .ellipse, .mask:
            let start = annotation.startPoint, end = annotation.endPoint
            let left = min(start.x, end.x), right = max(start.x, end.x)
            let top = min(start.y, end.y), bottom = max(start.y, end.y)
            return [
                (.corner(left: true, top: true), handleRect(CGPoint(x: left, y: top))),
                (.corner(left: false, top: true), handleRect(CGPoint(x: right, y: top))),
                (.corner(left: true, top: false), handleRect(CGPoint(x: left, y: bottom))),
                (.corner(left: false, top: false), handleRect(CGPoint(x: right, y: bottom)))
            ]
        case .text, .pen, .highlight:
            return []
        }
    }

    private func handle(at point: CGPoint, for annotation: RecordingAnnotation) -> Handle? {
        handleRects(for: annotation)
            .filter { $0.1.insetBy(dx: -4, dy: -4).contains(point) }
            .min { lhs, rhs in
                hypot(lhs.1.midX - point.x, lhs.1.midY - point.y) < hypot(rhs.1.midX - point.x, rhs.1.midY - point.y)
            }?.0
    }

    private func adjustedAnnotation(_ annotation: RecordingAnnotation, by adjustment: Adjustment,
                                    anchor: CGPoint, end: CGPoint) -> RecordingAnnotation {
        switch adjustment {
        case .move:
            return movedAnnotation(annotation, anchor: anchor, end: end)
        case .resize(let handle):
            return resizedAnnotation(annotation, handle: handle, anchor: anchor, end: end)
        }
    }

    private func resizedAnnotation(_ annotation: RecordingAnnotation, handle: Handle,
                                   anchor: CGPoint, end: CGPoint) -> RecordingAnnotation {
        let frame = videoRect
        let dx = end.x - anchor.x
        let dy = end.y - anchor.y
        guard !frame.isEmpty, dx != 0 || dy != 0 else { return annotation }
        var adjusted = annotation
        switch handle {
        case let .corner(left, top):
            let a = annotation.startPoint, b = annotation.endPoint
            var topLeft = CGPoint(x: min(a.x, b.x), y: min(a.y, b.y))
            var bottomRight = CGPoint(x: max(a.x, b.x), y: max(a.y, b.y))
            let minWidth = min(Self.minimumSize / frame.width, bottomRight.x - topLeft.x)
            let minHeight = min(Self.minimumSize / frame.height, bottomRight.y - topLeft.y)
            if left { topLeft.x = min(bottomRight.x - minWidth, max(0, topLeft.x + dx)) }
            else { bottomRight.x = max(topLeft.x + minWidth, min(1, bottomRight.x + dx)) }
            if top { topLeft.y = min(bottomRight.y - minHeight, max(0, topLeft.y + dy)) }
            else { bottomRight.y = max(topLeft.y + minHeight, min(1, bottomRight.y + dy)) }
            adjusted.startPoint = topLeft
            adjusted.endPoint = bottomRight
        case .start, .end:
            let movesStart = handle == .start
            let original = movesStart ? annotation.startPoint : annotation.endPoint
            let other = movesStart ? annotation.endPoint : annotation.startPoint
            let candidate = CGPoint(x: min(1, max(0, original.x + dx)), y: min(1, max(0, original.y + dy)))
            let minimum = min(Self.minimumSize, hypot((original.x - other.x) * frame.width, (original.y - other.y) * frame.height))
            guard hypot((candidate.x - other.x) * frame.width, (candidate.y - other.y) * frame.height) >= minimum
            else { return annotation }
            if movesStart { adjusted.startPoint = candidate }
            else { adjusted.endPoint = candidate }
        }
        return adjusted
    }

    private func movedAnnotation(_ annotation: RecordingAnnotation, anchor: CGPoint, end: CGPoint) -> RecordingAnnotation {
        let frame = videoRect
        let original = annotationRect(for: annotation).intersection(frame)
        guard !frame.isEmpty, !original.isNull else { return annotation }
        let dx = min(frame.maxX - original.maxX, max(frame.minX - original.minX, (end.x - anchor.x) * frame.width))
        let dy = min(frame.maxY - original.maxY, max(frame.minY - original.minY, (end.y - anchor.y) * frame.height))
        guard dx != 0 || dy != 0 else { return annotation }
        var moved = annotation
        let start = annotation.kind == .text ? normalizedPoint(original.origin) : annotation.startPoint
        moved.startPoint = CGPoint(x: start.x + dx / frame.width, y: start.y + dy / frame.height)
        moved.endPoint = annotation.kind == .text ? moved.startPoint : CGPoint(
            x: annotation.endPoint.x + dx / frame.width, y: annotation.endPoint.y + dy / frame.height
        )
        moved.points = annotation.points.map {
            CGPoint(x: $0.x + dx / frame.width, y: $0.y + dy / frame.height)
        }
        return moved
    }

    private func drawSelection(_ annotation: RecordingAnnotation, in context: CGContext) {
        let frame = selectionRect(for: annotation)
        guard !frame.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        context.setLineWidth(3)
        context.stroke(frame)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(frame)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(1)
        context.setFillColor(NSColor.white.cgColor)
        for (_, rect) in handleRects(for: annotation) {
            context.fill(rect)
            context.stroke(rect)
        }
    }

    private func drawAnnotations(_ annotations: [RecordingAnnotation], in context: CGContext) {
        guard !annotations.isEmpty else { return }
        let frame = videoRect
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: frame.width / videoSize.width, y: frame.height / videoSize.height)
        RecordingAnnotationRenderer.draw(annotations, in: context, size: videoSize)
    }
}
