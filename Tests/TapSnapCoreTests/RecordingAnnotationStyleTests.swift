import AVFoundation
import CoreGraphics
import ImageIO
import TapSnapCore
import XCTest
@testable import TapSnapMedia

final class RecordingAnnotationStyleTests: XCTestCase {
    func testFreehandUsesEveryPointAndTranslucentHighlightDoesNotDarkenOnItself() throws {
        let source = try whiteFrame()
        let range = try RecordingTimeRange(start: 0, end: 1)
        let left = CGPoint(x: 0.15, y: 0.3)
        let right = CGPoint(x: 0.85, y: 0.3)
        let middle = CGPoint(x: 0.5, y: 0.75)
        let pen = RecordingAnnotation(kind: .pen, startPoint: left, endPoint: right, range: range,
                                      style: .init(color: .black, lineWidth: 30), points: [left, middle, right])
        let penned = try RecordingAnnotationRenderer.render([pen], over: source)
        XCTAssertLessThan(try pixel(penned, x: 96, y: 96).red, 0.1)
        XCTAssertGreaterThan(try pixel(penned, x: 96, y: 38).red, 0.96, "画笔不能用首尾直线替代路径")
        let bounds = RecordingAnnotationRenderer.bounds(of: pen, size: CGSize(width: 192, height: 128))
        XCTAssertGreaterThan(bounds.maxY, 96, "选区应包括拐点及线宽")

        var highlight = RecordingAnnotation(kind: .highlight, startPoint: left, endPoint: right, range: range,
                                            points: [left, right])
        let single = try RecordingAnnotationRenderer.render([highlight], over: source)
        highlight.points = [left, right, left, right]
        let retraced = try RecordingAnnotationRenderer.render([highlight], over: source)
        let shaded = try pixel(single, x: 96, y: 38)
        XCTAssertGreaterThan(shaded.blue, 0.4)
        XCTAssertLessThan(shaded.blue, 0.9)
        XCTAssertEqual(try pixel(retraced, x: 96, y: 38).blue, shaded.blue, accuracy: 0.02)

        var dot = pen
        dot.points = [middle]
        let dotted = try RecordingAnnotationRenderer.render([dot], over: source)
        XCTAssertLessThan(try pixel(dotted, x: 96, y: 96).red, 0.1)
        XCTAssertGreaterThan(try pixel(dotted, x: 96, y: 38).red, 0.96)
    }

    func testStrokePatternAndTextSizeAreRenderedFromStyle() throws {
        let source = try whiteFrame()
        let range = try RecordingTimeRange(start: 0, end: 1)
        var line = RecordingAnnotation(kind: .line, startPoint: CGPoint(x: 0.1, y: 0.5),
                                       endPoint: CGPoint(x: 0.9, y: 0.5), range: range,
                                       style: .init(color: .black, lineWidth: 30))
        let solid = try RecordingAnnotationRenderer.render([line], over: source)
        line.style.strokePattern = .dashed
        let dashed = try RecordingAnnotationRenderer.render([line], over: source)
        line.style.strokePattern = .dotted
        let dotted = try RecordingAnnotationRenderer.render([line], over: source)
        func darkCount(_ image: CGImage) throws -> Int {
            try (24..<168).filter { try pixel(image, x: $0, y: 64).red < 0.1 }.count
        }
        XCTAssertEqual(try darkCount(solid), 144)
        XCTAssertLessThan(try darkCount(dashed), try darkCount(solid))
        XCTAssertLessThan(try darkCount(dotted), try darkCount(dashed))
        XCTAssertGreaterThan(try darkCount(dotted), 10)

        var text = RecordingAnnotation(kind: .text, startPoint: CGPoint(x: 0.1, y: 0.1),
                                       endPoint: CGPoint(x: 0.1, y: 0.1), text: "TapSnap", range: range)
        let size = CGSize(width: 192, height: 128)
        let original = RecordingAnnotationRenderer.bounds(of: text, size: size)
        text.style.fontSize = 96
        text.style.textBackground = .init(red: 0, green: 0, blue: 1)
        let enlarged = RecordingAnnotationRenderer.bounds(of: text, size: size)
        XCTAssertGreaterThan(enlarged.height, original.height)
        XCTAssertGreaterThan(enlarged.width, original.width)
        let drawn = try RecordingAnnotationRenderer.render([text], over: source)
        let backgroundX = Int(enlarged.minX) + 2, backgroundY = Int(enlarged.midY)
        let background = try pixel(drawn, x: backgroundX, y: backgroundY)
        XCTAssertGreaterThan(background.blue - background.red, 0.8)
        text.style.textBackground = nil
        let transparent = try RecordingAnnotationRenderer.render([text], over: source)
        XCTAssertGreaterThan(try pixel(transparent, x: backgroundX, y: backgroundY).red, 0.96)
    }

    @MainActor
    func testExportsStyledEllipseAndOpaqueMaskToMP4AndGIF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let encoder = VideoEncoder(configuration: .init(width: 192, height: 128, frameRate: 4))
        try encoder.prepare(outputURL: source)
        let frame = try whiteFrame()
        for index in 0..<4 {
            try encoder.append(frame, at: Double(index) / 4)
            try await Task.sleep(for: .milliseconds(20))
        }
        let recording = try await encoder.finish(endingAt: 1)
        XCTAssertEqual(recording, source)

        let range = try RecordingTimeRange(start: 0.25, end: 0.75)
        let shape = RecordingAnnotation(kind: .ellipse, startPoint: CGPoint(x: 0.1, y: 0.1),
                                        endPoint: CGPoint(x: 0.55, y: 0.55), range: range,
                                        style: .init(color: .init(red: 0, green: 0, blue: 1), lineWidth: 30,
                                                     fillColor: .init(red: 1, green: 0, blue: 0)))
        let mask = RecordingAnnotation(kind: .mask, startPoint: CGPoint(x: 0.65, y: 0.1),
                                       endPoint: CGPoint(x: 0.9, y: 0.35), range: range,
                                       style: .init(color: .init(red: 0.1, green: 0.6, blue: 0.2, alpha: 0.1)))
        let mp4 = directory.appendingPathComponent("annotated.mp4")
        let gif = directory.appendingPathComponent("annotated.gif")
        try await VideoTrimmer.export(videoURL: source, to: mp4, range: .init(start: 0, end: 1),
                                      annotations: [shape, mask])
        try await GifExporter.export(videoURL: source, to: gif, sampleInterval: 0.25,
                                     annotations: [shape, mask])
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mp4))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let videoFrame = try await generator.image(at: CMTime(value: 1, timescale: 2)).image
        let animation = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let gifFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(animation, 2, nil))
        for rendered in [videoFrame, gifFrame] {
            let fill = try pixel(rendered, x: 62, y: 42)
            XCTAssertGreaterThan(fill.red - fill.blue, 0.75)
            let border = try pixel(rendered, x: 20, y: 42)
            XCTAssertGreaterThan(border.blue - border.red, 0.5)
            XCTAssertGreaterThan(try pixel(rendered, x: 21, y: 16).green, 0.92, "椭圆角外应为原始画面")
            let covered = try pixel(rendered, x: 148, y: 25)
            XCTAssertLessThan(covered.red, 0.25)
            XCTAssertGreaterThan(covered.green, 0.45)
            XCTAssertLessThan(covered.blue, 0.4, "打码颜色始终不透明")
        }
        let unedited = try await generator.image(at: .zero).image
        XCTAssertGreaterThan(try pixel(unedited, x: 62, y: 42).blue, 0.95)
    }

    private func whiteFrame() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 192, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 192, height: 128))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGBAColor {
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return RGBAColor(red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
    }
}
