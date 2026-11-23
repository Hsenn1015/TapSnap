import AppKit
import SwiftUI
import XCTest
@testable import TapSnapApp

@MainActor
final class PermissionGuidePanelTests: XCTestCase {
    private final class Feedback: ObservableObject {
        @Published var text: String?
    }

    private struct Guide: View {
        @ObservedObject var feedback: Feedback
        var body: some View {
            PermissionGuideView(theme: .light, title: "允许截图和录屏",
                                instructions: "请在系统设置中允许 TapSnap，然后重新检测。",
                                feedback: feedback.text, openSettings: {}, recheck: {}, relaunch: {}, close: {})
        }
    }

    func testGuideStaysAvailableAndFitsChangingContentOnSmallDisplay() throws {
        _ = NSApplication.shared
        let feedback = Feedback()
        let display = CGRect(x: -600, y: 0, width: 600, height: 420)
        let panel = PermissionGuidePanel(theme: .light, visibleFrame: display) { Guide(feedback: feedback) }
        defer { panel.close() }
        let scroll = try XCTUnwrap(panel.contentView as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.styleMask.contains(.closable))
        let originalHeight = scroll.frame.height
        XCTAssertGreaterThan(originalHeight, 100)
        XCTAssertEqual(originalHeight, document.fittingSize.height, accuracy: 1)

        feedback.text = String(repeating: "已开启系统设置中的录屏权限，请重新检测。", count: 70)
        RunLoop.main.run(until: .now + 0.15)
        XCTAssertGreaterThan(scroll.frame.height, originalHeight)
        XCTAssertGreaterThan(document.frame.height, scroll.frame.height)
        XCTAssertEqual(document.frame.height, document.fittingSize.height, accuracy: 1)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertTrue(display.contains(panel.frame))

        feedback.text = nil
        RunLoop.main.run(until: .now + 0.15)
        XCTAssertEqual(scroll.frame.height, originalHeight, accuracy: 1)
    }
}
