import AppKit
import TapSnapConfig
import TapSnapPrivacy
import XCTest
@testable import TapSnapApp

@MainActor
final class SettingsAppearanceTests: XCTestCase {
    func testSettingsWindowAndHostedControlsFollowAppTheme() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("设置窗口测试需要 macOS WindowServer") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update { $0.appearance.useDarkTheme = false }
        let environment = AppEnvironment(config: config)
        environment.openSettings()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "TapSnap 设置" })
        defer { window.close() }

        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .aqua)

        config.update { $0.appearance.useDarkTheme = true }
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .darkAqua)

        environment.openSettings(section: .privacy)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .darkAqua)

        window.close()
        config.update { $0.appearance.useDarkTheme = false }
        environment.openSettings()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: appearances), .aqua)
    }

    func testContinuousChangeDefersDiskWriteUntilEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let config = ConfigStore(fileURL: file)
        config.update { $0.annotate.defaultLineWidth = 2 }

        config.beginContinuousChange()
        config.update { $0.annotate.defaultLineWidth = 5 }
        config.update { $0.annotate.defaultLineWidth = 8 }
        // 内存中即时更新，磁盘仍保留拖动前的值。
        XCTAssertEqual(config.settings.annotate.defaultLineWidth, 8)
        XCTAssertEqual(ConfigStore(fileURL: file).settings.annotate.defaultLineWidth, 2)

        config.endContinuousChange()
        XCTAssertEqual(ConfigStore(fileURL: file).settings.annotate.defaultLineWidth, 8)
    }

    func testPrivacySettingsPreservesAIProfileWhenDisabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let config = ConfigStore(fileURL: file)

        var custom = PrivacyAIConfiguration(provider: .custom)
        custom.baseURL = "https://example.com/v1"
        custom.model = "my-vision-model"

        config.update {
            $0.privacy.saveAIProfile(custom)
            $0.privacy.ai = custom
        }
        // 切回仅本机规则不应丢失之前填写的端点和模型。
        config.update { $0.privacy.ai = nil }

        let reloaded = ConfigStore(fileURL: file)
        XCTAssertNil(reloaded.settings.privacy.ai)
        XCTAssertEqual(reloaded.settings.privacy.savedAI(for: .custom), custom)
    }

    func testMainMenuProvidesStandardTextEditingShortcuts() throws {
        _ = NSApplication.shared
        AppDelegate.installMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let allItems = mainMenu.items.compactMap(\.submenu).flatMap(\.items)

        func hasShortcut(_ key: String, modifiers: NSEvent.ModifierFlags = .command, action: Selector) -> Bool {
            allItems.contains {
                $0.keyEquivalent == key
                    && $0.keyEquivalentModifierMask == modifiers
                    && $0.action == action
            }
        }

        XCTAssertTrue(hasShortcut("a", action: #selector(NSText.selectAll(_:))))
        XCTAssertTrue(hasShortcut("c", action: #selector(NSText.copy(_:))))
        XCTAssertTrue(hasShortcut("v", action: #selector(NSText.paste(_:))))
        XCTAssertTrue(hasShortcut("x", action: #selector(NSText.cut(_:))))
        XCTAssertTrue(hasShortcut("z", action: Selector(("undo:"))))
        XCTAssertTrue(hasShortcut("z", modifiers: [.command, .shift], action: Selector(("redo:"))))
        XCTAssertTrue(hasShortcut("w", action: #selector(NSWindow.performClose(_:))))
    }
}
