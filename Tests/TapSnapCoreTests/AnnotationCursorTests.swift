import AppKit
import CoreGraphics
import TapSnapCore
import XCTest
@testable import TapSnapApp

@MainActor
final class AnnotationCursorTests: XCTestCase {
    private func fixture() -> (EditController, EditItemLayerView) {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = EditController(environment: AppEnvironment(), image: context.makeImage()!,
                                        scale: 2, style: EditItemStyle())
        controller.selectedTool = .serialNumber
        let view = EditItemLayerView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.controller = controller
        return (controller, view)
    }

    private func bitmap(size: CGSize, draw: (CGContext) -> Void) throws -> Data {
        let width = Int(size.width), height = Int(size.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(rep.bitmapData)
        pixels.initialize(repeating: 0, count: rep.bytesPerRow * height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = graphics
        draw(graphics.cgContext)
        return Data(bytes: pixels, count: rep.bytesPerRow * height)
    }

    private func cursorPixels(_ view: EditItemLayerView) throws -> Data {
        let image = view.annotationCursor.image
        return try bitmap(size: image.size) { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func refreshWithoutEditing(_ view: EditItemLayerView, controller: EditController) throws -> Data {
        let ids = controller.document.items.map(\.id)
        let selectedID = controller.document.selectedItemID
        let revision = controller.revision
        let canUndo = controller.canUndo, canRedo = controller.canRedo
        view.updateInteractionState()
        let pixels = try cursorPixels(view)
        XCTAssertEqual(controller.document.items.map(\.id), ids)
        XCTAssertEqual(controller.document.selectedItemID, selectedID)
        XCTAssertEqual(controller.revision, revision)
        XCTAssertEqual(controller.canUndo, canUndo)
        XCTAssertEqual(controller.canRedo, canRedo)
        XCTAssertNil(view.window, "只测试离屏组件，不创建窗口")
        return pixels
    }

    func testCursorSizeAndHotSpotFollowCanvasZoomWithoutDoublingRetinaScale() throws {
        let (controller, view) = fixture()
        for scale: CGFloat in [0.5, 1, 2] {
            view.displayScale = scale
            let pixels = try refreshWithoutEditing(view, controller: controller)
            XCTAssertEqual(view.annotationCursor.image.size, CGSize(width: 22 * scale, height: 22 * scale))
            XCTAssertEqual(view.annotationCursor.hotSpot, CGPoint(x: 11 * scale, y: 11 * scale))
            XCTAssertTrue(pixels.contains { $0 != 0 })
        }
    }

    func testCursorNumberRefreshesAfterPlacementUndoAndRedo() throws {
        let (controller, view) = fixture()
        let first = try refreshWithoutEditing(view, controller: controller)
        XCTAssertEqual(controller.nextSerialIndex, 1)
        controller.add(EditItemFactory.makeSerial(at: CGPoint(x: 20, y: 20), index: 1, style: controller.style))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let second = try refreshWithoutEditing(view, controller: controller)
        XCTAssertEqual(controller.nextSerialIndex, 2)
        XCTAssertNotEqual(first, second)

        controller.perform(.undo)
        XCTAssertEqual(controller.nextSerialIndex, 1)
        XCTAssertEqual(try refreshWithoutEditing(view, controller: controller), first)
        controller.perform(.redo)
        XCTAssertEqual(controller.nextSerialIndex, 2)
        XCTAssertEqual(try refreshWithoutEditing(view, controller: controller), second)
    }

    func testCursorUpdatesImmediatelyWhenNextSerialIndexIsCustomized() throws {
        let (controller, view) = fixture()
        let initial = try refreshWithoutEditing(view, controller: controller)
        controller.nextSerialIndex = 4
        let custom = try refreshWithoutEditing(view, controller: controller)
        XCTAssertNotEqual(initial, custom)
        XCTAssertTrue(controller.document.items.isEmpty)
        XCTAssertFalse(controller.canUndo)
    }

    func testCursorStyleRefreshDoesNotCreateAnAnnotationOrUndoStep() throws {
        let (controller, view) = fixture()
        let red = try refreshWithoutEditing(view, controller: controller)
        controller.style.color = RGBAColor(rgb: 0x0088FF)
        let blue = try refreshWithoutEditing(view, controller: controller)
        XCTAssertNotEqual(red, blue)
        controller.style.opacity = 0.35
        XCTAssertNotEqual(blue, try refreshWithoutEditing(view, controller: controller))
        XCTAssertTrue(controller.document.items.isEmpty)
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
    }

    func testLeavingSerialToolRestoresTheAppropriateSystemCursor() {
        let (controller, view) = fixture()
        view.updateInteractionState()
        controller.selectedTool = .rectangle
        view.updateInteractionState()
        XCTAssertTrue(view.annotationCursor === NSCursor.crosshair)
        controller.selectedTool = nil
        view.updateInteractionState()
        XCTAssertTrue(view.annotationCursor === NSCursor.arrow)
        controller.selectedTool = .serialNumber
        view.updateInteractionState()
        controller.toggleCrop()
        view.updateInteractionState()
        XCTAssertTrue(view.annotationCursor === NSCursor.crosshair)
    }

    func testCursorPixelsMatchThePlacedSerialInFlippedCanvasCoordinates() throws {
        let (controller, view) = fixture()
        // 用非上下对称的数字确认文字没有被翻转。
        controller.add(EditItemFactory.makeSerial(at: CGPoint(x: 20, y: 20), index: 1, style: controller.style))
        for scale: CGFloat in [0.5, 1, 2] {
            view.displayScale = scale
            let actual = try refreshWithoutEditing(view, controller: controller)
            let size = view.annotationCursor.image.size
            let expected = try bitmap(size: size) { context in
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: scale, y: -scale)
                EditItemFactory.makeSerial(at: CGPoint(x: 11, y: 11), index: 2,
                                           style: controller.style).draw(in: context, scale: controller.document.scale)
            }
            XCTAssertEqual(actual, expected, "鼠标图案应与落下的序号大小、方向和颜色相同，scale=\(scale)")
        }
    }
}
