import Foundation
import XCTest
import TapSnapActionsBar
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

    func testDevelopmentDefaultsLeaveGlobalShortcutsUnassignedAndKeepEditorShortcuts() {
        let settings = Settings.withDefaultShortcuts(includesGlobalShortcuts: false)
        XCTAssertTrue(settings.shortcuts.isEmpty)
        XCTAssertEqual(settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(OperationShortcut.action(.pin).binding(in: settings), KeyBinding(keyCode: 17, flags: .command))
    }

    func testDefaultGlobalsUseCommandAndLeaveCommandTToTheFrontmostApp() {
        let defaults = Settings.withDefaultShortcuts().shortcuts
        XCTAssertEqual(defaults["screenshot"], KeyBinding(keyCode: 18, modifiers: modifiers))
        XCTAssertEqual(defaults["pinFromClipboard"], KeyBinding(keyCode: 9, modifiers: modifiers))
        XCTAssertTrue(defaults.values.allSatisfy { $0.combo.cocoaModifiers.contains(.command) })
        XCTAssertFalse(defaults.values.contains(KeyBinding(keyCode: 17, flags: .command)))
    }

    func testOldShippedScreenshotBindingMigratesToCommandShiftOne() throws {
        var settings = Settings.withDefaultShortcuts()
        for (version, oldModifiers) in [(2, modifiers), (3, GlobalShortcut.Combo.command),
                                        (4, GlobalShortcut.Combo.control), (5, GlobalShortcut.Combo.control)] {
            settings.schemaVersion = version
            settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: oldModifiers)
            let config = try load(settings)
            XCTAssertEqual(config.binding(for: .screenshot), KeyBinding(keyCode: 18, modifiers: modifiers))
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
        for (version, oldModifiers) in [(3, GlobalShortcut.Combo.command), (5, GlobalShortcut.Combo.control)] {
            var settings = Settings.withDefaultShortcuts()
            settings.schemaVersion = version
            settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: oldModifiers)
            settings.shortcuts["showHistory"] = KeyBinding(keyCode: 18, modifiers: modifiers)
            XCTAssertEqual(try load(settings).binding(for: .screenshot), settings.shortcuts["screenshot"])
            settings.shortcuts.removeValue(forKey: "showHistory")
            settings.operationShortcuts = ["pin": KeyBinding(keyCode: 18, modifiers: modifiers)]
            XCTAssertEqual(try load(settings).binding(for: .screenshot), settings.shortcuts["screenshot"])
        }
    }

    func testBindingsThatWereCustomForTheirVersionArePreserved() throws {
        for (version, customModifiers) in [(2, GlobalShortcut.Combo.control), (3, GlobalShortcut.Combo.control),
                                           (5, GlobalShortcut.Combo.command)] {
            var settings = Settings.withDefaultShortcuts()
            settings.schemaVersion = version
            settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: customModifiers)
            XCTAssertEqual(try load(settings).binding(for: .screenshot), settings.shortcuts["screenshot"])
        }
    }

    func testPinMigrationPreservesOtherEditsAndExplicitlyClearedBindings() throws {
        let pin = OperationShortcut.action(.pin)
        let old = KeyBinding(keyCode: 35, flags: .shift)
        let new = KeyBinding(keyCode: 17, flags: .command)
        let custom = KeyBinding(keyCode: 38, flags: .option)
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 5
        XCTAssertEqual(pin.binding(in: try load(settings).settings), new)
        settings.operationShortcuts = ["pin": old, "save": custom]
        XCTAssertEqual(try load(settings).settings.operationShortcuts, ["pin": new, "save": custom])
        settings.operationShortcuts = ["pin": custom]
        XCTAssertEqual(pin.binding(in: try load(settings).settings), custom)
        settings.operationShortcuts = [:]
        XCTAssertNil(pin.binding(in: try load(settings).settings))
    }

    func testPinMigrationHonorsExistingCommandTInEitherScope() throws {
        let pin = OperationShortcut.action(.pin)
        let old = KeyBinding(keyCode: 35, flags: .shift)
        let new = KeyBinding(keyCode: 17, flags: .command)
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 5
        settings.shortcuts["showHistory"] = new
        for keys in [nil, ["pin": old]] {
            settings.operationShortcuts = keys
            let config = try load(settings)
            XCTAssertEqual(config.binding(for: .showHistory), new)
            XCTAssertEqual(pin.binding(in: config.settings), old)
        }
        settings.shortcuts.removeValue(forKey: "showHistory")
        settings.operationShortcuts = ["pin": old, "save": new]
        XCTAssertEqual(try load(settings).settings.operationShortcuts, settings.operationShortcuts)
    }

    func testOldShippedLongShotBindingMigratesToL() throws {
        var settings = Settings.withDefaultShortcuts()
        settings.schemaVersion = 1
        settings.shortcuts["longShot"] = KeyBinding(keyCode: 20, modifiers: modifiers)
        settings.shortcuts["screenshot"] = KeyBinding(keyCode: 18, modifiers: modifiers)
        let config = try load(settings)
        XCTAssertEqual(config.binding(for: .longShot), KeyBinding(keyCode: 37, modifiers: modifiers))
        XCTAssertEqual(config.binding(for: .screenshot), KeyBinding(keyCode: 18, modifiers: modifiers))
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
