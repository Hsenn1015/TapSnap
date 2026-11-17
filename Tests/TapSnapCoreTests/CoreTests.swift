import XCTest
@testable import TapSnapCore

final class ColorFormatTests: XCTestCase {
    func testHexRoundTrip() {
        let color = RGBAColor(rgb: 0x1E90FF)
        XCTAssertEqual(color.hex, "#1E90FF")
        XCTAssertEqual(RGBAColor(hex: "#1e90ff"), color)
        XCTAssertEqual(RGBAColor(hex: "1e90ff"), color)
    }

    func testHexWithAlpha() {
        let color = RGBAColor(hex: "#00000080")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.alpha ?? 0, 128.0 / 255.0, accuracy: 0.001)
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(RGBAColor(hex: "not-a-color"))
        XCTAssertNil(RGBAColor(hex: "#12"))
    }
}

final class GeometryTests: XCTestCase {
    func testFlippedVertically() {
        let container = CGRect(x: 0, y: 0, width: 100, height: 200)
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let flipped = rect.flippedVertically(in: container)
        XCTAssertEqual(flipped.minY, 200 - 60, accuracy: 0.0001)
        XCTAssertEqual(flipped.width, 30, accuracy: 0.0001)
    }

    func testSnappedToPixelGrid() {
        let rect = CGRect(x: 10.3, y: 20.6, width: 30.2, height: 40.7)
        let snapped = rect.snapped(to: 2)
        XCTAssertEqual(snapped.minX, 10.5, accuracy: 0.0001)
        XCTAssertEqual(snapped.minY, 20.5, accuracy: 0.0001)
        XCTAssertEqual(snapped.width, 30, accuracy: 0.0001)
    }

    func testBoundingBox() {
        let rects = [
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 20, y: 20, width: 10, height: 10),
        ]
        XCTAssertEqual(Geometry.boundingBox(of: rects), CGRect(x: 0, y: 0, width: 30, height: 30))
        XCTAssertNil(Geometry.boundingBox(of: []))
    }
}
