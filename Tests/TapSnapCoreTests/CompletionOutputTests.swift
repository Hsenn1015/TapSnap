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
