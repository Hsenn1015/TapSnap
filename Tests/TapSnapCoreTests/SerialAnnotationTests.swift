import AppKit
import CoreGraphics
import XCTest
@testable import TapSnapApp

@MainActor
final class SerialAnnotationTests: XCTestCase {
    private func makeController() -> EditController {
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditController(environment: AppEnvironment(), image: context.makeImage()!,
                              scale: 1, style: EditItemStyle())
    }

    private func serial(at point: CGPoint = CGPoint(x: 40, y: 60)) throws -> SerialItem {
        try XCTUnwrap(EditItemFactory.make(kind: .serialNumber, from: point, to: point,
                                          style: EditItemStyle()) as? SerialItem)
    }

    func testSerialFactoryCentersBadgeOnClick() throws {
        let point = CGPoint(x: 40, y: 60)
        let item = try serial(at: point)
        XCTAssertEqual(item.bounds.size, CGSize(width: 22, height: 22))
        XCTAssertEqual(item.bounds.midX, point.x)
        XCTAssertEqual(item.bounds.midY, point.y)
        let preview = EditItemFactory.makeSerial(at: point, index: 7, style: EditItemStyle())
        XCTAssertEqual(preview.bounds, item.bounds)
        XCTAssertEqual(preview.index, 7)
    }

    func testDeletingMiddleNumberDoesNotDuplicateRemainingNumber() throws {
        let controller = makeController()
        let first = try serial(), middle = try serial(), last = try serial()
        [first, middle, last].forEach(controller.add)
        XCTAssertEqual([first.index, middle.index, last.index], [1, 2, 3])
        controller.remove(middle)
        let next = try serial()
        controller.add(next)
        XCTAssertEqual(next.index, 4)
        let indexes = controller.document.items.compactMap { ($0 as? SerialItem)?.index }
        XCTAssertEqual(Set(indexes).count, indexes.count)
    }

    func testNextSerialIndexMatchesPlacementAfterUndoRedoAndDeletion() throws {
        let controller = makeController()
        XCTAssertEqual(controller.nextSerialIndex, 1)
        controller.add(try serial())
        settleUndoGroup()
        let second = try serial()
        controller.add(second)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 3)

        controller.perform(.undo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 2)
        controller.perform(.redo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 3)

        controller.remove(second)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 2)
        controller.perform(.undo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 3)
        controller.perform(.redo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 2)

        let preview = EditItemFactory.makeSerial(at: CGPoint(x: 20, y: 30),
                                                index: controller.nextSerialIndex, style: controller.style)
        let previewIndex = preview.index
        controller.add(preview)
        XCTAssertEqual(preview.index, previewIndex)
        XCTAssertEqual(controller.nextSerialIndex, previewIndex + 1)
    }

    func testCustomNextSerialIndexAdvancesAndRestoresOnUndoRedoAndDelete() throws {
        let controller = makeController()
        controller.nextSerialIndex = 4
        XCTAssertEqual(controller.nextSerialIndex, 4)

        let fourth = try serial()
        controller.add(fourth)
        settleUndoGroup()
        let fifth = try serial()
        controller.add(fifth)
        settleUndoGroup()
        XCTAssertEqual([fourth.index, fifth.index], [4, 5])
        XCTAssertEqual(controller.nextSerialIndex, 6)

        controller.perform(.undo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 5)

        controller.perform(.undo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 4)

        controller.perform(.redo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 5)

        // 删除最新落下的序号 4 时回退到 4；撤销删除再恢复到 5
        controller.remove(fourth)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 4)
        controller.perform(.undo)
        settleUndoGroup()
        XCTAssertEqual(controller.nextSerialIndex, 5)

        // 非空画布上也可手动重置为 1 或跳号，且限制在合法范围内
        controller.nextSerialIndex = 0
        XCTAssertEqual(controller.nextSerialIndex, 1)
        let restarted = try serial()
        controller.add(restarted)
        settleUndoGroup()
        XCTAssertEqual(restarted.index, 1)
        XCTAssertEqual(controller.nextSerialIndex, 2)

        controller.nextSerialIndex = 2000
        XCTAssertEqual(controller.nextSerialIndex, 999)
    }

    private func settleUndoGroup() {
        // 与真实鼠标事件一样，让 UndoManager 在操作之间结束当前分组。
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
