import AppKit
import CoreGraphics
import TapSnapOCR
import XCTest
@testable import TapSnapApp

@MainActor
final class TranslationReadingSessionTests: XCTestCase {
    func testSelectionWinsAndPreviousHoverCannotReplaceItsResult() throws {
        let reading = TranslationReadingSession()
        reading.show("The session has expired.", bounds: .zero, trigger: .hover)
        let old = try XCTUnwrap(reading.request)
        reading.select("session", bounds: CGRect(x: 24, y: 12, width: 6, height: 10))
        let selected = try XCTUnwrap(reading.request)
        reading.hover("Next", bounds: .zero)
        reading.finish(old.id, result: .success("过期"))
        XCTAssertEqual(reading.phase, .waiting)
        reading.finish(selected.id, result: .success("会话"))
        XCTAssertEqual(reading.focus?.text, "session")
        XCTAssertEqual(reading.phase, .translated("会话"))
        reading.select(nil, bounds: .zero)
        XCTAssertNil(reading.focus)
        reading.show("session", bounds: .zero, trigger: .hover)
        XCTAssertNil(reading.request)
        XCTAssertEqual(reading.phase, .translated("会话"))
        reading.refresh()
        XCTAssertEqual(reading.phase, .waiting)
        XCTAssertNotNil(reading.request)
    }

    func testAppleDownloadRequiresExplicitRequestAndCanRetry() throws {
        let reading = TranslationReadingSession()
        reading.show("Retry", bounds: .zero, trigger: .hover)
        let first = try XCTUnwrap(reading.request)
        XCTAssertFalse(first.allowDownload)
        reading.needsDownload(first.id)
        XCTAssertEqual(reading.phase, .languageDownload)
        XCTAssertNil(reading.request)
        reading.authorizeDownload()
        XCTAssertEqual(reading.request?.allowDownload, true)
        XCTAssertEqual(reading.focus?.trigger, .hover)
        let download = try XCTUnwrap(reading.request)
        reading.finish(download.id, result: .failure(CancellationError()))
        reading.start()
        let retry = try XCTUnwrap(reading.request)
        reading.finish(retry.id, result: .success("重试"))
        XCTAssertEqual(reading.phase, .translated("重试"))
    }

    func testLeavingBeforeHoverDelayDoesNotSendText() async throws {
        let reading = TranslationReadingSession()
        reading.hover("first", bounds: .zero)
        reading.hover(nil, bounds: .zero)
        try await Task.sleep(for: .milliseconds(490))
        XCTAssertNil(reading.focus)
        XCTAssertNil(reading.request)
    }

    func testPinnedFloatingCardSurvivesPointerLeave() async throws {
        let reading = TranslationReadingSession()
        reading.show("Pinned sentence.", bounds: .zero, trigger: .hover)
        reading.isPinned = true
        reading.hover(nil, bounds: .zero)
        reading.cardHover(false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(reading.focus?.text, "Pinned sentence.")
        reading.isPinned = false
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(reading.focus)
    }

    func testDocumentSessionAutoTranslatesBlocksSupportsInlineEditAndCaching() throws {
        let firstLine = OCRTextLine(text: "Hello world.", normalizedBounds: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1), confidence: 1)
        let secondLine = OCRTextLine(text: "Sign in again.", normalizedBounds: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1), confidence: 1)
        let firstBlock = OCRTextBlock(lines: [firstLine], normalizedBounds: firstLine.normalizedBounds)
        let secondBlock = OCRTextBlock(lines: [secondLine], normalizedBounds: secondLine.normalizedBounds)
        let document = OCRDocument(blocks: [firstBlock, secondBlock], languages: ["en-US"], sourceSize: CGSize(width: 400, height: 200))

        let session = TranslationDocumentSession()
        session.load(document: document, image: nil, autoStart: true)

        XCTAssertEqual(session.totalCount, 2)
        let job = try XCTUnwrap(session.batchJob)
        XCTAssertEqual(job.items.count, 2)
        XCTAssertTrue(session.isTranslating)

        session.finishBlock(job.id, blockID: firstBlock.id, result: .success("你好世界。"))
        XCTAssertEqual(session.completedCount, 1)
        session.finishBlock(job.id, blockID: secondBlock.id, result: .failure(CancellationError()))
        session.completeJob(job.id)
        XCTAssertTrue(session.hasFailures)
        XCTAssertEqual(session.combinedTranslatedText, "你好世界。")

        // Retry only failed block while keeping cached first block
        session.retry(blockID: secondBlock.id)
        let retryJob = try XCTUnwrap(session.batchJob)
        XCTAssertEqual(retryJob.items.map(\.id), [secondBlock.id])
        session.finishBlock(retryJob.id, blockID: secondBlock.id, result: .success("请重新登录。"))
        session.completeJob(retryJob.id)
        XCTAssertFalse(session.hasFailures)
        XCTAssertEqual(session.combinedTranslatedText, "你好世界。\n\n请重新登录。")
        XCTAssertTrue(session.combinedBilingualText.contains("Hello world.\n你好世界。"))

        // Inline edit triggers single-block retranslation
        session.retranslate(blockID: firstBlock.id, editedText: "Hello TapSnap.")
        let editJob = try XCTUnwrap(session.batchJob)
        XCTAssertEqual(editJob.items.count, 1)
        XCTAssertEqual(editJob.items.first?.text, "Hello TapSnap.")
        session.finishBlock(editJob.id, blockID: firstBlock.id, result: .success("你好 TapSnap。"))
        session.completeJob(editJob.id)
        XCTAssertEqual(session.blocks.first?.phase.translatedText, "你好 TapSnap。")

        // Editing back to previously cached text resolves immediately without creating a job
        session.retranslate(blockID: firstBlock.id, editedText: "Hello world.")
        XCTAssertNil(session.batchJob)
        XCTAssertEqual(session.blocks.first?.phase.translatedText, "你好世界。")

        // Directly edit translated text to trim redundant noise
        session.updateTranslatedText(blockID: firstBlock.id, editedTranslation: "你好世界")
        XCTAssertEqual(session.blocks.first?.phase.translatedText, "你好世界")

        // Delete a redundant block and verify copy output & undo restoration
        session.remove(blockID: firstBlock.id)
        XCTAssertEqual(session.totalCount, 1)
        XCTAssertEqual(session.deletedCount, 1)
        XCTAssertEqual(session.combinedTranslatedText, "请重新登录。")

        let restoredID = session.undoLastRemoval()
        XCTAssertEqual(restoredID, firstBlock.id)
        XCTAssertEqual(session.totalCount, 2)
        XCTAssertEqual(session.deletedCount, 0)
        XCTAssertEqual(session.blocks.first?.id, firstBlock.id)
    }

    func testBackdropSamplingDetectsDarkAndLightRegions() throws {
        func solidImage(r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            return try XCTUnwrap(ctx.makeImage())
        }

        let darkImg = try solidImage(r: 0.08, g: 0.09, b: 0.11)
        let darkSample = TranslationBlockBackdrop.sample(from: darkImg, normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        XCTAssertTrue(darkSample.isDark)

        let lightImg = try solidImage(r: 0.95, g: 0.96, b: 0.98)
        let lightSample = TranslationBlockBackdrop.sample(from: lightImg, normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        XCTAssertFalse(lightSample.isDark)
    }

    func testPanelFrameAdaptsCompactStripVsTallScreenshot() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let stripFrame = TranslationPanel.panelFrame(
            imageSize: CGSize(width: 480, height: 80),
            anchor: CGRect(x: 300, y: 400, width: 320, height: 60),
            center: CGPoint(x: 460, y: 430),
            in: visible
        )
        let tallFrame = TranslationPanel.panelFrame(
            imageSize: CGSize(width: 400, height: 800),
            anchor: CGRect(x: 300, y: 200, width: 360, height: 640),
            center: CGPoint(x: 480, y: 520),
            in: visible
        )
        XCTAssertLessThan(stripFrame.height, tallFrame.height)
        XCTAssertTrue(visible.contains(stripFrame))
        XCTAssertTrue(visible.contains(tallFrame))
    }

    func testBatchRemovalKeepOnlyTransactionalUndoAndNoiseDetector() throws {
        func makeBlock(_ text: String, y: CGFloat) -> OCRTextBlock {
            let line = OCRTextLine(text: text, normalizedBounds: CGRect(x: 0.1, y: y, width: 0.6, height: 0.05), confidence: 1)
            return OCRTextBlock(lines: [line], normalizedBounds: line.normalizedBounds)
        }

        let b1 = makeBlock("Worked for 6m>", y: 0.85)
        let b2 = makeBlock("正在编译第三方翻译 API 并运行单元测试。", y: 0.72)
        let b3 = makeBlock("156%", y: 0.60)
        let b4 = makeBlock("Worked for 7m > ○ 5/5 steps", y: 0.50)
        let b5 = makeBlock("Google 翻译支持免密通道与官方批量接口。", y: 0.35)
        let doc = OCRDocument(blocks: [b1, b2, b3, b4, b5], languages: ["zh-Hans", "en-US"], sourceSize: CGSize(width: 600, height: 400))

        let session = TranslationDocumentSession()
        // Manual mode (autoStart: false) keeps blocks idle until explicitly triggered
        session.load(document: doc, image: nil, autoStart: false)
        XCTAssertNil(session.batchJob)
        XCTAssertEqual(session.untranslatedCount, 5)

        // Smart noise detector flags status/metric/symbol fragments without touching real content
        let noise = session.suspectedNoiseIDs()
        XCTAssertEqual(noise, Set([b1.id, b3.id, b4.id]))

        // Batch delete removes all noise in one undoable transaction
        XCTAssertEqual(session.remove(blockIDs: noise), 3)
        XCTAssertEqual(session.blocks.map(\.id), [b2.id, b5.id])
        XCTAssertEqual(session.deletedCount, 3)

        // Selective translation only queues the remaining/chosen blocks
        session.startPending(for: [b2.id])
        let job = try XCTUnwrap(session.batchJob)
        XCTAssertEqual(job.items.map(\.id), [b2.id])

        // Single undo restores all 3 deleted noise blocks back in their exact original order
        _ = session.undoLastRemoval()
        XCTAssertEqual(session.blocks.map(\.id), [b1.id, b2.id, b3.id, b4.id, b5.id])
        XCTAssertEqual(session.deletedCount, 0)

        // Keep-only keeps chosen content blocks and removes all others in one transaction
        XCTAssertEqual(session.keepOnly(blockIDs: [b2.id, b5.id]), 3)
        XCTAssertEqual(session.blocks.map(\.id), [b2.id, b5.id])

        // Remove all and restore all
        XCTAssertEqual(session.removeAll(), 2)
        XCTAssertTrue(session.blocks.isEmpty)
        session.restoreAllRemoved()
        XCTAssertEqual(session.totalCount, 5)
    }
}
