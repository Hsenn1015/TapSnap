import CoreGraphics
import CoreText
import XCTest
@testable import TapSnapStitching

/// 长截图拼帧的回归测试。
///
/// 用一张「每行灰度都不同」的竖直渐变长页当作网页，模拟滚动取帧，
/// 断言位移估计和拼接结果 —— 这是整套逻辑里最容易悄悄算错的部分。
final class StitchingTests: XCTestCase {
    private let pageWidth = 200
    private let pageHeight = 600

    /// 一张「每行每列纹理都不同」的长页。
    ///
    /// 不能用线性渐变：NCC 对亮度线性变换不敏感，渐变平移任意距离相关系数都是 1，
    /// 天然不可辨识。这里用确定性伪随机填充，保证匹配有唯一峰。
    private func makePage(width: Int = 200, height: Int = 600) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x9E37_79B9
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = UInt8(truncatingIfNeeded: state >> 24)
            bytes[index] = value
            bytes[index + 1] = value
            bytes[index + 2] = value
            bytes[index + 3] = 255
        }
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// 纯线性渐变：任何位移都能"匹配"，必须被判为不可信。
    private func makeGradient() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: pageWidth * pageHeight * 4)
        for y in 0..<pageHeight {
            let value = UInt8((y * 255) / max(1, pageHeight - 1))
            for x in 0..<pageWidth {
                let index = (y * pageWidth + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = 255
            }
        }
        let context = CGContext(
            data: &bytes,
            width: pageWidth,
            height: pageHeight,
            bitsPerComponent: 8,
            bytesPerRow: pageWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func frame(_ page: CGImage, top: Int, height: Int) -> CGImage {
        page.cropping(to: CGRect(x: 0, y: top, width: page.width, height: height))!
    }

    /// 两张图逐像素的平均绝对差（0-255）。
    private func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        func bytes(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height)
            let context = CGContext(
                data: &buffer,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer
        }
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return 255 }
        let a = bytes(lhs)
        let b = bytes(rhs)
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(max(1, a.count))
    }

    func testDetectsScrollDisplacement() throws {
        let page = makePage()
        let first = frame(page, top: 0, height: 300)
        let second = frame(page, top: 100, height: 300)

        let estimate = try DisplacementEstimator().estimate(previous: first, next: second)

        XCTAssertEqual(Double(estimate.dy), 100, accuracy: 2)
        XCTAssertGreaterThan(estimate.confidence, 0.6)
    }

    func testAppendGrowsByShiftAndKeepsContent() throws {
        let page = makePage()
        let first = frame(page, top: 0, height: 300)
        let second = frame(page, top: 100, height: 300)

        let stitcher = FrameStitcher()
        _ = try stitcher.append(first)
        let stitched = try stitcher.append(second)

        XCTAssertEqual(stitched.height, 400)

        // 拼出来的应该就是原页面的前 400 行。
        let expected = frame(page, top: 0, height: 400)
        XCTAssertLessThan(meanAbsoluteDifference(stitched, expected), 3)
    }

    func testUnchangedFrameDoesNotGrow() throws {
        let page = makePage()
        let first = frame(page, top: 0, height: 300)

        let stitcher = FrameStitcher()
        _ = try stitcher.append(first)
        let stitched = try stitcher.append(first)

        XCTAssertEqual(stitched.height, 300)
    }

    func testFlatGradientIsRejectedAsAmbiguous() {
        let page = makeGradient()
        let first = frame(page, top: 0, height: 300)
        let second = frame(page, top: 100, height: 300)

        // 渐变里每个位移的相关系数都是 1，唯一的正确答案无从判断，
        // 这里要求它老实返回低置信度，而不是瞎猜一个位移。
        let estimate = try? DisplacementEstimator().estimate(previous: first, next: second)
        if let estimate {
            XCTAssertLessThan(estimate.confidence, 0.6, "重复/无纹理内容不该给出高置信度")
        }
    }

    func testFourFramesHaveNoDuplicatedOrMissingRows() throws {
        let page = makePage()
        let stitcher = FrameStitcher()
        for top in [0, 100, 200, 300] {
            let result = try stitcher.append(frame(page, top: top, height: 300))
            XCTAssertEqual(result.height, top + 300)
            XCTAssertLessThan(meanAbsoluteDifference(result, frame(page, top: 0, height: top + 300)), 3)
        }
    }

    func testRetinaWidthKeepsExactPixelDisplacement() throws {
        let page = makePage(width: 1300, height: 1500)
        let stitcher = FrameStitcher()
        _ = try stitcher.append(frame(page, top: 0, height: 800))
        let result = try stitcher.append(frame(page, top: 137, height: 800))
        XCTAssertEqual(result.height, 937)
        XCTAssertLessThan(meanAbsoluteDifference(result, frame(page, top: 0, height: 937)), 3)
    }

    func testStationaryBlankFrameIsNotAnError() throws {
        let context = CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let blank = context.makeImage()!
        let stitcher = FrameStitcher()
        _ = try stitcher.append(blank)
        XCTAssertEqual(try stitcher.append(blank).height, 300)
    }

    func testReverseScrollPreservesImageAndCanResume() throws {
        let page = makePage()
        let stitcher = FrameStitcher()
        _ = try stitcher.append(frame(page, top: 0, height: 300))
        _ = try stitcher.append(frame(page, top: 100, height: 300))
        XCTAssertThrowsError(try stitcher.append(frame(page, top: 40, height: 300)))
        XCTAssertEqual(stitcher.currentImage?.height, 400)
        let result = try stitcher.append(frame(page, top: 200, height: 300))
        XCTAssertEqual(result.height, 500)
        XCTAssertLessThan(meanAbsoluteDifference(result, frame(page, top: 0, height: 500)), 3)
    }

    private func withFixedBars(_ body: CGImage, header: Int = 35, footer: Int = 55) -> CGImage {
        let height = body.height + header + footer
        let context = CGContext(data: nil, width: body.width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: body.width, height: height))
        context.draw(body, in: CGRect(x: 0, y: footer, width: body.width, height: body.height))
        return context.makeImage()!
    }

    func testFixedHeaderAndFooterAppearOnlyOnce() throws {
        let page = makePage()
        let stitcher = FrameStitcher()
        for top in [0, 80, 160] {
            let result = try stitcher.append(withFixedBars(frame(page, top: top, height: 210)))
            let expected = withFixedBars(frame(page, top: 0, height: 210 + top))
            XCTAssertEqual(result.height, expected.height)
            XCTAssertLessThan(meanAbsoluteDifference(result, expected), 3)
        }
    }

    private func makeTextPage(repeated: Bool = false) -> CGImage {
        let width = 1300, height = 1900
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 18, nil)
        for row in 0..<60 {
            let text = repeated ? "Repeated list entry" : "Record \(row * 7919) - scroll capture text, amount \(row * row + 317)"
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 90, y: height - 30 - row * 30)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }

    func testSparseTextAtRetinaWidthKeepsEveryRow() throws {
        let page = makeTextPage()
        let stitcher = FrameStitcher()
        for top in [0, 137, 281, 429] {
            let result = try stitcher.append(frame(page, top: top, height: 800))
            XCTAssertEqual(result.height, top + 800)
            XCTAssertLessThan(meanAbsoluteDifference(result, frame(page, top: 0, height: top + 800)), 1)
        }
    }

    func testRepeatedTextDoesNotProduceAnInventedShift() throws {
        let page = makeTextPage(repeated: true)
        let stitcher = FrameStitcher()
        _ = try stitcher.append(frame(page, top: 40, height: 800))
        XCTAssertThrowsError(try stitcher.append(frame(page, top: 177, height: 800)))
        XCTAssertEqual(stitcher.currentImage?.height, 800)
    }

    func testSmallScrollsAreNotLostAtTheEnd() throws {
        let page = makePage()
        let stitcher = FrameStitcher()
        for top in [0, 1, 4, 7] {
            let result = try stitcher.append(frame(page, top: top, height: 300))
            XCTAssertEqual(result.height, 300 + top)
        }
    }

    func testFrameSizeChangePreservesLastGoodImage() throws {
        let page = makePage()
        let stitcher = FrameStitcher()
        _ = try stitcher.append(frame(page, top: 0, height: 300))
        XCTAssertThrowsError(try stitcher.append(frame(page, top: 100, height: 299)))
        XCTAssertEqual(stitcher.currentImage?.height, 300)
        XCTAssertEqual(try stitcher.append(frame(page, top: 100, height: 300)).height, 400)
    }
}
