import AppKit
import TapSnapConfig
import TapSnapCore
import TapSnapIcons
import XCTest
@testable import TapSnapApp

@MainActor
final class InlineTextSessionTests: XCTestCase {
    private func editor() -> EditController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditController(environment: AppEnvironment(config: config), image: context.makeImage()!, scale: 1, style: EditItemStyle())
    }
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    private func text() -> TextItem { TextItem(bounds: CGRect(x: 30, y: 40, width: 120, height: 24)) }

    func testNewInlineTextCommitsToDocumentAndCanUndoRedo() {
        let controller = editor(), item = text()
        controller.add(item)
        XCTAssertEqual(controller.textEditingItem?.id, item.id)
        XCTAssertTrue(controller.document.items.isEmpty)
        controller.updateEditingText("中文标注\n第二行")
        XCTAssertEqual(item.text, "中文标注\n第二行")
        controller.finishTextEditing()
        settle()
        XCTAssertNil(controller.textEditingItem)
        XCTAssertEqual(controller.document.items.count, 1)
        controller.perform(.undo)
        XCTAssertTrue(controller.document.items.isEmpty)
        controller.perform(.redo)
        XCTAssertEqual((controller.document.items.first as? TextItem)?.text, "中文标注\n第二行")
    }

    func testCancelAndEmptyDraftLeaveNoPlaceholder() {
        let controller = editor()
        controller.add(text())
        controller.updateEditingText("临时输入")
        controller.finishTextEditing(commit: false)
        XCTAssertTrue(controller.document.items.isEmpty)
        controller.add(text())
        controller.updateEditingText(" \n ")
        controller.finishTextEditing()
        XCTAssertTrue(controller.document.items.isEmpty)
        XCTAssertFalse(controller.canUndo)
    }

    func testEditingExistingTextCanCancelOrUndoWholeEdit() {
        let controller = editor(), item = text()
        controller.add(item)
        controller.updateEditingText("原文")
        controller.finishTextEditing()
        settle()
        let originalBounds = item.bounds
        controller.promptEdit(item)
        controller.updateEditingText("取消这次修改\n第二行")
        controller.style.fontSize = 30
        controller.finishTextEditing(commit: false)
        XCTAssertEqual(item.text, "原文")
        XCTAssertEqual(item.style.fontSize, 14)
        XCTAssertEqual(item.bounds, originalBounds)
        controller.promptEdit(item)
        controller.updateEditingText("修改")
        settle()
        controller.updateEditingText("修改完成\n第二行")
        settle()
        controller.finishTextEditing()
        settle()
        controller.perform(.undo)
        XCTAssertEqual(item.text, "原文")
        XCTAssertEqual(item.bounds, originalBounds)
        controller.perform(.redo)
        XCTAssertEqual(item.text, "修改完成\n第二行")
    }

    func testDeletingExistingTextIsUndoable() {
        let controller = editor(), item = text()
        controller.add(item)
        controller.updateEditingText("保留备份")
        controller.finishTextEditing()
        settle()
        controller.promptEdit(item)
        controller.updateEditingText("")
        controller.finishTextEditing()
        settle()
        XCTAssertTrue(controller.document.items.isEmpty)
        controller.perform(.undo)
        XCTAssertEqual((controller.document.items.first as? TextItem)?.text, "保留备份")
    }

    func testExportCommitsInputThroughCanvasCallback() {
        let controller = editor(), item = text()
        controller.add(item)
        var committed = false
        controller.onFinishTextEditing = { commit in
            committed = commit
            controller.updateEditingText("输入法已确认")
            controller.finishTextEditing(commit: commit)
        }
        XCTAssertNotNil(controller.renderedImage())
        XCTAssertTrue(committed)
        XCTAssertEqual((controller.document.items.first as? TextItem)?.text, "输入法已确认")
        controller.onFinishTextEditing = nil
    }

    func testTextToolHasDedicatedNonLocalizedIcon() {
        XCTAssertEqual(IconSet.text.systemName, "t.square")
        XCTAssertNotNil(NSImage(systemSymbolName: IconSet.text.systemName, accessibilityDescription: nil))
        XCTAssertEqual(IconSet.text.accessibilityLabel, "文字标注")
    }
}
