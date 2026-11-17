import CoreGraphics
import XCTest
@testable import TapSnapApp

final class DesktopInteractionTests: XCTestCase {
    private let screens = [CGRect(x: 0, y: 32, width: 1512, height: 900),
                           CGRect(x: -1920, y: -168, width: 1920, height: 1080)]

    func testFloatingBallSnapsOnOffsetExternalScreenUsingAppKitCoordinates() {
        let moved = ToolBallController.snapped(CGRect(x: -1900, y: -100, width: 52, height: 52), screens: screens)
        XCTAssertEqual(moved.origin, CGPoint(x: -1912, y: -100))
        XCTAssertTrue(ToolBallController.isNearEdge(moved, screens: screens))
        let interior = CGRect(x: -1600, y: 200, width: 52, height: 52)
        XCTAssertEqual(ToolBallController.snapped(interior, screens: screens), interior)
        XCTAssertFalse(ToolBallController.isNearEdge(interior, screens: screens))
    }

    func testFloatingBallRecoversOntoRemainingDisplayAfterDisconnect() {
        let recovered = ToolBallController.snapped(CGRect(x: -1700, y: -800, width: 52, height: 52), screens: [screens[0]])
        XCTAssertTrue(screens[0].contains(recovered))
        XCTAssertTrue(ToolBallController.isNearEdge(recovered, screens: [screens[0]]))
    }

    func testFloatingBallSnapsToTopAndBottomWithoutCrossingMenuBarOrDock() {
        let top = ToolBallController.snapped(CGRect(x: 400, y: 870, width: 52, height: 52), screens: screens)
        XCTAssertEqual(top.maxY, screens[0].maxY - 8)
        let bottom = ToolBallController.snapped(CGRect(x: 400, y: 44, width: 52, height: 52), screens: screens)
        XCTAssertEqual(bottom.minY, screens[0].minY + 8)
    }

    func testDesktopToolbarStaysFullyVisibleAfterDisplayChange() {
        let recovered = DesktopBarController.visibleFrame(CGRect(x: -1000, y: -700, width: 176, height: 36), screens: [screens[0]])
        XCTAssertTrue(screens[0].contains(recovered))
        let partlyOutside = DesktopBarController.visibleFrame(CGRect(x: 1400, y: 920, width: 176, height: 36), screens: screens)
        XCTAssertEqual(partlyOutside.maxX, screens[0].maxX)
        XCTAssertEqual(partlyOutside.maxY, screens[0].maxY)
    }
}
