import AppKit
import CoreText
import TapSnapConfig
import TapSnapCore
import TapSnapPrivacy
import XCTest
@testable import TapSnapApp

@MainActor
final class EditFeatureCompletionTests: XCTestCase {
    private func image(width: Int = 300, height: Int = 200) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func controller(configure: (inout Settings) -> Void = { _ in }) -> EditController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update(configure)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return EditController(environment: AppEnvironment(config: config), image: image(), scale: 1,
                              style: EditItemStyle())
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    func testConfirmOutputCombinationsOnlyPerformConfiguredActions() {
        for copyEnabled in [false, true] {
            for saveEnabled in [false, true] {
                var copied = 0, saved = 0
                XCTAssertTrue(EditController.completeOutputs(autoCopy: copyEnabled, autoSave: saveEnabled,
                    copy: { copied += 1; return true }, save: { saved += 1; return true }))
                XCTAssertEqual(copied, copyEnabled ? 1 : 0)
                XCTAssertEqual(saved, saveEnabled ? 1 : 0)
            }
        }
    }

    func testFailedSaveKeepsEditorOpenAndCanBeRetried() {
        var copied = false
        XCTAssertFalse(EditController.completeOutputs(autoCopy: true, autoSave: true,
            copy: { copied = true; return true }, save: { false }))
        XCTAssertFalse(copied)
        XCTAssertTrue(EditController.completeOutputs(autoCopy: true, autoSave: true,
            copy: { copied = true; return true }, save: { true }))
        XCTAssertTrue(copied)
    }

    func testToolDefaultsReadMosaicSizeAndMagnifierZoomSettings() {
        let editor = controller {
            $0.annotate.mosaicBlockSize = 28
            $0.annotate.magnifierZoom = 4
        }
        XCTAssertEqual(editor.toolOptions.mosaicBlockSize, 28)
        XCTAssertEqual(editor.toolOptions.magnifierZoom, 4)
    }

    func testFactoryPropagatesEveryToolOption() throws {
        var options = EditToolOptions()
        options.arrowHead = .hollow
        options.mosaicMode = .blur
        options.mosaicBlockSize = 30
        options.serialFormat = .upperAlpha
        options.magnifierZoom = 4
        options.watermarkText = "内部资料"
        options.watermarkAngle = 25
        options.watermarkTiled = false
        options.textBackground = .rounded
        let start = CGPoint(x: 10, y: 20), end = CGPoint(x: 190, y: 120)
        func make(_ kind: EditItemKind) -> (any EditItem)? {
            EditItemFactory.make(kind: kind, from: start, to: end, style: EditItemStyle(), options: options)
        }
        XCTAssertEqual((make(.arrow) as? ArrowItem)?.headStyle, .hollow)
        XCTAssertEqual((make(.text) as? TextItem)?.background, .rounded)
        XCTAssertEqual((make(.mosaic) as? MosaicItem)?.mode, .blur)
        XCTAssertEqual((make(.mosaic) as? MosaicItem)?.blockSize, 30)
        XCTAssertEqual((make(.serialNumber) as? SerialItem)?.format, .upperAlpha)
        XCTAssertEqual((make(.magnifier) as? MagnifierItem)?.zoom, 4)
        let watermark = try XCTUnwrap(make(.watermark) as? WatermarkItem)
        XCTAssertEqual(watermark.text, "内部资料")
        XCTAssertEqual(watermark.angle, 25)
        XCTAssertFalse(watermark.isTiled)
        XCTAssertEqual(watermark.bounds, CGRect(x: 10, y: 20, width: 180, height: 100))
    }

    func testSelectedAnnotationStyleChangeSupportsRepeatedUndoRedo() {
        let editor = controller()
        let arrow = ArrowItem(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100))
        editor.add(arrow)
        settle()
        editor.select(arrow)
        editor.toolOptions.arrowHead = .hollow
        settle()
        XCTAssertEqual(arrow.headStyle, .hollow)
        for _ in 0..<2 {
            editor.perform(.undo)
            XCTAssertEqual(arrow.headStyle, .filled)
            XCTAssertEqual(editor.toolOptions.arrowHead, .filled)
            editor.perform(.redo)
            XCTAssertEqual(arrow.headStyle, .hollow)
        }
        XCTAssertEqual(editor.document.items.count, 1)
    }

    func testHandDrawnStyleAppliesToNewShapesAndCanBeToggledOnExistingOnes() throws {
        let editor = controller()
        let standard = LineItem(start: CGPoint(x: 15, y: 20), end: CGPoint(x: 125, y: 20), style: editor.style)
        XCTAssertEqual(standard.style.strokeStyle, .standard)
        editor.add(standard)
        settle()

        editor.perform(.rectangle)
        editor.style.strokeStyle = .handDrawn
        let shape = try XCTUnwrap(EditItemFactory.make(kind: .rectangle, from: CGPoint(x: 20, y: 40),
                                                      to: CGPoint(x: 150, y: 120), style: editor.style))
        editor.add(shape)
        settle()
        XCTAssertEqual(shape.style.strokeStyle, .handDrawn)
        XCTAssertEqual(standard.style.strokeStyle, .standard)

        editor.select(standard)
        XCTAssertEqual(editor.style.strokeStyle, .standard)
        editor.style.strokeStyle = .handDrawn
        settle()
        XCTAssertEqual(standard.style.strokeStyle, .handDrawn)

        editor.perform(.undo)
        XCTAssertEqual(editor.style.strokeStyle, .standard)
        XCTAssertEqual(standard.style.strokeStyle, .standard)
        editor.perform(.redo)
        XCTAssertEqual(editor.style.strokeStyle, .handDrawn)
        XCTAssertEqual(standard.style.strokeStyle, .handDrawn)
        XCTAssertEqual(shape.style.strokeStyle, .handDrawn)
    }

    func testHandDrawnPenRoughnessAndFillAreIndependentlyUndoable() {
        let editor = controller()
        var style = editor.style
        style.strokeStyle = .handDrawn
        style.shapeFill = .fillAndOutline
        let item = ShapeItem(kind: .rectangle, bounds: CGRect(x: 15, y: 20, width: 100, height: 80), style: style)
        editor.add(item)
        settle()
        editor.select(item)
        XCTAssertEqual(editor.style.handDrawnPen, .sketch)
        XCTAssertEqual(editor.style.handDrawnRoughness, .natural)
        XCTAssertEqual(editor.style.handDrawnFill, .hachure)

        editor.style.handDrawnPen = .ink
        settle()
        editor.style.handDrawnRoughness = .expressive
        settle()
        editor.style.handDrawnFill = .zigzag
        settle()
        XCTAssertEqual(item.style.handDrawnPen, .ink)
        XCTAssertEqual(item.style.handDrawnRoughness, .expressive)
        XCTAssertEqual(item.style.handDrawnFill, .zigzag)

        editor.perform(.undo)
        XCTAssertEqual(item.style.handDrawnRoughness, .expressive)
        XCTAssertEqual(item.style.handDrawnFill, .hachure)
        editor.perform(.undo)
        XCTAssertEqual(item.style.handDrawnRoughness, .natural)
        XCTAssertEqual(item.style.handDrawnPen, .ink)
        editor.perform(.undo)
        XCTAssertEqual(item.style.handDrawnPen, .sketch)
        editor.perform(.redo)
        editor.perform(.redo)
        editor.perform(.redo)
        XCTAssertEqual(editor.style.handDrawnPen, .ink)
        XCTAssertEqual(editor.style.handDrawnRoughness, .expressive)
        XCTAssertEqual(editor.style.handDrawnFill, .zigzag)
    }

    func testLineWidthDragUpdatesSelectedFrameAndUndoesAsOneAction() {
        let editor = controller()
        let rectangle = ShapeItem(kind: .rectangle, bounds: CGRect(x: 10, y: 10, width: 90, height: 60))
        editor.add(rectangle)
        settle()
        let original = rectangle.style.lineWidth
        editor.setStyleEditing(true)
        for width: CGFloat in [4, 9, 15, 20] {
            let revision = editor.revision
            editor.style.lineWidth = width
            XCTAssertEqual(rectangle.style.lineWidth, width)
            XCTAssertGreaterThan(editor.revision, revision)
            settle() // Each update is a separate event, as during a real slider drag.
        }
        editor.setStyleEditing(false)
        settle()
        editor.perform(.undo)
        XCTAssertEqual(rectangle.style.lineWidth, original)
        XCTAssertEqual(editor.style.lineWidth, original)
        XCTAssertEqual(editor.document.items.count, 1)
        editor.perform(.redo)
        XCTAssertEqual(rectangle.style.lineWidth, 20)
        XCTAssertEqual(editor.style.lineWidth, 20)
    }

    func testFontSizeDragUndoesToTheOriginalTextBox() {
        let editor = controller()
        let item = TextItem(text: "对齐的文字标注", bounds: CGRect(x: 10, y: 10, width: 150, height: 24))
        item.style.textFormat.alignment = .right
        item.fitToText(maxWidth: 150)
        editor.document.append(item)
        editor.select(item)
        let original = item.bounds

        editor.setStyleEditing(true)
        for size: CGFloat in [18, 30, 44] {
            editor.style.fontSize = size
            XCTAssertEqual(item.style.fontSize, size)
            settle()
        }
        editor.setStyleEditing(false)
        settle()
        let resized = item.bounds
        XCTAssertGreaterThan(resized.height, original.height)
        XCTAssertEqual(resized.width, 150)
        editor.perform(.undo)
        XCTAssertEqual(item.style.fontSize, 14)
        XCTAssertEqual(item.bounds, original)
        editor.perform(.redo)
        XCTAssertEqual(item.style.fontSize, 44)
        XCTAssertEqual(item.bounds, resized)
        XCTAssertEqual(item.style.textFormat.alignment, .right)
    }

    func testChoosingAnotherToolDoesNotChangePreviousAnnotation() {
        let editor = controller()
        let rectangle = ShapeItem(kind: .rectangle, bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
        editor.add(rectangle)
        editor.perform(.arrow)
        editor.style.color = RGBAColor(rgb: 0x0088FF)
        XCTAssertEqual(rectangle.style.color, RGBAColor(rgb: 0xFF3B30))
    }

    func testOpeningMatchingToolStyleKeepsExistingAnnotationSelected() {
        let editor = controller()
        let shape = ShapeItem(kind: .rectangle, bounds: CGRect(x: 20, y: 20, width: 60, height: 40))
        editor.add(shape)
        editor.perform(.rectangle)
        XCTAssertEqual(editor.document.selectedItemID, shape.id)
        XCTAssertEqual(editor.selectedTool, .rectangle)
        editor.style.lineWidth = 9
        XCTAssertEqual(shape.style.lineWidth, 9)
        editor.perform(.arrow)
        XCTAssertNil(editor.document.selectedItemID)
        XCTAssertEqual(editor.activeItemKind, .arrow)
        editor.style.lineWidth = 3
        XCTAssertEqual(shape.style.lineWidth, 9)
    }

    func testSerialFormatsContinuePastTheirFirstAlphabetAndUnicodeRange() {
        let serial = SerialItem(index: 27, bounds: CGRect(x: 0, y: 0, width: 22, height: 22), format: .upperAlpha)
        XCTAssertEqual(serial.label, "AA")
        serial.format = .lowerAlpha
        XCTAssertEqual(serial.label, "aa")
        serial.index = 21
        serial.format = .circled
        XCTAssertEqual(serial.label, "(21)")
    }

    func testWatermarkSingleAndTiledModesProduceDifferentRenderedPixels() throws {
        let item = WatermarkItem(text: "TapSnap", bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                                 angle: 0, isTiled: false)
        let document = EditDocument(baseImage: image(), items: [item])
        let single = try XCTUnwrap(try document.render().dataProvider?.data) as Data
        item.isTiled = true
        let tiled = try XCTUnwrap(try document.render().dataProvider?.data) as Data
        XCTAssertNotEqual(single, tiled)
        XCTAssertNotEqual(single, try XCTUnwrap(image().dataProvider?.data) as Data)
    }

    func testCropMapsToGlobalSourceOnAnOffsetRetinaDisplay() {
        let source = CGRect(x: -1400, y: 250, width: 600, height: 400)
        let rect = EditController.sourceRect(captureRect: source,
            crop: CGRect(x: 50, y: 25, width: 100, height: 75), canvas: CGSize(width: 300, height: 200))
        XCTAssertEqual(rect, CGRect(x: -1300, y: 300, width: 200, height: 150))
        XCTAssertNil(EditController.sourceRect(captureRect: nil, crop: source, canvas: source.size))
    }

    func testOutOfCanvasCropIsClampedBeforeModeHandoff() {
        let source = CGRect(x: 100, y: 200, width: 300, height: 200)
        XCTAssertEqual(EditController.sourceRect(captureRect: source,
            crop: CGRect(x: -20, y: -20, width: 120, height: 120), canvas: source.size),
            CGRect(x: 100, y: 200, width: 100, height: 100))
    }

    func testLegacyToolbarPositionUsesFixedBottomWithoutResettingAppearance() throws {
        for legacy in ["followSelection", "top", "bottom"] {
            let json = "{\"useDarkTheme\":false,\"toolBarPosition\":\"\(legacy)\",\"showDesktopBar\":true}"
            let appearance = try JSONDecoder().decode(Settings.Appearance.self, from: Data(json.utf8))
            XCTAssertEqual(appearance.toolBarPosition, "bottom")
            XCTAssertFalse(appearance.useDarkTheme)
            XCTAssertTrue(appearance.showDesktopBar)
        }
        XCTAssertEqual(Settings.Appearance().toolBarPosition, "bottom")
    }

    func testAutoMosaicConvertsCoordinatesAndIgnoresDetectionsOutsideSelectedRegion() {
        let boxes = [CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2),
                     CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2)]
        let regions = AutoMosaicDetector.documentRects(boxes, canvas: CGSize(width: 100, height: 100),
                                                       selection: CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].minX, 6, accuracy: 0.001)
        XCTAssertEqual(regions[0].minY, 6, accuracy: 0.001)
        XCTAssertEqual(regions[0].width, 28, accuracy: 0.001)
        XCTAssertTrue(AutoMosaicDetector.documentRects(boxes, canvas: CGSize(width: 100, height: 100),
            selection: CGRect(x: 45, y: 45, width: 5, height: 5)).isEmpty)
    }

    func testLocalTextDetectorFindsRenderedTextForAutomaticMosaic() throws {
        let context = CGContext(data: nil, width: 600, height: 180, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 180))
        let text = NSAttributedString(string: "CONFIDENTIAL 123456", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 25, y: 80)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let boxes = try AutoMosaicDetector.detect(in: context.makeImage()!, faces: false, text: true)
        XCTAssertFalse(boxes.isEmpty)
        let regions = AutoMosaicDetector.documentRects(boxes, canvas: CGSize(width: 600, height: 180),
                                                       selection: CGRect(x: 0, y: 0, width: 600, height: 180))
        XCTAssertFalse(regions.isEmpty)
        XCTAssertTrue(regions.contains { $0.width > 200 && $0.height > 15 })
    }

    func testClosingEditorCancelsPendingAutomaticMosaic() async throws {
        let editor = controller()
        editor.mosaicDetectText = true
        editor.add(MosaicItem(bounds: CGRect(x: 0, y: 0, width: 200, height: 100), autoDetect: true))
        XCTAssertTrue(editor.isDetectingMosaic)
        editor.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(editor.isDetectingMosaic)
        XCTAssertTrue(editor.document.items.isEmpty)
    }

    func testAutomaticMosaicKeepsSelectedRedactionStyleOnDetectedText() async throws {
        let editor = controller()
        editor.mosaicAutoDetect = false
        editor.mosaicDetectText = true
        let context = CGContext(data: nil, width: 480, height: 160, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image(width: 480, height: 160), in: CGRect(x: 0, y: 0, width: 480, height: 160))
        let text = NSAttributedString(string: "DEMO 123456", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 30, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 25, y: 75)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let edited = EditController(environment: editor.environment, image: context.makeImage()!, scale: 1,
                                    style: EditItemStyle())
        edited.mosaicAutoDetect = false
        edited.mosaicDetectText = true
        let selection = CGRect(x: 0, y: 0, width: 480, height: 160)
        let mode = MosaicItem.Mode.redaction(.init(style: .erase))
        edited.add(MosaicItem(bounds: selection, mode: mode, autoDetect: true))
        for _ in 0..<120 {
            if !edited.isDetectingMosaic { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(edited.isDetectingMosaic)
        let item = try XCTUnwrap(edited.document.items.first as? MosaicItem)
        XCTAssertEqual(item.mode, mode)
        XCTAssertNotEqual(item.bounds, selection)
        XCTAssertEqual(edited.document.privacyPixelBounds, [item.bounds.integral])
        edited.select(item)
        edited.toolOptions.mosaicMode = .blur
        XCTAssertTrue(edited.document.privacyPixelBounds.isEmpty)
        settle()
        edited.perform(.undo)
        XCTAssertEqual(item.mode, mode)
        XCTAssertEqual(edited.document.privacyPixelBounds, [item.bounds.integral])
    }
}
