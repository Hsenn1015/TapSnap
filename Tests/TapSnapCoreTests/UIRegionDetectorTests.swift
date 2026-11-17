import CoreGraphics
import TapSnapVision
import XCTest

final class UIRegionDetectorTests: XCTestCase {
    func testDetectionKeepsAnAlignedPanelAndRejectsRotatedArtwork() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func paint(_ rect: CGRect, shade: CGFloat) {
            context.setFillColor(CGColor(gray: shade, alpha: 1))
            context.fill(rect)
        }

        paint(CGRect(x: 0, y: 0, width: 800, height: 500), shade: 0.20)
        paint(CGRect(x: 70, y: 60, width: 660, height: 380), shade: 0.97)
        paint(CGRect(x: 140, y: 150, width: 390, height: 200), shade: 0.65)
        context.saveGState()
        context.translateBy(x: 620, y: 260)
        context.rotate(by: 18 * .pi / 180)
        paint(CGRect(x: -45, y: -20, width: 90, height: 40), shade: 0.08)
        context.restoreGState()

        let image = try XCTUnwrap(context.makeImage())
        let regions = UIRegionDetector().detectRegions(in: image)
        let panel = try XCTUnwrap(regions.first {
            abs($0.bounds.midX - 335.0 / 800.0) < 0.015 && abs($0.bounds.midY - 0.5) < 0.015
        })
        XCTAssertEqual(panel.bounds.width, 390.0 / 800.0, accuracy: 0.015)
        XCTAssertEqual(panel.bounds.height, 200.0 / 500.0, accuracy: 0.015)
        XCTAssertFalse(regions.contains {
            abs($0.bounds.midX - 620.0 / 800.0) < 0.015 && abs($0.bounds.midY - 260.0 / 500.0) < 0.015
        })
    }
}
