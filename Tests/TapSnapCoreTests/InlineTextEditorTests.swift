import AppKit
import TapSnapConfig
import TapSnapCore
import XCTest
@testable import TapSnapApp

@MainActor
final class InlineTextEditorTests: XCTestCase {
    private func fixture() throws -> (EditController, EditItemLayerView, NSWindow) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = EditController(environment: AppEnvironment(config: config), image: try XCTUnwrap(bitmap.makeImage()),
                                        scale: 1, style: EditItemStyle())
        let view = EditItemLayerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.controller = controller
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertFalse(window.isVisible)
        return (controller, view, window)
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, view: EditItemLayerView, clicks: Int = 1) throws {
        let position = view.convert(CGPoint(x: point.x * view.displayScale, y: point.y * view.displayScale), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        if type == .leftMouseDown { view.mouseDown(with: event) }
        else if type == .leftMouseDragged { view.mouseDragged(with: event) }
        else { view.mouseUp(with: event) }
    }

    private func key(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code))
    }

    func testCanvasClickStartsNativeEditorAndReturnAddsLineWithoutDialog() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        let brush = try key(11, text: "b", window: window)
        XCTAssertTrue(controller.handleKeyEvent(brush))
        XCTAssertEqual(controller.selectedTool, .pen)
        controller.perform(.text)
        try mouse(.leftMouseDown, point: CGPoint(x: 20, y: 30), view: view)
        try mouse(.leftMouseUp, point: CGPoint(x: 20, y: 30), view: view)
        let editor = try XCTUnwrap(view.inlineTextEditor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(controller.handleKeyEvent(brush), "文字输入期间 B 应交给输入框")
        XCTAssertFalse(controller.handleKeyEvent(try key(17, text: "t", modifiers: .command, window: window)),
                       "文字输入期间 ⌘T 应交给输入框")
        XCTAssertEqual(controller.selectedTool, .text)
        XCTAssertNotNil(controller.textEditingItem)
        XCTAssertTrue(controller.document.items.isEmpty)
        XCTAssertNil(NSApp.modalWindow)
        editor.insertText("中文", replacementRange: editor.selectedRange())
        let enter = try key(36, text: "\r", window: window)
        XCTAssertFalse(controller.handleKeyEvent(enter), "Window hotkeys must leave text input to NSTextView")
        editor.keyDown(with: enter)
        editor.insertText("second line", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "中文\nsecond line")
        XCTAssertEqual(controller.textEditingItem?.text, editor.string)
        editor.keyDown(with: try key(36, text: "\r", modifiers: .command, window: window))
        XCTAssertNil(controller.textEditingItem)
        XCTAssertNil(view.inlineTextEditor)
        XCTAssertEqual((controller.document.items.first as? TextItem)?.text, "中文\nsecond line")
    }

    func testCompositionAndSelectionSurviveModelAndZoomUpdates() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        let item = TextItem(text: "before", bounds: CGRect(x: 20, y: 30, width: 120, height: 24))
        controller.beginTextEditing(item, isNew: true)
        view.updateInteractionState()
        let editor = try XCTUnwrap(view.inlineTextEditor)
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        view.displayScale = 0.5
        view.updateInteractionState()
        XCTAssertTrue(view.inlineTextEditor === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 2))
        XCTAssertEqual(editor.frame.minX, 10)
        XCTAssertEqual(editor.frame.width, (item.textContainerWidth ?? 0) * 0.5)
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        let marked = editor.markedRange()
        let selected = editor.selectedRange()
        view.displayScale = 1
        view.updateInteractionState()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selected)
        _ = controller.renderedImage()
        XCTAssertNil(controller.textEditingItem, "Export must finish native composition and commit")
        XCTAssertFalse((controller.document.items.first as? TextItem)?.text.isEmpty ?? true)
    }

    func testTypingKeepsNativeUndoAcrossCanvasRefreshes() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        let item = TextItem(bounds: CGRect(x: 20, y: 30, width: 120, height: 24))
        controller.beginTextEditing(item, isNew: true)
        view.updateInteractionState()
        let editor = try XCTUnwrap(view.inlineTextEditor)
        editor.insertText("abcdef", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        view.updateInteractionState()
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        editor.doCommand(by: NSSelectorFromString("undo:"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(controller.textEditingItem?.text, "")
        editor.doCommand(by: NSSelectorFromString("redo:"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(editor.string, "abcdef")
        XCTAssertEqual(controller.textEditingItem?.text, "abcdef")
    }

    func testFormattingUpdatesTextInPlaceAndAppliesToNewlyTypedCharacters() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        let item = TextItem(text: "中A", bounds: CGRect(x: 20, y: 30, width: 150, height: 24))
        controller.beginTextEditing(item, isNew: true)
        view.updateInteractionState()
        let editor = try XCTUnwrap(view.inlineTextEditor)
        let cursor = editor.selectedRange()

        controller.style.textFormat.fontFamily = "Menlo"
        controller.style.textFormat.isBold = false
        controller.style.textFormat.isItalic = true
        controller.style.textFormat.isUnderlined = true
        controller.style.textFormat.isStruckThrough = true
        controller.style.textFormat.alignment = .center
        controller.style.fontSize = 25
        controller.style.color = RGBAColor(rgb: 0x064FCF)
        controller.style.textBackgroundColor = RGBAColor(rgb: 0xF0EACC)
        controller.toolOptions.textBackground = .rounded
        view.updateInteractionState()

        XCTAssertTrue(view.inlineTextEditor === editor)
        XCTAssertEqual(editor.selectedRange(), cursor)
        editor.insertText("B", replacementRange: cursor)
        let storage = try XCTUnwrap(editor.textStorage)
        for index in [0, 1, 2] {
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            let font = try XCTUnwrap(attributes[.font] as? NSFont)
            XCTAssertEqual(font.pointSize, 25)
            // AppKit chooses a CJK fallback for glyphs that Menlo does not cover.
            if index > 0 {
                XCTAssertEqual(font.familyName, "Menlo")
                XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
            }
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
            XCTAssertEqual(attributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
            XCTAssertEqual((attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment, .center)
        }
        XCTAssertEqual(item.bounds.width, item.textContainerWidth)
        let image = try XCTUnwrap(controller.renderedImage())
        XCTAssertEqual(item.text, "中AB")
        XCTAssertEqual(item.background, .rounded)
        XCTAssertEqual(item.style.textBackgroundColor, RGBAColor(rgb: 0xF0EACC))
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let background = (Int(item.bounds.midY) * image.bytesPerRow) + (Int(item.bounds.minX) + 12) * 4
        XCTAssertGreaterThan(data[background], 215)
        XCTAssertEqual(data[background + 3], 255)
        let inkColumns = (Int(item.bounds.minX)..<Int(item.bounds.maxX)).filter { x in
            (Int(item.bounds.minY)..<Int(item.bounds.maxY)).contains { y in
                let offset = y * image.bytesPerRow + x * 4
                return data[offset + 3] > 240 && data[offset] < 100 && data[offset + 2] > 160
            }
        }
        XCTAssertGreaterThan(inkColumns.count, 20)
        XCTAssertGreaterThan(try XCTUnwrap(inkColumns.first), Int(item.bounds.minX + 60))
        XCTAssertLessThan(try XCTUnwrap(inkColumns.last), Int(item.bounds.maxX - 60))
    }

    func testDoubleClickEditsExistingTextAndEscapeRestoresIt() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        let item = TextItem(text: "Original", bounds: CGRect(x: 30, y: 40, width: 120, height: 24))
        item.fitToText(maxWidth: 180)
        controller.document.append(item)
        try mouse(.leftMouseDown, point: CGPoint(x: 35, y: 45), view: view, clicks: 2)
        let editor = try XCTUnwrap(view.inlineTextEditor)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("Changed", replacementRange: editor.selectedRange())
        XCTAssertEqual(item.text, "Changed")
        editor.keyDown(with: try key(53, text: "\u{1b}", window: window))
        XCTAssertEqual(item.text, "Original")
        XCTAssertEqual(controller.document.items.count, 1)
        XCTAssertNil(view.inlineTextEditor)
    }

    func testTextResizeKeepsWrapWidthWhenReeditingAndUndoing() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        let item = TextItem(text: "one two three four five", bounds: CGRect(x: 30, y: 40, width: 180, height: 24))
        item.fitToText(maxWidth: 180)
        controller.document.append(item)
        let original = item.bounds
        let handle = CGPoint(x: original.maxX, y: original.midY)
        let dragged = CGPoint(x: original.minX + 70, y: original.midY)
        try mouse(.leftMouseDown, point: handle, view: view)
        try mouse(.leftMouseDragged, point: dragged, view: view)
        try mouse(.leftMouseUp, point: dragged, view: view)
        XCTAssertEqual(item.textContainerWidth, 70)
        XCTAssertEqual(item.bounds.width, 70)
        let resized = item.bounds
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        controller.perform(.undo)
        XCTAssertEqual(item.bounds, original)
        XCTAssertEqual(item.textContainerWidth, 180)
        controller.perform(.redo)
        XCTAssertEqual(item.bounds, resized)
        XCTAssertEqual(item.textContainerWidth, 70)
        try mouse(.leftMouseDown, point: CGPoint(x: item.bounds.minX + 5, y: item.bounds.minY + 5), view: view, clicks: 2)
        XCTAssertEqual(try XCTUnwrap(view.inlineTextEditor).frame.width, 70)
    }

    func testDraggingTextBoxSetsWrapWidthAndClickOutsideCommits() throws {
        let (controller, view, window) = try fixture()
        defer { window.close() }
        controller.perform(.text)
        try mouse(.leftMouseDown, point: CGPoint(x: 20, y: 30), view: view)
        try mouse(.leftMouseDragged, point: CGPoint(x: 160, y: 70), view: view)
        try mouse(.leftMouseUp, point: CGPoint(x: 160, y: 70), view: view)
        let editor = try XCTUnwrap(view.inlineTextEditor)
        XCTAssertEqual(controller.textEditingItem?.textContainerWidth, 140)
        XCTAssertEqual(editor.frame.width, 140)
        editor.insertText("Text", replacementRange: editor.selectedRange())
        try mouse(.leftMouseDown, point: CGPoint(x: 300, y: 200), view: view)
        XCTAssertEqual((controller.document.items.first as? TextItem)?.text, "Text")
        XCTAssertNil(controller.textEditingItem)
        XCTAssertNil(view.inlineTextEditor)
    }
}
