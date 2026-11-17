import Foundation
import XCTest
import TapSnapConfig
import TapSnapCore

final class BrandingCompatibilityTests: XCTestCase {
    private func bundleMetadata() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testBundleUsesTapSnapNameAndExecutableWithOriginalIdentity() throws {
        let info = try bundleMetadata()
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "TapSnap")
        XCTAssertEqual(info["CFBundleName"] as? String, "TapSnap")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "TapSnap")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.sensnap.app")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, AppPaths.bundleIdentifier)
    }

    func testBundleDeclaresNewAndLegacyURLSchemes() throws {
        let info = try bundleMetadata()
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        XCTAssertTrue(schemes.contains("tapsnap"))
        XCTAssertTrue(schemes.contains("sensnap"), "已有外部链接需要继续可用")
    }

    func testStorageRootsStayCompatibleAndNewSaveDefaultUsesTapSnap() throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory,
                                                              in: .userDomainMask).first)
        let cache = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let pictures = try XCTUnwrap(FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first)
        XCTAssertEqual(AppPaths.applicationSupport, support.appendingPathComponent("com.sensnap.app", isDirectory: true))
        XCTAssertEqual(AppPaths.caches, cache.appendingPathComponent("com.sensnap.app", isDirectory: true))
        XCTAssertEqual(AppPaths.configFile, AppPaths.applicationSupport.appendingPathComponent("settings.json"))
        XCTAssertEqual(AppPaths.defaultSaveDirectory, pictures.appendingPathComponent("TapSnap", isDirectory: true))
        XCTAssertEqual(Settings().capture.saveDirectory, AppPaths.defaultSaveDirectory.path)
    }

    func testLegacyConfigurationKeepsCustomShortcutsDisabledActionsAndSavePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tapsnap-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")

        // 固定旧版 JSON，不用新版 Settings 编码，以便发现字段或动作标识被误改。
        let legacyJSON = """
        {
          "schemaVersion": 4,
          "capture": {
            "hideDesktopIcons": false, "playShutterSound": true,
            "autoCopyToClipboard": true, "autoSaveToFile": false,
            "saveDirectory": "", "saveFormat": "png", "jpegQuality": 0.9,
            "showMagnifier": true, "showSelectionSize": true
          },
          "pin": {
            "defaultOpacity": 1, "alwaysOnTop": true, "doubleClickToClose": false,
            "showShadow": true, "snapToEdges": true
          },
          "annotate": {
            "defaultColorHex": "#FF3B30", "defaultLineWidth": 3,
            "defaultFontSize": 14, "mosaicBlockSize": 12,
            "autoMosaicDetectsFaces": false, "magnifierZoom": 2
          },
          "ocr": { "languages": ["zh-Hans", "en-US"], "autoCopyText": true, "joinLinesWithSpace": false },
          "longShot": { "autoScroll": true, "scrollStep": 200, "scrollIntervalMs": 120, "overlapRatio": 0.15 },
          "record": {
            "frameRate": 30, "includesCursor": true, "includesMicrophone": false,
            "includesSystemAudio": false, "format": "mp4"
          },
          "appearance": { "useDarkTheme": true, "toolBarPosition": "followSelection" },
          "shortcuts": {
            "screenshot": { "keyCode": 40, "modifiers": 768 },
            "longShot": { "keyCode": 31, "modifiers": 4096 }
          }
        }
        """
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any])
        for savedPath in ["/Users/example/Pictures/SenSnap", "/Volumes/Work/Capture Archive"] {
            var capture = try XCTUnwrap(fixture["capture"] as? [String: Any])
            capture["saveDirectory"] = savedPath
            fixture["capture"] = capture
            try JSONSerialization.data(withJSONObject: fixture).write(to: file)
            let config = ConfigStore(fileURL: file)
            XCTAssertEqual(config.binding(for: .screenshot), KeyBinding(keyCode: 40, modifiers: 768))
            XCTAssertEqual(config.binding(for: .longShot), KeyBinding(keyCode: 31, modifiers: 4096))
            XCTAssertNil(config.binding(for: .recordScreen), "改名不能恢复用户已解绑的快捷键")
            XCTAssertEqual(config.settings.shortcuts.count, 2)
            XCTAssertEqual(config.settings.capture.saveDirectory, savedPath)
            XCTAssertEqual(config.settings.capture.selectionBorderStyle, .aurora)
        }
    }

    func testLegacyClipboardMetadataTypeAndPayloadRemainReadable() throws {
        XCTAssertEqual(ClipMetaData.pasteboardType, "com.sensnap.app.clipboard.metadata")
        let legacyJSON = """
        {"kind":"longShot","pixelWidth":600,"pixelHeight":1800,"scale":2,
         "createdAt":0,"isPinned":true,"opacity":0.75}
        """
        let metadata = try JSONDecoder().decode(ClipMetaData.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(metadata.kind, .longShot)
        XCTAssertEqual(metadata.logicalSize, CGSize(width: 300, height: 900))
        XCTAssertTrue(metadata.isPinned)
        XCTAssertEqual(metadata.opacity, 0.75)
    }

    func testSelectionBorderStylePersistsAndUnknownStyleKeepsOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tapsnap-borders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let config = ConfigStore(fileURL: file)

        for style in SelectionBorderStyle.allCases {
            config.update { $0.capture.selectionBorderStyle = style }
            XCTAssertEqual(ConfigStore(fileURL: file).settings.capture.selectionBorderStyle, style)
        }

        let data = try Data(contentsOf: file)
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var capture = try XCTUnwrap(fixture["capture"] as? [String: Any])
        capture["selectionBorder"] = "futureStyle"
        capture["showMagnifier"] = false
        fixture["capture"] = capture
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        let loaded = ConfigStore(fileURL: file).settings.capture
        XCTAssertEqual(loaded.selectionBorderStyle, .aurora)
        XCTAssertFalse(loaded.showMagnifier)
    }
}
