import AppKit
import AVKit
import ImageIO
import SwiftUI
import TapSnapCore
import TapSnapMedia
import UniformTypeIdentifiers
import XCTest
@testable import TapSnapApp

@MainActor
final class RecordingPreviewTests: XCTestCase {
    func testCopiesOriginalWithShortcutAndSelectedSegmentFromToolbar() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("录屏预览需要 macOS WindowServer") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("原始 录屏.mp4")
        try await makeVideo(at: source)
        let pasteboard = NSPasteboard(name: .init("tapsnap-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let panel = RecordingPreviewPanel(videoURL: source, theme: .dark, pasteboard: pasteboard)
        defer { panel.close() }
        panel.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "录屏预览" })
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let timeline = try XCTUnwrap(views.compactMap { $0 as? RecordingTrimTimeline }.first)
        let player = try XCTUnwrap(views.compactMap { $0 as? AVPlayerView }.first?.player)
        let copy = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("复制视频") })
        try await waitUntil { copy.isEnabled }
        XCTAssertEqual(player.timeControlStatus, .paused)

        let commandC = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(window.performKeyEquivalent(with: commandC))
        XCTAssertEqual(fileURL(on: pasteboard)?.standardizedFileURL, source.standardizedFileURL)

        window.setContentSize(window.contentMinSize)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.bounds.contains(copy.convert(copy.bounds, to: content)))
        XCTAssertTrue(content.bounds.contains(timeline.convert(timeline.bounds, to: content)))
        try drag(in: timeline, from: 7, to: timeline.bounds.width / 3)
        try drag(in: timeline, from: timeline.bounds.width - 7, to: timeline.bounds.width * 2 / 3)
        let range = try XCTUnwrap(timeline.range)
        XCTAssertEqual(range.start, 1, accuracy: 0.08)
        XCTAssertEqual(range.end, 2, accuracy: 0.08)
        copy.performClick(nil)
        try await waitUntil {
            guard let url = self.fileURL(on: pasteboard) else { return false }
            return url.standardizedFileURL != source.standardizedFileURL
        }
        let clip = try XCTUnwrap(fileURL(on: pasteboard))
        XCTAssertEqual(clip.pathExtension, "mp4")
        let length = try await AVURLAsset(url: clip).load(.duration).seconds
        XCTAssertEqual(length, range.duration, accuracy: 0.06)

        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.keyDown(with: space)
        try await waitUntil { player.timeControlStatus == .playing }
        try await waitUntil { player.timeControlStatus == .paused }
        XCTAssertEqual(player.currentTime().seconds, range.end, accuracy: 0.06)

        panel.selectExportFormat(.gif)
        panel.setGIFSpeed(2.0)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(copy.title.hasPrefix("复制 GIF"))
        XCTAssertTrue(content.bounds.contains(copy.convert(copy.bounds, to: content)))
        XCTAssertTrue(copy.isEnabled)
        copy.performClick(nil)
        let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
        try await waitUntil { pasteboard.data(forType: gifType) != nil }
        let data = try XCTUnwrap(pasteboard.data(forType: gifType))
        let gif = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let frameCount = CGImageSourceGetCount(gif)
        XCTAssertGreaterThan(frameCount, 1)
        XCTAssertLessThan(frameCount, 20, "2 倍速裁剪片段的 GIF 帧数应明显少于整段 3 秒录屏")
        XCTAssertEqual(fileURL(on: pasteboard)?.pathExtension, "gif")

        panel.close()
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: clip.path), "粘贴接收方在关闭窗口后仍要能读取片段")
    }

    func testAddsSingleFrameMaskInPreviewAndCopiesEditedMP4AndGIF() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("录屏预览需要 macOS WindowServer") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try await makeVideo(at: source)
        let pasteboard = NSPasteboard(name: .init("tapsnap-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let panel = RecordingPreviewPanel(videoURL: source, theme: .dark, pasteboard: pasteboard)
        defer { panel.close() }
        panel.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "录屏预览" })
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let canvas = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationCanvas }.first)
        let timeline = try XCTUnwrap(views.compactMap { $0 as? RecordingTrimTimeline }.first)
        let lane = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationTimeline }.first)
        let player = try XCTUnwrap(views.compactMap { $0 as? AVPlayerView }.first?.player)
        let buttons = views.compactMap { $0 as? NSButton }
        XCTAssertTrue(views.contains { $0 is NSHostingView<RecordingAnnotationToolbar> })
        let nextFrame = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "下一帧" })
        let singleFrame = try XCTUnwrap(buttons.first { $0.title == "仅此帧" })
        let copy = try XCTUnwrap(buttons.first { $0.title.hasPrefix("复制视频") })
        try await waitUntil { canvas.videoSize.width > 0 && canvas.isInteractionEnabled && nextFrame.isEnabled }
        XCTAssertNotNil(nextFrame.image)
        let initialFrame = try await RecordingAnnotationRenderer.frameRange(at: 0, in: AVURLAsset(url: source))
        XCTAssertEqual(initialFrame, try RecordingTimeRange(start: 0, end: 1))
        XCTAssertEqual(timeline.playhead, 0, accuracy: 0.01)
        let right = try arrowKey(code: 124, in: window)
        let left = try arrowKey(code: 123, in: window)
        window.keyDown(with: right)
        window.keyDown(with: right)
        XCTAssertEqual(timeline.playhead, 2, accuracy: 0.01, "连续逐帧应从已请求的位置继续")
        window.keyDown(with: left)
        window.keyDown(with: left)
        XCTAssertEqual(timeline.playhead, 0, accuracy: 0.01)
        nextFrame.performClick(nil)
        try await waitUntil { abs(timeline.playhead - 1) < 0.01 && abs(player.currentTime().seconds - 1) < 0.01 }
        XCTAssertEqual(timeline.playhead, 1, accuracy: 0.01)
        XCTAssertEqual(player.currentTime().seconds, 1, accuracy: 0.01)
        panel.toggleAnnotationTool(.mask)

        content.layoutSubtreeIfNeeded()
        let initialCanvasFrame = canvas.frame
        let scale = min(canvas.bounds.width / canvas.videoSize.width, canvas.bounds.height / canvas.videoSize.height)
        let size = CGSize(width: canvas.videoSize.width * scale, height: canvas.videoSize.height * scale)
        try drag(in: canvas, from: CGPoint(x: canvas.bounds.midX - size.width * 0.3, y: canvas.bounds.midY - size.height * 0.3),
                 to: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        let fullRange = try RecordingTimeRange(start: 0, end: 3)
        XCTAssertEqual(panel.edits.annotations.first?.range, fullRange)
        XCTAssertEqual(lane.selectedID, panel.edits.annotations.first?.id)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(canvas.frame, initialCanvasFrame, "选中标注不应让视频画面移动")

        singleFrame.performClick(nil)
        let expectedRange = try RecordingTimeRange(start: 1, end: 2)
        try await waitUntil { panel.edits.annotations.first?.range == expectedRange }
        XCTAssertEqual(canvas.visibleAnnotations.first?.range, expectedRange)
        XCTAssertEqual(lane.annotations.first?.range, expectedRange)
        panel.undoAnnotation()
        XCTAssertEqual(lane.annotations.first?.range, fullRange)
        panel.redoAnnotation()
        XCTAssertEqual(lane.annotations.first?.range, expectedRange)

        window.setContentSize(window.contentMinSize)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.bounds.contains(singleFrame.convert(singleFrame.bounds, to: content)))
        XCTAssertTrue(content.bounds.contains(copy.convert(copy.bounds, to: content)))
        copy.performClick(nil)
        try await waitUntil { self.fileURL(on: pasteboard)?.pathExtension == "mp4" }
        let edited = try XCTUnwrap(fileURL(on: pasteboard))
        XCTAssertNotEqual(edited, source)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: edited))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let masked = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        let before = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        XCTAssertTrue(try isDarkAtMaskCenter(masked))
        XCTAssertFalse(try isDarkAtMaskCenter(before))

        panel.selectExportFormat(.gif)
        try await waitUntil { copy.isEnabled }
        copy.performClick(nil)
        let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
        try await waitUntil { pasteboard.data(forType: gifType) != nil }
        let data = try XCTUnwrap(pasteboard.data(forType: gifType))
        let gif = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, 0, nil))
        let middle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, CGImageSourceGetCount(gif) / 2, nil))
        XCTAssertFalse(try isDarkAtMaskCenter(first))
        XCTAssertTrue(try isDarkAtMaskCenter(middle))
    }

    func testTextSheetKeepsThePreviewEditableAfterCreatingAndUpdatingText() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("录屏预览需要 macOS WindowServer") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try await makeVideo(at: source)
        let panel = RecordingPreviewPanel(videoURL: source, theme: .dark)
        defer { panel.close() }
        panel.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "录屏预览" })
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let canvas = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationCanvas }.first)
        let lane = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationTimeline }.first)
        let toolbar = try XCTUnwrap(views.compactMap { $0 as? NSHostingView<RecordingAnnotationToolbar> }.first)
        try await waitUntil { canvas.videoSize.width > 0 && canvas.isInteractionEnabled }
        content.layoutSubtreeIfNeeded()
        let scale = min(canvas.bounds.width / canvas.videoSize.width, canvas.bounds.height / canvas.videoSize.height)
        let videoOrigin = CGPoint(x: canvas.bounds.midX - canvas.videoSize.width * scale / 2,
                                  y: canvas.bounds.midY - canvas.videoSize.height * scale / 2)
        let start = CGPoint(x: videoOrigin.x + 20 * scale, y: videoOrigin.y + 20 * scale)
        toolbar.rootView.select(.text)
        try click(in: canvas, at: start)
        try await submitAnnotationText("第一条", in: window)

        let created = try XCTUnwrap(panel.edits.annotations.first)
        XCTAssertEqual(created.text, "第一条")
        XCTAssertTrue(canvas.isInteractionEnabled)
        XCTAssertTrue(lane.isEnabled)
        XCTAssertTrue(toolbar.rootView.state.isEnabled)

        let textBounds = RecordingAnnotationRenderer.bounds(of: created, size: canvas.videoSize)
        let textCenter = CGPoint(x: videoOrigin.x + textBounds.midX * scale,
                                 y: videoOrigin.y + textBounds.midY * scale)
        try click(in: canvas, at: textCenter, count: 2)
        try await submitAnnotationText("再次编辑", in: window)
        let updated = try XCTUnwrap(panel.edits.annotations.first)
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.text, "再次编辑")
        XCTAssertTrue(canvas.isInteractionEnabled)
        XCTAssertTrue(lane.isEnabled)
        XCTAssertTrue(toolbar.rootView.state.isEnabled)

        let updatedBounds = RecordingAnnotationRenderer.bounds(of: updated, size: canvas.videoSize)
        let updatedCenter = CGPoint(x: videoOrigin.x + updatedBounds.midX * scale,
                                    y: videoOrigin.y + updatedBounds.midY * scale)
        try drag(in: canvas, from: updatedCenter, to: CGPoint(x: updatedCenter.x + 20, y: updatedCenter.y + 15))
        let moved = try XCTUnwrap(panel.edits.annotations.first)
        XCTAssertGreaterThan(moved.startPoint.x, updated.startPoint.x)
        XCTAssertGreaterThan(moved.startPoint.y, updated.startPoint.y)
    }

    private func submitAnnotationText(_ text: String, in window: NSWindow) async throws {
        try await waitUntil { window.attachedSheet?.isVisible == true }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let field = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(sheet.makeFirstResponder(nil))
        field.stringValue = text
        let done = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "完成" })
        done.performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
    }

    private func click(in view: NSView, at point: CGPoint, count: Int = 1) throws {
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                       timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                                       context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
    }

    func testContinuesDrawingAndReselectsEditedMaskAfterChangingItsTime() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("录屏预览需要 macOS WindowServer") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-repeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try await makeVideo(at: source)
        let panel = RecordingPreviewPanel(videoURL: source, theme: .dark)
        defer { panel.close() }
        panel.show()

        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "录屏预览" })
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let canvas = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationCanvas }.first)
        let lane = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationTimeline }.first)
        try await waitUntil { canvas.videoSize.width > 0 && canvas.isInteractionEnabled }
        content.layoutSubtreeIfNeeded()
        let video = AVMakeRect(aspectRatio: canvas.videoSize, insideRect: canvas.bounds)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: video.minX + x * video.width, y: video.minY + y * video.height)
        }

        panel.toggleAnnotationTool(.mask)
        try drag(in: canvas, from: point(0.15, 0.2), to: point(0.35, 0.4))
        let first = try XCTUnwrap(panel.edits.annotations.first)
        try drag(in: canvas, from: point(0.65, 0.55), to: point(0.85, 0.75))
        XCTAssertEqual(canvas.tool, .mask)
        XCTAssertEqual(panel.edits.annotations.count, 2, "工具应保留，用户可以直接画第二个标注")

        let trackWidth = lane.bounds.width - 22
        try drag(in: lane, from: CGPoint(x: 11 + trackWidth / 2, y: 14),
                 to: CGPoint(x: 11 + trackWidth / 2, y: 14))
        XCTAssertEqual(lane.selectedID, first.id)
        for (oldStart, newStart, frame) in [(0.0, 0.5, 1.0), (0.5, 1.5, 2.0)] {
            try drag(in: lane, from: CGPoint(x: 11 + trackWidth * oldStart / 3, y: 14),
                     to: CGPoint(x: 11 + trackWidth * newStart / 3, y: 14))
            let edited = try XCTUnwrap(panel.edits.annotations.first { $0.id == first.id })
            XCTAssertEqual(edited.range.start, newStart, accuracy: 0.001)
            XCTAssertEqual(lane.playhead, frame, accuracy: 0.01)
            XCTAssertEqual(canvas.selectedAnnotation?.id, first.id, "改时间后同一标注仍可继续调整")
        }

        try drag(in: canvas, from: point(0.25, 0.3), to: point(0.35, 0.3))
        let moved = try XCTUnwrap(panel.edits.annotations.first { $0.id == first.id })
        XCTAssertEqual(moved.startPoint.x, 0.25, accuracy: 0.002)
        XCTAssertEqual(moved.range.start, 1.5, accuracy: 0.001)
    }

    func testStylesApplyToNewAndExistingVideoAnnotations() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("录屏预览需要 macOS WindowServer") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try await makeVideo(at: source)
        let panel = RecordingPreviewPanel(videoURL: source, theme: .dark)
        defer { panel.close() }
        panel.show()

        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "录屏预览" })
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let canvas = try XCTUnwrap(views.compactMap { $0 as? RecordingAnnotationCanvas }.first)
        let styleButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "样式" })
        try await waitUntil { canvas.videoSize.width > 0 && canvas.isInteractionEnabled }
        XCTAssertFalse(styleButton.isEnabled)

        panel.toggleAnnotationTool(.ellipse)
        XCTAssertTrue(styleButton.isEnabled)
        styleButton.performClick(nil)
        var popover = try XCTUnwrap(panel.stylePopover)
        XCTAssertTrue(popover.isShown)
        var host = try XCTUnwrap(popover.contentViewController as? NSHostingController<RecordingAnnotationStylePanel>)
        let fill = RGBAColor(rgb: 0xE12D39, alpha: 0.8)
        host.rootView.draft.style.color = .init(rgb: 0x1848ED)
        host.rootView.draft.style.fillColor = fill
        host.rootView.draft.style.strokePattern = .dashed
        popover.close()

        content.layoutSubtreeIfNeeded()
        let image = AVMakeRect(aspectRatio: canvas.videoSize, insideRect: canvas.bounds)
        try drag(in: canvas, from: CGPoint(x: image.minX + image.width * 0.2, y: image.minY + image.height * 0.2),
                 to: CGPoint(x: image.midX, y: image.midY))
        let ellipse = try XCTUnwrap(panel.edits.annotations.first)
        XCTAssertEqual(ellipse.kind, .ellipse)
        XCTAssertEqual(ellipse.style.fillColor, fill)
        XCTAssertEqual(ellipse.style.strokePattern, .dashed)

        styleButton.performClick(nil)
        popover = try XCTUnwrap(panel.stylePopover)
        host = try XCTUnwrap(popover.contentViewController as? NSHostingController<RecordingAnnotationStylePanel>)
        XCTAssertEqual(host.rootView.draft.style, ellipse.style)
        host.rootView.draft.style.lineWidth = 18
        host.rootView.draft.style.fillColor = nil
        try await waitUntil { canvas.visibleAnnotations.first?.style.lineWidth == 18 }
        XCTAssertNil(canvas.visibleAnnotations.first?.style.fillColor)
        XCTAssertEqual(panel.edits.annotations.first?.style, ellipse.style, "关闭前只更新预览")

        popover.close()
        XCTAssertEqual(panel.edits.annotations.first?.id, ellipse.id)
        XCTAssertEqual(panel.edits.annotations.first?.style.lineWidth, 18)
        panel.undoAnnotation()
        XCTAssertEqual(panel.edits.annotations.first?.style, ellipse.style)
    }

    private func isDarkAtMaskCenter(_ image: CGImage) throws -> Bool {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: Int(Double(image.width) * 0.35),
                                                            y: Int(Double(image.height) * 0.35), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).allSatisfy { $0 < 32 }
    }

    private func arrowKey(code: UInt16, in window: NSWindow) throws -> NSEvent {
        let character = code == 123 ? "\u{f702}" : "\u{f703}"
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: character,
                                              charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func fileURL(on pasteboard: NSPasteboard) -> URL? {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "预览操作未及时完成")
    }

    private func drag(in view: NSView, from start: CGFloat, to end: CGFloat) throws {
        try drag(in: view, from: CGPoint(x: start, y: view.bounds.midY), to: CGPoint(x: end, y: view.bounds.midY))
    }

    private func drag(in view: NSView, from start: CGPoint, to end: CGPoint) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let location = view.convert(point, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                       timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    private func makeVideo(at url: URL) async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let encoder = VideoEncoder(configuration: .init(width: 128, height: 72, frameRate: 20))
        try encoder.prepare(outputURL: url)
        for (index, color) in [NSColor.systemRed, .systemGreen, .systemBlue].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 72))
            try encoder.append(try XCTUnwrap(context.makeImage()), at: Double(index))
            try await Task.sleep(for: .milliseconds(20))
        }
        let output = try await encoder.finish(endingAt: 3)
        XCTAssertNotNil(output)
    }
}
