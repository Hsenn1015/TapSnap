import AppKit
import CoreGraphics
import TapSnapCore
import XCTest
@testable import TapSnapApp

/// 编辑器键盘操作的回归测试。
///
/// 之前 Delete 和 ⌘Z 根本没接上，这类「少接一根线」的 bug 单测能兜住：
/// 用真实的 `NSEvent` 驱动 `handleKeyEvent`，看图元有没有被删、撤销栈有没有转。
@MainActor
final class EditKeyboardTests: XCTestCase {
    private func makeImage() -> CGImage {
        let width = 60, height = 60
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func makeController() -> EditController {
        EditController(
            environment: AppEnvironment(),
            image: makeImage(),
            scale: 1,
            style: EditItemStyle()
        )
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private func addRectangle(to controller: EditController) -> ShapeItem {
        let item = ShapeItem(kind: .rectangle, bounds: CGRect(x: 10, y: 10, width: 20, height: 20))
        controller.add(item)
        return item
    }

    /// UndoManager 默认按「一次事件循环」分组。测试里连续操作之间没有跑 runloop，
    /// 会和真实使用时的分组不一样，这里手动放一轮让它落组。
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    func testDeleteRemovesSelectedAnnotation() {
        let controller = makeController()
        let item = addRectangle(to: controller)
        controller.select(item)
        XCTAssertEqual(controller.document.items.count, 1)

        let handled = controller.handleKeyEvent(key(51, "\u{7F}"))

        XCTAssertTrue(handled, "Delete 应该被处理掉")
        XCTAssertTrue(controller.document.items.isEmpty, "标注应该被删掉")
        XCTAssertNil(controller.document.selectedItemID)
    }

    func testDeleteWithoutSelectionFallsThrough() {
        let controller = makeController()
        _ = addRectangle(to: controller)
        controller.clearSelection()

        let handled = controller.handleKeyEvent(key(51, "\u{7F}"))

        XCTAssertFalse(handled, "没选中东西时不该吞掉按键")
        XCTAssertEqual(controller.document.items.count, 1)
    }

    func testCommandZRestoresDeletedAnnotation() {
        let controller = makeController()
        let item = addRectangle(to: controller)
        settle()
        controller.select(item)
        _ = controller.handleKeyEvent(key(51, "\u{7F}"))
        settle()
        XCTAssertTrue(controller.document.items.isEmpty)

        let handled = controller.handleKeyEvent(key(6, "z", .command))

        XCTAssertTrue(handled)
        XCTAssertEqual(controller.document.items.count, 1, "⌘Z 应该把标注撤回来")
        XCTAssertTrue(controller.canRedo, "撤销之后应该还能重做")
    }

    func testCommandShiftZRedoesTheDelete() {
        let controller = makeController()
        let item = addRectangle(to: controller)
        settle()
        controller.select(item)
        _ = controller.handleKeyEvent(key(51, "\u{7F}"))
        settle()
        _ = controller.handleKeyEvent(key(6, "z", .command))
        settle()

        let handled = controller.handleKeyEvent(key(6, "z", [.command, .shift]))

        XCTAssertTrue(handled)
        XCTAssertTrue(controller.document.items.isEmpty, "⌘⇧Z 应该把删除重做一遍")
    }

    func testMoveIsUndoable() {
        let controller = makeController()
        let item = addRectangle(to: controller)
        let original = item.bounds

        item.bounds = original.offsetBy(dx: 15, dy: 15)
        controller.registerBoundsUndo(for: item, original: original)

        controller.perform(.undo)
        XCTAssertEqual(item.bounds.origin.x, original.origin.x, accuracy: 0.001)
        XCTAssertEqual(item.bounds.origin.y, original.origin.y, accuracy: 0.001)

        controller.perform(.redo)
        XCTAssertEqual(item.bounds.origin.x, original.origin.x + 15, accuracy: 0.001)
    }

    func testReturnAppliesCropOnlyInCropMode() {
        let controller = makeController()
        XCTAssertFalse(controller.handleKeyEvent(key(36, "\r")), "没在裁剪时 Return 不该被吞")

        controller.toggleCrop()
        XCTAssertTrue(controller.isCropping)
        XCTAssertTrue(controller.handleKeyEvent(key(36, "\r")))
        XCTAssertFalse(controller.isCropping, "裁剪模式下 Return 应该退出裁剪")
    }
}
