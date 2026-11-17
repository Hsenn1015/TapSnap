import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import TapSnapPrivacy

final class PrivacyVisualAITests: XCTestCase {
    func testLongCropKeepsFullCoverageAndMapsLaterTileToOriginalPixels() throws {
        let region = CGRect(x: 80, y: 190, width: 1440, height: 7100)
        let tiles = PrivacyAI.imageTiles(in: region)
        XCTAssertEqual(tiles.count, 5)
        XCTAssertEqual(tiles.first?.minY, region.minY)
        XCTAssertEqual(tiles.last?.maxY, region.maxY)
        XCTAssertTrue(tiles.allSatisfy { $0.width == 1440 && $0.height <= 1536 })
        for (first, second) in zip(tiles, tiles.dropFirst()) {
            XCTAssertGreaterThanOrEqual(first.maxY - second.minY, 96)
        }

        let tile = try XCTUnwrap(tiles.last)
        let box = try XCTUnwrap(PrivacyAI.imageRect(for: [100, 250, 350, 400], in: tile))
        XCTAssertEqual(box.minX, tile.minX + 144, accuracy: 0.01)
        XCTAssertEqual(box.minY, tile.minY + tile.height * 0.25, accuracy: 0.01)
        XCTAssertEqual(box.width, 360, accuracy: 0.01)
        for malformed: [Double] in [[0, 0, 1000, 1000], [40, 10, 30, 70], [0, 0, 900, 1001], [.nan, 0, 90, 100]] {
            XCTAssertNil(PrivacyAI.imageRect(for: malformed, in: tile))
        }
    }

    func testRequestContainsOnlyTheFlattenedCropAndUsesCompatibleImageParts() throws {
        let image = try fixture(width: 240, height: 170)
        let crop = CGRect(x: 50, y: 40, width: 130, height: 100)
        let tile = try PrivacyAI.prepareTile(image, rect: crop,
                                             covering: [CGRect(x: 64, y: 49, width: 25, height: 20)])
        let request = try PrivacyAI.visualRequest(.init(provider: .deepSeek), key: "fake-key", imageURL: tile.imageURL,
                                                   rules: [.name, .mobile], domainSuffixes: [])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let attachment = try XCTUnwrap(parts.first?["image_url"] as? [String: String])
        let url = try XCTUnwrap(attachment["url"])
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))
        let bytes = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let sent = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(sent.width, Int(crop.width))
        XCTAssertEqual(sent.height, Int(crop.height))
        XCTAssertLessThan(try redPixel(sent, x: 26, y: 19), 8)
        XCTAssertGreaterThan(try redPixel(sent, x: 103, y: 13), 246)
        XCTAssertGreaterThan(try redPixel(sent, x: 26, y: 75), 246)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-key")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testVisualOnlyFindingsRemainEditableSuggestionsAndRespectRuleModes() throws {
        let tile = CGRect(x: 20, y: 80, width: 240, height: 260)
        let scan = PrivacyScanResult(findings: [], text: [], matches: [],
                                     imageBounds: CGRect(x: 0, y: 0, width: 700, height: 1000))
        var settings = PrivacySettings()
        settings[.face] = .automatic
        let selections: [PrivacyAI.VisualSelection] = [
            .init(type: "mobile", bbox_2d: [120, 200, 480, 260], text: nil),
            .init(type: "face", bbox_2d: [550, 220, 740, 470], text: nil),
            .init(type: "barcode", bbox_2d: [550, 220, 740, 470], text: nil),
            .init(type: "unknown", bbox_2d: [120, 200, 480, 260], text: nil),
            .init(type: "mobile", bbox_2d: [-4, 220, 740, 470], text: nil)
        ]
        let findings = PrivacyAI.visualFindings(selections, tile: tile, scan: scan, settings: settings, excluding: [])
        XCTAssertEqual(findings.map(\.label), [PrivacyRule.mobile.title, PrivacyRule.face.title])
        XCTAssertTrue(findings.allSatisfy { !$0.isCovered })
        XCTAssertTrue(tile.contains(try XCTUnwrap(findings.first?.bounds)))
        let excluding = PrivacyAI.visualFindings(selections, tile: tile, scan: scan, settings: settings,
                                                  excluding: [try XCTUnwrap(findings.first?.bounds)])
        XCTAssertEqual(excluding.map(\.label), [PrivacyRule.face.title])
    }

    func testOCRRefinesUniqueValueAndRejectsPartialValue() async throws {
        let image = try fixture(width: 600, height: 160, text: "Assigned to Sample Person")
        var settings = PrivacySettings()
        settings[.name] = .automatic
        let scan = try await PrivacyScanner.inspect(image, settings: settings, includeText: true)
        let line = try XCTUnwrap(scan.text.first { $0.line.text.contains("Sample Person") })
        let tile = scan.imageBounds
        let y = line.line.rect.minY / tile.height * 1000
        let bottom = line.line.rect.maxY / tile.height * 1000
        let roughBox: [Double] = [80, y, 720, bottom]
        let selections: [PrivacyAI.VisualSelection] = [
            .init(type: "name", bbox_2d: roughBox, text: "sample person"),
            .init(type: "name", bbox_2d: roughBox, text: "Sample Pers")
        ]
        let findings = PrivacyAI.visualFindings(selections, tile: tile, scan: scan, settings: settings, excluding: [])
        XCTAssertEqual(findings.map(\.isCovered), [true, false])
        XCTAssertGreaterThan(try XCTUnwrap(findings.first?.bounds.minX), 100)
        XCTAssertLessThan(try XCTUnwrap(findings.first?.bounds.width), 260)
    }

    func testVisualBoxAboveTextSnapsToItsFullLineHeight() async throws {
        let image = try fixture(width: 600, height: 160, text: "Assigned to Sample Person")
        var settings = PrivacySettings()
        settings[.name] = .automatic
        let scan = try await PrivacyScanner.inspect(image, settings: settings, includeText: true)
        let text = try XCTUnwrap(scan.text.first { $0.line.text.contains("Sample Person") })
        let line = text.line.rect
        let y = (line.minY - 32) / scan.imageBounds.height * 1000
        let bottom = (line.minY - 10) / scan.imageBounds.height * 1000
        let found = PrivacyAI.visualFindings(
            [.init(type: "name", bbox_2d: [170, y, 480, bottom], text: "Sample Person")],
            tile: scan.imageBounds, scan: scan, settings: settings, excluding: [])
        let mask = try XCTUnwrap(found.first)
        XCTAssertTrue(mask.isCovered)
        XCTAssertLessThanOrEqual(mask.bounds.minY, line.minY)
        XCTAssertGreaterThanOrEqual(mask.bounds.maxY, line.maxY)
        XCTAssertGreaterThan(mask.bounds.minY, line.minY - 10)
    }

    func testCoverageUsesFragmentWidthAndEntireObservedLineHeight() {
        let fragment = CGRect(x: 80, y: 24, width: 88, height: 8)
        let line = CGRect(x: 18, y: 21, width: 290, height: 19)
        let image = CGRect(x: 0, y: 0, width: 350, height: 100)
        XCTAssertEqual(PrivacyScanner.coverageRect(fragment: fragment, line: line, inside: image),
                       CGRect(x: 77, y: 18, width: 94, height: 25))
    }

    func testDeadlineCancelsSlowModelOperation() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await PrivacyAI.withDeadline(.milliseconds(40)) {
                try await Task.sleep(for: .seconds(3))
                return true
            }
            XCTFail("The request should time out")
        } catch let error as PrivacyAIError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    private func fixture(width: Int, height: Int, text: String? = nil) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 26, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            context.textPosition = CGPoint(x: 30, y: 85)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func redPixel(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var data = [UInt8](repeating: 0, count: 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return data[0]
    }
}
