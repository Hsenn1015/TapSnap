import AppKit
import CoreGraphics
import TapSnapConfig
import TapSnapPrivacy
import XCTest
@testable import TapSnapApp
@testable import TapSnapScreen

@MainActor
final class LongShotPreviewTests: XCTestCase {
    private func image(width: Int = 600, height: Int = 6000) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func previewWindow() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { window in
            guard window.isVisible, let content = window.contentView else { return false }
            return descendants(content).contains { $0 is LongShotPreviewView }
        })
    }

    private func requireWindowServer() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("预览窗口测试需要 macOS WindowServer")
        }
    }

    private func screen(visibleFrame: CGRect? = nil) -> ScreenDescriptor {
        let actual = ScreenLayout.current()[0]
        return ScreenDescriptor(id: actual.id, frame: actual.frame,
                                visibleFrame: visibleFrame ?? actual.visibleFrame,
                                scale: actual.scale, isMain: true, localizedName: "Test")
    }

    func testLiveHintDoesNotOverlapFinishOrCancel() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        panel.showLive(on: screen(), avoiding: nil, onFinish: {}, onCancel: {})
        let window = try previewWindow()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let hint = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.stringValue.contains("滚动")
        })
        for button in views.compactMap({ $0 as? NSButton }).filter({ ["完成", "取消"].contains($0.title) }) {
            XCTAssertFalse(hint.convert(hint.bounds, to: content)
                .intersects(button.convert(button.bounds, to: content)))
        }
    }

    func testMissingScrollViewportKeepsCaptureUsableAndOnlyShowsSelectionOnRequest() async throws {
        try requireWindowServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update { $0.longShot.autoScroll = false }
        let session = LongShotSession(environment: AppEnvironment(config: config), makeStreamer: {
            ScreenStreamer(loadContent: {
                try await Task.sleep(for: .seconds(10))
                throw CaptureError.noDisplays
            })
        }, resolveRegion: { _, _ in nil })
        defer { session.cancel() }
        let display = screen()
        let rect = CGRect(x: display.frame.minX + 60, y: display.frame.minY + 60, width: 300, height: 220)
        let first = image(width: Int(rect.width * display.scale), height: Int(rect.height * display.scale))
        session.beginCapturing(rect: rect, screen: display, initialImage: first)
        let window = try previewWindow()
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let regionButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "滚动区域…" })
        let status = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("滚动") })
        session.didScroll(at: CGPoint(x: rect.midX, y: rect.midY))
        for _ in 0..<100 {
            if status.stringValue.contains("没找到滚动区域") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(status.stringValue.contains("点「滚动区域…」"))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(regionButton.isEnabled)
        XCTAssertFalse(NSApp.windows.contains { $0 is SelectionOverlayWindow && $0.isVisible })

        regionButton.performClick(nil)
        let overlay = try XCTUnwrap(NSApp.windows.first { $0 is SelectionOverlayWindow && $0.isVisible })
        let selection = try XCTUnwrap(overlay.contentView as? SelectionOverlayView)
        selection.keyDown(with: keyEvent(code: 53, characters: "\u{1b}", window: overlay))
        XCTAssertFalse(overlay.isVisible)
        XCTAssertTrue(window.isVisible, "取消第二次框选应回到原长截图预览")

        let finish = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "完成" })
        finish.performClick(nil)
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.isVisible && $0.title == "长截图预览" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try previewWindow().title, "长截图预览")
    }

    func testFinishedLongShotOpensSameDocumentInScrollableEditor() async throws {
        try requireWindowServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update {
            $0.longShot.autoScroll = false
            $0.privacy.enabled = false
        }
        let environment = AppEnvironment(config: config)
        let session = LongShotSession(environment: environment, makeStreamer: {
            ScreenStreamer(loadContent: {
                try await Task.sleep(for: .seconds(10))
                throw CaptureError.noDisplays
            })
        })
        environment.longShot = session
        defer { session.cancel() }
        let display = screen()
        let rect = CGRect(x: display.frame.minX + 60, y: display.frame.minY + 60, width: 300, height: 220)
        let screenshot = image(width: Int(rect.width * display.scale), height: Int(3000 * display.scale))
        session.beginCapturing(rect: rect, screen: display, initialImage: screenshot)
        XCTAssertTrue(environment.isUpdateInteractionBusy)

        let liveContent = try XCTUnwrap(try previewWindow().contentView)
        let finish = try XCTUnwrap(descendants(liveContent).compactMap { $0 as? NSButton }.first { $0.title == "完成" })
        finish.performClick(nil)
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.isVisible && $0.title == "长截图预览" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let preview = try previewWindow()
        XCTAssertTrue(environment.isUpdateInteractionBusy)
        let content = try XCTUnwrap(preview.contentView)
        let views = descendants(content)
        let previewLayer = try XCTUnwrap(views.compactMap { $0 as? EditItemLayerView }.first)
        let editor = try XCTUnwrap(previewLayer.controller)
        defer { editor.close() }
        let document = editor.document
        let mask = PrivacyMaskItem(bounds: CGRect(x: 12, y: 120, width: 80, height: 20),
                                   appearance: .init(style: .solid, rgb: 0))
        editor.add(mask)

        let edit = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "编辑" })
        edit.performClick(nil)
        XCTAssertFalse(preview.isVisible)
        XCTAssertTrue(environment.isUpdateInteractionBusy)
        let editorWindow = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "TapSnap 编辑" })
        let editorContent = try XCTUnwrap(editorWindow.contentView)
        editorContent.layoutSubtreeIfNeeded()
        let editorLayer = try XCTUnwrap(descendants(editorContent).compactMap { $0 as? EditItemLayerView }.first)
        XCTAssertTrue(editorLayer.controller === editor)
        XCTAssertTrue(editorLayer.controller?.document === document)
        XCTAssertEqual(document.baseImage.width, screenshot.width)
        XCTAssertEqual(document.baseImage.height, screenshot.height)
        XCTAssertEqual(document.items.map(\.id), [mask.id])
        XCTAssertTrue(editor.canUndo)

        let scroll = try XCTUnwrap(editorLayer.enclosingScrollView)
        let scrollDocument = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(scrollDocument.frame.height, scroll.contentSize.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        editor.close()
        XCTAssertFalse(environment.isUpdateInteractionBusy)
    }

    func testLongImageUsesTheEditableCanvasAndReenablesOutputAfterScan() async throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        let screenshot = image(width: 600, height: 2600)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update { settings in
            for rule in PrivacyRule.allCases { settings.privacy[rule] = .off }
        }
        let editor = EditController(environment: AppEnvironment(config: config), image: screenshot,
                                    scale: 2, style: EditItemStyle())
        var output: CGImage?
        editor.scanPrivacy()
        panel.showResult(screenshot, actions: [("复制", { output = editor.renderedImage() })],
                         privacyEditor: editor, onEdit: {}, onClose: {})
        let window = try previewWindow()
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(content)
        let copy = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "复制" })
        let edit = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "编辑" })
        let canvas = try XCTUnwrap(views.compactMap { $0 as? EditItemLayerView }.first)
        XCTAssertTrue(canvas.controller === editor)
        XCTAssertFalse(copy.isEnabled)
        XCTAssertTrue(edit.isEnabled)
        let deadline = ContinuousClock.now + .seconds(10)
        while !copy.isEnabled && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard copy.isEnabled else {
            XCTFail("隐私扫描结束后应恢复复制按钮，当前扫描状态：\(editor.privacy.phase)")
            return
        }
        editor.add(PrivacyMaskItem(bounds: CGRect(x: 12, y: 120, width: 80, height: 20),
                                   appearance: .init(style: .solid, rgb: 0)))
        XCTAssertTrue(copy.isEnabled)
        copy.performClick(nil)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.width, 600)
        XCTAssertEqual(result.height, 2600)
        let data = try XCTUnwrap(result.dataProvider?.data) as Data
        let offset = 246 * result.bytesPerRow + 30 * 4
        XCTAssertEqual(Array(data[offset..<(offset + 4)]), [0, 0, 0, 255])
    }

    func testLivePanelRemainsWithinSmallVisibleScreen() throws {
        try requireWindowServer()
        let visible = CGRect(x: 100, y: 100, width: 320, height: 300)
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        panel.showLive(on: screen(visibleFrame: visible), avoiding: nil, onFinish: {}, onCancel: {})
        XCTAssertTrue(visible.contains(try previewWindow().frame), "完成和取消不能落在屏幕外")
    }

    func testResultHasScrollableReadableImageAndFixedActions() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        panel.showResult(image(), actions: [("贴图", {}), ("复制", {}), ("保存", {})], onClose: {})
        let window = try previewWindow()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first,
                                  "长图预览需要滚动查看，不能整图缩成细条")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height * 3)
        XCTAssertGreaterThan(document.bounds.width, 250)
        let save = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "保存" })
        XCTAssertNil(save.enclosingScrollView, "操作按钮应固定在滚动区外")
        XCTAssertTrue(window.canBecomeKey, "结果窗口必须能接收键盘快捷键")
        window.setContentSize(NSSize(width: 360, height: 240))
        content.layoutSubtreeIfNeeded()
        for button in descendants(content).compactMap({ $0 as? NSButton }) {
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)),
                          "缩小预览时操作按钮仍应完整可见")
        }
    }

    func testOriginalPixelModeUsesDisplayBackingScale() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        panel.showResult(image(), actions: [], onClose: {})
        let window = try previewWindow()
        let content = try XCTUnwrap(window.contentView)
        let mode = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
        mode.selectedSegment = 1
        mode.sendAction(mode.action, to: mode.target)
        let preview = try XCTUnwrap(descendants(content).compactMap { $0 as? LongShotPreviewView }.first)
        XCTAssertEqual(preview.displayScale * window.backingScaleFactor, 1, accuracy: 0.001)
    }

    func testLiveFollowsNewContentUnlessUserScrolledBack() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        panel.showLive(on: screen(), avoiding: nil, onFinish: {}, onCancel: {})
        panel.update(image: image(height: 3000), viewportHeight: 500)
        let content = try XCTUnwrap(try previewWindow().contentView)
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.maxY, accuracy: 1)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.update(image: image(height: 4000), viewportHeight: 500)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1,
                       "回看旧内容时不能被新帧强制拉回底部")
    }

    func testClosingLiveWindowCancelsAndExistingWindowCanBeRestored() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        var cancelled = 0
        panel.showLive(on: screen(), avoiding: nil, onFinish: {}, onCancel: { cancelled += 1 })
        let window = try previewWindow()
        window.orderOut(nil)
        panel.showExisting()
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(panel.windowNumber)
    }

    func testLiveAvoidanceConvertsSelectionFromDisplayCoordinates() throws {
        try requireWindowServer()
        let descriptor = screen()
        guard descriptor.visibleFrame.width > 700, descriptor.visibleFrame.height > 600 else {
            throw XCTSkip("避让测试需要可容纳两列预览的显示器")
        }
        let avoidInAppKit = CGRect(x: descriptor.visibleFrame.maxX - 350,
                                  y: descriptor.visibleFrame.minY, width: 350, height: 480)
        let desktopTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let selection = CGRect(x: avoidInAppKit.minX, y: desktopTop - avoidInAppKit.maxY,
                               width: avoidInAppKit.width, height: avoidInAppKit.height)
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        panel.showLive(on: descriptor, avoiding: selection, onFinish: {}, onCancel: {})
        XCTAssertFalse(try previewWindow().frame.intersects(avoidInAppKit))
    }

    private func keyEvent(code: UInt16, characters: String, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }

    func testLiveUnmodifiedReturnAndEscapeReachButtons() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        var finished = 0
        var cancelled = 0
        panel.showLive(on: screen(), avoiding: nil,
                       onFinish: { finished += 1 }, onCancel: { cancelled += 1 })
        let window = try previewWindow()
        window.makeKeyAndOrderFront(nil)
        let content = try XCTUnwrap(window.contentView)
        for button in descendants(content).compactMap({ $0 as? NSButton }) {
            XCTAssertEqual(button.keyEquivalentModifierMask, [], "完成/取消不应要求额外按住 Command")
        }
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(code: 36, characters: "\r", window: window)))
        XCTAssertEqual(finished, 1)
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(code: 53, characters: "\u{1b}", window: window)))
        XCTAssertEqual(cancelled, 1)
    }

    func testResultUnmodifiedEscapeClosesPreview() throws {
        try requireWindowServer()
        let panel = LongShotPreviewPanel()
        defer { panel.close() }
        var closed = 0
        panel.showResult(image(), actions: [], onClose: { closed += 1 })
        let window = try previewWindow()
        let content = try XCTUnwrap(window.contentView)
        let close = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "关闭" })
        XCTAssertEqual(close.keyEquivalentModifierMask, [])
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent(code: 53, characters: "\u{1b}", window: window)))
        XCTAssertEqual(closed, 1)
    }
}
