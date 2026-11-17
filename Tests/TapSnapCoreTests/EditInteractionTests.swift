import AppKit
import CoreGraphics
import TapSnapCore
import TapSnapPrivacy
import XCTest
@testable import TapSnapApp

@MainActor
final class EditInteractionTests: XCTestCase {
    private let displayScales: [CGFloat] = [0.5, 1, 2]

    private func fixture(displayScale: CGFloat, patterned: Bool = false) -> (EditController, EditItemLayerView, NSWindow) {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        if patterned {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in stride(from: 0, to: 300, by: 8) {
                for x in stride(from: 0, to: 400, by: 8) where (x / 8 + y / 8).isMultiple(of: 2) {
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let style = EditItemStyle(color: RGBAColor(rgb: 0xD62D20), lineWidth: 5, fontSize: 18, opacity: 0.85)
        let controller = EditController(environment: AppEnvironment(), image: context.makeImage()!, scale: 2, style: style)
        let frame = CGRect(x: 0, y: 0, width: 200 * displayScale, height: 150 * displayScale)
        let view = EditItemLayerView(frame: frame)
        view.controller = controller
        view.displayScale = displayScale
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertFalse(window.isVisible)
        return (controller, view, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: EditItemLayerView) throws {
        let local = CGPoint(x: point.x * view.displayScale, y: point.y * view.displayScale)
        let windowPoint = view.convert(local, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [],
                                                   timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        default: XCTFail("Unsupported test event")
        }
    }

    /// 匹配 AppKit 对 flipped view 的 CTM，只画标注，不依赖窗口显示或系统输入。
    private func bitmap(for view: EditItemLayerView, drawing: (CGContext) -> Void) throws -> [UInt8] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.bitmapData)
        data.initialize(repeating: 0, count: rep.bytesPerRow * height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        drawing(context)
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * height))
    }

    private func rendered(_ view: EditItemLayerView) throws -> [UInt8] {
        try bitmap(for: view) { _ in view.draw(view.bounds) }
    }

    private func reference(_ item: any EditItem, view: EditItemLayerView,
                           controller: EditController) throws -> [UInt8] {
        try bitmap(for: view) { context in
            context.scaleBy(x: view.displayScale, y: view.displayScale)
            item.prepare(source: controller.document.baseImage, scale: controller.document.scale)
            item.draw(in: context, scale: controller.document.scale)
        }
    }

    private func assertPixelsEqual(_ actual: [UInt8], _ expected: [UInt8], _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let differences = zip(actual, expected).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        XCTAssertEqual(differences, 0, message, file: file, line: line)
    }

    func testArrowDragPreviewMatchesRealArrowAndCommittedPixelsAtEveryZoom() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.arrow)
            let start = CGPoint(x: 20, y: 20), end = CGPoint(x: 140, y: 100)
            try mouse(.leftMouseDown, at: start, in: view)
            try mouse(.leftMouseDragged, at: end, in: view)
            let preview = try rendered(view)
            let arrow = ArrowItem(start: start, end: end, style: controller.style)
            let expected = try reference(arrow, view: view, controller: controller)
            XCTAssertTrue(expected.contains { $0 != 0 }, "参考箭头应有实际像素")
            assertPixelsEqual(preview, expected, "拖动时应显示真实颜色的斜箭杆和箭头，不是包围矩形，zoom=\(scale)")
            XCTAssertTrue(controller.document.items.isEmpty, "预览不能提前写入文档")
            XCTAssertFalse(controller.canUndo, "预览不能占用撤销步骤")
            try mouse(.leftMouseUp, at: end, in: view)
            XCTAssertEqual(controller.document.items.count, 1)
            controller.clearSelection()
            assertPixelsEqual(try rendered(view), preview, "松手提交后的箭头应和预览一致，zoom=\(scale)")
        }
    }

    func testEllipseDragPreviewMatchesRealEllipseAndCommittedPixelsAtEveryZoom() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.ellipse)
            let rect = CGRect(x: 30, y: 25, width: 120, height: 80)
            try mouse(.leftMouseDown, at: rect.origin, in: view)
            try mouse(.leftMouseDragged, at: CGPoint(x: rect.maxX, y: rect.maxY), in: view)
            let preview = try rendered(view)
            let ellipse = ShapeItem(kind: .ellipse, bounds: rect, style: controller.style)
            let expected = try reference(ellipse, view: view, controller: controller)
            XCTAssertTrue(expected.contains { $0 != 0 })
            assertPixelsEqual(preview, expected, "拖动时应有椭圆弧线及透明四角，不是矩形，zoom=\(scale)")
            XCTAssertTrue(controller.document.items.isEmpty)
            try mouse(.leftMouseUp, at: CGPoint(x: rect.maxX, y: rect.maxY), in: view)
            XCTAssertEqual(controller.document.items.count, 1)
            controller.clearSelection()
            assertPixelsEqual(try rendered(view), preview, "松手提交后的椭圆应和预览一致，zoom=\(scale)")
        }
    }

    func testHandDrawnRectanglePreviewMatchesCommittedPixelsAtEveryZoom() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.rectangle)
            controller.style.shapeFill = .fillAndOutline
            let rect = CGRect(x: 26, y: 30, width: 126, height: 74)
            let standard = ShapeItem(kind: .rectangle, bounds: rect, style: controller.style)
            let standardPixels = try reference(standard, view: view, controller: controller)
            controller.style.strokeStyle = .handDrawn
            controller.style.handDrawnPen = .ink
            controller.style.handDrawnRoughness = .expressive
            controller.style.handDrawnFill = .dots

            let end = CGPoint(x: rect.maxX, y: rect.maxY)
            try mouse(.leftMouseDown, at: rect.origin, in: view)
            try mouse(.leftMouseDragged, at: end, in: view)
            let preview = try rendered(view)
            XCTAssertTrue(preview.contains { $0 != 0 })
            XCTAssertFalse(preview.elementsEqual(standardPixels), "手绘描边应区别于标准描边，zoom=\(scale)")
            XCTAssertTrue(controller.document.items.isEmpty)

            try mouse(.leftMouseUp, at: end, in: view)
            let rectangle = try XCTUnwrap(controller.document.items.first as? ShapeItem)
            XCTAssertEqual(rectangle.style.strokeStyle, .handDrawn)
            XCTAssertEqual(rectangle.style.handDrawnPen, .ink)
            XCTAssertEqual(rectangle.style.handDrawnFill, .dots)
            controller.clearSelection()
            assertPixelsEqual(try rendered(view), preview, "松手后应保留预览中的手绘笔迹，zoom=\(scale)")
        }
    }

    func testHighlightFollowsFreehandDragAndCanBeUndoneAtEveryZoom() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.highlight)
            let empty = try rendered(view)
            let end = CGPoint(x: 145, y: 125)
            try mouse(.leftMouseDown, at: CGPoint(x: 25, y: 25), in: view)
            try mouse(.leftMouseDragged, at: CGPoint(x: 25, y: 95), in: view)
            try mouse(.leftMouseDragged, at: CGPoint(x: 25, y: 125), in: view)
            try mouse(.leftMouseDragged, at: end, in: view)

            let preview = try rendered(view)
            let height = Int(view.bounds.height)
            let middleRowOffset = (height / 2) * (preview.count / height)
            let strokeAlpha = preview[middleRowOffset + Int(25 * scale) * 4 + 3]
            let boxInteriorAlpha = preview[middleRowOffset + Int(85 * scale) * 4 + 3]
            XCTAssertGreaterThan(strokeAlpha, 0, "高亮应沿拖动轨迹出现，zoom=\(scale)")
            XCTAssertLessThan(strokeAlpha, 255, "高亮应保留底图，zoom=\(scale)")
            XCTAssertEqual(boxInteriorAlpha, 0, "高亮不应填满轨迹的包围框，zoom=\(scale)")
            XCTAssertFalse(controller.canUndo)

            try mouse(.leftMouseUp, at: end, in: view)
            XCTAssertEqual(controller.document.items.map(\.kind), [.highlight])
            controller.clearSelection()
            assertPixelsEqual(try rendered(view), preview, "已提交的轨迹应与拖动预览一致，zoom=\(scale)")
            controller.perform(.undo)
            assertPixelsEqual(try rendered(view), empty, "一笔高亮应能一次撤销，zoom=\(scale)")
            controller.perform(.redo)
            controller.clearSelection()
            assertPixelsEqual(try rendered(view), preview, "重做应恢复完整的高亮轨迹，zoom=\(scale)")

            let hit = CGPoint(x: 25, y: 65)
            let item = try XCTUnwrap(controller.document.item(at: hit) as? HighlightItem)
            XCTAssertNil(controller.document.item(at: CGPoint(x: 85, y: 75)))
            let original = item.points
            let moved = CGPoint(x: 40, y: 73)
            try mouse(.leftMouseDown, at: hit, in: view)
            try mouse(.leftMouseDragged, at: moved, in: view)
            try mouse(.leftMouseUp, at: moved, in: view)
            XCTAssertEqual(item.points, original.map { $0 + CGPoint(x: 15, y: 8) })
        }
    }

    func testSerialNumberClickWithoutDraggingPlacesCenterAtClick() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.serialNumber)
            let point = CGPoint(x: 60, y: 55)
            try mouse(.leftMouseDown, at: point, in: view)
            try mouse(.leftMouseUp, at: point, in: view)
            XCTAssertEqual(controller.document.items.count, 1, "序号单击无需拖动，zoom=\(scale)")
            let serial = try XCTUnwrap(controller.document.items.first as? SerialItem)
            XCTAssertEqual(serial.bounds.midX, point.x, accuracy: 0.001)
            XCTAssertEqual(serial.bounds.midY, point.y, accuracy: 0.001)
            XCTAssertEqual(serial.index, 1)
        }
    }

    func testSerialNumberClickAtDocumentOriginDoesNotRequireMovement() throws {
        let (controller, view, window) = fixture(displayScale: 1)
        defer { window.close() }
        controller.perform(.serialNumber)
        try mouse(.leftMouseDown, at: .zero, in: view)
        XCTAssertTrue(controller.document.items.isEmpty, "鼠标按下不应提交临时序号")
        try mouse(.leftMouseUp, at: .zero, in: view)
        let serial = try XCTUnwrap(controller.document.items.first as? SerialItem)
        XCTAssertEqual(controller.document.items.count, 1)
        XCTAssertEqual(serial.bounds.midX, 0, accuracy: 0.001)
        XCTAssertEqual(serial.bounds.midY, 0, accuracy: 0.001)
    }

    func testSerialNumberDragPlacesCenterAtFinalReleasePoint() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.serialNumber)
            try mouse(.leftMouseDown, at: CGPoint(x: 40, y: 35), in: view)
            try mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 65), in: view)
            XCTAssertTrue(controller.document.items.isEmpty)
            let release = CGPoint(x: 110, y: 80)
            try mouse(.leftMouseUp, at: release, in: view)
            XCTAssertEqual(controller.document.items.count, 1)
            let serial = try XCTUnwrap(controller.document.items.first as? SerialItem)
            XCTAssertEqual(serial.bounds.midX, release.x, accuracy: 0.001, "序号应在释放点，zoom=\(scale)")
            XCTAssertEqual(serial.bounds.midY, release.y, accuracy: 0.001)
        }
    }

    func testNewStrokeDoesNotReusePreviousEndpointOrCommitOnClick() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.arrow)
            try mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view)
            try mouse(.leftMouseDragged, at: CGPoint(x: 140, y: 90), in: view)
            try mouse(.leftMouseUp, at: CGPoint(x: 140, y: 90), in: view)
            controller.clearSelection()
            let committed = try rendered(view)
            let newStart = CGPoint(x: 30, y: 130)
            try mouse(.leftMouseDown, at: newStart, in: view)
            assertPixelsEqual(try rendered(view), committed, "新一笔尚未拖动不能连到上一笔终点，zoom=\(scale)")
            try mouse(.leftMouseUp, at: newStart, in: view)
            XCTAssertEqual(controller.document.items.count, 1, "箭头单击不能提交幽灵图元")
        }
    }

    func testArrowUsesFinalMouseUpPosition() throws {
        let (controller, view, window) = fixture(displayScale: 0.5)
        defer { window.close() }
        controller.perform(.arrow)
        let start = CGPoint(x: 20, y: 20), release = CGPoint(x: 140, y: 100)
        try mouse(.leftMouseDown, at: start, in: view)
        try mouse(.leftMouseDragged, at: CGPoint(x: 90, y: 70), in: view)
        try mouse(.leftMouseUp, at: release, in: view)
        let arrow = try XCTUnwrap(controller.document.items.first as? ArrowItem)
        XCTAssertEqual(arrow.start, start)
        XCTAssertEqual(arrow.end, release, "释放点可能晚于最后一个drag事件")
    }

    func testDraftUsesLatestColorAndLineWidthWithoutChangingDocument() throws {
        let (controller, view, window) = fixture(displayScale: 1)
        defer { window.close() }
        controller.perform(.arrow)
        let start = CGPoint(x: 20, y: 20), end = CGPoint(x: 140, y: 100)
        try mouse(.leftMouseDown, at: start, in: view)
        try mouse(.leftMouseDragged, at: end, in: view)
        let original = try rendered(view)
        controller.style.color = RGBAColor(rgb: 0x00AA44)
        controller.style.lineWidth = 8
        let updated = try rendered(view)
        XCTAssertTrue(updated != original, "样式改变时预览应立即更新")
        let expected = try reference(ArrowItem(start: start, end: end, style: controller.style),
                                     view: view, controller: controller)
        assertPixelsEqual(updated, expected, "预览应使用当前颜色和线宽")
        XCTAssertTrue(controller.document.items.isEmpty)
        try mouse(.leftMouseUp, at: end, in: view)
        controller.clearSelection()
        assertPixelsEqual(try rendered(view), updated, "提交不能恢复旧样式")
    }

    func testEscapeCancelsDraftAndLaterMouseUpCannotCommitIt() throws {
        let (controller, view, window) = fixture(displayScale: 1)
        defer { window.close() }
        controller.perform(.ellipse)
        let empty = try rendered(view)
        try mouse(.leftMouseDown, at: CGPoint(x: 30, y: 25), in: view)
        let end = CGPoint(x: 150, y: 105)
        try mouse(.leftMouseDragged, at: end, in: view)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                                  isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        assertPixelsEqual(try rendered(view), empty, "Esc后草稿预览必须消失")
        try mouse(.leftMouseUp, at: end, in: view)
        XCTAssertTrue(controller.document.items.isEmpty, "取消后的迟到mouseUp不能落笔")
        XCTAssertFalse(controller.canUndo)
    }

    func testMosaicPreviewSamplesPatternedBaseImageBeforeCommit() throws {
        let (controller, view, window) = fixture(displayScale: 1, patterned: true)
        defer { window.close() }
        controller.mosaicAutoDetect = false
        controller.perform(.mosaic)
        let rect = CGRect(x: 30, y: 25, width: 120, height: 80)
        try mouse(.leftMouseDown, at: rect.origin, in: view)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        try mouse(.leftMouseDragged, at: end, in: view)
        let preview = try rendered(view)
        let prepared = MosaicItem(bounds: rect, style: controller.style)
        let expected = try reference(prepared, view: view, controller: controller)
        XCTAssertTrue(expected.contains { $0 > 20 && $0 < 230 }, "黑白图案打码后应产生平均灰色")
        assertPixelsEqual(preview, expected, "马赛克草稿必须prepare真实底图，不能只描矩形或采样空图")
        XCTAssertTrue(controller.document.items.isEmpty)
        XCTAssertFalse(controller.canUndo)
        try mouse(.leftMouseUp, at: end, in: view)
        controller.clearSelection()
        assertPixelsEqual(try rendered(view), preview, "马赛克提交不能改变预览的采样或方向")
    }

    func testRedactionInMosaicToolMatchesPrivacyMaskDuringDragAndAfterExport() throws {
        let (controller, view, window) = fixture(displayScale: 1, patterned: true)
        defer { window.close() }
        controller.mosaicAutoDetect = false
        controller.perform(.mosaic)
        let appearance = PrivacyMaskAppearance(style: .frosted)
        controller.toolOptions.mosaicMode = .redaction(appearance)
        let bounds = CGRect(x: 30, y: 25, width: 120, height: 80)
        let end = CGPoint(x: bounds.maxX, y: bounds.maxY)
        try mouse(.leftMouseDown, at: bounds.origin, in: view)
        try mouse(.leftMouseDragged, at: end, in: view)
        let preview = try rendered(view)
        let mask = PrivacyMaskItem(bounds: bounds, appearance: appearance)
        let expected = try bitmap(for: view) { context in
            let document = controller.document
            mask.prepareBackground(source: document.baseImage, scale: document.scale, excluding: [])
            mask.draw(in: context, scale: document.scale)
        }
        XCTAssertTrue(expected.contains { $0 > 0 })
        assertPixelsEqual(preview, expected, "马赛克入口的柔焦应使用同一份渲染")

        try mouse(.leftMouseUp, at: end, in: view)
        let item = try XCTUnwrap(controller.document.selectedItem as? MosaicItem)
        XCTAssertEqual(item.mode, .redaction(appearance))
        controller.clearSelection()
        assertPixelsEqual(try rendered(view), preview, "松手后的圆角羽化应与预览一致")
        let document = controller.document
        let reference = EditDocument(baseImage: document.baseImage, scale: document.scale, items: [mask])
        XCTAssertEqual(try document.render().dataProvider?.data as Data?,
                       try reference.render().dataProvider?.data as Data?)
        XCTAssertEqual(document.privacyPixelBounds, [mask.pixelBounds(scale: document.scale)])
    }

    func testPrivacyToolPreviewsMovesResizesAndChangesStyle() throws {
        let (controller, view, window) = fixture(displayScale: 0.5)
        defer { window.close() }
        controller.perform(.privacy)
        let start = CGPoint(x: 24, y: 30)
        let end = CGPoint(x: 106, y: 90)
        try mouse(.leftMouseDown, at: start, in: view)
        try mouse(.leftMouseDragged, at: end, in: view)
        XCTAssertTrue(try rendered(view).contains { $0 == 255 }, "The mask should already be opaque while dragging")
        XCTAssertTrue(controller.document.items.isEmpty)
        try mouse(.leftMouseUp, at: end, in: view)
        let mask = try XCTUnwrap(controller.document.selectedItem as? PrivacyMaskItem)
        let original = CGRect(x: 24, y: 30, width: 82, height: 60)
        XCTAssertEqual(mask.bounds, original)

        let center = CGPoint(x: original.midX, y: original.midY)
        let movedCenter = CGPoint(x: center.x + 10, y: center.y + 6)
        try mouse(.leftMouseDown, at: center, in: view)
        try mouse(.leftMouseDragged, at: movedCenter, in: view)
        try mouse(.leftMouseUp, at: movedCenter, in: view)
        XCTAssertEqual(mask.bounds, original.offsetBy(dx: 10, dy: 6))

        let corner = CGPoint(x: mask.bounds.maxX, y: mask.bounds.maxY)
        let resizedCorner = CGPoint(x: corner.x + 18, y: corner.y + 10)
        try mouse(.leftMouseDown, at: corner, in: view)
        try mouse(.leftMouseDragged, at: resizedCorner, in: view)
        try mouse(.leftMouseUp, at: resizedCorner, in: view)
        XCTAssertEqual(mask.bounds, CGRect(x: 34, y: 36, width: 100, height: 70))

        controller.updatePrivacyAppearance(.init(style: .stripes, patternSize: 14))
        XCTAssertEqual(mask.appearance.style, .stripes)
        controller.remove(mask)
        XCTAssertTrue(controller.document.items.isEmpty)
    }

    func testPolygonHoverThirdPointDrawsActualStyledEdgesAndFill() throws {
        for filled in [false, true] {
            let (controller, view, window) = fixture(displayScale: 1)
            defer { window.close() }
            controller.style.color = RGBAColor(rgb: 0x00AA44)
            controller.style.opacity = 1
            controller.style.shapeFill = filled ? .fill : .outline
            controller.perform(.polygon)
            let first = CGPoint(x: 20, y: 20), second = CGPoint(x: 140, y: 20)
            for point in [first, second] {
                try mouse(.leftMouseDown, at: point, in: view)
                try mouse(.leftMouseUp, at: point, in: view)
            }
            let beforeHover = try rendered(view)
            let third = CGPoint(x: 80, y: 110)
            view.needsDisplay = false
            try mouse(.mouseMoved, at: third, in: view)
            XCTAssertTrue(view.needsDisplay)
            let preview = try rendered(view)
            let expected = try reference(PolygonItem(points: [first, second, third], style: controller.style),
                                         view: view, controller: controller)
            // 已落点有额外提示圆点，只比较真实多边形实心像素，避免把提示标记当成图元。
            let solidPixels = stride(from: 0, to: expected.count, by: 4).filter { expected[$0 + 3] == 255 }
            XCTAssertGreaterThan(solidPixels.count, 100)
            let differences = solidPixels.filter { offset in
                (0..<4).contains { preview[offset + $0] != expected[offset + $0] }
            }.count
            XCTAssertEqual(differences, 0, "悬停第三点应画当前样式的真实多边形，filled=\(filled)")
            XCTAssertTrue(preview != beforeHover)
            XCTAssertTrue(controller.document.items.isEmpty, "hover第三点不能提交图元")
            XCTAssertFalse(controller.canUndo)
        }
    }

    func testSerialCursorIsCenteredScaledAndUpdatesWithoutTemporaryItems() throws {
        for scale in displayScales {
            let (controller, view, window) = fixture(displayScale: scale)
            defer { window.close() }
            controller.perform(.serialNumber)
            view.updateInteractionState()
            let cursor = view.annotationCursor
            XCTAssertEqual(cursor.image.size, CGSize(width: 22 * scale, height: 22 * scale))
            XCTAssertEqual(cursor.hotSpot, CGPoint(x: 11 * scale, y: 11 * scale))
            let firstImage = try XCTUnwrap(cursor.image.tiffRepresentation)
            XCTAssertTrue(controller.document.items.isEmpty)
            XCTAssertFalse(controller.canUndo)
            let point = CGPoint(x: 70, y: 60)
            try mouse(.leftMouseDown, at: point, in: view)
            try mouse(.leftMouseUp, at: point, in: view)
            view.updateInteractionState()
            let secondImage = try XCTUnwrap(view.annotationCursor.image.tiffRepresentation)
            XCTAssertTrue(firstImage != secondImage, "落下1后，鼠标应显示下一序号2")
            XCTAssertEqual(controller.document.items.count, 1)
            controller.perform(.ellipse)
            view.updateInteractionState()
            XCTAssertTrue(view.annotationCursor === NSCursor.crosshair, "换工具后不能残留序号光标")
        }
    }

    func testSerialCanBeStampedOverExistingAnnotationWithoutMovingIt() throws {
        let (controller, view, window) = fixture(displayScale: 1)
        defer { window.close() }
        controller.perform(.serialNumber)
        let point = CGPoint(x: 70, y: 60)
        for _ in 0..<2 {
            try mouse(.leftMouseDown, at: point, in: view)
            try mouse(.leftMouseUp, at: point, in: view)
        }
        let serials = controller.document.items.compactMap { $0 as? SerialItem }
        XCTAssertEqual(serials.map(\.index), [1, 2], "当前盖章工具应优先于旧图元命中")
        for serial in serials {
            XCTAssertEqual(serial.bounds.midX, point.x)
            XCTAssertEqual(serial.bounds.midY, point.y)
        }
    }
}
