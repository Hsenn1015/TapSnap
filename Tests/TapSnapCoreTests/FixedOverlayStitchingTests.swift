import CoreGraphics
import CoreText
import XCTest
@testable import TapSnapStitching

/// 页面正文滚动，但右下角的小型浮动控件保持屏幕位置不变。
final class FixedOverlayStitchingTests: XCTestCase {
    private let width = 960
    private let viewportHeight = 560
    private let overlay = CGRect(x: 858, y: 426, width: 72, height: 40)

    private func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private func fill(_ rect: CGRect, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.fill(CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY,
                            width: rect.width, height: rect.height))
    }

    private func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat,
                      color: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - top - size)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    /// 白底聊天记录，正文长度、时间和段间距变化；右侧可为真实内容或留白。
    private func page(hasRightSideContent: Bool, height: Int) -> CGImage {
        let context = context(width: width, height: height)
        fill(CGRect(x: 0, y: 0, width: width, height: context.height),
             color: CGColor(gray: 1, alpha: 1), in: context)
        var top: CGFloat = 17
        for row in 0..<22 {
            let bubbleWidth = CGFloat(380 + (row * 71) % 310)
            fill(CGRect(x: 24, y: top, width: 25, height: 25),
                 color: CGColor(gray: 0.56 + Double(row % 4) * 0.06, alpha: 1), in: context)
            fill(CGRect(x: 61, y: top, width: bubbleWidth, height: 38),
                 color: CGColor(gray: 0.96, alpha: 1), in: context)
            text("Message \(row * 7919 + 31): review the scroll capture at \(row * row + 317).",
                 x: 72, top: top + 4, size: 13, color: CGColor(gray: 0.14, alpha: 1), in: context)
            if row % 3 != 1 {
                text("Reply \(row + 1) - keep this line and the original page pixels.",
                     x: 72, top: top + 21, size: 11, color: CGColor(gray: 0.38, alpha: 1), in: context)
            }
            top += CGFloat(45 + (row * 17) % 39)
        }
        if hasRightSideContent {
            // 随正文滚动的时间/回复编号；覆盖区确有非白色像素，不能靠涂白修复。
            for row in 0..<34 {
                text(String(format: "R%03d", row * 7 + 1), x: 866, top: CGFloat(row * 29 + 9),
                     size: 12, color: CGColor(gray: 0.25, alpha: 1), in: context)
            }
        }
        return context.makeImage()!
    }

    private let clockRect = CGRect(x: 842, y: 11, width: 90, height: 22)

    private func drawHeader(in context: CGContext, height: Int, clock: Int) {
        fill(CGRect(x: 0, y: 0, width: width, height: height),
             color: CGColor(gray: 0.94, alpha: 1), in: context)
        fill(CGRect(x: 0, y: height - 1, width: width, height: 1),
             color: CGColor(gray: 0.82, alpha: 1), in: context)
        text("Chat workspace", x: 24, top: 12, size: 14,
             color: CGColor(gray: 0.18, alpha: 1), in: context)
        text(String(format: "09:41:%02d", clock), x: clockRect.minX + 5, top: clockRect.minY + 3, size: 12,
             color: CGColor(gray: 0.18, alpha: 1), in: context)
    }

    private func frame(_ page: CGImage, at top: Int, paleControl: Bool = false,
                       headerHeight: Int = 0, clock: Int = 0) -> CGImage {
        let bodyHeight = viewportHeight - headerHeight
        let source = page.cropping(to: CGRect(x: 0, y: top, width: width, height: bodyHeight))!
        let context = context(width: width, height: viewportHeight)
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: bodyHeight))
        if headerHeight > 0 { drawHeader(in: context, height: headerHeight, clock: clock) }
        let roundedRect = CGRect(x: overlay.minX, y: CGFloat(viewportHeight) - overlay.maxY,
                                 width: overlay.width, height: overlay.height)
        context.addPath(CGPath(roundedRect: roundedRect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.setFillColor(CGColor(gray: paleControl ? 1 : 0.99, alpha: 1))
        context.setStrokeColor(paleControl ? CGColor(gray: 0.975, alpha: 1)
            : CGColor(red: 0.32, green: 0.55, blue: 0.91, alpha: 1))
        context.setLineWidth(1)
        context.drawPath(using: .fillStroke)
        text("Expand", x: overlay.minX + 12, top: overlay.minY + 13, size: 11,
             color: CGColor(red: 0.10, green: 0.35, blue: 0.90, alpha: 1), in: context)
        return context.makeImage()!
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * context.height))
    }

    private func differentPixels(_ actual: [UInt8], _ expected: [UInt8], in rect: CGRect,
                                 excluding exception: CGRect? = nil) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                if exception?.contains(CGPoint(x: x, y: y)) == true { continue }
                let offset = (y * width + x) * 4
                if (0..<4).contains(where: { abs(Int(actual[offset + $0]) - Int(expected[offset + $0])) > 1 }) {
                    count += 1
                }
            }
        }
        return count
    }

    private func verifyRecoverableContent(hasRightSideContent: Bool, offsets: [Int] = [0, 137, 274, 411],
                                           paleControl: Bool = false,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let page = page(hasRightSideContent: hasRightSideContent, height: viewportHeight + offsets.last!)
        let frames = offsets.map { frame(page, at: $0, paleControl: paleControl) }
        XCTAssertLessThan(overlay.width, CGFloat(width) / 10, file: file, line: line)
        let estimator = DisplacementEstimator()
        for (index, pair) in zip(frames, frames.dropFirst()).enumerated() {
            let displacement = try estimator.estimate(previous: pair.0, next: pair.1)
            XCTAssertEqual(displacement.dy, CGFloat(offsets[index + 1] - offsets[index]),
                           "位移正确也不能把固定小控件重复拼入", file: file, line: line)
            XCTAssertGreaterThanOrEqual(displacement.confidence, 0.9, file: file, line: line)
        }
        let stitcher = FrameStitcher()
        for (offset, frame) in zip(offsets, frames) {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.width, width, "不能裁掉按钮所在整列", file: file, line: line)
            XCTAssertEqual(result.height, viewportHeight + offset, file: file, line: line)
        }
        let result = try stitcher.finish()
        let actual = rgba(result), expected = rgba(page)
        // 控件边框外侧有半像素抗锯齿，比较区域覆盖整个控件及其边缘。
        let covered = overlay.insetBy(dx: -2, dy: -2)
        for index in 0..<(offsets.count - 1) {
            let global = covered.offsetBy(dx: 0, dy: CGFloat(offsets[index]))
            let revealed = global.offsetBy(dx: 0, dy: -CGFloat(offsets[index + 1]))
            XCTAssertFalse(revealed.intersects(covered), "后续帧确实露出了此前遮挡位置", file: file, line: line)
            let clean = page.cropping(to: global)!
            let revealedPixels = frames[index + 1].cropping(to: revealed)!
            XCTAssertEqual(rgba(clean), rgba(revealedPixels), "期望值必须来自实际输入帧，不是补画内容", file: file, line: line)
            if hasRightSideContent {
                XCTAssertTrue(rgba(clean).enumerated().contains { $0.offset % 4 != 3 && $0.element < 180 },
                              "覆盖区必须含真实文字，防止涂白假修复", file: file, line: line)
            }
            XCTAssertEqual(differentPixels(actual, expected, in: global), 0,
                           "第\(index + 1)处旧浮动控件应由后续帧露出的真实像素替换", file: file, line: line)
        }
        // 末帧的遮挡区从未被其他帧看到，不要求凭空恢复；其他位置不能被修改。
        let untouchedLeft = CGRect(x: 0, y: 0, width: covered.minX, height: CGFloat(result.height))
        XCTAssertEqual(differentPixels(actual, expected, in: untouchedLeft), 0,
                       "恢复局部控件不应破坏已对齐的聊天正文", file: file, line: line)
    }

    func testFixedSmallControlIsRemovedWhereLaterFramesRevealRealChatContent() throws {
        try verifyRecoverableContent(hasRightSideContent: true)
    }

    func testBlueTextControlOnBlankRightGutterDoesNotRepeatInTheLongImage() throws {
        try verifyRecoverableContent(hasRightSideContent: false)
    }

    func testLargeScrollRestoresTheOldControlFromTheTopOfTheNextFrame() throws {
        try verifyRecoverableContent(hasRightSideContent: true, offsets: [0, 360, 720])
    }

    func testPaleControlRestoresItsEntireWhiteBodyAndBorderNotOnlyTheBlueText() throws {
        try verifyRecoverableContent(hasRightSideContent: true, offsets: [0, 360, 720], paleControl: true)
    }

    private func verifyTranslucentEdge(atTop: Bool, withFadingScrollbar: Bool = false,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let edgeHeight = 48
        let scrollbarWidth = withFadingScrollbar ? 8 : 0
        let offsets = [0, 26, 63, 131, 203]
        let page = page(hasRightSideContent: true, height: viewportHeight + offsets.last!)
        let stitcher = FrameStitcher()
        for (index, offset) in offsets.enumerated() {
            let bounds = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
            let clean = page.cropping(to: bounds.offsetBy(dx: 0, dy: CGFloat(offset)))!
            let context = context(width: width, height: viewportHeight)
            context.draw(clean, in: bounds)
            // 渐变固定在视口边缘，透过它看到的正文随滚动变化。
            let edgeY = atTop ? viewportHeight - edgeHeight : 0
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: edgeY, width: width, height: edgeHeight))
            context.setAlpha(0.35)
            context.draw(clean, in: bounds.offsetBy(dx: 0, dy: 2))
            context.draw(clean, in: bounds.offsetBy(dx: 0, dy: -2))
            context.setAlpha(1)
            for distance in 0..<edgeHeight {
                let y = atTop ? viewportHeight - 1 - distance : distance
                let opacity = 0.40 - 0.25 * CGFloat(distance) / CGFloat(edgeHeight)
                context.setFillColor(CGColor(gray: 0.86, alpha: opacity))
                context.fill(CGRect(x: 0, y: y, width: width, height: 1))
            }
            context.restoreGState()
            if withFadingScrollbar {
                context.setFillColor(CGColor(gray: 0.35 + 0.12 * CGFloat(index), alpha: 1))
                context.fill(CGRect(x: width - scrollbarWidth, y: 0, width: scrollbarWidth, height: viewportHeight))
            }
            let image = try stitcher.append(context.makeImage()!)
            XCTAssertEqual(image.height, viewportHeight + offset, file: file, line: line)
        }
        let result = try stitcher.finish()
        guard result.width == page.width, result.height == page.height else {
            return XCTFail("成图尺寸应与原页一致", file: file, line: line)
        }
        // 这个区间的每个像素在至少一个输入帧中清晰可见。
        let recoverable = CGRect(x: 0, y: atTop ? edgeHeight : 0,
                                 width: width - scrollbarWidth, height: page.height - edgeHeight)
        XCTAssertEqual(differentPixels(rgba(result), rgba(page), in: recoverable), 0,
                       "滚动正文中应保留清晰的原始像素", file: file, line: line)
    }

    func testTranslucentTopEdgeDoesNotReplaceClearTextWithBlur() throws {
        try verifyTranslucentEdge(atTop: true)
    }

    func testTranslucentBottomEdgeDoesNotLeaveBlurredTextInTheBody() throws {
        try verifyTranslucentEdge(atTop: false)
    }

    func testFadingScrollbarDoesNotLeaveTopEdgeBlurInTheBody() throws {
        try verifyTranslucentEdge(atTop: true, withFadingScrollbar: true)
    }

    func testChangingClockInFixedHeaderDoesNotDuplicateHeaderOrLoseChatRows() throws {
        let headerHeight = 44
        let offsets = [0, 137, 274, 411]
        let body = page(hasRightSideContent: true, height: viewportHeight - headerHeight + offsets.last!)
        let frames = offsets.enumerated().map {
            frame(body, at: $0.element, headerHeight: headerHeight, clock: $0.offset)
        }
        let estimator = DisplacementEstimator()
        for pair in zip(frames, frames.dropFirst()) {
            let displacement = try estimator.estimate(previous: pair.0, next: pair.1)
            XCTAssertEqual(displacement.dy, 137)
            XCTAssertGreaterThanOrEqual(displacement.confidence, 0.9)
        }
        let stitcher = FrameStitcher()
        for (offset, frame) in zip(offsets, frames) {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.width, width)
            XCTAssertEqual(result.height, viewportHeight + offset, "固定头栏只能保留一次")
        }
        let result = try stitcher.finish()
        let reference = context(width: width, height: headerHeight + body.height)
        reference.draw(body, in: CGRect(x: 0, y: 0, width: width, height: body.height))
        drawHeader(in: reference, height: headerHeight, clock: 0)
        let actual = rgba(result), expected = rgba(reference.makeImage()!)
        XCTAssertEqual(differentPixels(actual, expected,
                                        in: CGRect(x: 0, y: 0, width: width, height: headerHeight),
                                        excluding: clockRect), 0, "头栏只有时钟区域允许选择不同输入版本")
        let clockVersions = frames.map { rgba($0.cropping(to: clockRect)!) }
        XCTAssertEqual(Set(clockVersions).count, offsets.count, "时钟必须逐帧实际变化")
        let actualClock = rgba(result.cropping(to: clockRect)!)
        XCTAssertTrue(clockVersions.contains(actualClock), "不能混合或伪造时钟文字")
        let lastControl = overlay.insetBy(dx: -2, dy: -2).offsetBy(dx: 0, dy: CGFloat(offsets.last!))
        XCTAssertEqual(differentPixels(actual, expected,
                                        in: CGRect(x: 0, y: headerHeight, width: width, height: body.height),
                                        excluding: lastControl), 0,
                       "除最后尚未露出的按钮，正文每一行应与原页一致，不夹入头栏或旧控件")
    }
}
