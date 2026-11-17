import AppKit
import TapSnapConfig
import TapSnapScreen
import XCTest
@testable import TapSnapApp

@MainActor
final class CaptureFeatureCompletionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func screen(id: UInt32, frame: CGRect) -> ScreenDescriptor {
        ScreenDescriptor(id: id, frame: frame, visibleFrame: frame, scale: 2,
                         isMain: id == 1, localizedName: "Screen \(id)")
    }

    func testPresetCRUDPersistsCompleteCaptureAndOutputSettings() throws {
        let file = try directory().appendingPathComponent("presets.json")
        let store = ScreenshotPresetStore(fileURL: file)
        var preset = ScreenshotPreset(name: "聊天区域", rect: CGRect(x: -100, y: 40, width: 800, height: 600),
                                      screenID: 42, format: "jpeg", autoSave: true)
        try store.save(preset)
        XCTAssertEqual(ScreenshotPresetStore(fileURL: file).presets, [preset])
        preset.name = "工作聊天"
        preset.autoSave = false
        try store.save(preset)
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(ScreenshotPresetStore(fileURL: file).presets, [preset])
        try store.remove(id: preset.id)
        XCTAssertTrue(ScreenshotPresetStore(fileURL: file).presets.isEmpty)
    }

    func testPresetSaveFailureDoesNotPublishAnUnsavedPreset() throws {
        let file = try directory().appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let store = ScreenshotPresetStore(fileURL: file.appendingPathComponent("presets.json"))
        XCTAssertThrowsError(try store.save(ScreenshotPreset(name: "失败")))
        XCTAssertTrue(store.presets.isEmpty)
    }

    func testPresetScreenResolutionHonorsIDAndDetectsDisconnectedScreens() {
        let main = screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let external = screen(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        var preset = ScreenshotPreset(name: "扩展屏", rect: CGRect(x: -1800, y: 20, width: 500, height: 400), screenID: 2)
        XCTAssertEqual(CaptureCoordinator.screen(for: preset, among: [main, external]), external)
        XCTAssertNil(CaptureCoordinator.screen(for: preset, among: [main]))
        preset.screenID = nil
        XCTAssertEqual(CaptureCoordinator.screen(for: preset, among: [main, external]), external)
    }

    func testPresetOutputOverridesApplyToOneCaptureWithoutChangingGlobalSettings() throws {
        let directory = try directory()
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update {
            $0.capture.autoCopyToClipboard = false
            $0.capture.autoSaveToFile = false
            $0.capture.saveFormat = "png"
            $0.capture.saveDirectory = directory.appendingPathComponent("output").path
        }
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let editor = EditController(environment: AppEnvironment(config: config), image: context.makeImage()!,
                                    scale: 1, style: EditItemStyle(),
                                    outputOptions: ScreenshotOutputOptions(format: "jpeg", autoSave: true))
        editor.perform(.confirm)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("output"),
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].pathExtension, "jpg")
        XCTAssertEqual(Array(try Data(contentsOf: files[0]).prefix(2)), [0xFF, 0xD8])
        XCTAssertFalse(config.settings.capture.autoSaveToFile)
        XCTAssertEqual(config.settings.capture.saveFormat, "png")
    }

    func testWindowSelectionUsesFrontmostWindowAndClipsToSelectedDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let front = CGRect(x: -100, y: 100, width: 700, height: 500)
        let back = CGRect(x: 200, y: 200, width: 100, height: 100)
        XCTAssertEqual(SelectionOverlayView.windowRegion(at: CGPoint(x: 250, y: 250),
            regions: [front, back], bounds: bounds), CGRect(x: 0, y: 100, width: 600, height: 500))
        XCTAssertNil(SelectionOverlayView.windowRegion(at: CGPoint(x: 900, y: 20),
            regions: [front, back], bounds: bounds))
    }

    func testWindowFirstClickSelectsAndReturnConfirmsWithoutDragging() {
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let rect = CGRect(x: 80, y: 100, width: 300, height: 200)
        view.selectsWindows = true
        view.windowRegions = [rect]
        var result: CGRect?
        view.onFinish = { result = $0 }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 150, y: 150),
                                      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: click)
        let confirm = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36)!
        view.keyDown(with: confirm)
        XCTAssertEqual(result, rect)
        view.stopBorderAnimation()
    }

    func testCaptureFilterCombinesCurrentAppExplicitWindowsAndDesktopIcons() {
        let options = ScreenCaptureService.Options(excludingCurrentApplication: true,
                                                    excludedWindowIDs: [50], hideDesktopIcons: true)
        let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        XCTAssertTrue(ScreenCaptureService.shouldExcludeWindow(id: 1, processID: 20, layer: 0,
            options: options, currentProcessID: 20))
        XCTAssertTrue(ScreenCaptureService.shouldExcludeWindow(id: 50, processID: 30, layer: 0,
            options: options, currentProcessID: 20))
        XCTAssertTrue(ScreenCaptureService.shouldExcludeWindow(id: 3, processID: 30, layer: desktopLayer,
            options: options, currentProcessID: 20))
        XCTAssertFalse(ScreenCaptureService.shouldExcludeWindow(id: 4, processID: 30, layer: 0,
            options: options, currentProcessID: 20))
        XCTAssertFalse(ScreenCaptureService.shouldExcludeWindow(id: 3, processID: 30, layer: desktopLayer,
            options: .init(), currentProcessID: 20))
    }
}
