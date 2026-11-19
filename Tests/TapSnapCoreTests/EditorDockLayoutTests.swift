import AppKit
import SwiftUI
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapScreen
import XCTest
@testable import TapSnapApp

@MainActor
final class EditorDockLayoutTests: XCTestCase {
    func testNativeEditorAlignsCanvasOnNegativeOriginDisplayAndKeepsDockBelow() throws {
        let screen = ScreenDescriptor(id: 2, frame: CGRect(x: -1920, y: -360, width: 1920, height: 1080),
                                      visibleFrame: .zero, scale: 2, isMain: false, localizedName: "扩展屏")
        let appKitScreen = screen.appKitFrame(primaryDisplayHeight: 900)
        let visible = appKitScreen.insetBy(dx: 0, dy: 30)
        let capture = CGRect(x: -1799.8, y: -248.7, width: 480.3, height: 210.7)
        let selection = try XCTUnwrap(EditController.captureImageFrame(
            capture: capture, capturedScreen: screen, screen: appKitScreen, canvasSize: CGSize(width: 480.5, height: 210.5)
        ))
        XCTAssertEqual(selection, CGRect(x: -1800, y: 938, width: 480.5, height: 210.5))
        let content = editorContent(over: selection, visible: visible)
        let canvas = content.insetBy(dx: 6, dy: 6)
        XCTAssertEqual(canvas.minY + 44, selection.minY, accuracy: 0.5)
        XCTAssertEqual(canvas.minX, selection.minX, accuracy: 0.5)
        XCTAssertEqual(canvas.width, selection.width)
        XCTAssertEqual(canvas.height - 44, selection.height)
        XCTAssertTrue(visible.contains(CGRect(x: content.minX, y: content.minY,
                                              width: content.width, height: content.height + 32)))
    }

    func testSmallSelectionAtBottomRightFitsInsideNativeWindowWithDockBelow() throws {
        let screenFrame = CGRect(x: 1400, y: -200, width: 900, height: 760)
        let visible = screenFrame.insetBy(dx: 0, dy: 38)
        let screen = ScreenDescriptor(id: 3, frame: CGRect(x: 1400, y: 340, width: 900, height: 760),
                                      visibleFrame: visible, scale: 1, isMain: false, localizedName: "扩展屏")
        let capture = CGRect(x: 2240, y: 1060, width: 60, height: 24)
        let selection = try XCTUnwrap(EditController.captureImageFrame(
            capture: capture, capturedScreen: screen, screen: screenFrame, canvasSize: capture.size
        ))
        XCTAssertEqual(selection, CGRect(x: 2240, y: -184, width: 60, height: 24))
        let content = editorContent(over: selection, visible: visible)
        XCTAssertEqual(content.minY, visible.minY)
        XCTAssertEqual(content.maxX, visible.maxX)
        let canvas = CanvasLayout(canvas: capture.size, in: CGSize(width: content.width - 12, height: content.height - 56))
        XCTAssertEqual(canvas.fitted, capture.size)
        XCTAssertEqual(canvas.scale, 1)
        XCTAssertTrue(visible.contains(CGRect(x: content.minX, y: content.minY,
                                              width: content.width, height: content.height + 32)))
    }

    func testFullScreenCaptureFitsNativeChromeAndKeepsImageAspectRatio() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 60, width: 1440, height: 810)
        let screen = ScreenDescriptor(id: 1, frame: screenFrame, visibleFrame: visible,
                                      scale: 2, isMain: true, localizedName: "内置屏")
        let selection = try XCTUnwrap(EditController.captureImageFrame(
            capture: screen.frame, capturedScreen: screen, screen: screenFrame, canvasSize: screen.frame.size
        ))
        XCTAssertEqual(selection, screenFrame)
        let content = editorContent(over: selection, visible: visible)
        XCTAssertTrue(visible.contains(CGRect(x: content.minX, y: content.minY,
                                              width: content.width, height: content.height + 32)))
        let canvas = CanvasLayout(canvas: selection.size, in: CGSize(width: content.width - 12, height: content.height - 56))
        XCTAssertGreaterThan(canvas.scale, 0)
        XCTAssertLessThan(canvas.scale, 1)
        XCTAssertEqual(canvas.fitted.width / canvas.fitted.height, selection.width / selection.height, accuracy: 0.001)
    }

    func testCapturedImageOpensInMovableNativeWindowAndKeepsPositionWithPrivacyStatus() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.last)
        let screenID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let scale = screen.backingScaleFactor
        let screenRect = CGDisplayBounds(screenID.uint32Value)
        let descriptor = ScreenDescriptor(id: screenID.uint32Value, frame: screenRect, visibleFrame: screen.visibleFrame,
                                          scale: scale, isMain: true, localizedName: screen.localizedName)
        let width = 92 + 1 / scale, height = 58 + 1 / scale
        let offsetX = 112 + 1 / scale, offsetY = 124 + 1 / scale
        let capture = CGRect(x: screenRect.minX + offsetX, y: screenRect.minY + offsetY, width: width, height: height)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(capture.width * scale), height: Int(capture.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let config = ConfigStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let controller = EditController(environment: AppEnvironment(config: config), image: try XCTUnwrap(bitmap.makeImage()),
                                        scale: scale, style: EditItemStyle(), captureRect: capture, captureScreen: descriptor)
        controller.scanPrivacy()
        let window = controller.makeWindow()
        defer { controller.privacy.cancel(); window.delegate = nil; window.close() }
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .resizable]))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        let host = try XCTUnwrap(window.contentView)
        let expected = CGRect(x: screen.frame.minX + offsetX, y: screen.frame.maxY - offsetY - height,
                              width: width, height: height)
        func checkCanvas(at expected: CGRect) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
            let canvas = try XCTUnwrap(canvasView(in: host))
            let actual = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
            XCTAssertEqual(actual.midX, expected.midX, accuracy: 1)
            XCTAssertEqual(actual.midY, expected.midY, accuracy: 1)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        }
        try checkCanvas(at: expected)
        XCTAssertNotEqual(controller.privacy.phase, .idle)
        let origin = window.frame.origin
        window.setFrameOrigin(CGPoint(x: origin.x + 70, y: origin.y - 32))
        try checkCanvas(at: expected.offsetBy(dx: 70, dy: -32))
        let output = try controller.document.render()
        XCTAssertEqual(output.width, bitmap.width)
        XCTAssertEqual(output.height, bitmap.height)
    }

    private func editorContent(over selection: CGRect, visible: CGRect) -> CGRect {
        let size = EditController.contentSize(for: selection.size, screen: visible.size, titlebarHeight: 32,
                                              toolbarHeight: 44, nearCapture: true)
        return EditController.positionEditor(over: selection, contentSize: size, titlebarHeight: 32,
                                             toolbarHeight: 44, statusHeight: 0, visible: visible)
    }

    func testOpenedEditorFitsImageWithSixPointInsetsAndKeepsPixelSize() throws {
        _ = NSApplication.shared
        let config = ConfigStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 760, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = EditController(environment: AppEnvironment(config: config), image: try XCTUnwrap(bitmap.makeImage()),
                                        scale: 2, style: EditItemStyle())
        let window = controller.makeWindow()
        defer { window.delegate = nil; window.close() }
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        host.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(canvasView(in: host))
        let frame = host.convert(canvas.bounds, from: canvas)
        XCTAssertEqual(canvas.displayScale, 1, accuracy: 0.01)
        XCTAssertEqual(frame.width, 600, accuracy: 0.5)
        XCTAssertEqual(frame.height, 380, accuracy: 0.5)
        XCTAssertEqual(frame.minX, 6, accuracy: 0.5)
        XCTAssertEqual(host.bounds.maxX - frame.maxX, 6, accuracy: 0.5)
        let topInset = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        let bottomInset = host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY
        XCTAssertEqual(topInset, 6, accuracy: 0.5)
        XCTAssertEqual(bottomInset, 50, accuracy: 0.5)
        XCTAssertEqual(window.subtitle, "1200 × 760")
        let viewport = try XCTUnwrap(controller.canvasViewport)
        XCTAssertFalse(viewport.hasHorizontalScroller)
        XCTAssertFalse(viewport.hasVerticalScroller)
        let rendered = try controller.document.render()
        XCTAssertEqual(rendered.width, 1200)
        XCTAssertEqual(rendered.height, 760)
    }

    func testWindowSizingCapsTallAndWideImagesAndRetainsRoomForSmallImageTools() {
        let screen = CGSize(width: 900, height: 760)
        for canvas in [CGSize(width: 800, height: 1800), CGSize(width: 2000, height: 600),
                       CGSize(width: 90, height: 36)] {
            let size = EditController.contentSize(for: canvas, screen: screen, titlebarHeight: 32, toolbarHeight: 44)
            let layout = CanvasLayout(canvas: canvas, in: CGSize(width: size.width - 12, height: size.height - 56))
            XCTAssertGreaterThanOrEqual(size.width, 288)
            XCTAssertLessThanOrEqual(size.width, screen.width * 0.9)
            XCTAssertLessThanOrEqual(size.height + 32, screen.height * 0.85)
            XCTAssertEqual(layout.fitted.width / layout.fitted.height, canvas.width / canvas.height, accuracy: 0.001)
            if canvas.width >= 288 { XCTAssertLessThanOrEqual(layout.scale, 1) }
        }
        let small = EditController.contentSize(for: CGSize(width: 90, height: 36), screen: screen,
                                               titlebarHeight: 32, toolbarHeight: 44)
        XCTAssertEqual(small, CGSize(width: 288, height: 144))
    }

    func testRenderedEditorKeepsCanvasGeometryAcrossSelectionWithoutScrollbars() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = EditController(environment: AppEnvironment(config: config), image: try XCTUnwrap(bitmap.makeImage()),
                                        scale: 1, style: EditItemStyle())
        let host = NSHostingView(rootView: EditCanvasView(controller: controller))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let canvas = try XCTUnwrap(canvasView(in: host))
        let initial = host.convert(canvas.bounds, from: canvas)
        XCTAssertGreaterThan(initial.height, 0)
        let top = ArrowItem(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 150, y: 60))
        let bottom = ArrowItem(start: CGPoint(x: 650, y: 490), end: CGPoint(x: 850, y: 580))
        for item in [top, bottom] {
            controller.add(item)
            settle()
            let frame = host.convert(canvas.bounds, from: canvas)
            XCTAssertEqual(frame, initial)

        }
        let viewport = try XCTUnwrap(controller.canvasViewport)
        XCTAssertFalse(viewport.hasHorizontalScroller)
        XCTAssertFalse(viewport.hasVerticalScroller)
    }

    func testZoomKeepsPointerOnImageAndMapsAnnotationAndCropToOriginalPixels() throws {
        _ = NSApplication.shared
        let config = ConfigStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = EditController(environment: AppEnvironment(config: config), image: try XCTUnwrap(bitmap.makeImage()),
                                        scale: 2, style: EditItemStyle())
        let window = controller.makeWindow()
        defer { window.delegate = nil; window.close() }
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(controller.canvasViewport)
        let canvas = try XCTUnwrap(canvasView(in: viewport))
        let clip = viewport.contentView
        let initialScale = canvas.displayScale
        let anchor = CGPoint(x: 110, y: 95)

        func clipPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: clip.bounds.minX + p.x, y: clip.bounds.minY + p.y) }
        func documentPoint(_ p: CGPoint) -> CGPoint {
            let point = canvas.convert(clipPoint(p), from: clip)
            return CGPoint(x: point.x / canvas.displayScale, y: point.y / canvas.displayScale)
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: clip.convert(clipPoint(p), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func drag(from: CGPoint, to: CGPoint) throws {
            canvas.mouseDown(with: try mouse(.leftMouseDown, from))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, to))
            canvas.mouseUp(with: try mouse(.leftMouseUp, to))
        }

        let originalPoint = documentPoint(anchor)
        viewport.zoom(by: 2, at: anchor)
        XCTAssertEqual(canvas.displayScale, initialScale * 2, accuracy: 0.01)
        XCTAssertEqual(documentPoint(anchor).x, originalPoint.x, accuracy: 0.5)
        XCTAssertEqual(documentPoint(anchor).y, originalPoint.y, accuracy: 0.5)
        XCTAssertTrue(viewport.hasHorizontalScroller)
        XCTAssertTrue(viewport.hasVerticalScroller)

        let end = CGPoint(x: anchor.x + 60, y: anchor.y + 48)
        let expected = CGRect(origin: documentPoint(anchor),
                              size: CGSize(width: 60 / canvas.displayScale, height: 48 / canvas.displayScale))
        controller.perform(.rectangle)
        try drag(from: anchor, to: end)
        XCTAssertEqual(controller.document.items.first?.bounds, expected)
        XCTAssertEqual(try controller.document.render().width, 800)
        XCTAssertEqual(try controller.document.render().height, 600)

        controller.perform(.crop)
        try drag(from: anchor, to: end)
        XCTAssertEqual(controller.document.cropRect, expected)
        let output = try controller.document.render()
        XCTAssertEqual(output.width, Int((expected.width * 2).rounded()))
        XCTAssertEqual(output.height, Int((expected.height * 2).rounded()))

        XCTAssertTrue(canvas.scrollToVisible(CGRect(x: canvas.bounds.maxX - 4, y: canvas.bounds.maxY - 4, width: 4, height: 4)))
        XCTAssertEqual(canvas.visibleRect.maxX, canvas.bounds.maxX, accuracy: 1)
        XCTAssertEqual(canvas.visibleRect.maxY, canvas.bounds.maxY, accuracy: 1)
        config.update {
            var bindings = OperationShortcut.defaults
            bindings[OperationShortcut.fitImage.id] = KeyBinding(keyCode: 38, modifiers: 0)
            $0.operationShortcuts = bindings
        }
        let oldFit = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "0", charactersIgnoringModifiers: "0",
            isARepeat: false, keyCode: 29))
        XCTAssertFalse(controller.handleKeyEvent(oldFit))
        let fit = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j",
            isARepeat: false, keyCode: 38))
        XCTAssertTrue(controller.handleKeyEvent(fit))
        XCTAssertEqual(canvas.displayScale, initialScale, accuracy: 0.01)
        XCTAssertEqual(clip.bounds.origin, .zero)
        XCTAssertEqual(controller.document.cropRect, expected)
    }

    private func canvasView(in view: NSView) -> EditItemLayerView? {
        if let canvas = view as? EditItemLayerView { return canvas }
        return view.subviews.lazy.compactMap { self.canvasView(in: $0) }.first
    }
}
