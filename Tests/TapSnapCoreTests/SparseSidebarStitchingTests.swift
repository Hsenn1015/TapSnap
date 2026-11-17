import CoreGraphics
import CoreText
import XCTest
@testable import TapSnapStitching

/// 接近窄选区聊天窗口的几何比例；文字与成员名均为合成数据。
private struct SparseSidebarFixture {
    let width = 914
    let height = 800
    let offsets = [0, 137, 281]
    let fixedRect = CGRect(x: 814, y: 0, width: 100, height: 800)
    var scrollingRect: CGRect { CGRect(x: 0, y: 0, width: fixedRect.minX, height: CGFloat(height)) }
    let frames: [CGImage]
    let expected: CGImage

    init(scrollbarTops: [Int?] = [nil, nil, nil]) {
        let width = self.width, height = self.height, offsets = self.offsets
        let body = Self.page(width: 814, height: height + offsets.last!)
        let sidebar = Self.context(width: 100, height: height)
        Self.fill(CGRect(x: 0, y: 0, width: 100, height: height), gray: 1, in: sidebar)
        // 左侧 10px 是聊天滚动条 gutter；此例不画 thumb，单独证明侧栏识别。
        Self.fill(CGRect(x: 10, y: 0, width: 1, height: height), gray: 0.94, in: sidebar)
        for member in 0..<8 {
            let top = CGFloat(126 + member * 29)
            Self.fill(CGRect(x: 24, y: top, width: 16, height: 16),
                      gray: 0.64 + Double(member % 3) * 0.08, in: sidebar)
            // 名称超出当前选区右边缘，只保留部分文字。
            Self.text("Member \(member + 1)", x: 49, top: top + 1, in: sidebar)
        }
        let sidebarImage = sidebar.makeImage()!
        func compose(_ body: CGImage, height outputHeight: Int, thumbTop: Int?) -> CGImage {
            let context = Self.context(width: width, height: outputHeight)
            Self.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight), gray: 1, in: context)
            context.draw(body, in: CGRect(x: 0, y: 0, width: body.width, height: body.height))
            context.draw(sidebarImage, in: CGRect(x: 814, y: outputHeight - height, width: 100, height: height))
            if let thumbTop {
                Self.fill(CGRect(x: 817, y: thumbTop, width: 3, height: 90), gray: 0.76, in: context)
            }
            return context.makeImage()!
        }
        frames = offsets.enumerated().map { index, offset in
            compose(body.cropping(to: CGRect(x: 0, y: offset, width: 814, height: height))!,
                    height: height, thumbTop: scrollbarTops[index])
        }
        expected = compose(body, height: body.height, thumbTop: scrollbarTops[0])
    }

    static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func fill(_ rect: CGRect, gray: CGFloat, in context: CGContext) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY,
                            width: rect.width, height: rect.height))
    }

    static func text(_ value: String, x: CGFloat, top: CGFloat, in context: CGContext) {
        let attributed = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.25, alpha: 1),
        ])
        context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - top - 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    static func page(width: Int, height: Int, wideImage: Bool = false, grayMargin: Bool = false) -> CGImage {
        let context = context(width: width, height: height)
        fill(CGRect(x: 0, y: 0, width: width, height: height), gray: 1, in: context)
        if grayMargin {
            fill(CGRect(x: width - 90, y: 0, width: 90, height: height), gray: 0.985, in: context)
            fill(CGRect(x: width - 91, y: 0, width: 1, height: height), gray: 0.94, in: context)
        }
        for row in 0..<(height / 53 + 1) {
            let top = CGFloat(9 + row * 53 + row % 7)
            let cardWidth = CGFloat(width - 140 - (row * 37) % 86)
            fill(CGRect(x: 20, y: top, width: cardWidth, height: 39), gray: 0.965, in: context)
            text("Message \(row * 7919 + 31) / review \(row * row + 317)", x: 30, top: top + 3, in: context)
            text("Reply \(row + 1), preserve all original text and images.", x: 30, top: top + 21, in: context)
        }
        if wideImage {
            // 前两帧末端分别为 800/937，第三帧才出现延伸到右边的真实图像。
            for column in 0..<8 {
                fill(CGRect(x: 800 + column * 13, y: 950, width: 13, height: 100),
                     gray: 0.22 + CGFloat(column) * 0.065, in: context)
            }
        }
        return context.makeImage()!
    }

    static func floatingButtons(on frame: CGImage) -> CGImage {
        let context = context(width: frame.width, height: frame.height)
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        for top in [56, 714] {
            fill(CGRect(x: 851, y: top, width: 57, height: 31), gray: 0.94, in: context)
            text("More", x: 860, top: CGFloat(top + 8), in: context)
        }
        return context.makeImage()!
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

final class SparseSidebarStitchingTests: XCTestCase {
    func testNarrowPartiallySelectedMemberSidebarAppearsOnlyOnce() throws {
        let fixture = SparseSidebarFixture()
        let stitcher = FrameStitcher(scrollingRect: fixture.scrollingRect)
        let fixedPixels = SparseSidebarFixture.pixels(fixture.frames[0].cropping(to: fixture.fixedRect)!)
        for (index, frame) in fixture.frames.enumerated() {
            XCTAssertEqual(SparseSidebarFixture.pixels(frame.cropping(to: fixture.fixedRect)!), fixedPixels)
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.width, fixture.width)
        XCTAssertEqual(result.height, fixture.expected.height)
        guard result.width == fixture.expected.width, result.height == fixture.expected.height else { return }
        XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected,
            in: CGRect(x: 0, y: 0, width: 814, height: result.height)), 0, "聊天正文必须完整")
        XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected, in: fixture.fixedRect), 0,
                       "稀疏成员和滚动条只保留首屏，不能在开头区域重复或移位")
        XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected,
            in: CGRect(x: 814, y: 800, width: 100, height: result.height - 800)), 0,
                       "固定成员栏以下必须留白，包括浅色分隔线")
    }

    func testTopAndBottomFloatingButtonsDoNotBlankTheirEntireColumn() throws {
        let page = SparseSidebarFixture.page(width: 914, height: 1081, wideImage: true)
        let stitcher = FrameStitcher()
        for offset in [0, 137, 281] {
            let frame = page.cropping(to: CGRect(x: 0, y: offset, width: 914, height: 800))!
            _ = try stitcher.append(SparseSidebarFixture.floatingButtons(on: frame))
            XCTAssertFalse(stitcher.hasFixedRegions, "局部上下按钮不能证明整列都是固定侧栏")
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, page.height)
        guard result.height == page.height else { return }
        // 该片宽图不被任何输入帧按钮遮挡，必须逐像素保留；末帧按钮遮挡区不要求凭空恢复。
        XCTAssertEqual(SparseSidebarFixture.differences(result, page,
            in: CGRect(x: 840, y: 950, width: 64, height: 35)), 0)
        XCTAssertEqual(SparseSidebarFixture.differences(result, page,
            in: CGRect(x: 0, y: 0, width: 800, height: page.height)), 0)
    }

    func testMovingOrFadingScrollbarBesideMemberSidebarIsKeptOnlyAtTheStart() throws {
        for positions: [Int?] in [[220, 260, 300], [220, nil, 300]] {
            let fixture = SparseSidebarFixture(scrollbarTops: positions)
            let stitcher = FrameStitcher(scrollingRect: fixture.scrollingRect)
            for (index, frame) in fixture.frames.enumerated() {
                let result = try stitcher.append(frame)
                XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
            }
            let result = try stitcher.finish()
            XCTAssertEqual(result.height, fixture.expected.height)
            guard result.height == fixture.expected.height else { continue }
            XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected,
                in: CGRect(x: 0, y: 0, width: 814, height: result.height)), 0,
                           "滚动条 gutter 左侧的正文必须逐像素完整")
            XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected,
                in: CGRect(x: 814, y: 0, width: 100, height: result.height)), 0,
                           "侧栏旁移动或淡出的滚动条只保留第一帧，不重复成多个 thumb")
            let acceptedPixels = SparseSidebarFixture.pixels(result)
            let changed = SparseSidebarFixture.context(width: fixture.width, height: fixture.height)
            changed.draw(fixture.frames[2], in: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
            SparseSidebarFixture.fill(CGRect(x: 814, y: 0, width: 10, height: 800), gray: 1, in: changed)
            SparseSidebarFixture.fill(CGRect(x: 814, y: 400, width: 10, height: 28), gray: 0.3, in: changed)
            let unchanged = try stitcher.append(changed.makeImage()!)
            XCTAssertEqual(unchanged.height, result.height)
            XCTAssertEqual(SparseSidebarFixture.pixels(unchanged), acceptedPixels,
                           "已指定视口外的内容变化仍保留第一屏原始像素")
        }
    }

    func testFloatingButtonsOverDividedArticleMarginDoNotCreateAFixedSidebar() throws {
        let page = SparseSidebarFixture.page(width: 914, height: 1081, wideImage: true, grayMargin: true)
        let stitcher = FrameStitcher()
        for offset in [0, 137, 281] {
            let frame = page.cropping(to: CGRect(x: 0, y: offset, width: 914, height: 800))!
            _ = try stitcher.append(SparseSidebarFixture.floatingButtons(on: frame))
            XCTAssertFalse(stitcher.hasFixedRegions,
                           "浅灰页边的分隔线加两个局部按钮，仍不能证明整个页边是固定侧栏")
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, page.height)
        guard result.height == page.height else { return }
        XCTAssertEqual(SparseSidebarFixture.differences(result, page,
            in: CGRect(x: 840, y: 950, width: 64, height: 35)), 0,
                       "按钮所在列后续出现的真实宽图必须保留")
    }

    func testLightGrayArticleMarginPreservesTheWideImageRevealedLater() throws {
        let page = SparseSidebarFixture.page(width: 914, height: 1081, wideImage: true, grayMargin: true)
        let stitcher = FrameStitcher()
        for offset in [0, 137, 281] {
            _ = try stitcher.append(page.cropping(to: CGRect(x: 0, y: offset, width: 914, height: 800))!)
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, page.height)
        guard result.height == page.height else { return }
        XCTAssertEqual(SparseSidebarFixture.differences(result, page,
            in: CGRect(x: 0, y: 0, width: page.width, height: page.height)), 0,
                       "浅灰正文页边与后续宽图不能被侧栏留白删除")
    }

    func testOutsideStatusChangePreservesTheFirstFixedPartition() throws {
        let fixture = SparseSidebarFixture()
        let stitcher = FrameStitcher(scrollingRect: fixture.scrollingRect)
        for (index, original) in fixture.frames.enumerated() {
            var frame = original
            if index == 1 {
                let context = SparseSidebarFixture.context(width: fixture.width, height: fixture.height)
                context.draw(original, in: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
                // 单个图标仅提高三个灰阶；其余图标、名字、贯穿分隔线均未改变。
                SparseSidebarFixture.fill(CGRect(x: 838, y: 126, width: 16, height: 16),
                                          gray: 0.64 + 3.0 / 255, in: context)
                frame = context.makeImage()!
            }
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.height, fixture.height + fixture.offsets[index])
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, fixture.expected.height)
        guard result.height == fixture.expected.height else { return }
        XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected,
            in: CGRect(x: 0, y: 0, width: 814, height: result.height)), 0)
        XCTAssertEqual(SparseSidebarFixture.differences(result, fixture.expected,
            in: CGRect(x: 814, y: 0, width: 100, height: result.height)), 0,
                       "指定视口外的状态变化不能改变分区边界，首屏像素必须完整保留一次")
    }
}
