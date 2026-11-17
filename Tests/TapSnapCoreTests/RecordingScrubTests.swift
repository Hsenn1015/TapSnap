import AppKit
import AVKit
import TapSnapMedia
import XCTest
@testable import TapSnapApp

@MainActor
final class RecordingScrubTests: XCTestCase {
    func testScrubbingKeepsLatestTimeAndSeeksExactlyAtRelease() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("录屏拖动测试需要 macOS WindowServer") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("scrub.mp4")
        try await makeVideo(at: video)

        let panel = RecordingPreviewPanel(videoURL: video, theme: .dark)
        defer { panel.close() }
        panel.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "录屏预览" })
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let timeline = try XCTUnwrap(views.compactMap { $0 as? RecordingTrimTimeline }.first)
        let player = try XCTUnwrap(views.compactMap { $0 as? AVPlayerView }.first?.player)
        for _ in 0..<100 where !timeline.isEnabled || player.currentItem?.status != .readyToPlay {
            try await Task.sleep(for: .milliseconds(20))
        }
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(timeline.isEnabled)

        try scrub(.leftMouseDown, fraction: 0.31, in: timeline)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(timeline.playhead, timeline.duration * 0.31, accuracy: 0.001)
        for fraction in [0.45, 0.72, 0.28, 0.67, 0.38] {
            try scrub(.leftMouseDragged, fraction: fraction, in: timeline)
            XCTAssertEqual(timeline.playhead, timeline.duration * fraction, accuracy: 0.001)
        }
        try scrub(.leftMouseUp, fraction: 0.59, in: timeline)
        let released = timeline.duration * 0.59
        XCTAssertEqual(timeline.playhead, released, accuracy: 0.001)
        for _ in 0..<100 where abs(player.currentTime().seconds - released) > 0.002 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.currentTime().seconds, released, accuracy: 0.002)
        XCTAssertEqual(timeline.playhead, released, accuracy: 0.002)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func scrub(_ type: NSEvent.EventType, fraction: CGFloat, in timeline: RecordingTrimTimeline) throws {
        let x = 11 + (timeline.bounds.width - 22) * fraction
        let point = timeline.convert(CGPoint(x: x, y: timeline.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: timeline.window?.windowNumber ?? 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: timeline.mouseDown(with: event)
        case .leftMouseDragged: timeline.mouseDragged(with: event)
        default: timeline.mouseUp(with: event)
        }
    }

    private func makeVideo(at url: URL) async throws {
        let encoder = VideoEncoder(configuration: .init(width: 96, height: 64, frameRate: 10))
        try encoder.prepare(outputURL: url)
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for frame in 0..<20 {
            context.setFillColor(CGColor(gray: CGFloat(frame) / 20, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            try encoder.append(try XCTUnwrap(context.makeImage()), at: Double(frame) / 10)
            try await Task.sleep(for: .milliseconds(12))
        }
        let result = try await encoder.finish(endingAt: 2)
        XCTAssertEqual(result, url)
    }
}
