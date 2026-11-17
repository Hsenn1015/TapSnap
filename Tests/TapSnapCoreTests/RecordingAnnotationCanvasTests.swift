import AppKit
import TapSnapMedia
import XCTest
@testable import TapSnapApp

@MainActor
final class RecordingAnnotationCanvasTests: XCTestCase {
    func testLetterboxedCanvasClampsDragToVideoAndPassesThroughWhenIdle() throws {
        let (window, canvas) = try makeCanvas()
        let videoPoint = CGPoint(x: 100, y: 83.75)
        let parentPoint = canvas.convert(videoPoint, to: canvas.superview)
        XCTAssertNil(canvas.hitTest(parentPoint))

        canvas.tool = .rectangle
        XCTAssertTrue(canvas.hitTest(parentPoint) === canvas)
        let letterboxPoint = canvas.convert(CGPoint(x: 100, y: 15), to: canvas.superview)
        XCTAssertNil(canvas.hitTest(letterboxPoint))

        var geometry: (CGPoint, CGPoint)?
        canvas.onCreate = { kind, start, end in
            XCTAssertEqual(kind, .rectangle)
            geometry = (start, end)
        }
        canvas.mouseDown(with: try event(.leftMouseDown, at: videoPoint, canvas: canvas, window: window))
        canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 500, y: 223),
                                       canvas: canvas, window: window))

        let (start, end) = try XCTUnwrap(geometry)
        XCTAssertEqual(start.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(start.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(end.x, 1, accuracy: 0.001)
        XCTAssertEqual(end.y, (223 - 27.5) / 225, accuracy: 0.001)
    }

    func testDraggingVisibleMaskSelectsAndRendersItAtItsLivePosition() throws {
        let (window, canvas) = try makeCanvas()
        let mask = RecordingAnnotation(kind: .mask, startPoint: CGPoint(x: 0.4, y: 0.4),
                                       endPoint: CGPoint(x: 0.6, y: 0.6), range: try .init(start: 0, end: 1))
        canvas.visibleAnnotations = [mask]
        var selected: UUID?
        canvas.onSelect = { selected = $0 }
        var geometry: (CGPoint, CGPoint)?
        canvas.onChangeGeometry = { id, start, end, _ in
            XCTAssertEqual(id, mask.id)
            geometry = (start, end)
        }
        let original = try render(canvas)
        XCTAssertGreaterThan(darkPixels(in: original, column: 170), 35)
        XCTAssertEqual(darkPixels(in: original, column: 250), 0)

        canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 200, y: 140),
                                         canvas: canvas, window: window))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 240, y: 162.5),
                                            canvas: canvas, window: window))
        XCTAssertEqual(selected, mask.id)
        XCTAssertNil(geometry)
        let dragged = try render(canvas)
        XCTAssertEqual(darkPixels(in: dragged, column: 170), 0)
        XCTAssertGreaterThan(darkPixels(in: dragged, column: 250), 35)

        canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 240, y: 162.5),
                                       canvas: canvas, window: window))

        let (start, end) = try XCTUnwrap(geometry)
        XCTAssertEqual(start.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(start.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(end.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(end.y, 0.7, accuracy: 0.001)
    }

    func testSelectedMaskCanBeResizedRepeatedlyAndShowsLiveGeometry() throws {
        let (window, canvas) = try makeCanvas()
        var mask = RecordingAnnotation(kind: .mask, startPoint: CGPoint(x: 0.2, y: 0.2),
                                       endPoint: CGPoint(x: 0.4, y: 0.4), range: try .init(start: 1, end: 2))
        canvas.visibleAnnotations = [mask]
        canvas.selectedAnnotation = mask
        canvas.tool = .mask
        var changes = 0
        canvas.onCreate = { _, _, _ in XCTFail("拖动已有遮盖的控制点不应创建新遮盖") }
        canvas.onChangeGeometry = { [weak canvas] id, start, end, _ in
            XCTAssertEqual(id, mask.id)
            mask.startPoint = start
            mask.endPoint = end
            canvas?.visibleAnnotations = [mask]
            canvas?.selectedAnnotation = mask
            changes += 1
        }

        let start = CGPoint(x: 160, y: 117.5)
        let end = CGPoint(x: 280, y: 173.75)
        XCTAssertTrue(canvas.hitTest(canvas.convert(start, to: canvas.superview)) === canvas)
        XCTAssertEqual(darkPixels(in: try render(canvas), column: 240), 0)
        canvas.mouseDown(with: try event(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, canvas: canvas, window: window))
        XCTAssertGreaterThan(darkPixels(in: try render(canvas), column: 240), 80)
        XCTAssertEqual(changes, 0)
        canvas.mouseUp(with: try event(.leftMouseUp, at: end, canvas: canvas, window: window))

        XCTAssertEqual(mask.endPoint.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(mask.endPoint.y, 0.65, accuracy: 0.001)
        try drag(canvas, in: window, from: end, to: CGPoint(x: 450, y: 280))
        XCTAssertEqual(mask.endPoint, CGPoint(x: 1, y: 1))
        try drag(canvas, in: window, from: CGPoint(x: 80, y: 72.5), to: CGPoint(x: 450, y: 280))
        XCTAssertEqual(mask.endPoint, CGPoint(x: 1, y: 1))
        XCTAssertEqual((1 - mask.startPoint.x) * 400, 3, accuracy: 0.001)
        XCTAssertEqual((1 - mask.startPoint.y) * 225, 3, accuracy: 0.001)
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(canvas.tool, .mask)
    }

    func testArrowCanBeReselectedWithToolActiveAndEndpointsCanBeAdjustedIndependently() throws {
        let (window, canvas) = try makeCanvas()
        var arrow = RecordingAnnotation(kind: .arrow, startPoint: CGPoint(x: 0.25, y: 0.25),
                                        endPoint: CGPoint(x: 0.5, y: 0.5), range: try .init(start: 0, end: 1))
        let other = RecordingAnnotation(kind: .rectangle, startPoint: CGPoint(x: 0.6, y: 0.15),
                                        endPoint: CGPoint(x: 0.8, y: 0.35), range: arrow.range)
        canvas.visibleAnnotations = [arrow, other]
        canvas.selectedAnnotation = other
        canvas.tool = .arrow
        var selections: [UUID] = []
        canvas.onSelect = { [weak canvas] id in
            selections.append(id)
            canvas?.selectedAnnotation = id == arrow.id ? arrow : other
        }
        var changes = 0
        canvas.onChangeGeometry = { [weak canvas] id, start, end, _ in
            XCTAssertEqual(id, arrow.id)
            arrow.startPoint = start
            arrow.endPoint = end
            canvas?.visibleAnnotations = [arrow, other]
            canvas?.selectedAnnotation = arrow
            changes += 1
        }
        canvas.onCreate = { _, _, _ in XCTFail("应重新选中已有箭头") }

        let arrowBody = CGPoint(x: 150, y: 111.875)
        try drag(canvas, in: window, from: arrowBody, to: arrowBody)
        XCTAssertEqual(selections, [arrow.id])
        try drag(canvas, in: window, from: CGPoint(x: 200, y: 140), to: CGPoint(x: 360, y: 185))
        XCTAssertEqual(arrow.startPoint, CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(arrow.endPoint.x, 0.9, accuracy: 0.001)
        XCTAssertEqual(arrow.endPoint.y, 0.7, accuracy: 0.001)
        try drag(canvas, in: window, from: CGPoint(x: 100, y: 83.75), to: CGPoint(x: -15, y: 0))
        XCTAssertEqual(arrow.startPoint, .zero)
        XCTAssertEqual(arrow.endPoint.x, 0.9, accuracy: 0.001)
        XCTAssertEqual(arrow.endPoint.y, 0.7, accuracy: 0.001)
        XCTAssertEqual(changes, 2)
    }

    func testPenUsesTheSelectedStyleInTheDraftAndUpdatesEveryPathPointWhenMoved() throws {
        let (window, canvas) = try makeCanvas()
        let range = try RecordingTimeRange(start: 0, end: 1)
        var style = RecordingAnnotation.Style.defaults(for: .pen)
        style.color = .init(red: 1, green: 0, blue: 0, alpha: 1)
        style.lineWidth = 16
        canvas.tool = .pen
        canvas.style = style
        var created: RecordingAnnotation?
        canvas.onCreate = { _, _, _ in XCTFail("画笔必须提交完整路径") }
        canvas.onCreatePath = { kind, points in
            XCTAssertEqual(kind, .pen)
            if let first = points.first, let last = points.last {
                created = RecordingAnnotation(kind: kind, startPoint: first, endPoint: last, range: range,
                                              style: style, points: points)
            }
        }
        canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 72.5), canvas: canvas, window: window))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 120, y: 140), canvas: canvas, window: window))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 160, y: 140), canvas: canvas, window: window))
        let live = try render(canvas)
        XCTAssertTrue((0..<live.pixelsHigh).contains { y in
            guard let color = live.colorAt(x: 140, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.9 && color.redComponent > 0.9
                && color.greenComponent < 0.25 && color.blueComponent < 0.2
        })
        canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 220, y: 185), canvas: canvas, window: window))

        let path = try XCTUnwrap(created)
        XCTAssertEqual(path.points.count, 4)
        XCTAssertEqual(path.points[0].x, 0.2, accuracy: 0.001)
        XCTAssertEqual(path.points[2].y, 0.5, accuracy: 0.001)
        XCTAssertEqual(path.points[3].x, 0.55, accuracy: 0.001)
        canvas.visibleAnnotations = [path]
        canvas.tool = nil
        let emptyPoint = canvas.convert(CGPoint(x: 190, y: 90), to: canvas.superview)
        XCTAssertNil(canvas.hitTest(emptyPoint), "只应命中画过的路径")
        var changed: [CGPoint]?
        canvas.onChangeGeometry = { id, start, end, points in
            XCTAssertEqual(id, path.id)
            XCTAssertEqual(start, points.first)
            XCTAssertEqual(end, points.last)
            changed = points
        }
        try drag(canvas, in: window, from: CGPoint(x: 140, y: 140), to: CGPoint(x: 180, y: 162.5))
        let moved = try XCTUnwrap(changed)
        XCTAssertEqual(moved.count, path.points.count)
        for (original, translated) in zip(path.points, moved) {
            XCTAssertEqual(translated.x - original.x, 0.1, accuracy: 0.001)
            XCTAssertEqual(translated.y - original.y, 0.1, accuracy: 0.001)
        }
    }

    func testLineAndEllipseMatchExistingEndpointAndCornerGestures() throws {
        let (window, canvas) = try makeCanvas()
        let range = try RecordingTimeRange(start: 0, end: 1)
        var shape: RecordingAnnotation?
        canvas.onCreate = { kind, start, end in
            shape = RecordingAnnotation(kind: kind, startPoint: start, endPoint: end, range: range)
        }
        canvas.tool = .line
        try drag(canvas, in: window, from: CGPoint(x: 80, y: 140), to: CGPoint(x: 260, y: 140))
        let line = try XCTUnwrap(shape)
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.startPoint.y, line.endPoint.y)

        canvas.tool = .ellipse
        try drag(canvas, in: window, from: CGPoint(x: 80, y: 72.5), to: CGPoint(x: 160, y: 117.5))
        let ellipse = try XCTUnwrap(shape)
        XCTAssertEqual(ellipse.kind, .ellipse)
        canvas.visibleAnnotations = [ellipse]
        canvas.selectedAnnotation = ellipse
        var corner: CGPoint?
        canvas.onChangeGeometry = { id, start, end, _ in
            XCTAssertEqual(id, ellipse.id)
            XCTAssertEqual(start, ellipse.startPoint)
            corner = end
        }
        try drag(canvas, in: window, from: CGPoint(x: 160, y: 117.5), to: CGPoint(x: 240, y: 185))
        let end = try XCTUnwrap(corner)
        XCTAssertEqual(end.x, 0.6, accuracy: 0.001)
        XCTAssertEqual(end.y, 0.7, accuracy: 0.001)
    }

    private func drag(_ canvas: RecordingAnnotationCanvas, in window: NSWindow, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try event(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, canvas: canvas, window: window))
        canvas.mouseUp(with: try event(.leftMouseUp, at: end, canvas: canvas, window: window))
    }

    private func render(_ canvas: RecordingAnnotationCanvas) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.bounds.width), pixelsHigh: Int(canvas.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(canvas.bounds)
        canvas.draw(canvas.bounds)
        return bitmap
    }

    private func darkPixels(in bitmap: NSBitmapImageRep, column: Int) -> Int {
        (0..<bitmap.pixelsHigh).filter { y in
            guard let pixel = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return pixel.alphaComponent > 0.9 && pixel.redComponent < 0.1
                && pixel.greenComponent < 0.1 && pixel.blueComponent < 0.1
        }.count
    }

    private func makeCanvas() throws -> (NSWindow, RecordingAnnotationCanvas) {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("视频画布需要 macOS WindowServer") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let canvas = RecordingAnnotationCanvas(frame: CGRect(x: 27, y: 18, width: 400, height: 280))
        canvas.videoSize = CGSize(width: 1280, height: 720)
        canvas.isInteractionEnabled = true
        window.contentView?.addSubview(canvas)
        return (window, canvas)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, canvas: NSView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
