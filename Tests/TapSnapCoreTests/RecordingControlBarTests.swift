import AppKit
import XCTest
@testable import TapSnapApp

final class RecordingControlBarTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = CGRect(x: 0, y: 60, width: 1440, height: 816)
    private let barSize = CGSize(width: 370, height: 44)

    func testControlBarCentersBelowSelection() {
        let region = CGRect(x: 360, y: 100, width: 480, height: 260)
        let bar = RecordController.controlBarFrame(for: region, displayFrame: display, visibleFrame: visible, size: barSize)
        XCTAssertEqual(bar.midX, region.midX)
        XCTAssertEqual(bar.maxY, display.maxY - region.maxY - 16)
    }

    func testControlBarMovesAboveSelectionWhenDockBlocksSpaceBelow() {
        let region = CGRect(x: 360, y: 680, width: 480, height: 160)
        let bar = RecordController.controlBarFrame(for: region, displayFrame: display, visibleFrame: visible, size: barSize)
        XCTAssertEqual(bar.minY, display.maxY - region.minY + 16)
        XCTAssertTrue(visible.contains(bar))
    }

    func testControlBarStaysVisibleForFullDisplayCapture() {
        let bar = RecordController.controlBarFrame(for: display, displayFrame: display, visibleFrame: visible, size: barSize)
        XCTAssertEqual(bar.minY, visible.minY + 8)
        XCTAssertTrue(visible.contains(bar))
    }

    func testControlBarUsesOffsetDisplayAndClampsToItsLeftEdge() {
        let secondary = CGRect(x: -1280, y: -960, width: 1280, height: 960)
        let region = CGRect(x: 40, y: 100, width: 220, height: 140)
        let bar = RecordController.controlBarFrame(for: region, displayFrame: secondary, visibleFrame: secondary, size: barSize)
        XCTAssertEqual(bar.minX, secondary.minX + 8)
        XCTAssertEqual(bar.maxY, secondary.maxY - region.maxY - 16)
        XCTAssertTrue(secondary.contains(bar))
    }

    @MainActor
    func testNativeControlBarRemainsCenteredAsRecordingStateChanges() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("录屏控制条需要 macOS WindowServer") }
        let centerX = screen.visibleFrame.midX
        let region = CGRect(x: centerX - screen.frame.minX - 150, y: 80, width: 300, height: 160)
        let model = RecordControlBarModel()
        let panel = RecordController.makeControlBar(for: region, displayFrame: screen.frame,
                                                    visibleFrame: screen.visibleFrame, model: model, theme: .dark)
        let initialFrame = panel.frame
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(initialFrame.maxY, screen.frame.maxY - region.maxY - 16, accuracy: 1)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(100))
        try assertDrawnControlBarIsCentered(in: panel, at: centerX)
        XCTAssertEqual(panel.frame, initialFrame)

        model.isBusy = false
        model.elapsed = 65
        try await Task.sleep(for: .milliseconds(100))
        try assertDrawnControlBarIsCentered(in: panel, at: centerX, expectsClearSides: true)
        XCTAssertEqual(panel.frame, initialFrame)

        model.isBusy = true
        model.busyText = "正在重录…"
        try await Task.sleep(for: .milliseconds(100))
        try assertDrawnControlBarIsCentered(in: panel, at: centerX)
        XCTAssertEqual(panel.frame, initialFrame)
    }

    @MainActor
    private func assertDrawnControlBarIsCentered(in panel: NSPanel, at centerX: CGFloat, expectsClearSides: Bool = false,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(panel.contentView, file: file, line: line)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), file: file, line: line)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        for y in [0, bitmap.pixelsHigh - 1] {
            for x in [0, bitmap.pixelsWide - 1] {
                let corner = try XCTUnwrap(bitmap.colorAt(x: x, y: y), file: file, line: line)
                XCTAssertLessThan(corner.alphaComponent, 0.02, "圆角外侧应保持透明", file: file, line: line)
            }
        }
        if expectsClearSides {
            for x in [0, bitmap.pixelsWide - 1] {
                let alpha = (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: x, y: $0)?.alphaComponent }.max()
                XCTAssertLessThan(try XCTUnwrap(alpha), 0.02, "控制条两侧不应有阴影残边", file: file, line: line)
            }
        }
        let middleRow = bitmap.pixelsHigh / 2
        let opaquePixels = (0..<bitmap.pixelsWide).filter {
            (bitmap.colorAt(x: $0, y: middleRow)?.alphaComponent ?? 0) >= 0.9
        }
        let left = try XCTUnwrap(opaquePixels.first, file: file, line: line)
        let right = try XCTUnwrap(opaquePixels.last, file: file, line: line)
        let localX = (CGFloat(left + right) + 1) / 2 * view.bounds.width / CGFloat(bitmap.pixelsWide)
        XCTAssertEqual(panel.frame.minX + localX, centerX, accuracy: 1, file: file, line: line)
    }
}
