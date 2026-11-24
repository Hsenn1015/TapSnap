import AppKit
import TapSnapOCR
import VisionKit
import XCTest
@testable import TapSnapApp

@MainActor
final class TranslationImageViewTests: XCTestCase {
    func testWrappedSentenceMapsToBothLinesButNotTheNextSentenceOrBlankGutter() throws {
        let first = line("Your session", x: 0.1, y: 0.75, width: 0.28)
        let second = line("has expired. Try again.", x: 0.1, y: 0.65, width: 0.54)
        let block = OCRTextBlock(lines: [first, second], normalizedBounds: first.normalizedBounds.union(second.normalizedBounds))
        let sentences = TranslationImageSentence.sentences(in: block)
        XCTAssertEqual(sentences.map(\.text), ["Your session has expired.", "Try again."])
        let wrapped = try XCTUnwrap(sentences.first)
        let next = try XCTUnwrap(sentences.last)
        XCTAssertEqual(wrapped.regions.first, first.normalizedBounds)
        XCTAssertTrue(wrapped.regions.contains { $0.contains(CGPoint(x: 0.15, y: 0.67)) })
        XCTAssertTrue(next.regions.contains { $0.contains(CGPoint(x: 0.62, y: 0.67)) })
        XCTAssertFalse(wrapped.regions.contains { $0.contains(CGPoint(x: 0.62, y: 0.67)) })
        XCTAssertFalse(wrapped.regions.contains { $0.contains(CGPoint(x: 0.25, y: 0.72)) })
    }

    func testHoverAnchorTracksImageLetterboxingAndScrolledZoom() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("需 macOS WindowServer 验证视图坐标") }
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 250, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let row = line("Retry.", x: 0.5, y: 0.5, width: 0.3)
        let document = OCRDocument(blocks: [.init(lines: [row], normalizedBounds: row.normalizedBounds)],
                                   languages: ["en-US"], sourceSize: CGSize(width: image.width, height: image.height))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 320), styleMask: .borderless,
                              backing: .buffered, defer: false)
        let view = TranslationImageViewport(frame: CGRect(x: 0, y: 0, width: 600, height: 320))
        window.contentView = view
        defer { view.stop() }
        var hover: (String?, CGRect)?
        view.onHover = { hover = ($0, $1) }
        func pointAtRow(_ zoom: CGFloat) throws -> CGRect {
            view.update(image: image, document: document, zoom: zoom, reset: 0)
            view.layoutSubtreeIfNeeded()
            let canvas = try XCTUnwrap(view.documentView)
            let source = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSImageView }.first)
            let rect = try XCTUnwrap(OCRSourceViewport.region(row.normalizedBounds, in: source.frame))
            if zoom > 1 {
                view.contentView.scroll(to: CGPoint(x: 400, y: 0))
                view.reflectScrolledClipView(view.contentView)
            }
            let location = canvas.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 0, pressure: 0))
            view.mouseMoved(with: event)
            XCTAssertEqual(hover?.0, "Retry.")
            return try XCTUnwrap(hover?.1)
        }
        let fit = try pointAtRow(1)
        XCTAssertEqual(fit.minX, 300, accuracy: 1)
        XCTAssertEqual(fit.midY, 156.25, accuracy: 1)
        let zoomed = try pointAtRow(2)
        XCTAssertEqual(zoomed.width, 2 * fit.width, accuracy: 1)
        XCTAssertEqual(zoomed.minX, 200, accuracy: 1)
        view.mouseExited(with: NSEvent())
        XCTAssertNil(hover?.0)
    }

    func testSelectedPhraseUsesTheNearestFullLineIncludingWhenWrapped() {
        let first = line("Your session", x: 0.1, y: 0.75, width: 0.28)
        let second = line("has expired. Try again.", x: 0.1, y: 0.65, width: 0.54)
        let repeated = line("Your session", x: 0.1, y: 0.35, width: 0.3)
        let block = OCRTextBlock(lines: [first, second], normalizedBounds: first.normalizedBounds.union(second.normalizedBounds))
        let sentences = TranslationImageSentence.sentences(in: block)
        func anchor(_ text: String, y: CGFloat) -> CGRect? {
            TranslationImageViewport.selectedRow(for: text, near: CGPoint(x: 0.15, y: y),
                imageSize: CGSize(width: 560, height: 200), lines: [first, second, repeated], sentences: sentences)
        }
        XCTAssertEqual(anchor("session", y: 0.37), repeated.normalizedBounds)
        XCTAssertEqual(anchor("session has", y: 0.66), second.normalizedBounds)
        XCTAssertEqual(anchor("session has", y: 0.78), first.normalizedBounds)
        XCTAssertNil(anchor("Other content", y: 0.75))
    }

    func testLiveTextReturnsTheActualSubstringFromAnImage() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty, ImageAnalyzer.isSupported else {
            throw XCTSkip("需要 macOS 实况文本和 WindowServer")
        }
        let size = CGSize(width: 560, height: 120)
        let source = NSImage(size: size, flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            ("Your session has expired." as NSString).draw(at: CGPoint(x: 20, y: 35),
                withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            return true
        }
        let image = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let view = TranslationImageViewport(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { view.stop() }
        let row = line("Your session has expired.", x: 0.03, y: 0.25, width: 0.8)
        let document = OCRDocument(blocks: [.init(lines: [row], normalizedBounds: row.normalizedBounds)],
                                   languages: ["en-US"], sourceSize: size)
        var unavailable: String?
        view.onSelectionUnavailable = { unavailable = $0 }
        // The app OCR and native selection analysis start independently when the viewer opens.
        view.update(image: image, document: nil, zoom: 1, reset: 0, languages: ["en-US"])
        view.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(view.documentView?.subviews.first?.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        for _ in 0..<120 where overlay.analysis == nil && unavailable == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        if let unavailable { throw XCTSkip(unavailable) }
        let analysis = try XCTUnwrap(overlay.analysis)
        view.update(image: image, document: document, zoom: 1, reset: 0)
        XCTAssertTrue(analysis === overlay.analysis)
        let range = try XCTUnwrap(overlay.text.range(of: "session has"))
        let selected = expectation(description: "选区返回片段而非整行 OCR")
        view.onSelection = { text, anchor in
            guard text == "session has" else { return }
            XCTAssertEqual(anchor.width, size.width * row.normalizedBounds.width, accuracy: 1)
            XCTAssertEqual(anchor.minX, size.width * row.normalizedBounds.minX, accuracy: 1)
            selected.fulfill()
        }
        overlay.selectedRanges = [range]
        XCTAssertEqual(overlay.selectedText.trimmingCharacters(in: .whitespacesAndNewlines), "session has")
        await fulfillment(of: [selected], timeout: 3)
        let scrolled = expectation(description: "已选原文行随着缩放和滚动重新定位")
        view.onSelection = { text, anchor in
            guard text == "session has", anchor.minX < 0 else { return }
            XCTAssertEqual(anchor.width, 2 * size.width * row.normalizedBounds.width, accuracy: 1)
            XCTAssertEqual(anchor.minX, 2 * size.width * row.normalizedBounds.minX - 100, accuracy: 1)
            scrolled.fulfill()
        }
        view.update(image: image, document: document, zoom: 2, reset: 0)
        view.contentView.scroll(to: CGPoint(x: 100, y: 0))
        view.reflectScrolledClipView(view.contentView)
        await fulfillment(of: [scrolled], timeout: 3)
        view.update(image: image, document: document, zoom: 1, reset: 1)
        XCTAssertTrue(overlay.selectedText.isEmpty)
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> OCRTextLine {
        OCRTextLine(text: text, normalizedBounds: CGRect(x: x, y: y, width: width, height: 0.05), confidence: 1)
    }
}
