import CoreGraphics
import TapSnapCore
import XCTest
@testable import TapSnapApp

final class EditRenderTests: XCTestCase {
    private func solid(width: Int, height: Int, top: (UInt8, UInt8, UInt8), bottom: (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let color = y < height / 2 ? top : bottom
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = color.0; bytes[i+1] = color.1; bytes[i+2] = color.2; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (Int(buf[i]), Int(buf[i+1]), Int(buf[i+2]))
    }

    func testRenderKeepsImageUpright() throws {
        let base = solid(width: 40, height: 40, top: (255, 0, 0), bottom: (0, 0, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        let rendered = try document.render()
        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(rendered.height, 40)

        let top = pixel(rendered, x: 20, y: 2)
        let bottom = pixel(rendered, x: 20, y: 37)
        XCTAssertGreaterThan(top.0, 200, "顶部应该还是红色（没被上下翻转）")
        XCTAssertLessThan(top.2, 60)
        XCTAssertGreaterThan(bottom.2, 200, "底部应该还是蓝色")
        XCTAssertLessThan(bottom.0, 60)
    }

    func testRectangleAnnotationIsDrawn() throws {
        let base = solid(width: 40, height: 40, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        var style = EditItemStyle()
        style.color = RGBAColor(rgb: 0x00FF00)
        style.shapeFill = .fill
        document.append(ShapeItem(
            kind: .rectangle,
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
            style: style
        ))

        let rendered = try document.render()
        let inside = pixel(rendered, x: 20, y: 20)
        let outside = pixel(rendered, x: 2, y: 2)
        XCTAssertGreaterThan(inside.1, 200, "标注区域内应该是绿色")
        XCTAssertLessThan(inside.0, 60)
        XCTAssertGreaterThan(outside.0, 200, "标注区域外应该还是白色")
    }

    func testHandDrawnFillKeepsEachTextureInsideTheShapeInExport() throws {
        let base = solid(width: 120, height: 100, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base)
        var style = EditItemStyle(color: .black, lineWidth: 3)
        style.strokeStyle = .handDrawn
        style.shapeFill = .fill
        let ellipse = ShapeItem(kind: .ellipse, bounds: CGRect(x: 20, y: 20, width: 80, height: 60), style: style)
        document.append(ellipse)

        func inkCount(_ fill: EditItemStyle.HandDrawnFill) throws -> Int {
            ellipse.style.handDrawnFill = fill
            let result = try document.render()
            XCTAssertGreaterThan(pixel(result, x: 23, y: 23).0, 250, "椭圆之外应留白")
            return (32..<88).filter { pixel(result, x: $0, y: 48).0 < 225 }.count
        }

        let hachure = try inkCount(.hachure)
        let crossHatch = try inkCount(.crossHatch)
        XCTAssertGreaterThan(hachure, 0, "斜线应在填充区域内留下笔迹")
        XCTAssertGreaterThan(crossHatch, hachure, "交叉线应有两个方向的笔迹")
        XCTAssertLessThan(crossHatch, 56, "交叉线之间应透出底图")
        XCTAssertEqual(try inkCount(.solid), 56, "纯色应连续填满内部")

        let patterns = EditItemStyle.HandDrawnFill.allCases
        let textures = try patterns.map { pattern in
            ellipse.style.handDrawnFill = pattern
            let image = try document.render()
            XCTAssertGreaterThan(pixel(image, x: 23, y: 23).0, 250, "每种纹理都应该限制在形状内")
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        XCTAssertEqual(Set(textures).count, patterns.count, "每种填充应有不同的纹理")
    }

    func testHandDrawnRoughnessProducesDistinctRepeatableStrokes() throws {
        let base = solid(width: 180, height: 80, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base)
        var style = EditItemStyle(color: .black, lineWidth: 3)
        style.strokeStyle = .handDrawn
        let line = LineItem(start: CGPoint(x: 20, y: 40), end: CGPoint(x: 160, y: 40), style: style)
        document.append(line)

        func renderedBytes(_ roughness: EditItemStyle.HandDrawnRoughness) throws -> Data {
            line.style.handDrawnRoughness = roughness
            return try XCTUnwrap(document.render().dataProvider?.data) as Data
        }

        let subtle = try renderedBytes(.subtle)
        let natural = try renderedBytes(.natural)
        let pronounced = try renderedBytes(.pronounced)
        let expressive = try renderedBytes(.expressive)
        XCTAssertEqual(Set([subtle, natural, pronounced, expressive]).count, 4)
        XCTAssertEqual(try renderedBytes(.natural), natural)
    }

    func testHandDrawnPensIncreaseCoverageAndPreserveOpacity() throws {
        let base = solid(width: 180, height: 80, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base)
        var style = EditItemStyle(color: .black, lineWidth: 3, opacity: 0.5)
        style.strokeStyle = .handDrawn
        let line = LineItem(start: CGPoint(x: 20, y: 40), end: CGPoint(x: 160, y: 40), style: style)
        document.append(line)

        func darkness(_ pen: EditItemStyle.HandDrawnPen) throws -> Int {
            line.style.handDrawnPen = pen
            let image = try document.render()
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            let red = (0..<image.height).flatMap { y in
                (0..<image.width).map { x in pixels[y * image.bytesPerRow + x * 4] }
            }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(red.min()), 126, "复描不能改变设置的不透明度")
            return red.reduce(0) { $0 + 255 - Int($1) }
        }

        let single = try darkness(.single)
        let sketch = try darkness(.sketch)
        let ink = try darkness(.ink)
        XCTAssertGreaterThan(single, 0)
        XCTAssertGreaterThan(sketch, single)
        XCTAssertGreaterThan(ink, sketch)
    }

    func testCropRectShrinksOutput() throws {
        let base = solid(width: 40, height: 40, top: (255, 0, 0), bottom: (0, 0, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        document.cropRect = CGRect(x: 0, y: 20, width: 40, height: 20)

        let rendered = try document.render()
        XCTAssertEqual(rendered.height, 20)
        let first = pixel(rendered, x: 20, y: 0)
        XCTAssertGreaterThan(first.2, 200, "裁的是下半部分，应该是蓝色")
    }

    func testArrowDrawsInkAlongLine() throws {
        let base = solid(width: 60, height: 40, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        var style = EditItemStyle()
        style.color = RGBAColor(rgb: 0xFF0000)
        style.lineWidth = 3
        document.append(ArrowItem(
            start: CGPoint(x: 5, y: 20),
            end: CGPoint(x: 55, y: 20),
            style: style
        ))

        let rendered = try document.render()
        let onLine = pixel(rendered, x: 20, y: 20)
        XCTAssertGreaterThan(onLine.0, 150, "箭杆经过的地方应该是红色")
        XCTAssertLessThan(onLine.1, 120)
    }

    func testDashedAndDottedLinesLeaveGapsAndSolidLineStaysContinuous() throws {
        let base = solid(width: 160, height: 60, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base)
        var style = EditItemStyle(color: .black, lineWidth: 4)
        let lines: [(EditItemStyle.StrokePattern, CGFloat)] = [(.dashed, 10), (.dotted, 30), (.solid, 50)]
        for (pattern, y) in lines {
            style.strokePattern = pattern
            document.append(LineItem(start: CGPoint(x: 10, y: y), end: CGPoint(x: 150, y: y), style: style))
        }
        let image = try document.render()
        func inkCount(y: Int) -> Int { (20..<140).filter { pixel(image, x: $0, y: y).0 < 120 }.count }
        XCTAssertEqual(inkCount(y: 50), 120)
        XCTAssertTrue((20..<100).contains(inkCount(y: 10)))
        XCTAssertTrue((20..<100).contains(inkCount(y: 30)))
        XCTAssertLessThan(inkCount(y: 30), inkCount(y: 10))
    }

    func testRoundedShapeCombinesSeparateStrokeAndTranslucentFill() throws {
        let base = solid(width: 100, height: 90, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base)
        var style = EditItemStyle(color: RGBAColor(rgb: 0x0000FF), lineWidth: 4)
        style.shapeFill = .fillAndOutline
        style.fillColor = RGBAColor(rgb: 0x00FF00, alpha: 0.5)
        style.cornerRadius = 16
        document.append(ShapeItem(kind: .rectangle, bounds: CGRect(x: 20, y: 20, width: 60, height: 50), style: style))

        let image = try document.render()
        let fill = pixel(image, x: 50, y: 45)
        XCTAssertTrue((110...145).contains(fill.0))
        XCTAssertGreaterThan(fill.1, 245)
        let stroke = pixel(image, x: 50, y: 20)
        XCTAssertLessThan(stroke.1, 100)
        XCTAssertGreaterThan(stroke.2, 245)
        XCTAssertGreaterThan(pixel(image, x: 21, y: 21).0, 245)
    }

    func testTextAnnotationRendersUprightInk() throws {
        let base = solid(width: 80, height: 40, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        var style = EditItemStyle()
        style.color = RGBAColor(rgb: 0x000000)
        style.fontSize = 24
        let text = TextItem(text: "Hi", bounds: CGRect(x: 5, y: 5, width: 70, height: 30), style: style)
        document.append(text)

        let rendered = try document.render()
        var darkPixels = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                let p = pixel(rendered, x: x, y: y)
                if p.0 < 100 && p.1 < 100 && p.2 < 100 { darkPixels += 1 }
            }
        }
        XCTAssertGreaterThan(darkPixels, 30, "文字应该真的画出了墨迹")
        XCTAssertLessThan(darkPixels, rendered.width * rendered.height, "文字不应该铺满整张图（说明没画成整块）")
    }

    func testMosaicChangesOnlyItsRegion() throws {
        // 底图左半黑右半白，马赛克盖在交界处。
        var bytes = [UInt8](repeating: 0, count: 40 * 40 * 4)
        for y in 0..<40 {
            for x in 0..<40 {
                let value: UInt8 = x < 20 ? 0 : 255
                let i = (y * 40 + x) * 4
                bytes[i] = value; bytes[i+1] = value; bytes[i+2] = value; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: 40, height: 40, bitsPerComponent: 8,
                            bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let base = ctx.makeImage()!

        let document = EditDocument(baseImage: base, scale: 1)
        document.append(MosaicItem(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), blockSize: 6))

        let rendered = try document.render()
        // 马赛克里会出现介于纯黑纯白之间的灰度（块的平均色）。
        var grayInside = false
        for y in 10..<30 {
            for x in 10..<30 {
                let p = pixel(rendered, x: x, y: y)
                if p.0 > 60 && p.0 < 200 { grayInside = true }
            }
        }
        XCTAssertTrue(grayInside, "马赛克区域里应该出现混合色")

        let far = pixel(rendered, x: 2, y: 2)
        XCTAssertLessThan(far.0, 60, "马赛克区域外的黑边不该被动过")
    }

    func testPolygonRenders() throws {
        let base = solid(width: 60, height: 60, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        var style = EditItemStyle()
        style.color = RGBAColor(rgb: 0x00FF00)
        style.shapeFill = .fill
        document.append(PolygonItem(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 30, y: 50)],
            style: style
        ))

        let rendered = try document.render()
        let inside = pixel(rendered, x: 30, y: 25)
        let outside = pixel(rendered, x: 5, y: 55)
        XCTAssertGreaterThan(inside.1, 200, "多边形内部应该是绿色")
        XCTAssertLessThan(inside.0, 60)
        XCTAssertGreaterThan(outside.0, 200, "多边形外面应该还是白色")
    }

    func testSpotlightDarkensOutsideOnly() throws {
        let base = solid(width: 60, height: 60, top: (255, 255, 255), bottom: (255, 255, 255))
        let document = EditDocument(baseImage: base, scale: 1)
        document.append(SpotlightItem(bounds: CGRect(x: 20, y: 20, width: 20, height: 20)))

        let rendered = try document.render()
        let center = pixel(rendered, x: 30, y: 30)
        let corner = pixel(rendered, x: 2, y: 2)
        XCTAssertGreaterThan(center.0, 200, "聚光灯里应该保持原样")
        XCTAssertLessThan(corner.0, 180, "聚光灯外应该被压暗")
    }

    func testRotateSwapsDimensions() throws {
        // 左上角一块红，其余蓝。
        var bytes = [UInt8](repeating: 0, count: 40 * 20 * 4)
        for y in 0..<20 {
            for x in 0..<40 {
                let i = (y * 40 + x) * 4
                let isRed = x < 20 && y < 10
                bytes[i] = isRed ? 255 : 0
                bytes[i + 1] = 0
                bytes[i + 2] = isRed ? 0 : 255
                bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: 40, height: 20, bitsPerComponent: 8,
                            bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!

        let rotated = try XCTUnwrap(image.rotated(clockwise: true))
        XCTAssertEqual(rotated.width, 20)
        XCTAssertEqual(rotated.height, 40)

        // 四分之一像素仍是红的
        var red = 0
        for y in 0..<rotated.height {
            for x in 0..<rotated.width {
                let p = pixel(rotated, x: x, y: y)
                if p.0 > 200 && p.2 < 60 { red += 1 }
            }
        }
        XCTAssertEqual(red, 20 * 10)
    }

    func testFlipMirrorsContent() throws {
        var bytes = [UInt8](repeating: 0, count: 20 * 10 * 4)
        for y in 0..<10 {
            for x in 0..<20 {
                let i = (y * 20 + x) * 4
                let isRed = x < 10
                bytes[i] = isRed ? 255 : 0
                bytes[i + 1] = 0
                bytes[i + 2] = isRed ? 0 : 255
                bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: 20, height: 10, bitsPerComponent: 8,
                            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!

        let flipped = try XCTUnwrap(image.flipped(horizontally: true))
        XCTAssertEqual(flipped.width, 20)
        let left = pixel(flipped, x: 0, y: 5)
        XCTAssertGreaterThan(left.2, 200, "水平翻转后左边应该变成原来的右边（蓝色）")
    }
}
