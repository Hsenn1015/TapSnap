import AppKit
import SwiftUI
import TapSnapTheme
import XCTest
@testable import TapSnapToast

@MainActor
final class ToastTests: XCTestCase {
    func testToastCentersAboveBottomOfSecondaryDisplay() {
        let visible = CGRect(x: -1440, y: 128, width: 1440, height: 840)
        for width: CGFloat in [178, 408] {
            let frame = ToastPresenter.panelFrame(size: CGSize(width: width, height: 68), visible: visible)
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.minY - visible.minY, 22)
            XCTAssertTrue(visible.contains(frame))
        }
    }

    func testCopyToastFitsItsTextAndLongToastWraps() {
        _ = NSApplication.shared
        func size(for message: String) -> CGSize {
            let root = ToastStackView(messages: [ToastMessage(text: message, style: .success)], theme: .light) { _ in }
            let controller = NSHostingController(rootView: root)
            return controller.sizeThatFits(in: CGSize(width: 408, height: 760))
        }
        let copy = size(for: "已复制到剪贴板")
        let long = size(for: "截图需要屏幕录制权限，请在系统设置中勾选 TapSnap 后重新打开截图。"
                        + "如果权限已经打开，请先退出应用，再重新启动。")
        XCTAssertLessThan(copy.width, 224)
        XCTAssertEqual(copy.height, 68, accuracy: 1)
        XCTAssertLessThanOrEqual(long.width, 408)
        XCTAssertGreaterThan(long.height, copy.height)
    }

    func testMessagesExpireIndependentlyWhenStackChanges() async throws {
        let center = ToastCenter()
        let first = ToastMessage(text: "已复制", style: .success, duration: 0.05)
        let second = ToastMessage(text: "已保存", style: .success, duration: 10)
        center.show(first)
        center.show(second)
        XCTAssertEqual(center.messages, [first, second])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(center.messages, [second])
        center.dismiss(second.id)
        XCTAssertTrue(center.messages.isEmpty)
    }

    func testActionToastTriggersCallbackOnceAndDismisses() {
        let center = ToastCenter()
        var triggers = 0
        let message = ToastMessage(text: "已复制 12 个字符", style: .success, duration: 10, actionTitle: "查看结果")
        center.show(message) { triggers += 1 }
        XCTAssertEqual(center.messages.first?.actionTitle, "查看结果")

        center.performAction(for: message.id)
        XCTAssertEqual(triggers, 1)
        XCTAssertTrue(center.messages.isEmpty)

        center.performAction(for: message.id)
        XCTAssertEqual(triggers, 1)
    }
}
