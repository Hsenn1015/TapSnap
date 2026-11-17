import AppKit
import TapSnapMedia
import XCTest
@testable import TapSnapApp

@MainActor
final class RecordingAnnotationTimelineTests: XCTestCase {
    func testOverlappingClipsCanBeSelectedIndividually() throws {
        try requireWindowServer()
        let lane = RecordingAnnotationTimeline(frame: CGRect(x: 0, y: 0, width: 222, height: 50))
        lane.duration = 10
        lane.isEnabled = true
        let arrow = try annotation(.arrow, start: 2, end: 4)
        let mask = try annotation(.mask, start: 2, end: 4)
        lane.annotations = [arrow, mask]
        var selected: [UUID] = []
        var sought: [(TimeInterval, Bool)] = []
        lane.onSelect = { selected.append($0) }
        lane.onSeek = { sought.append(($0, $1)) }

        try mouse(.leftMouseDown, x: 71, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 71, y: 14, in: lane)
        try mouse(.leftMouseDown, x: 71, y: 36, in: lane)
        try mouse(.leftMouseUp, x: 71, y: 36, in: lane)
        XCTAssertEqual(lane.intrinsicContentSize.height, 50)
        XCTAssertEqual(selected, [arrow.id, mask.id])
        XCTAssertTrue(sought.isEmpty)

        try mouse(.leftMouseDown, x: 191, y: 14, in: lane)
        try mouse(.leftMouseDragged, x: 211, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 171, y: 14, in: lane)
        XCTAssertEqual(sought.map(\.0), [9, 10, 8])
        XCTAssertEqual(sought.map(\.1), [true, true, false])
    }

    func testHandleCommitsOnMouseUpAndLeavesOneFrameClipUnchangedOnClick() throws {
        try requireWindowServer()
        let lane = RecordingAnnotationTimeline(frame: CGRect(x: 0, y: 0, width: 222, height: 28))
        lane.duration = 10
        lane.isEnabled = true
        let clip = try annotation(.rectangle, start: 2, end: 4)
        lane.annotations = [clip]
        lane.selectedID = clip.id
        var previewed: [RecordingTimeRange] = []
        var committed: [RecordingTimeRange] = []
        lane.onPreviewRange = { id, range in
            XCTAssertEqual(id, lane.selectedID)
            previewed.append(range)
        }
        lane.onChangeRange = { id, range in
            XCTAssertEqual(id, lane.selectedID)
            committed.append(range)
        }

        try mouse(.leftMouseDown, x: 91, y: 14, in: lane)
        try mouse(.leftMouseDragged, x: 131, y: 14, in: lane)
        XCTAssertTrue(committed.isEmpty)
        let dragRange = try RecordingTimeRange(start: 2, end: 6)
        XCTAssertEqual(previewed, [dragRange])
        let finalRange = try RecordingTimeRange(start: 2, end: 7)
        try mouse(.leftMouseUp, x: 151, y: 14, in: lane)
        XCTAssertEqual(previewed, [dragRange, finalRange])
        XCTAssertEqual(committed, [finalRange])

        let single = try annotation(.mask, start: 4, end: 4.002)
        lane.annotations = [single]
        lane.selectedID = single.id
        try mouse(.leftMouseDown, x: 94, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 94, y: 14, in: lane)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(previewed.count, 2)
    }

    func testClipCanBeResizedMovedAndReselectedAcrossSuccessiveEdits() throws {
        try requireWindowServer()
        let lane = RecordingAnnotationTimeline(frame: CGRect(x: 0, y: 0, width: 222, height: 50))
        lane.duration = 10
        lane.isEnabled = true
        let edited = try annotation(.rectangle, start: 2, end: 4)
        let neighbor = try annotation(.mask, start: 2, end: 4)
        lane.annotations = [edited, neighbor]
        lane.selectedID = neighbor.id

        var selected: [UUID] = []
        var committed: [RecordingTimeRange] = []
        lane.onSelect = {
            selected.append($0)
            lane.selectedID = $0
        }
        lane.onChangeRange = { id, range in
            XCTAssertEqual(id, edited.id)
            committed.append(range)
            lane.annotations = lane.annotations.map {
                guard $0.id == id else { return $0 }
                var annotation = $0
                annotation.range = range
                return annotation
            }
        }

        // 另一条标注原本处于选中态，直接从第一条的右端开始调整。
        try mouse(.leftMouseDown, x: 89, y: 14, in: lane)
        try mouse(.leftMouseDragged, x: 109, y: 14, in: lane)
        XCTAssertTrue(committed.isEmpty)
        try mouse(.leftMouseUp, x: 109, y: 14, in: lane)
        XCTAssertEqual(selected, [edited.id])

        // 接着从中间拖整段，保留已经调整过的两端间距。
        try mouse(.leftMouseDown, x: 81, y: 14, in: lane)
        try mouse(.leftMouseDragged, x: 161, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 161, y: 14, in: lane)

        // 移动后其他标注保持在原来的行。选走，再从之前标注的左端继续调整。
        try mouse(.leftMouseDown, x: 71, y: 36, in: lane)
        try mouse(.leftMouseUp, x: 71, y: 36, in: lane)
        try mouse(.leftMouseDown, x: 133, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 153, y: 14, in: lane)
        XCTAssertEqual(selected, [edited.id, neighbor.id, edited.id])
        XCTAssertEqual(committed, [
            try RecordingTimeRange(start: 2, end: 5),
            try RecordingTimeRange(start: 6, end: 9),
            try RecordingTimeRange(start: 7, end: 9)
        ])

        // 已选条目的中间仍可单击跳转，松手抖动不会修改区间。
        try mouse(.leftMouseDown, x: 171, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 172, y: 14, in: lane)
        XCTAssertEqual(selected.last, edited.id)
        XCTAssertEqual(selected.count, 4)
        XCTAssertEqual(committed.count, 3)
    }

    func testResizingOverlappingClipKeepsItsRowWhenTheStartOrderChanges() throws {
        try requireWindowServer()
        let lane = RecordingAnnotationTimeline(frame: CGRect(x: 0, y: 0, width: 222, height: 50))
        lane.duration = 10
        lane.isEnabled = true
        var edited = try annotation(.mask, start: 0, end: 10)
        let neighbor = try annotation(.rectangle, start: 0, end: 10)
        lane.annotations = [edited, neighbor]
        lane.selectedID = edited.id

        var committed: [RecordingTimeRange] = []
        lane.onChangeRange = { id, range in
            XCTAssertEqual(id, edited.id)
            committed.append(range)
            edited.range = range
            lane.annotations = [edited, neighbor]
        }

        try mouse(.leftMouseDown, x: 11, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 21, y: 14, in: lane)
        try mouse(.leftMouseDown, x: 21, y: 14, in: lane)
        try mouse(.leftMouseUp, x: 41, y: 14, in: lane)

        XCTAssertEqual(committed, [
            try RecordingTimeRange(start: 0.5, end: 10),
            try RecordingTimeRange(start: 1.5, end: 10)
        ])
    }

    private func annotation(_ kind: RecordingAnnotation.Kind, start: TimeInterval, end: TimeInterval) throws -> RecordingAnnotation {
        RecordingAnnotation(kind: kind, startPoint: .zero, endPoint: CGPoint(x: 1, y: 1),
                            range: try RecordingTimeRange(start: start, end: end))
    }

    private func requireWindowServer() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("标注时间轴事件需要 macOS WindowServer") }
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, in lane: RecordingAnnotationTimeline) throws {
        let location = lane.convert(CGPoint(x: x, y: y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: lane.mouseDown(with: event)
        case .leftMouseDragged: lane.mouseDragged(with: event)
        default: lane.mouseUp(with: event)
        }
    }
}
