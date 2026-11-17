import CoreGraphics
import XCTest
@testable import TapSnapApp

/// 仅测试 AX 几何结果的裁剪规则，不查询真实应用或辅助功能权限。
final class ScrollRegionResolverTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let verticalBar = CGRect(x: 580, y: 0, width: 20, height: 380)

    func testViewportClipsAncestorsAndSelectionInGlobalNegativeCoordinates() throws {
        let result = try XCTUnwrap(ScrollRegionResolver.clippedResolution(
            viewport: CGRect(x: -100, y: 50, width: 600, height: 400),
            clippingRects: [CGRect(x: -90, y: 70, width: 520, height: 320)],
            selection: CGRect(x: -80, y: 60, width: 550, height: 370)))
        XCTAssertEqual(result.viewport, CGRect(x: -80, y: 70, width: 510, height: 320))
        XCTAssertEqual(result.content, result.viewport)
    }

    func testOversizedDocumentClipsToViewportAndSeparateScrollbarIsExcluded() throws {
        let result = try XCTUnwrap(ScrollRegionResolver.clippedResolution(
            viewport: bounds, contents: [CGRect(x: 0, y: -100, width: 580, height: 1200)],
            verticalScrollbars: [verticalBar], selection: bounds))
        XCTAssertEqual(result.viewport, bounds)
        XCTAssertEqual(result.content, CGRect(x: 0, y: 0, width: 580, height: 400))
    }

    func testScrollbarOverlappingDocumentDoesNotEraseContent() throws {
        let result = try XCTUnwrap(ScrollRegionResolver.clippedResolution(
            viewport: bounds, contents: [CGRect(x: 0, y: -100, width: 600, height: 1200)],
            verticalScrollbars: [verticalBar], selection: bounds))
        XCTAssertEqual(result.content, bounds)
    }

    func testMissingContentsCannotProveScrollbarIsOutsideContent() throws {
        let result = try XCTUnwrap(ScrollRegionResolver.clippedResolution(
            viewport: bounds, verticalScrollbars: [verticalBar], selection: bounds))
        XCTAssertEqual(result.content, bounds)
    }

    func testNarrowTextNodeDoesNotCropTheScrollViewport() throws {
        let result = try XCTUnwrap(ScrollRegionResolver.clippedResolution(
            viewport: bounds, contents: [CGRect(x: 80, y: 40, width: 150, height: 100)],
            selection: bounds))
        XCTAssertEqual(result.content, bounds)
    }

    func testIndependentHorizontalAndVerticalScrollbarsPreserveKnownContents() throws {
        let content = CGRect(x: 0, y: 0, width: 580, height: 380)
        let result = try XCTUnwrap(ScrollRegionResolver.clippedResolution(
            viewport: bounds, contents: [content], verticalScrollbars: [verticalBar],
            horizontalScrollbars: [CGRect(x: 0, y: 380, width: 580, height: 20)],
            selection: bounds))
        XCTAssertEqual(result.viewport, bounds)
        XCTAssertEqual(result.content, content)
    }

    func testNonIntersectingSelectionReturnsNoResolution() {
        XCTAssertNil(ScrollRegionResolver.clippedResolution(
            viewport: bounds, selection: CGRect(x: 800, y: 0, width: 30, height: 30)))
    }

    func testInvalidViewportReturnsNoResolution() {
        XCTAssertNil(ScrollRegionResolver.clippedResolution(viewport: .null, selection: bounds))
    }
}
