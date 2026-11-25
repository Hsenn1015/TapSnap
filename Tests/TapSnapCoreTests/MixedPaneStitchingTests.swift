import CoreGraphics
import CoreText
import XCTest
@testable import TapSnapStitching

/// 独立构造固定侧栏、可滚动图文和最终真值，不依赖拼接器的区域判断。
private struct MixedPaneFixture {
    enum Side { case left, right }

    let width = 960
    let height = 560
    let offsets = [0, 137, 281, 429]
    let headerHeight: Int
    let footerHeight: Int
    let bodyRect: CGRect
    let fixedRect: CGRect?
    let frames: [CGImage]
    let expected: CGImage

    init(side: Side? = .left, sidebarWidth: Int = 280, separatorWidth: Int = 2,
         sameWhiteBackground: Bool = false, whiteMargins: Bool = false,
         expandsBelowFirstFrame: Bool = false, headerHeight: Int = 0, footerHeight: Int = 0) {
        let width = self.width, height = self.height, offsets = self.offsets
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        let viewportBodyHeight = height - headerHeight - footerHeight
        let fixedWidth = side == nil ? 0 : sidebarWidth + separatorWidth
        let bodyWidth = width - fixedWidth
        let bodyX = side == .left ? fixedWidth : 0
        bodyRect = CGRect(x: bodyX, y: headerHeight, width: bodyWidth, height: viewportBodyHeight)
        fixedRect = side.map { CGRect(x: $0 == .left ? 0 : bodyWidth, y: headerHeight,
                                     width: fixedWidth, height: viewportBodyHeight) }
        let page = Self.page(width: bodyWidth, height: viewportBodyHeight + offsets.last!, whiteMargins: whiteMargins,
                             expandsBelowFirstFrame: expandsBelowFirstFrame)
        let sidebar = side.map { _ in Self.sidebar(width: sidebarWidth, height: viewportBodyHeight, white: sameWhiteBackground) }

        func compose(body: CGImage, outputHeight: Int) -> CGImage {
            let context = Self.context(width: width, height: outputHeight)
            Self.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight),
                      color: CGColor(gray: 1, alpha: 1), in: context)
            context.draw(body, in: CGRect(x: bodyX, y: footerHeight, width: bodyWidth, height: body.height))
            if let sidebar, let side {
                let sidebarX = side == .left ? 0 : bodyWidth + separatorWidth
                context.draw(sidebar, in: CGRect(x: sidebarX, y: outputHeight - headerHeight - viewportBodyHeight,
                                                width: sidebarWidth, height: viewportBodyHeight))
                let separatorX = side == .left ? sidebarWidth : bodyWidth
                Self.fill(CGRect(x: separatorX, y: headerHeight, width: separatorWidth, height: viewportBodyHeight),
                          color: CGColor(gray: sameWhiteBackground ? 0.98 : 0.82, alpha: 1), in: context)
            }
            if headerHeight > 0 {
                Self.fill(CGRect(x: 0, y: 0, width: width, height: headerHeight),
                          color: CGColor(gray: 0.91, alpha: 1), in: context)
                Self.text("Fixed workspace header", x: 20, top: 12, in: context)
            }
            if footerHeight > 0 {
                Self.fill(CGRect(x: 0, y: outputHeight - footerHeight, width: width, height: footerHeight),
                          color: CGColor(gray: 0.88, alpha: 1), in: context)
                Self.text("Fixed status footer", x: 20, top: CGFloat(outputHeight - footerHeight + 9), in: context)
            }
            return context.makeImage()!
        }
        frames = offsets.map { offset in
            compose(body: page.cropping(to: CGRect(x: 0, y: offset, width: bodyWidth, height: viewportBodyHeight))!,
                    outputHeight: height)
        }
        // 固定侧栏只放在输出开头；其余区域是白底，正文原页完整保留。
        expected = compose(body: page, outputHeight: page.height + headerHeight + footerHeight)
    }

    func frameChangingSidebar(at index: Int) -> CGImage {
        let context = Self.context(width: width, height: height)
        context.draw(frames[index], in: CGRect(x: 0, y: 0, width: width, height: height))
        Self.fill(CGRect(x: fixedRect!.minX + 18, y: fixedRect!.minY + 120, width: 120, height: 24),
                  color: CGColor(red: 0.18, green: 0.42, blue: 0.8, alpha: 1), in: context)
        return context.makeImage()!
    }

    private static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func fill(_ rect: CGRect, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.fill(CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY,
                            width: rect.width, height: rect.height))
    }

    private static func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat = 12,
                             in context: CGContext) {
        let attributed = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.18, alpha: 1),
        ])
        context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - top - size)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    private static func sidebar(width: Int, height: Int, white: Bool) -> CGImage {
        let context = context(width: width, height: height)
        fill(CGRect(x: 0, y: 0, width: width, height: height),
             color: CGColor(gray: white ? 1 : 0.94, alpha: 1), in: context)
        text("Workspace", x: 20, top: 19, size: 15, in: context)
        for (index, title) in ["Inbox", "Pinned", "Documents", "Members", "Settings"].enumerated() {
            let top = CGFloat(72 + index * 98)
            fill(CGRect(x: 20, y: top, width: 12, height: 12),
                 color: CGColor(gray: 0.4, alpha: 1), in: context)
            text(title, x: 43, top: top - 1, in: context)
        }
        return context.makeImage()!
    }

    private static func page(width: Int, height: Int, whiteMargins: Bool, expandsBelowFirstFrame: Bool) -> CGImage {
        let context = context(width: width, height: height)
        fill(CGRect(x: 0, y: 0, width: width, height: height),
             color: CGColor(gray: 1, alpha: 1), in: context)
        let margin: CGFloat = whiteMargins ? 78 : 14
        for row in 0..<(height / 55 + 1) {
            let top = CGFloat(13 + row * 55 + (row * 7) % 13)
            let cardWidth = CGFloat(width) - margin * 2 - CGFloat((row * 23) % 37)
            fill(CGRect(x: margin, y: top, width: cardWidth, height: 43),
                 color: CGColor(gray: 0.97, alpha: 1), in: context)
            text("Message \(row * 7919 + 31)", x: margin + 10, top: top + 4, in: context)
            text("Details \(row * row + 317) / reply \(row + 1)",
                 x: margin + 10, top: top + 24, size: 11, in: context)
            if row % 3 == 0 {
                // 图文布局里的小缩略图随正文移动，不是固定栏。
                let imageWidth = min(110, cardWidth / 4)
                let imageX = margin + cardWidth - imageWidth - 5
                for column in 0..<4 {
                    fill(CGRect(x: imageX + CGFloat(column) * imageWidth / 4, y: top + 5,
                                width: imageWidth / 4, height: 31),
                         color: CGColor(red: 0.2 + Double((row + column) % 5) * 0.12,
                                        green: 0.36 + Double(column) * 0.12,
                                        blue: 0.65 - Double(row % 4) * 0.08, alpha: 1), in: context)
                }
            }
        }
        if expandsBelowFirstFrame {
            // 前两帧这些列都是正文白边；固定区确认后才出现宽图，必须完整保留。
            for column in 0..<8 {
                fill(CGRect(x: 4 + CGFloat(column) * CGFloat(width - 8) / 8, y: 735,
                            width: CGFloat(width - 8) / 8, height: 105),
                     color: CGColor(red: 0.15 + Double(column) * 0.08,
                                    green: 0.64 - Double(column) * 0.04,
                                    blue: 0.25 + Double(column % 3) * 0.2, alpha: 1), in: context)
            }
            text("Wide image after the first viewport", x: 14, top: 772, in: context)
        }
        return context.makeImage()!
    }

    static func repeatingCheckboxTable() -> (page: CGImage, frames: [CGImage]) {
        let width = 480, height = 320
        let context = context(width: width, height: height + 40)
        fill(CGRect(x: 0, y: 0, width: width, height: height + 40),
             color: CGColor(gray: 1, alpha: 1), in: context)
        fill(CGRect(x: 0, y: 0, width: 40, height: height + 40),
             color: CGColor(gray: 0.96, alpha: 1), in: context)
        for row in 0..<18 {
            let top = CGFloat(row * 20)
            // 每行相同的复选框随整张表格滚动；恰好滚动 20px 时视口里的这一列看似不动。
            fill(CGRect(x: 13, y: top + 5, width: 12, height: 12),
                 color: CGColor(gray: 0.3, alpha: 1), in: context)
            fill(CGRect(x: 14, y: top + 6, width: 10, height: 10),
                 color: CGColor(gray: 1, alpha: 1), in: context)
            text("Task \(row * 7919 + 31) / value \(row * row + 317)",
                 x: 54, top: top + 3, in: context)
        }
        let page = context.makeImage()!
        return (page, [0, 20, 40].map {
            page.cropping(to: CGRect(x: 0, y: $0, width: width, height: height))!
        })
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * context.height))
    }
}

final class MixedPaneStitchingTests: XCTestCase {
    private func verify(_ fixture: MixedPaneFixture, stitcher: FrameStitcher = FrameStitcher(),
                        file: StaticString = #filePath, line: UInt = #line) throws {
        if fixture.fixedRect != nil { try stitcher.setScrollingRect(fixture.bodyRect) }
        for (index, frame) in fixture.frames.enumerated() {
            if let fixed = fixture.fixedRect {
                XCTAssertEqual(MixedPaneFixture.pixels(frame.cropping(to: fixed)!),
                               MixedPaneFixture.pixels(fixture.frames[0].cropping(to: fixed)!),
                               "输入侧栏确实完全固定", file: file, line: line)
            }
            let body = frame.cropping(to: fixture.bodyRect)!
            let expectedBodyRect = fixture.bodyRect.offsetBy(dx: 0, dy: CGFloat(fixture.offsets[index]))
            XCTAssertEqual(MixedPaneFixture.pixels(body),
                           MixedPaneFixture.pixels(fixture.expected.cropping(to: expectedBodyRect)!),
                           "正文真值来自同一原页", file: file, line: line)
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.width, fixture.width, "固定区域保留一次，不裁窄输出", file: file, line: line)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index], file: file, line: line)
        }
        assertResult(try stitcher.finish(), matches: fixture, file: file, line: line)
    }

    private func assertResult(_ result: CGImage, matches fixture: MixedPaneFixture,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.width, fixture.expected.width, file: file, line: line)
        XCTAssertEqual(result.height, fixture.expected.height, file: file, line: line)
        guard result.width == fixture.expected.width, result.height == fixture.expected.height else { return }
        let actual = MixedPaneFixture.pixels(result), expected = MixedPaneFixture.pixels(fixture.expected)
        var bodyDifferences = 0, fixedTopDifferences = 0, nonWhiteBelowSidebar = 0, chromeDifferences = 0
        for y in 0..<result.height {
            for x in 0..<result.width {
                let offset = (y * result.width + x) * 4
                let differs = (0..<4).contains { abs(Int(actual[offset + $0]) - Int(expected[offset + $0])) > 1 }
                if y < fixture.headerHeight || y >= result.height - fixture.footerHeight {
                    if differs { chromeDifferences += 1 }
                } else if x >= Int(fixture.bodyRect.minX), x < Int(fixture.bodyRect.maxX) {
                    if differs { bodyDifferences += 1 }
                } else if y < fixture.height - fixture.footerHeight {
                    if differs { fixedTopDifferences += 1 }
                } else if (0..<4).contains(where: { actual[offset + $0] < 254 }) {
                    nonWhiteBelowSidebar += 1
                }
            }
        }
        XCTAssertEqual(bodyDifferences, 0, "滚动正文不能丢行、错位或被当成固定栏抹掉", file: file, line: line)
        XCTAssertEqual(fixedTopDifferences, 0, "侧栏开头必须保留第一屏原始像素", file: file, line: line)
        XCTAssertEqual(nonWhiteBelowSidebar, 0, "固定侧栏以下应留白，不能重复拉长", file: file, line: line)
        XCTAssertEqual(chromeDifferences, 0, "全宽固定头尾各保留一次且不受侧栏留白影响", file: file, line: line)
    }

    func testFixedLeftSidebarAppearsOnceBesideCompleteScrollingBody() throws {
        try verify(MixedPaneFixture(side: .left))
    }

    func testFixedRightSidebarAppearsOnceBesideCompleteScrollingBody() throws {
        try verify(MixedPaneFixture(side: .right))
    }

    func testExplicitPaneBoundaryPreservesSameWhiteBackgroundAndNarrowDivider() throws {
        for side in [MixedPaneFixture.Side.left, .right] {
            try verify(MixedPaneFixture(side: side, sidebarWidth: 240, separatorWidth: 1,
                                        sameWhiteBackground: true))
        }
    }

    func testScrollingBodyIsFoundEvenWhenFixedSidebarOccupiesMostOfTheWidth() throws {
        try verify(MixedPaneFixture(side: .left, sidebarWidth: 640))
    }

    func testResetDoesNotLeaveSidebarMaskInTheNextScrollingCapture() throws {
        let first = MixedPaneFixture(side: .right)
        let stitcher = FrameStitcher(scrollingRect: first.bodyRect)
        for frame in first.frames { _ = try stitcher.append(frame) }
        stitcher.reset()
        XCTAssertNil(stitcher.currentImage)
        try verify(MixedPaneFixture(side: nil), stitcher: stitcher)
    }

    func testFullyScrollingArticleWithWhiteMarginsAndImagesIsNotErased() throws {
        try verify(MixedPaneFixture(side: nil, whiteMargins: true))
    }

    func testLaterWideImageIsNotMistakenForTheInitialWhiteMarginBesideFixedSidebar() throws {
        try verify(MixedPaneFixture(side: .left, sidebarWidth: 240, separatorWidth: 1,
                                    sameWhiteBackground: true, whiteMargins: true,
                                    expandsBelowFirstFrame: true))
    }

    func testFixedSidebarWithFullWidthHeaderAndFooterPreservesEveryBodyRow() throws {
        try verify(MixedPaneFixture(side: .left, headerHeight: 42, footerHeight: 34))
    }

    func testLaterWideImageWithFixedHeaderAndFooterDoesNotExpandTheSidebarMask() throws {
        try verify(MixedPaneFixture(side: .left, sidebarWidth: 240, separatorWidth: 1,
                                    sameWhiteBackground: true, whiteMargins: true,
                                    expandsBelowFirstFrame: true, headerHeight: 42, footerHeight: 34))
    }

    func testStaticAndReverseFramesDoNotChangeTheResultAndScrollingCanResume() throws {
        let fixture = MixedPaneFixture(side: .right)
        let stitcher = FrameStitcher(scrollingRect: fixture.bodyRect)
        _ = try stitcher.append(fixture.frames[0])
        let accepted = try stitcher.append(fixture.frames[1])
        let pixels = MixedPaneFixture.pixels(accepted)
        let still = try stitcher.append(fixture.frames[1])
        XCTAssertEqual(still.height, accepted.height)
        XCTAssertEqual(MixedPaneFixture.pixels(still), pixels)
        XCTAssertThrowsError(try stitcher.append(fixture.frames[0])) { error in
            guard case StitchingError.reverseScroll = error else { return XCTFail("应明确拒绝逆滚：\(error)") }
        }
        XCTAssertEqual(MixedPaneFixture.pixels(try XCTUnwrap(stitcher.currentImage)), pixels)
        for frame in fixture.frames.dropFirst(2) { _ = try stitcher.append(frame) }
        assertResult(try stitcher.finish(), matches: fixture)
    }

    func testChangedOutsideContentRetainsFirstPixelsWhileTheViewportContinues() throws {
        let fixture = MixedPaneFixture(side: .left)
        let stitcher = FrameStitcher(scrollingRect: fixture.bodyRect)
        _ = try stitcher.append(fixture.frames[0])
        _ = try stitcher.append(fixture.frames[1])
        let changed = try stitcher.append(fixture.frameChangingSidebar(at: 2))
        XCTAssertEqual(changed.height, fixture.height + fixture.offsets[2])
        _ = try stitcher.append(fixture.frames[3])
        assertResult(try stitcher.finish(), matches: fixture)
    }

    func testRepeatingCheckboxColumnBelongingToScrollingTableIsNotBlanked() throws {
        let fixture = MixedPaneFixture.repeatingCheckboxTable()
        let column = CGRect(x: 0, y: 0, width: 40, height: fixture.frames[0].height)
        let firstColumn = MixedPaneFixture.pixels(fixture.frames[0].cropping(to: column)!)
        let stitcher = FrameStitcher()
        for (index, frame) in fixture.frames.enumerated() {
            XCTAssertEqual(MixedPaneFixture.pixels(frame.cropping(to: column)!), firstColumn,
                           "周期复选框在视口坐标相同，但属于滚动正文")
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.height, frame.height + index * 20)
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.width, fixture.page.width)
        XCTAssertEqual(result.height, fixture.page.height)
        guard result.width == fixture.page.width, result.height == fixture.page.height else { return }
        let actual = MixedPaneFixture.pixels(result), expected = MixedPaneFixture.pixels(fixture.page)
        let differences = stride(from: 0, to: actual.count, by: 4).filter { offset in
            (0..<4).contains { abs(Int(actual[offset + $0]) - Int(expected[offset + $0])) > 1 }
        }.count
        XCTAssertEqual(differences, 0, "每个复选框和正文都必须保留，周期相同不能作为抹白依据")
    }

    func testAutoDetectsFixedLeftSidebarWithoutExplicitScrollingRect() throws {
        let fixture = MixedPaneFixture(side: .left, sidebarWidth: 280)
        let stitcher = FrameStitcher()
        for (index, frame) in fixture.frames.enumerated() {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.width, fixture.width)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
        }
        XCTAssertTrue(stitcher.hasFixedRegions, "无需手动指定滚动区也应自动识别固定左侧栏")
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, fixture.expected.height)
        let actual = MixedPaneFixture.pixels(result), expected = MixedPaneFixture.pixels(fixture.expected)
        var bodyDiffs = 0
        for y in 0..<result.height {
            for x in Int(fixture.bodyRect.minX)..<Int(fixture.bodyRect.maxX) {
                let offset = (y * result.width + x) * 4
                if (0..<4).contains(where: { abs(Int(actual[offset + $0]) - Int(expected[offset + $0])) > 1 }) {
                    bodyDiffs += 1
                }
            }
        }
        XCTAssertEqual(bodyDiffs, 0, "自动隔离左侧栏后滚动正文应逐像素完整")
        // 固定侧栏下方应保持干净留白，不能把侧栏重复拼进长图。
        var repeatedSidebarPixels = 0
        for y in fixture.height..<result.height {
            for x in 0..<(280 - 8) {
                let offset = (y * result.width + x) * 4
                if (0..<3).contains(where: { actual[offset + $0] < 250 }) {
                    repeatedSidebarPixels += 1
                }
            }
        }
        XCTAssertEqual(repeatedSidebarPixels, 0, "固定左侧栏不应在后续帧中被重复拼接")
    }

    func testAutoDetectsFixedRightSidebarWithoutExplicitScrollingRect() throws {
        let fixture = MixedPaneFixture(side: .right, sidebarWidth: 260)
        let stitcher = FrameStitcher()
        for (index, frame) in fixture.frames.enumerated() {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
        }
        XCTAssertTrue(stitcher.hasFixedRegions)
        let result = try stitcher.finish()
        let actual = MixedPaneFixture.pixels(result), expected = MixedPaneFixture.pixels(fixture.expected)
        var bodyDiffs = 0
        for y in 0..<result.height {
            for x in 0..<Int(fixture.bodyRect.maxX) {
                let offset = (y * result.width + x) * 4
                if (0..<4).contains(where: { abs(Int(actual[offset + $0]) - Int(expected[offset + $0])) > 1 }) {
                    bodyDiffs += 1
                }
            }
        }
        XCTAssertEqual(bodyDiffs, 0)
    }

    func testAutoDetectsLargeSidebarAndFullFrameWebViewWithoutManualSelection() throws {
        let fixture = MixedPaneFixture(side: .left, sidebarWidth: 560, headerHeight: 42, footerHeight: 34)
        // 模拟 Chrome / Electron 仅暴露整屏外层 AXScrollArea 的情况
        let stitcher = FrameStitcher(scrollingRect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
        for (index, frame) in fixture.frames.enumerated() {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
        }
        XCTAssertTrue(stitcher.hasFixedRegions, "外层整屏 WebView 视口内仍应自动识别 CSS 固定侧栏")
    }

    func testFixedBottomComposerWithBlinkingCursorStitchesCleanly() throws {
        let fixture = MixedPaneFixture(side: nil, headerHeight: 44, footerHeight: 64)
        let stitcher = FrameStitcher()
        for (index, base) in fixture.frames.enumerated() {
            let ctx = CGContext(data: nil, width: fixture.width, height: fixture.height, bitsPerComponent: 8,
                                bytesPerRow: fixture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
            // 模拟底部输入框里逐帧闪烁的 2×18 光标
            if index % 2 == 0 {
                ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
                ctx.fill(CGRect(x: 180, y: 20, width: 2, height: 18))
            }
            let result = try stitcher.append(ctx.makeImage()!)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, fixture.expected.height)
    }
}
