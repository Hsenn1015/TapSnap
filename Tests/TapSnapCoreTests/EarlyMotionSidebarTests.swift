import CoreGraphics
import CoreText
import XCTest
@testable import TapSnapStitching

/// 首个有效滚动仅 2px，成员图标恰好从 hover/彩色状态恢复；不是大步滚动后的理想稳定帧。
private struct EarlyMotionSidebarFixture {
    enum InitialState { case coloredIcons, hoveredIcon, unchanged }

    let width = 914
    let height = 621
    let headerHeight = 68
    let sidebarX = 817
    let offsets = [0, 2, 139, 283]
    let frames: [CGImage]
    let expected: CGImage

    init(initialState: InitialState) {
        let width = self.width, height = self.height, headerHeight = self.headerHeight
        let sidebarX = self.sidebarX, offsets = self.offsets
        let bodyHeight = height - headerHeight
        let pageContext = Self.context(width: sidebarX, height: bodyHeight + offsets.last!)
        Self.fill(CGRect(x: 0, y: 0, width: sidebarX, height: pageContext.height), gray: 1, in: pageContext)
        for row in 0..<(pageContext.height / 47 + 1) {
            let top = CGFloat(row * 47 + row % 5)
            Self.fill(CGRect(x: 16, y: top, width: CGFloat(646 - (row * 37) % 109), height: 38),
                      gray: 0.965, in: pageContext)
            Self.text("Message \(row * 7919 + 31) / anonymous review \(row * row + 317)",
                      x: 26, top: top + 3, in: pageContext)
            Self.text("Reply \(row + 1), retain the original content.", x: 26, top: top + 21, in: pageContext)
        }
        Self.fill(CGRect(x: 0, y: 0, width: sidebarX, height: 1), gray: 0.75, in: pageContext)
        let page = pageContext.makeImage()!

        func compose(_ body: CGImage, first: Bool) -> CGImage {
            let outputHeight = headerHeight + body.height
            let context = Self.context(width: width, height: outputHeight)
            Self.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight), gray: 1, in: context)
            context.draw(body, in: CGRect(x: 0, y: 0, width: sidebarX, height: body.height))
            Self.fill(CGRect(x: sidebarX, y: headerHeight, width: 1, height: bodyHeight), gray: 0.93, in: context)
            for member in 0..<8 {
                let top = CGFloat(126 + member * 29)
                if first, initialState == .hoveredIcon, member == 3 {
                    Self.fill(CGRect(x: 828, y: top - 3, width: 24, height: 24), gray: 0.88, in: context)
                }
                let icon = CGRect(x: 832, y: top, width: 18, height: 18)
                if first, initialState == .coloredIcons {
                    context.setFillColor(CGColor(red: 0.18, green: 0.47, blue: 0.84, alpha: 1))
                    context.fill(CGRect(x: icon.minX, y: CGFloat(outputHeight) - icon.maxY,
                                        width: icon.width, height: icon.height))
                } else {
                    Self.fill(icon, gray: 0.62, in: context)
                }
                Self.text("Member \(member + 1)", x: 853, top: top + 2, in: context)
            }
            Self.fill(CGRect(x: 0, y: 0, width: width, height: headerHeight), gray: 0.94, in: context)
            Self.text("Anonymous conversation", x: 20, top: 24, in: context)
            return context.makeImage()!
        }
        frames = offsets.enumerated().map { index, offset in
            compose(page.cropping(to: CGRect(x: 0, y: offset, width: sidebarX, height: bodyHeight))!,
                    first: index == 0)
        }
        // 真值以第一屏完整成员栏为准；其下留白，正文来自独立原页。
        expected = compose(page, first: true)
    }

    private static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func fill(_ rect: CGRect, gray: CGFloat, in context: CGContext) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY,
                            width: rect.width, height: rect.height))
    }

    private static func text(_ value: String, x: CGFloat, top: CGFloat, in context: CGContext) {
        let attributed = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.25, alpha: 1),
        ])
        context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - top - 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * context.height))
    }

    static func differences(_ actual: CGImage, _ expected: CGImage, in rect: CGRect) -> Int {
        let a = pixels(actual.cropping(to: rect)!), b = pixels(expected.cropping(to: rect)!)
        return stride(from: 0, to: a.count, by: 4).filter { offset in
            (0..<4).contains { abs(Int(a[offset + $0]) - Int(b[offset + $0])) > 1 }
        }.count
    }
}

final class EarlyMotionSidebarTests: XCTestCase {
    private func verify(_ state: EarlyMotionSidebarFixture.InitialState,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = EarlyMotionSidebarFixture(initialState: state)
        XCTAssertEqual(fixture.offsets[1], 2, "首段必须复现真实日志中的 2px", file: file, line: line)
        let viewport = CGRect(x: 0, y: fixture.headerHeight, width: fixture.sidebarX,
                              height: fixture.height - fixture.headerHeight)
        let stitcher = FrameStitcher(scrollingRect: viewport)
        for (index, frame) in fixture.frames.enumerated() {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.width, fixture.width, file: file, line: line)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index], file: file, line: line)
        }
        let result = try stitcher.finish()
        guard result.width == fixture.expected.width, result.height == fixture.expected.height else { return }
        XCTAssertEqual(EarlyMotionSidebarFixture.differences(result, fixture.expected,
            in: CGRect(x: 0, y: 0, width: fixture.sidebarX, height: result.height)), 0,
                       "首段极小位移后，完整正文与头栏仍应逐像素保留", file: file, line: line)
        XCTAssertEqual(EarlyMotionSidebarFixture.differences(result, fixture.expected,
            in: CGRect(x: fixture.sidebarX, y: 0, width: fixture.width - fixture.sidebarX, height: result.height)), 0,
                       "指定视口外分区无论如何变色，首屏像素应完整保留一次，其下留白", file: file, line: line)
    }

    func testTwoPixelInitialScrollWithOutsideColorChangeRetainsTheFirstPartition() throws {
        try verify(.coloredIcons)
    }

    func testTwoPixelInitialScrollWhileOutsideHoverDisappearsRetainsTheFirstPartition() throws {
        try verify(.hoveredIcon)
    }
}
