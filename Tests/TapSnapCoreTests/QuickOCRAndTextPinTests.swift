import AppKit
import CoreText
import TapSnapConfig
import TapSnapToast
import XCTest
@testable import TapSnapApp

@MainActor
final class QuickOCRAndTextPinTests: XCTestCase {
    private func textImage(_ text: String, width: Int = 560, height: Int = 120) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(colorSpace: space, components: [0, 0, 0, 1])!
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 32, y: 44)
        CTLineDraw(line, context)
        return try XCTUnwrap(context.makeImage())
    }

    func testSilentOCRCopiesTextWithoutOpeningResultPanelAndToastActionOpensOnDemand() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        let env = AppEnvironment(config: config)
        env.toast.dismissAll()
        defer {
            env.ocrResultPanel.close()
            env.toast.dismissAll()
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let image = try textImage("TapSnap Quick OCR 2026")
        let extracted = try await env.ocrCoordinator.runSilently(image, to: board)
        let text = try XCTUnwrap(extracted)
        XCTAssertTrue(text.contains("TapSnap"))
        XCTAssertTrue(text.contains("2026"))
        XCTAssertEqual(board.string(forType: .string), text)

        let visibleResultWindows = NSApp.windows.filter { $0.isVisible && $0.title == "识别结果" }
        XCTAssertTrue(visibleResultWindows.isEmpty, "极速取字不应主动弹出识别结果窗口抢焦点")

        let toast = try XCTUnwrap(env.toast.messages.last)
        XCTAssertEqual(toast.actionTitle, "查看结果")

        env.toast.performAction(for: toast.id)
        let openedResultWindows = NSApp.windows.filter { $0.isVisible && $0.title == "识别结果" }
        XCTAssertFalse(openedResultWindows.isEmpty, "点击 Toast 上的「查看结果」应按需打开结果窗")
    }

    func testTextPinRendersCardPreservesSourceTextAcrossPersistenceAndCopiesTextOrImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        let storage = root.appendingPathComponent("pins", isDirectory: true)
        let manager = PinGroupManager(config: config, storageDirectory: storage, presentsWindows: false)

        let sample = "工单 #4821\n复现步骤：先开启自动保存，再点击保存并复制"
        let rendered = try XCTUnwrap(PinTextRenderer.render(sample, isDark: true, scale: 2))
        XCTAssertEqual(rendered.scale, 2)
        XCTAssertGreaterThanOrEqual(rendered.image.width, Int(PinTextRenderer.minimumWidth * 2))
        XCTAssertLessThanOrEqual(rendered.image.width, Int(PinTextRenderer.maximumWidth * 2))
        XCTAssertGreaterThan(rendered.image.height, 60)

        let item = manager.show(rendered.image, at: CGPoint(x: 120, y: 140), scale: rendered.scale, sourceText: sample)
        XCTAssertEqual(item.sourceText, sample)

        let textBoard = NSPasteboard.withUniqueName()
        defer { textBoard.releaseGlobally() }
        manager.copyToPasteboard(item.id, to: textBoard)
        XCTAssertEqual(textBoard.string(forType: .string), sample, "纯文字贴图默认复制应还原原始文本")

        let imageBoard = NSPasteboard.withUniqueName()
        defer { imageBoard.releaseGlobally() }
        manager.copyImageToPasteboard(item.id, to: imageBoard)
        let env = AppEnvironment(config: config)
        let copiedImage = try XCTUnwrap(env.pinTransfer.imagePayload(from: imageBoard)?.image)
        XCTAssertEqual(copiedImage.width, rendered.image.width)
        XCTAssertEqual(copiedImage.height, rendered.image.height)

        manager.flushPersistence()
        let restored = PinGroupManager(config: config, storageDirectory: storage, presentsWindows: false)
        XCTAssertEqual(restored.items.first?.sourceText, sample, "重启恢复贴图后仍应保留原始文本")
    }

    func testPinTransferReadsPlainTextRejectsWhitespaceAndSupportsCommandCOnPinView() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        let env = AppEnvironment(config: config)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        board.clearContents()
        board.setString("   \n\t  ", forType: .string)
        XCTAssertNil(env.pinTransfer.textPayload(from: board))

        board.clearContents()
        board.setString("  TICKET-9921  ", forType: .string)
        XCTAssertEqual(env.pinTransfer.textPayload(from: board), "  TICKET-9921  ")

        let rendered = try XCTUnwrap(PinTextRenderer.render("TICKET-9921", isDark: false, scale: 2))
        let pin = PinItem(image: rendered.image, frame: CGRect(x: 0, y: 0, width: 160, height: 60),
                          scale: 2, sourceText: "TICKET-9921")
        let view = PinImageView(item: pin)
        var copied = 0
        view.onCopy = { copied += 1 }
        let cmdC = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        view.keyDown(with: cmdC)
        XCTAssertEqual(copied, 1)
    }

    func testCompleteScreenshotOutputsHonorAutoSaveAndAutoCopyWithPasteboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saveDir = root.appendingPathComponent("captures", isDirectory: true)
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        let env = AppEnvironment(config: config)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> CGImage {
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            ctx.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            return try XCTUnwrap(ctx.makeImage())
        }

        let red = try solid(1, 0, 0)
        let blue = try solid(0, 0, 1)

        // 仅复制时不向自动保存目录写文件
        config.update {
            $0.capture.saveDirectory = saveDir.path
            $0.capture.saveFormat = "png"
            $0.capture.autoCopyToClipboard = true
            $0.capture.autoSaveToFile = false
        }
        XCTAssertTrue(env.completeScreenshotOutputs(red, to: board))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saveDir.path))
        XCTAssertNotNil(env.pinTransfer.imagePayload(from: board))

        // 同时开启保存与复制：连续保存两张都落盘且不覆盖，剪贴板更新为最新一张
        config.update {
            $0.capture.autoCopyToClipboard = true
            $0.capture.autoSaveToFile = true
        }
        XCTAssertTrue(env.completeScreenshotOutputs(red, to: board))
        XCTAssertTrue(env.completeScreenshotOutputs(blue, to: board))
        let files = try FileManager.default.contentsOfDirectory(atPath: saveDir.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files.count, 2)
        XCTAssertNotNil(env.pinTransfer.imagePayload(from: board)?.image)

        // 仅自动保存时不改写剪贴板
        board.clearContents()
        board.setString("keep-me", forType: .string)
        config.update {
            $0.capture.autoCopyToClipboard = false
            $0.capture.autoSaveToFile = true
        }
        XCTAssertTrue(env.completeScreenshotOutputs(red, to: board))
        XCTAssertEqual(board.string(forType: .string), "keep-me")
        let filesAfterSaveOnly = try FileManager.default.contentsOfDirectory(atPath: saveDir.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(filesAfterSaveOnly.count, 3)
    }
}
