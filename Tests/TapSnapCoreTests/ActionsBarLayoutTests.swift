import AppKit
import SwiftUI
import XCTest
import TapSnapActionsBar

@MainActor
final class ActionsBarLayoutTests: XCTestCase {
    func testDockFitsEditorWidthsWithoutLosingActions() {
        let model = ActionsBarModel()
        let configured = Set(model.annotationTools + model.outputActions + model.overflow)
        for width: CGFloat in [304, 360, 480, 600, 740, 1000] {
            let layout = model.layout(availableWidth: width)
            XCTAssertLessThanOrEqual(layout.width, width, "Dock must fit a \(width)-point viewport")
            let actions = layout.annotationTools + layout.outputActions + layout.overflow
            XCTAssertEqual(Set(actions), configured)
            XCTAssertEqual(actions.count, configured.count, "Every action should appear exactly once")
            XCTAssertFalse(layout.annotationTools.isEmpty, "Even narrow editors retain a drawing tool")
        }
    }

    func testWideDockRetainsConfiguredOrderAndNarrowDockOffersHiddenToolsInMore() {
        let model = ActionsBarModel()
        let wide = model.layout(availableWidth: 1000)
        XCTAssertEqual(wide.annotationTools, model.annotationTools)
        XCTAssertEqual(wide.outputActions, model.outputActions)
        XCTAssertEqual(wide.overflow, model.overflow)
        let narrow = model.layout(availableWidth: 275)
        XCTAssertTrue(narrow.overflow.contains(.serialNumber))
        XCTAssertTrue(narrow.overflow.contains(.copy))
        XCTAssertTrue(narrow.overflow.contains(.save))
        XCTAssertTrue(narrow.overflow.contains(.formula))
        XCTAssertEqual(narrow.annotationTools, Array(model.annotationTools.prefix(narrow.annotationTools.count)))
    }

    func testCriticalControlsHaveReservedSpaceEvenWhenAllConfiguredActionsCollapse() {
        let model = ActionsBarModel()
        let compact = model.layout(availableWidth: 182)
        XCTAssertTrue(compact.annotationTools.isEmpty)
        XCTAssertTrue(compact.outputActions.isEmpty)
        XCTAssertFalse(compact.overflow.isEmpty)
        // Four fixed action buttons and More still have their full 28-point hit targets.
        XCTAssertEqual(compact.width, 182)
        XCTAssertFalse(compact.overflow.contains(.cancel))
        XCTAssertFalse(compact.overflow.contains(.confirm))
        XCTAssertFalse(compact.overflow.contains(.undo))
        XCTAssertFalse(compact.overflow.contains(.redo))
    }
    func testActualDockFitsNarrowWindowsAndHasNoScrollView() {
        _ = NSApplication.shared
        for width: CGFloat in [304, 480, 740, 1000] {
            let host = NSHostingView(rootView: ActionsBarView(
                selectedTool: .serialNumber,
                annotationOptions: { _ in AnyView(Text("样式")) },
                availableWidth: width,
                onSelect: { _ in }
            ))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 44)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width)
            XCTAssertEqual(host.fittingSize.height, 44, accuracy: 1)
            func hasScrollView(_ view: NSView) -> Bool {
                view is NSScrollView || view.subviews.contains(where: hasScrollView)
            }
            XCTAssertFalse(hasScrollView(host), "Dock must not create native scroll bars")
        }
    }

}
