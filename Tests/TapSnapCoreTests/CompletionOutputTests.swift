import AppKit
import XCTest
import CoreGraphics
import TapSnapConfig
import TapSnapImageIO
@testable import TapSnapApp

final class CompletionOutputTests: XCTestCase {
    func testWebPLosslessRoundTripPreservesPixelsAndAlpha() throws {
        let source = try image()
        let encoded = try ImageCodec.encode(source, as: .webp, quality: 1)
        XCTAssertEqual(String(data: encoded.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: encoded[8..<12], encoding: .ascii), "WEBP")
        let decoded = try ImageCodec.decode(encoded)
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
        let originalPixels = pixels(source), decodedPixels = pixels(decoded)
        XCTAssertEqual(originalPixels.count, decodedPixels.count)
        for (original, decoded) in zip(originalPixels, decodedPixels) {
            XCTAssertLessThanOrEqual(abs(Int(original) - Int(decoded)), 1)
        }
    }

    func testWebPLossyAndNonFiniteQualityEncode() throws {
        for quality in [0.4, Double.nan] {
            let data = try ImageCodec.encode(image(), as: .webp, quality: quality)
            XCTAssertEqual(try ImageCodec.decode(data).width, 3)
        }
    }

    func testAutomaticScrollKeepsOverlapAndBoundsUntrustedSettings() {
        let policy = AutomaticScrollPolicy(viewportHeight: 300, configuredStep: 800,
                                           intervalMilliseconds: 120, overlap: 0.15)
        XCTAssertEqual(policy.step, 195)
        XCTAssertEqual(policy.interval, 0.3)
        let invalid = AutomaticScrollPolicy(viewportHeight: .nan, configuredStep: -1,
                                            intervalMilliseconds: -20, overlap: .nan)
        XCTAssertEqual(invalid.step, 1)
        XCTAssertEqual(invalid.interval, 0.3)
    }

    func testNewSettingsDecodeExistingConfigWithoutLosingPreferences() throws {
        let original = Settings.withDefaultShortcuts()
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var record = try XCTUnwrap(json["record"] as? [String: Any])
        ["includesCamera", "showsKeyPresses", "showsMouseClicks"].forEach { record.removeValue(forKey: $0) }
        record["frameRate"] = 60
        json["record"] = record
        var appearance = try XCTUnwrap(json["appearance"] as? [String: Any])
        appearance.removeValue(forKey: "showDesktopBar")
        json["appearance"] = appearance
        let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.record.frameRate, 60)
        XCTAssertFalse(restored.record.includesCamera)
        XCTAssertFalse(restored.record.showsMouseClicks)
        XCTAssertFalse(restored.appearance.showDesktopBar)
        XCTAssertEqual(restored.shortcuts, original.shortcuts)
    }

    func testAutoSaveWriteAvoidsOverwritingSameNameAndPreservesDistinctPixels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try solidImage(r: 1, g: 0, b: 0)
        let blue = try solidImage(r: 0, g: 0, b: 1)
        let green = try solidImage(r: 0, g: 1, b: 0)

        let first = try ImageCodec.write(red, to: directory, fileName: "TapSnap_2026-11-27_16-50-00", format: .png)
        let second = try ImageCodec.write(blue, to: directory, fileName: "TapSnap_2026-11-27_16-50-00", format: .png)
        let third = try ImageCodec.write(green, to: directory, fileName: "TapSnap_2026-11-27_16-50-00", format: .png)

        XCTAssertEqual(first.lastPathComponent, "TapSnap_2026-11-27_16-50-00.png")
        XCTAssertEqual(second.lastPathComponent, "TapSnap_2026-11-27_16-50-00_2.png")
        XCTAssertEqual(third.lastPathComponent, "TapSnap_2026-11-27_16-50-00_3.png")

        let firstPixels = pixels(try ImageCodec.decode(Data(contentsOf: first)))
        let secondPixels = pixels(try ImageCodec.decode(Data(contentsOf: second)))
        let thirdPixels = pixels(try ImageCodec.decode(Data(contentsOf: third)))
        XCTAssertEqual(firstPixels[0], 255)
        XCTAssertEqual(firstPixels[2], 0)
        XCTAssertEqual(secondPixels[0], 0)
        XCTAssertEqual(secondPixels[2], 255)
        XCTAssertEqual(thirdPixels[1], 255)
    }

    @MainActor
    func testCustomFileNamingModesSanitizeAndIncrementSequentially() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saveDir = root.appendingPathComponent("named", isDirectory: true)
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        let env = AppEnvironment(config: config)
        let fixedDate = Date(timeIntervalSince1970: 1_764_244_800)
        let expectedStamp = ImageCodec.timestampString(now: fixedDate)

        // 确认按钮标题按自动保存/自动复制/隐私开关组合动态显示
        let settings = config.settings
        XCTAssertEqual(CaptureCoordinator.quickConfirmationTitle(autoCopy: true, autoSave: true, privacyEnabled: false, settings: settings), "保存并复制")
        XCTAssertEqual(CaptureCoordinator.quickConfirmationTitle(autoCopy: true, autoSave: true, privacyEnabled: true, settings: settings), "检查后保存并复制")
        XCTAssertEqual(CaptureCoordinator.quickConfirmationTitle(autoCopy: false, autoSave: true, privacyEnabled: false, settings: settings), "保存")
        XCTAssertEqual(CaptureCoordinator.quickConfirmationTitle(autoCopy: false, autoSave: true, privacyEnabled: true, settings: settings), "检查后保存")
        XCTAssertTrue(CaptureCoordinator.quickConfirmationTitle(autoCopy: true, autoSave: false, privacyEnabled: false, settings: settings).hasPrefix("复制"))

        // 默认模式与去前缀模式
        XCTAssertEqual(env.resolvedScreenshotFileName(in: saveDir, format: .png, now: fixedDate), "TapSnap_\(expectedStamp)")
        config.update { $0.capture.fileNamingMode = .timestampOnly }
        XCTAssertEqual(env.resolvedScreenshotFileName(in: saveDir, format: .png, now: fixedDate), expectedStamp)

        // 来源应用模式（带非法字符清洗和空值兜底）
        config.update { $0.capture.fileNamingMode = .sourceAppTimestamp }
        XCTAssertEqual(env.resolvedScreenshotFileName(in: saveDir, format: .png, sourceAppName: "Safari/Tech:Preview", now: fixedDate),
                       "Safari-Tech-Preview_\(expectedStamp)")
        XCTAssertEqual(env.resolvedScreenshotFileName(in: saveDir, format: .png, sourceAppName: nil, now: fixedDate),
                       expectedStamp)

        // 自定义前缀 + 递增序号模式
        config.update {
            $0.capture.saveDirectory = saveDir.path
            $0.capture.saveFormat = "png"
            $0.capture.fileNamingMode = .customPrefixSequence
            $0.capture.fileNamePrefix = "退款/流程:v1"
        }
        let img = try solidImage(r: 0, g: 0.5, b: 1)
        let first = try XCTUnwrap(env.saveScreenshotImage(img, notify: false))
        let second = try XCTUnwrap(env.saveScreenshotImage(img, notify: false))
        let third = try XCTUnwrap(env.saveScreenshotImage(img, notify: false))
        XCTAssertEqual(first.lastPathComponent, "退款-流程-v1-001.png")
        XCTAssertEqual(second.lastPathComponent, "退款-流程-v1-002.png")
        XCTAssertEqual(third.lastPathComponent, "退款-流程-v1-003.png")

        // 极速截图开启隐私检查时仍进入确认复核，不会绕过脱敏
        XCTAssertEqual(CaptureCoordinator.reviewedAction(for: .quickCapture), .confirm)
    }

    private func solidImage(r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let color = try XCTUnwrap(CGColor(colorSpace: space, components: [r, g, b, 1]))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
            bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 1))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 1, y: 1, width: 2, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}
