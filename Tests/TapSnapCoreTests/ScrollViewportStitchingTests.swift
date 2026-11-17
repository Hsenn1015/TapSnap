import CoreGraphics
import CoreText
import XCTest
@testable import TapSnapStitching

/// 已知滚动视口与独立原页。内容的外形、密度、颜色均不用于推导视口边界。
private struct ScrollViewportFixture {
    let size: CGSize
    let viewport: CGRect
    let offsets: [Int]
    let frames: [CGImage]
    let expected: CGImage

    init(size: CGSize = CGSize(width: 480, height: 360), viewport: CGRect,
         offsets: [Int] = [0, 67, 149], dark: Bool = false, sparse: Bool = false,
         changingOutside: Bool = false, laterWideImage: Bool = false) {
        self.size = size
        self.viewport = viewport
        self.offsets = offsets
        let width = Int(size.width), height = Int(size.height)
        let pageWidth = Int(viewport.width), pageHeight = Int(viewport.height) + offsets.last!
        let pageContext = Self.context(width: pageWidth, height: pageHeight)
        Self.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
                  color: CGColor(gray: dark ? 0.1 : 1, alpha: 1), in: pageContext)
        let spacing = sparse ? 102 : 43
        for row in 0..<(pageHeight / spacing + 1) {
            let top = CGFloat(row * spacing + (row * 11) % 17)
            let inset = CGFloat(8 + (row * 17) % min(25, max(1, pageWidth / 8)))
            Self.fill(CGRect(x: inset, y: top, width: CGFloat(pageWidth) - inset - 8, height: sparse ? 42 : 32),
                      color: CGColor(gray: dark ? 0.19 : 0.96, alpha: 1), in: pageContext)
            Self.text("\(row * 7919 + 31) | \(row * row + 17)", x: inset + 4, top: top + 5,
                      color: CGColor(gray: dark ? 0.9 : 0.18, alpha: 1), in: pageContext)
            Self.fill(CGRect(x: pageWidth - 29 - row % 3 * 5, y: Int(top) + 19, width: 12, height: 9),
                      color: CGColor(red: 0.2 + Double(row % 5) * 0.12,
                                     green: 0.65 - Double(row % 4) * 0.1,
                                     blue: 0.3 + Double(row % 3) * 0.15, alpha: 1), in: pageContext)
        }
        if laterWideImage {
            let top = Int(viewport.height) + offsets[1] + 12
            for column in 0..<8 {
                Self.fill(CGRect(x: CGFloat(column) * viewport.width / 8, y: CGFloat(top),
                                 width: viewport.width / 8, height: 56),
                          color: CGColor(red: 0.15 + Double(column) * 0.08,
                                         green: 0.7 - Double(column) * 0.05,
                                         blue: 0.2 + Double(column % 3) * 0.2, alpha: 1), in: pageContext)
            }
        }
        let page = pageContext.makeImage()!
        let rendered = offsets.enumerated().map { index, offset in
            let context = Self.context(width: width, height: height)
            let state = changingOutside ? index : 0
            Self.fill(CGRect(x: 0, y: 0, width: width, height: height),
                      color: CGColor(red: 0.81 + Double(state) * 0.025,
                                     green: 0.88 - Double(state) * 0.03, blue: 0.92, alpha: 1), in: context)
            // 外部任意几何状态与窄竖条逐帧变化，不能干扰视口位移或改变首屏外部像素。
            for x in stride(from: 12, to: width, by: 53) {
                Self.fill(CGRect(x: x, y: 19 + state * 17, width: 3, height: 48 + x % 31),
                          color: CGColor(gray: 0.4 + Double(state) * 0.08, alpha: 1), in: context)
                Self.fill(CGRect(x: x, y: height - 24, width: 18, height: 7),
                          color: CGColor(gray: 0.25 + Double(state) * 0.1, alpha: 1), in: context)
            }
            let body = page.cropping(to: CGRect(x: 0, y: offset, width: pageWidth, height: Int(viewport.height)))!
            context.draw(body, in: CGRect(x: viewport.minX, y: CGFloat(height) - viewport.maxY,
                                          width: viewport.width, height: viewport.height))
            return context.makeImage()!
        }
        frames = rendered

        let outputHeight = height + offsets.last!
        let result = Self.context(width: width, height: outputHeight)
        Self.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight), color: CGColor(gray: 1, alpha: 1), in: result)
        result.draw(page, in: CGRect(x: viewport.minX, y: CGFloat(height) - viewport.maxY,
                                     width: viewport.width, height: CGFloat(pageHeight)))
        func copy(_ image: CGImage, rect: CGRect, top: CGFloat) {
            guard rect.width > 0, rect.height > 0 else { return }
            result.draw(image.cropping(to: rect)!,
                        in: CGRect(x: rect.minX, y: CGFloat(outputHeight) - top - rect.height,
                                   width: rect.width, height: rect.height))
        }
        copy(rendered[0], rect: CGRect(x: 0, y: 0, width: width, height: Int(viewport.minY)), top: 0)
        copy(rendered[0], rect: CGRect(x: 0, y: viewport.minY, width: viewport.minX, height: viewport.height),
             top: viewport.minY)
        copy(rendered[0], rect: CGRect(x: viewport.maxX, y: viewport.minY,
                                      width: size.width - viewport.maxX, height: viewport.height), top: viewport.minY)
        copy(rendered.last!, rect: CGRect(x: 0, y: viewport.maxY, width: size.width,
                                         height: size.height - viewport.maxY), top: viewport.maxY + CGFloat(offsets.last!))
        expected = result.makeImage()!
    }

    static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func fill(_ rect: CGRect, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.fill(CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY,
                            width: rect.width, height: rect.height))
    }

    static func text(_ value: String, x: CGFloat, top: CGFloat, color: CGColor, in context: CGContext) {
        let attributed = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - top - 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    static func withOverlay(_ frame: CGImage, rect: CGRect) -> CGImage {
        let context = context(width: frame.width, height: frame.height)
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        fill(rect, color: CGColor(gray: 0.95, alpha: 1), in: context)
        text("+", x: rect.minX + 15, top: rect.minY + 5,
             color: CGColor(red: 0.15, green: 0.4, blue: 0.85, alpha: 1), in: context)
        return context.makeImage()!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * context.height))
    }
}

final class ScrollViewportStitchingTests: XCTestCase {
    private func assertImage(_ actual: CGImage, equals expected: CGImage, excluding exception: CGRect? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        let a = ScrollViewportFixture.pixels(actual), b = ScrollViewportFixture.pixels(expected)
        var differences = 0
        for y in 0..<actual.height {
            for x in 0..<actual.width {
                if exception?.contains(CGPoint(x: x, y: y)) == true { continue }
                let offset = (y * actual.width + x) * 4
                if (0..<4).contains(where: { abs(Int(a[offset + $0]) - Int(b[offset + $0])) > 1 }) { differences += 1 }
            }
        }
        XCTAssertEqual(differences, 0, "结果必须来自真实输入像素和约定的视口外留白", file: file, line: line)
    }

    private func verify(_ fixture: ScrollViewportFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let stitcher = FrameStitcher(scrollingRect: fixture.viewport)
        for (index, frame) in fixture.frames.enumerated() {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.height, Int(fixture.size.height) + fixture.offsets[index], file: file, line: line)
        }
        assertImage(try stitcher.finish(), equals: fixture.expected, file: file, line: line)
    }

    func testExplicitViewportWorksAtEitherEdgeInTheCenterAndAtFullWidth() throws {
        for viewport in [CGRect(x: 0, y: 21, width: 168, height: 288),
                         CGRect(x: 312, y: 21, width: 168, height: 288),
                         CGRect(x: 167, y: 54, width: 146, height: 260),
                         CGRect(x: 0, y: 0, width: 480, height: 360)] {
            try verify(ScrollViewportFixture(viewport: viewport))
        }
    }

    func testSparseDarkViewportWithTwoPixelStartIgnoresChangingOutsideColorsAndBars() throws {
        try verify(ScrollViewportFixture(size: CGSize(width: 914, height: 621),
                   viewport: CGRect(x: 67, y: 68, width: 612, height: 489), offsets: [0, 2, 139, 283],
                   dark: true, sparse: true, changingOutside: true))
    }

    func testPartiallySelectedSystemViewportPreservesTheLaterWideImageAtTheClippedBoundary() throws {
        let fixture = ScrollViewportFixture(size: CGSize(width: 640, height: 460),
            viewport: CGRect(x: 100, y: 55, width: 430, height: 330), laterWideImage: true)
        let selection = CGRect(x: 176, y: 92, width: 420, height: 348)
        let clipped = fixture.viewport.intersection(selection).offsetBy(dx: -selection.minX, dy: -selection.minY)
        let stitcher = FrameStitcher(scrollingRect: clipped)
        for (index, frame) in fixture.frames.enumerated() {
            let result = try stitcher.append(frame.cropping(to: selection)!)
            XCTAssertEqual(result.height, Int(selection.height) + fixture.offsets[index])
        }
        let expectedRect = CGRect(x: selection.minX, y: selection.minY, width: selection.width,
                                  height: selection.height + CGFloat(fixture.offsets.last!))
        assertImage(try stitcher.finish(), equals: fixture.expected.cropping(to: expectedRect)!)
    }

    func testLocalOverlayInsideTheViewportDoesNotEraseItsEntireColumn() throws {
        let fixture = ScrollViewportFixture(viewport: CGRect(x: 64, y: 40, width: 340, height: 280),
                                            offsets: [0, 89, 178])
        let overlay = CGRect(x: fixture.viewport.maxX - 60, y: fixture.viewport.maxY - 80, width: 44, height: 24)
        let stitcher = FrameStitcher(scrollingRect: fixture.viewport)
        for frame in fixture.frames { _ = try stitcher.append(ScrollViewportFixture.withOverlay(frame, rect: overlay)) }
        // 仅末帧覆盖区从未露出；其余区域必须完整，包括该列所有真实正文。
        assertImage(try stitcher.finish(), equals: fixture.expected,
                    excluding: overlay.offsetBy(dx: 0, dy: CGFloat(fixture.offsets.last!)))
    }

    func testInvalidViewportUpdateKeepsTheOriginalImageAndPreviousConfiguration() throws {
        let fixture = ScrollViewportFixture(viewport: CGRect(x: 64, y: 40, width: 340, height: 280))
        let stitcher = FrameStitcher(scrollingRect: fixture.viewport)
        let first = try stitcher.append(fixture.frames[0])
        let invalid = [CGRect.zero, CGRect(x: -1, y: 0, width: 200, height: 200),
                       CGRect(x: 400, y: 0, width: 100, height: 200),
                       CGRect(x: 0, y: 300, width: 200, height: 100),
                       CGRect(x: 0, y: 0, width: 16, height: 100),
                       CGRect(x: 0, y: 0, width: 200, height: 32),
                       CGRect(x: CGFloat.nan, y: 0, width: 200, height: 100)]
        for rect in invalid {
            XCTAssertThrowsError(try stitcher.setScrollingRect(rect))
            assertImage(try XCTUnwrap(stitcher.currentImage), equals: first)
        }
        for frame in fixture.frames.dropFirst() { _ = try stitcher.append(frame) }
        assertImage(try stitcher.finish(), equals: fixture.expected)
    }

    func testViewportCannotBeChangedAfterGrowthAndTheCurrentCaptureCanContinue() throws {
        let fixture = ScrollViewportFixture(viewport: CGRect(x: 64, y: 40, width: 340, height: 280))
        let stitcher = FrameStitcher(scrollingRect: fixture.viewport)
        _ = try stitcher.append(fixture.frames[0])
        let accepted = try stitcher.append(fixture.frames[1])
        XCTAssertThrowsError(try stitcher.setScrollingRect(CGRect(x: 0, y: 0, width: 200, height: 200)))
        assertImage(try XCTUnwrap(stitcher.currentImage), equals: accepted)
        _ = try stitcher.append(fixture.frames[2])
        assertImage(try stitcher.finish(), equals: fixture.expected)
    }

    func testViewportCanBeConfiguredAfterTheFirstStillFrame() throws {
        let fixture = ScrollViewportFixture(viewport: CGRect(x: 64, y: 40, width: 340, height: 280))
        let stitcher = FrameStitcher()
        _ = try stitcher.append(fixture.frames[0])
        _ = try stitcher.append(fixture.frames[0])
        try stitcher.setScrollingRect(fixture.viewport)
        for frame in fixture.frames.dropFirst() { _ = try stitcher.append(frame) }
        assertImage(try stitcher.finish(), equals: fixture.expected)
    }
}
