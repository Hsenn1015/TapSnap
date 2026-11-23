import AppKit
import XCTest
import TapSnapConfig
import TapSnapCore
import TapSnapSystem
@testable import TapSnapApp

final class PinHistoryPersistenceTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TapSnap-PinTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func config(at directory: URL) -> ConfigStore {
        ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
    }

    private func image(_ shade: CGFloat = 1, size: Int = 8) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    func testMovedPinPublishesItsCurrentTopLeftAndScale() throws {
        let root = directory()
        let config = config(at: root)
        config.update { $0.pin.snapToEdges = false }
        let manager = PinGroupManager(config: config, storageDirectory: root.appendingPathComponent("pins"),
                                      presentsWindows: false)
        let pin = manager.show(image(), at: .zero, scale: 2)
        manager.updatePosition(pin.id, frame: CGRect(x: -350, y: 70, width: 4, height: 4))
        let moved = try XCTUnwrap(manager.items.first)
        let copied = try XCTUnwrap(PinTransfer.pasteboardItem(for: moved.image, metadata: moved.clipMeta))
        let (decoded, metadata) = try XCTUnwrap(PinTransfer.bitmapPayload(from: [copied]))
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        XCTAssertEqual(metadata?.sourceTopLeft, CGPoint(x: -350, y: desktopTop - 74))
        XCTAssertEqual(metadata?.scale, 2)
        XCTAssertEqual(metadata?.kind, .pin)
        XCTAssertEqual(decoded.height, 8)
    }

    func testExternalAndIncompatibleClipboardMetadataKeepImageWithoutPlacement() throws {
        let image = image()
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let meta = ClipMetaData(kind: .screenshot, pixelWidth: image.width, pixelHeight: image.height, scale: 2,
                                sourceTopLeft: CGPoint(x: -120, y: 310))
        let metadataType = NSPasteboard.PasteboardType(ClipMetaData.pasteboardType)
        var mismatched = meta
        mismatched.pixelWidth += 1
        var badScale = meta
        badScale.scale = 0
        for stored in [nil, mismatched, badScale, meta] {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let stored {
                item.setString(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self), forType: metadataType)
            }
            // Another item can carry valid metadata for a different image.
            let other = NSPasteboardItem()
            other.setString(String(decoding: try JSONEncoder().encode(meta), as: UTF8.self), forType: metadataType)
            let (decoded, placement) = try XCTUnwrap(PinTransfer.bitmapPayload(from: [other, item]))
            XCTAssertEqual(decoded.width, image.width)
            XCTAssertEqual(placement, stored == meta ? meta : nil)
        }
    }

    @MainActor
    func testSourceWindowIsDismissedAfterTheNewPinShowsItsImage() throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("窗口交接测试需要 WindowServer") }
        let root = directory()
        let manager = PinGroupManager(config: config(at: root), storageDirectory: root)
        let pixels = image(size: 24)
        let rect = CGRect(x: screen.visibleFrame.midX.rounded(), y: screen.visibleFrame.midY.rounded(),
                          width: 24, height: 24)
        let topLeft = CGPoint(x: rect.minX, y: screen.frame.maxY - rect.maxY)
        let source = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        source.level = .screenSaver
        source.orderFrontRegardless()
        defer { source.orderOut(nil); manager.closeAll(); manager.flushPersistence() }

        manager.show(pixels, from: topLeft, scale: 1) {
            let pin = app.windows.compactMap { $0 as? PinPanel }.first {
                ($0.contentView as? PinImageView)?.item.image === pixels
            }
            XCTAssertTrue(source.isVisible)
            XCTAssertEqual(pin?.isVisible, true)
            XCTAssertTrue((pin?.contentView?.layer?.contents as AnyObject?) === pixels)
            XCTAssertEqual(pin?.frame, rect)
            source.orderOut(nil)
        }
        XCTAssertFalse(source.isVisible)
    }

    func testPinsAndClosedStackRestoreImagesGroupsAndEditedState() throws {
        let root = directory()
        let config = config(at: root)
        config.update { $0.pin.snapToEdges = false }
        let storage = root.appendingPathComponent("pins")
        let manager = PinGroupManager(config: config, storageDirectory: storage, presentsWindows: false)
        XCTAssertTrue(manager.createGroup("参考"))
        let first = manager.show(image(0.3), at: CGPoint(x: 80, y: 90), scale: 2, group: "参考")
        let second = manager.show(image(0.7), at: .zero)
        manager.setOpacity(first.id, value: 0.4)
        manager.setClickThrough(first.id, enabled: true)
        manager.updatePosition(first.id, frame: CGRect(x: 123, y: 234, width: 4, height: 4))
        manager.close(second.id)
        manager.hidesForFullScreen = true
        manager.flushPersistence()
        let restored = PinGroupManager(config: config, storageDirectory: storage, presentsWindows: false)
        let item = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(item.id, first.id)
        XCTAssertEqual(item.image.width, 8)
        XCTAssertEqual(item.frame, CGRect(x: 123, y: 234, width: 4, height: 4))
        XCTAssertEqual(item.opacity, 0.4)
        XCTAssertTrue(item.isClickThrough)
        XCTAssertEqual(item.group, "参考")
        XCTAssertTrue(restored.hidesForFullScreen)
        XCTAssertTrue(restored.canRestoreLastClosed)
        restored.restoreLastClosed()
        XCTAssertEqual(restored.items.last?.id, second.id)
        restored.flushPersistence()
    }

    func testGroupRenameMoveAndDeletePreserveImagesAcrossReload() throws {
        let root = directory()
        let config = config(at: root)
        let manager = PinGroupManager(config: config, storageDirectory: root.appendingPathComponent("pins"), presentsWindows: false)
        XCTAssertTrue(manager.createGroup(" A "))
        XCTAssertFalse(manager.createGroup("A"))
        XCTAssertFalse(manager.createGroup("  "))
        let item = manager.show(image(), at: .zero)
        manager.move(item.id, toGroup: "A")
        manager.setGroup("A", visible: false)
        XCTAssertTrue(manager.renameGroup("A", to: "B"))
        XCTAssertEqual(manager.items.first?.group, "B")
        XCTAssertFalse(manager.isGroupVisible("B"))
        manager.deleteGroup("B")
        XCTAssertNil(manager.items.first?.group)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertTrue(manager.groupNames.isEmpty)
        manager.flushPersistence()
        let restored = PinGroupManager(config: config, storageDirectory: root.appendingPathComponent("pins"), presentsWindows: false)
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertNil(restored.items.first?.group)
    }

    func testPinDefaultsAndSubsequentConfigurationChangesAreApplied() {
        let root = directory()
        let config = config(at: root)
        config.update { $0.pin.alwaysOnTop = false; $0.pin.defaultOpacity = 0.35 }
        let manager = PinGroupManager(config: config, storageDirectory: root.appendingPathComponent("pins"), presentsWindows: false)
        let item = manager.show(image(), at: .zero)
        XCTAssertFalse(item.isAlwaysOnTop)
        XCTAssertEqual(item.opacity, 0.35)
        config.update { $0.pin.alwaysOnTop = true; $0.pin.defaultOpacity = 0.8 }
        XCTAssertTrue(manager.items[0].isAlwaysOnTop)
        XCTAssertEqual(manager.items[0].opacity, 0.8)
        manager.flushPersistence()
    }

    func testRepeatedScalingUsesCurrentStateAndPersistsLatestPosition() throws {
        let root = directory()
        let config = config(at: root)
        config.update { $0.pin.snapToEdges = false }
        let storage = root.appendingPathComponent("pins")
        let manager = PinGroupManager(config: config, storageDirectory: storage, presentsWindows: false)
        let item = manager.show(image(size: 80), at: .zero)
        manager.rescale(item.id, to: 2)
        manager.rescale(item.id, to: manager.items[0].scale * 2)
        XCTAssertEqual(manager.items[0].scale, 4)
        XCTAssertEqual(manager.items[0].frame.size, CGSize(width: 20, height: 20))
        manager.updatePosition(item.id, frame: CGRect(x: -200, y: 300, width: 20, height: 20))
        manager.close(item.id)
        manager.flushPersistence()
        let restored = PinGroupManager(config: config, storageDirectory: storage, presentsWindows: false)
        XCTAssertEqual(restored.closedStack.first?.frame.origin, CGPoint(x: -200, y: 300))
        XCTAssertEqual(restored.closedStack.first?.scale, 4)
    }

    @MainActor
    func testFirstPinFrameAlreadyContainsTheUprightImageAndTransparency() throws {
        let bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        func bitmap() throws -> CGContext {
            try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        let source = try bitmap()
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        source.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        source.fill(CGRect(x: 1, y: 2, width: 3, height: 2))
        let pin = PinItem(image: try XCTUnwrap(source.makeImage()), frame: bounds)
        let view = PinImageView(item: pin)
        let layer = try XCTUnwrap(view.layer)
        XCTAssertTrue((layer.contents as AnyObject?) === pin.image)
        let expected = try bitmap(), displayed = try bitmap()
        expected.draw(pin.image, in: bounds)
        layer.render(in: displayed)
        let a = try XCTUnwrap(expected.data).assumingMemoryBound(to: UInt8.self)
        let b = try XCTUnwrap(displayed.data).assumingMemoryBound(to: UInt8.self)
        for offset in 0..<64 {
            XCTAssertEqual(Int(a[offset]), Int(b[offset]), accuracy: 1, "像素字节 \(offset)")
        }

        // 旋转、翻转后直接替换内容，不在两张图片之间叠化。
        var changed = pin
        changed.image = image(0.5)
        view.item = changed
        XCTAssertTrue((layer.contents as AnyObject?) === changed.image)
        XCTAssertNil(layer.animation(forKey: "contents"))
    }

    @MainActor
    func testCreatingAnotherPinKeepsPreviouslyRaisedPinsInOrder() throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("叠放顺序测试需要 macOS WindowServer") }
        let root = directory()
        let config = config(at: root)
        config.update { $0.pin.showShadow = false }
        let manager = PinGroupManager(config: config, storageDirectory: root.appendingPathComponent("pins"))
        defer { manager.closeAll(); manager.flushPersistence() }
        let origin = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        func open() throws -> (PinItem, Int) {
            let pin = manager.show(image(), at: origin)
            let panel = try XCTUnwrap(app.windows.compactMap { $0 as? PinPanel }.first {
                ($0.contentView as? PinImageView)?.item.id == pin.id
            })
            return (pin, panel.windowNumber)
        }
        func order(of numbers: Set<Int>) -> [Int] {
            (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue).filter(numbers.contains)
        }
        let (first, a) = try open()
        let (_, b) = try open()
        manager.reveal(first.id)
        XCTAssertEqual(order(of: [a, b]), [a, b])
        let (_, c) = try open()
        XCTAssertEqual(order(of: [a, b, c]), [c, a, b])
    }

    @MainActor
    func testPinHaloFollowsImageAndVisibility() throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("贴图光晕测试需要 macOS WindowServer") }
        let root = directory()
        let config = config(at: root)
        config.update { $0.pin.snapToEdges = false; $0.pin.showShadow = true }
        let manager = PinGroupManager(config: config, storageDirectory: root.appendingPathComponent("pins"))
        let origin = CGPoint(x: screen.visibleFrame.midX.rounded() - 80, y: screen.visibleFrame.midY.rounded() - 80)
        let item = manager.show(image(size: 160), at: origin, group: "参考")
        defer { manager.closeAll(); manager.flushPersistence() }

        let pin = try XCTUnwrap(app.windows.compactMap { $0 as? PinPanel }.first {
            ($0.contentView as? PinImageView)?.item.id == item.id
        })
        let halo = try XCTUnwrap(pin.childWindows?.first as? PinHaloPanel)
        XCTAssertEqual(pin.animationBehavior, .none)
        XCTAssertEqual(halo.animationBehavior, .none)
        XCTAssertTrue(halo.isVisible)
        XCTAssertTrue(halo.ignoresMouseEvents)
        XCTAssertFalse(halo.canBecomeKey)
        XCTAssertEqual(halo.sharingType, .none)
        XCTAssertEqual(pin.frame, item.frame)
        XCTAssertEqual(halo.frame, PinHaloPanel.frame(around: pin.frame))

        pin.setFrameOrigin(CGPoint(x: origin.x + 20, y: origin.y + 20))
        XCTAssertEqual(halo.frame, PinHaloPanel.frame(around: pin.frame))
        manager.rescale(item.id, to: 2)
        XCTAssertEqual(pin.frame.size, CGSize(width: 80, height: 80))
        XCTAssertEqual(halo.frame, PinHaloPanel.frame(around: pin.frame))
        manager.setOpacity(item.id, value: 0.5)
        manager.setAlwaysOnTop(item.id, enabled: false)
        XCTAssertEqual(halo.alphaValue, 0.5)
        XCTAssertEqual(halo.level, pin.level)

        manager.setGroup("参考", visible: false)
        XCTAssertFalse(halo.isVisible)
        XCTAssertTrue(pin.childWindows?.isEmpty ?? true)
        manager.setGroup("参考", visible: true)
        let reopenedHalo = try XCTUnwrap(pin.childWindows?.first as? PinHaloPanel)
        XCTAssertTrue(reopenedHalo.isVisible)
        config.update { $0.pin.showShadow = false }
        XCTAssertFalse(reopenedHalo.isVisible)
        XCTAssertTrue(pin.isVisible)
        XCTAssertTrue(pin.childWindows?.isEmpty ?? true)
        config.update { $0.pin.showShadow = true }
        let finalHalo = try XCTUnwrap(pin.childWindows?.first as? PinHaloPanel)
        manager.close(item.id)
        XCTAssertFalse(finalHalo.isVisible)
    }

    @MainActor
    func testPinHaloIsSubtleAndFadesToTransparent() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("贴图光晕测试需要 macOS WindowServer") }
        let pinFrame = CGRect(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.midY - 64, width: 200, height: 128)
        let halo = PinHaloPanel(pinFrame: pinFrame)
        defer { halo.close() }
        let view = try XCTUnwrap(halo.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        let middleRow = bitmap.pixelsHigh / 2
        let middleColumn = bitmap.pixelsWide / 2
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let nearEdge = Int((PinHaloPanel.padding - 2) * scale)
        let left = try XCTUnwrap(bitmap.colorAt(x: nearEdge, y: middleRow)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 1 - nearEdge, y: middleRow)?.usingColorSpace(.deviceRGB))
        let difference = abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent) + abs(left.blueComponent - right.blueComponent)
        XCTAssertGreaterThan(difference, 0.15)
        for color in [left, right] {
            XCTAssertGreaterThan(color.alphaComponent, 0.02)
            XCTAssertLessThan(color.alphaComponent, 0.20)
        }
        for (x, y) in [(0, middleRow), (bitmap.pixelsWide - 1, middleRow), (middleColumn, 0),
                       (middleColumn, bitmap.pixelsHigh - 1), (middleColumn, middleRow),
                       (Int((PinHaloPanel.padding + 2) * scale), middleRow)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            XCTAssertLessThan(color.alphaComponent, 0.01)
        }
    }

    func testTransformReplacesPersistedImageAndCleansOrphanFile() throws {
        let root = directory()
        let manager = PinGroupManager(config: config(at: root), storageDirectory: root.appendingPathComponent("pins"), presentsWindows: false)
        let item = manager.show(image(), at: .zero)
        manager.flushPersistence()
        let previous = item.imageID
        manager.rotate(item.id, clockwise: true)
        manager.flushPersistence()
        XCTAssertNotEqual(manager.items.first?.imageID, previous)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("pins"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, 1)
        XCTAssertFalse(files.contains { $0.lastPathComponent == previous.uuidString + ".png" })
    }

    func testHistoryBudgetRetainsNewestPinsAndLimitsClosedStack() {
        let root = directory()
        let manager = PinGroupManager(config: config(at: root), storageDirectory: root.appendingPathComponent("pins"), presentsWindows: false, byteLimit: 600)
        let first = manager.show(image(), at: .zero)
        let second = manager.show(image(), at: .zero)
        let third = manager.show(image(), at: .zero)
        XCTAssertEqual(manager.items.map(\.id), [second.id, third.id])
        XCTAssertFalse(manager.items.contains { $0.id == first.id })
        manager.closeAll()
        XCTAssertEqual(manager.closedStack.count, 2)
        manager.flushPersistence()
    }

    func testClearClosedHistoryKeepsActiveImageAndDeletesClosedImage() throws {
        let root = directory()
        let storage = root.appendingPathComponent("pins")
        let manager = PinGroupManager(config: config(at: root), storageDirectory: storage, presentsWindows: false)
        let active = manager.show(image(0.2), at: .zero)
        let closed = manager.show(image(0.8), at: .zero)
        manager.close(closed.id)
        manager.flushPersistence()
        manager.clearClosedHistory()
        XCTAssertFalse(manager.canRestoreLastClosed)
        let restored = PinGroupManager(config: config(at: root), storageDirectory: storage, presentsWindows: false)
        XCTAssertEqual(restored.items.map(\.id), [active.id])
        XCTAssertFalse(restored.canRestoreLastClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent(closed.imageID.uuidString + ".png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appendingPathComponent(active.imageID.uuidString + ".png").path))
    }

    func testSourcePinningKeepsGlobalTopLeftAcrossDisplaysAndCrops() {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = CGRect(x: -600, y: 650, width: 600, height: 500)
        let screens = [primary, secondary]
        let capture = CGPoint(x: -75, y: -40)
        let doc = EditDocument(baseImage: image(size: 400), scale: 2, sourceTopLeft: capture)
        func frame(_ size: CGSize) -> CGRect {
            PinGroupManager.initialFrame(size: size, sourceTopLeft: doc.outputTopLeft, desktopTop: primary.maxY,
                                         screens: screens, pointer: primary.origin, visible: primary)
        }
        // 左上角位于偏移副屏，右下角跨到主屏，要保持整个选区的位置。
        XCTAssertEqual(frame(doc.canvasSize), CGRect(x: -75, y: 640, width: 200, height: 200))
        doc.cropRect = CGRect(x: 3.5, y: 20, width: 50, height: 80)
        XCTAssertEqual(frame(CGSize(width: 50, height: 80)), CGRect(x: -71.5, y: 740, width: 50, height: 80))
        XCTAssertEqual(frame(CGSize(width: 50, height: 1800)).maxY, 820)
    }

    func testMissingOrDisconnectedPinSourceFallsBackToPointer() {
        let screen = CGRect(x: -800, y: 0, width: 800, height: 600)
        let pointer = CGPoint(x: -420, y: 360)
        for source: CGPoint? in [nil, CGPoint(x: 4000, y: 3000)] {
            let frame = PinGroupManager.initialFrame(size: CGSize(width: 240, height: 180), sourceTopLeft: source,
                                                     desktopTop: 600, screens: [screen], pointer: pointer, visible: screen)
            XCTAssertEqual(CGPoint(x: frame.midX, y: frame.midY), pointer)
        }
        let large = PinGroupManager.initialFrame(size: CGSize(width: 1300, height: 1800), sourceTopLeft: nil,
                                                 desktopTop: 600, screens: [screen], pointer: pointer, visible: screen)
        XCTAssertEqual(large.minX, screen.minX)
        XCTAssertEqual(large.maxY, screen.maxY)
    }

    @MainActor
    func testOpeningPinNearEdgeKeepsCapturePositionUntilDragged() throws {
        let app = NSApplication.shared
        guard let primary = NSScreen.screens.first else { throw XCTSkip("需要 macOS WindowServer") }
        let root = directory()
        let manager = PinGroupManager(config: config(at: root), storageDirectory: root.appendingPathComponent("pins"))
        defer { manager.closeAll(); manager.flushPersistence() }
        let expected = CGRect(x: primary.visibleFrame.minX + 6, y: primary.visibleFrame.midY.rounded(), width: 40, height: 40)
        let top = CGPoint(x: expected.minX, y: primary.frame.maxY - expected.maxY)
        let item = manager.show(image(size: 80), from: top, scale: 2)
        let panel = try XCTUnwrap(app.windows.compactMap { $0 as? PinPanel }.first {
            ($0.contentView as? PinImageView)?.item.id == item.id
        })
        XCTAssertEqual(panel.frame, expected)
        panel.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        XCTAssertEqual(manager.items.first(where: { $0.id == item.id })?.frame, expected)
        XCTAssertEqual(panel.contentView?.acceptsFirstMouse(for: nil), true)
        panel.setFrameOrigin(CGPoint(x: expected.minX + 54, y: expected.minY - 20))
        panel.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        XCTAssertEqual(manager.items.first(where: { $0.id == item.id })?.frame, expected.offsetBy(dx: 54, dy: -20))
    }

    func testEdgeSnapAndDisconnectedDisplayRecoveryUseAppKitCoordinates() {
        let screen = CGRect(x: -1200, y: 90, width: 1200, height: 800)
        XCTAssertEqual(PinGroupManager.snapped(CGRect(x: -1195, y: 95, width: 100, height: 80), to: screen),
                       CGRect(x: -1200, y: 90, width: 100, height: 80))
        let untouched = CGRect(x: -1000, y: 200, width: 100, height: 80)
        XCTAssertEqual(PinGroupManager.snapped(untouched, to: screen), untouched)
        let recovered = PinGroupManager.visibleFrame(CGRect(x: 5000, y: 5000, width: 300, height: 200), screens: [screen])
        XCTAssertTrue(screen.contains(recovered))
        let large = PinGroupManager.visibleFrame(CGRect(x: 5000, y: 5000, width: 1800, height: 600), screens: [screen])
        XCTAssertEqual(large.width / large.height, 3)
        XCTAssertTrue(screen.contains(large))
    }

    func testDoubleClickOnlyClosesWhenEnabled() throws {
        _ = NSApplication.shared
        let view = PinImageView(item: PinItem(image: image(), frame: CGRect(x: 0, y: 0, width: 8, height: 8)))
        var closes = 0
        view.onClose = { closes += 1 }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 2, pressure: 1))
        view.doubleClickToClose = false
        view.mouseDown(with: click)
        XCTAssertEqual(closes, 0)
        view.doubleClickToClose = true
        view.mouseDown(with: click)
        XCTAssertEqual(closes, 1)
    }

    func testFullScreenGeometryRejectsMaximizedOrPartialWindows() {
        let screen = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        XCTAssertTrue(WindowLayerMonitor.coversScreen(screen, screens: [screen]))
        XCTAssertFalse(WindowLayerMonitor.coversScreen(screen.insetBy(dx: 0, dy: 16), screens: [screen]))
        XCTAssertFalse(WindowLayerMonitor.coversScreen(CGRect(x: -1512, y: 0, width: 800, height: 982), screens: [screen]))
    }
}
