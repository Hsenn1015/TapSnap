import Foundation
import XCTest
import TapSnapConfig
import TapSnapSystem

final class ShortcutMigrationTests: XCTestCase {
    private let modifiers = GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift

    private func load(_ settings: Settings) throws -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: file)
        return ConfigStore(fileURL: file)
    }

    func testDefaultLongShotDoesNotUseSystemScreenshotKey() {
        XCTAssertEqual(Settings.withDefaultShortcuts().shortcuts["longShot"],
                       KeyBinding(keyCode: 37, modifiers: modifiers))
    }

    func testDefaultScreenshotUsesControlOne() {
        XCTAssertEqual(Settings.withDefaultShortcuts().shortcuts["screenshot"],
                       KeyBinding(keyCode: 18, modifiers: GlobalShortcut.Combo.control))
    }

    func testOldShippedScreenshotBindingMigratesToControlOne() throws {
        var settings = Settings.withDefaultShortcuts()
        for (version, oldModifiers) in [(2, modifiers), (3, GlobalShortcut.Combo.command)] {
            settings.schemaVersion = version
            settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: oldModifiers)
            let config = try load(settings)
            XCTAssertEqual(config.binding(for: .screenshot), KeyBinding(keyCode: 18, modifiers: GlobalShortcut.Combo.control))
            XCTAssertEqual(config.settings.schemaVersion, Settings.currentSchemaVersion)
            XCTAssertEqual(config.binding(for: .longShot), settings.shortcuts["longShot"])
        }
    }

    func testScreenshotMigrationPreservesCustomAndDisabledBindings() throws {
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 2
        settings.shortcuts["screenshot"] = KeyBinding(keyCode: 40, modifiers: modifiers)
        XCTAssertEqual(try load(settings).binding(for: .screenshot), settings.shortcuts["screenshot"])
        settings.shortcuts.removeValue(forKey: "screenshot")
        XCTAssertNil(try load(settings).binding(for: .screenshot))
    }

    func testScreenshotMigrationDoesNotTakeAnotherActionsBinding() throws {
        var settings = Settings.withDefaultShortcuts()
        for (version, oldModifiers) in [(2, modifiers), (3, GlobalShortcut.Combo.command)] {
            settings.schemaVersion = version
            settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: oldModifiers)
            settings.shortcuts["showHistory"] = KeyBinding(keyCode: 18, modifiers: GlobalShortcut.Combo.control)
            XCTAssertEqual(try load(settings).binding(for: .screenshot), settings.shortcuts["screenshot"])
        }
    }

    func testBindingsThatWereCustomForTheirVersionArePreserved() throws {
        for (version, customModifiers) in [(2, GlobalShortcut.Combo.command), (3, modifiers)] {
            var settings = Settings.withDefaultShortcuts()
            settings.schemaVersion = version
            settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: customModifiers)
            XCTAssertEqual(try load(settings).binding(for: .screenshot), settings.shortcuts["screenshot"])
        }
    }

    func testOldShippedLongShotBindingMigratesToL() throws {
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 1
        settings.shortcuts["longShot"] = KeyBinding(keyCode: 20, modifiers: modifiers)
        settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: modifiers)
        let config = try load(settings)
        XCTAssertEqual(config.binding(for: .longShot), KeyBinding(keyCode: 37, modifiers: modifiers))
        XCTAssertEqual(config.binding(for: .screenshot), KeyBinding(keyCode: 18, modifiers: GlobalShortcut.Combo.control))
    }

    func testCustomAndDisabledBindingsArePreserved() throws {
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 1
        settings.shortcuts["longShot"] = KeyBinding(keyCode: 40, modifiers: modifiers)
        settings.shortcuts.removeValue(forKey: "screenshot")
        let config = try load(settings)
        XCTAssertEqual(config.binding(for: .longShot), settings.shortcuts["longShot"])
        XCTAssertNil(config.binding(for: .screenshot))
    }

    func testDisabledLongShotIsNotRestored() throws {
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 1
        settings.shortcuts.removeValue(forKey: "longShot")
        XCTAssertNil(try load(settings).binding(for: .longShot))
    }

    func testMigrationDoesNotAssignAnAlreadyUsedCombination() throws {
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 1
        settings.shortcuts["longShot"] = KeyBinding(keyCode: 20, modifiers: modifiers)
        settings.shortcuts["screenshot"] = KeyBinding(keyCode: 37, modifiers: modifiers)
        XCTAssertEqual(try load(settings).binding(for: .longShot), settings.shortcuts["longShot"])
    }
}
