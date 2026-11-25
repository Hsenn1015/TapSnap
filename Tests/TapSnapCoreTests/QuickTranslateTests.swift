import AppKit
import CoreGraphics
import XCTest
import TapSnapConfig
@testable import TapSnapApp

@MainActor
final class QuickTranslateTests: XCTestCase {
    // MARK: - Settings Persistence

    func testQuickTranslateStylePersistsAndDefaultsCleanly() throws {
        var settings = ScreenshotTranslationSettings()
        XCTAssertEqual(settings.quickTranslateStyle, .liquidGlass)

        for style in QuickTranslateStyle.allCases {
            settings.quickTranslateStyle = style
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(ScreenshotTranslationSettings.self, from: data)
            XCTAssertEqual(decoded.quickTranslateStyle, style)
        }
    }

    func testLegacyTranslationJSONWithoutQuickTranslateStyleDecodesToLiquidGlass() throws {
        let legacyJSON = #"{"targetLanguage":"en","autoTranslateOnOpen":true}"#
        let decoded = try JSONDecoder().decode(
            ScreenshotTranslationSettings.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.targetLanguage, "en")
        XCTAssertEqual(decoded.quickTranslateStyle, .liquidGlass)
    }

    // MARK: - Popover Geometry

    func testPopoverPlacesBelowAnchorWhenSpaceIsAvailable() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 400, y: 500, width: 220, height: 40)
        let cardSize = CGSize(width: 396, height: 158)

        let placement = QuickTranslatePanel.popoverFrame(
            for: anchor,
            cardSize: cardSize,
            in: visible,
            overlayOriginal: false
        )

        XCTAssertFalse(placement.placedAbove)
        XCTAssertEqual(placement.frame.maxY, anchor.minY - 10, accuracy: 0.5)
        XCTAssertEqual(placement.frame.midX, anchor.midX, accuracy: 0.5)
        XCTAssertEqual(placement.arrowOffsetX, placement.frame.width / 2, accuracy: 0.5)
    }

    func testPopoverFlipsAboveAnchorNearBottomEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 400, y: 60, width: 220, height: 36)
        let cardSize = CGSize(width: 396, height: 160)

        let placement = QuickTranslatePanel.popoverFrame(
            for: anchor,
            cardSize: cardSize,
            in: visible,
            overlayOriginal: false
        )

        XCTAssertTrue(placement.placedAbove)
        XCTAssertEqual(placement.frame.minY, anchor.maxY + 10, accuracy: 0.5)
        XCTAssertTrue(visible.contains(placement.frame))
    }

    func testPopoverClampsHorizontallyNearRightEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 1320, y: 500, width: 100, height: 36)
        let cardSize = CGSize(width: 396, height: 150)

        let placement = QuickTranslatePanel.popoverFrame(
            for: anchor,
            cardSize: cardSize,
            in: visible,
            overlayOriginal: false
        )

        XCTAssertLessThanOrEqual(placement.frame.maxX, visible.maxX - 12 + 0.5)
        XCTAssertGreaterThan(placement.arrowOffsetX, placement.frame.width / 2)
    }

    func testOverlayOriginalModeCentersDirectlyOverAnchor() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 320, y: 420, width: 420, height: 80)
        let cardSize = CGSize(width: 396, height: 140)

        let placement = QuickTranslatePanel.popoverFrame(
            for: anchor,
            cardSize: cardSize,
            in: visible,
            overlayOriginal: true
        )

        XCTAssertFalse(placement.placedAbove)
        XCTAssertEqual(placement.frame.midX, anchor.midX, accuracy: 0.5)
        XCTAssertEqual(placement.frame.midY, anchor.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(placement.frame.width, anchor.width)
    }

    // MARK: - Adaptive Auto-Sizing & Manual Resize Geometry

    func testAdaptiveWidthScalesFromShortWordToLongParagraph() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let shortWidth = QuickTranslatePanel.adaptiveCardWidth(
            for: .editorial,
            sourceText: "ephemeral",
            translatedText: "短暂的",
            hasDictionary: false,
            showsBilingual: false,
            anchorWidth: 90,
            overlayOriginal: false,
            in: visible
        )
        let mediumWidth = QuickTranslatePanel.adaptiveCardWidth(
            for: .editorial,
            sourceText: "This view adapts cleanly to its translated content.",
            translatedText: "这个浮卡会根据翻译内容的长度自动调整最舒适的阅读宽度。",
            hasDictionary: false,
            showsBilingual: false,
            anchorWidth: 280,
            overlayOriginal: false,
            in: visible
        )
        let longWidth = QuickTranslatePanel.adaptiveCardWidth(
            for: .editorial,
            sourceText: nil,
            translatedText: "在现代桌面应用中，轻量级的划词或截图翻译浮窗应当根据译文长度智能适配宽高：遇到单个单词时紧凑克制不遮挡屏幕，遇到长段落说明文档时则自动展宽并增长高度，减少不必要的滚动与换行，同时允许用户随时拖曳边缘微调。",
            hasDictionary: false,
            showsBilingual: false,
            anchorWidth: 360,
            overlayOriginal: false,
            in: visible
        )

        XCTAssertLessThanOrEqual(shortWidth, 290)
        XCTAssertGreaterThan(mediumWidth, shortWidth)
        XCTAssertGreaterThan(longWidth, mediumWidth)
        XCTAssertLessThanOrEqual(longWidth, 580)

        // 调大译文字号后，自适应宽度也应同步放宽，避免大字号挤成窄列
        let largeFontWidth = QuickTranslatePanel.adaptiveCardWidth(
            for: .editorial,
            sourceText: "This view adapts cleanly to its translated content.",
            translatedText: "这个浮卡会根据翻译内容的长度自动调整最舒适的阅读宽度。",
            hasDictionary: false,
            showsBilingual: false,
            anchorWidth: 280,
            overlayOriginal: false,
            targetFontSize: 20,
            in: visible
        )
        XCTAssertGreaterThan(largeFontWidth, mediumWidth)
    }

    func testAdaptiveWidthExpandsToCoverWideAnchorInOverlayOriginalMode() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = QuickTranslatePanel.adaptiveCardWidth(
            for: .inlineBilingual,
            sourceText: "Short",
            translatedText: "简短",
            hasDictionary: false,
            showsBilingual: false,
            anchorWidth: 460,
            overlayOriginal: true,
            in: visible
        )
        XCTAssertGreaterThanOrEqual(width, 476)
        XCTAssertLessThanOrEqual(width, 580)
    }

    func testManualResizeAnchorsOppositeEdgesAndClampsBounds() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let start = CGRect(x: 400, y: 400, width: 360, height: 180)
        let minSize = QuickTranslatePanel.minimumCardSize(for: .liquidGlass)
        let maxSize = QuickTranslatePanel.maximumCardSize(in: visible)

        // 右下角向外拖拽（AppKit 坐标中向下移动 delta.height < 0）
        let grownBR = QuickTranslatePanel.resizedCardFrame(
            from: start,
            edge: .bottomRight,
            delta: CGSize(width: 90, height: -70),
            minSize: minSize,
            maxSize: maxSize,
            within: visible
        )
        XCTAssertEqual(grownBR.minX, start.minX, accuracy: 0.5)
        XCTAssertEqual(grownBR.maxY, start.maxY, accuracy: 0.5)
        XCTAssertEqual(grownBR.width, 450, accuracy: 0.5)
        XCTAssertEqual(grownBR.height, 250, accuracy: 0.5)

        // 左上角向外拖拽（向左 delta.width < 0，向上 delta.height > 0）
        let grownTL = QuickTranslatePanel.resizedCardFrame(
            from: start,
            edge: .topLeft,
            delta: CGSize(width: -80, height: 60),
            minSize: minSize,
            maxSize: maxSize,
            within: visible
        )
        XCTAssertEqual(grownTL.maxX, start.maxX, accuracy: 0.5)
        XCTAssertEqual(grownTL.minY, start.minY, accuracy: 0.5)
        XCTAssertEqual(grownTL.width, 440, accuracy: 0.5)
        XCTAssertEqual(grownTL.height, 240, accuracy: 0.5)

        // 过度向内压缩应夹紧到最小尺寸且保持对侧不动
        let shrunk = QuickTranslatePanel.resizedCardFrame(
            from: start,
            edge: .left,
            delta: CGSize(width: 300, height: 0),
            minSize: minSize,
            maxSize: maxSize,
            within: visible
        )
        XCTAssertEqual(shrunk.maxX, start.maxX, accuracy: 0.5)
        XCTAssertEqual(shrunk.width, minSize.width, accuracy: 0.5)
    }

    // MARK: - Selection Overlay Quick-Translate Interaction & Drawing

    func testQuickTranslateSelectionConfirmsImmediatelyOnMouseUpWithoutToolbar() throws {
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.quickTranslateStyle = .liquidGlass
        view.quickTranslateTargetLanguage = "简体中文"

        var finishedRect: CGRect?
        view.onFinish = { rect in finishedRect = rect }

        let start = CGPoint(x: 120, y: 140)
        let end = CGPoint(x: 360, y: 260)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: start, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: end, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: end, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        XCTAssertNil(view.barLayout())
        XCTAssertNil(view.quickToolbarLayout())
        XCTAssertNil(finishedRect)

        view.mouseUp(with: up)
        XCTAssertEqual(finishedRect, CGRect(x: 120, y: 140, width: 240, height: 120))
    }

    func testTabKeyCyclesTargetLanguageInQuickTranslateMode() throws {
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.quickTranslateStyle = .inlineBilingual
        view.quickTranslateTargetLanguage = "简体中文"
        var cycleCount = 0
        view.onCycleQuickTranslateLanguage = {
            cycleCount += 1
            return "英语"
        }

        let tabEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        view.keyDown(with: tabEvent)

        XCTAssertEqual(cycleCount, 1)
        XCTAssertEqual(view.quickTranslateTargetLanguage, "英语")
    }

    func testLanguageCycleSequenceWrapsCleanly() {
        XCTAssertEqual(CaptureCoordinator.nextQuickTranslateLanguage(after: "zh-Hans"), "en")
        XCTAssertEqual(CaptureCoordinator.nextQuickTranslateLanguage(after: "en"), "ja")
        XCTAssertEqual(CaptureCoordinator.nextQuickTranslateLanguage(after: "ja"), "ko")
        XCTAssertEqual(CaptureCoordinator.nextQuickTranslateLanguage(after: "ko"), "zh-Hans")
        XCTAssertEqual(CaptureCoordinator.nextQuickTranslateLanguage(after: "fr"), "zh-Hans")
    }

    func testAllFourQuickTranslateSelectionStylesRenderCleanlyWithCoreText() throws {
        for style in QuickTranslateStyle.allCases {
            let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
            view.quickTranslateStyle = style
            view.quickTranslateTargetLanguage = "简体中文"
            view.previewSnap(at: CGPoint(x: 200, y: 160))

            // 1. 先画未框选时的光标跟随提示牌
            _ = renderOffscreen(view)

            // 2. 再模拟拖出选区过程中绘制各样式专属框选组件
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 80, y: 90), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let drag = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDragged, location: CGPoint(x: 340, y: 220), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            view.mouseDown(with: down)
            view.mouseDragged(with: drag)

            let rep = renderOffscreen(view)
            XCTAssertEqual(rep.pixelsWide, 480)
            XCTAssertEqual(rep.pixelsHigh, 320)
        }
    }

    private func renderOffscreen(_ view: NSView) -> NSBitmapImageRep {
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
