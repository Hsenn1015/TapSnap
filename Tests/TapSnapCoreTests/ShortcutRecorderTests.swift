import AppKit
import Carbon.HIToolbox
import XCTest
import TapSnapConfig
import TapSnapSystem
@testable import TapSnapApp

final class ShortcutRecorderTests: XCTestCase {
    private final class Registration: ShortcutRegistration {
        func register() throws {}
        func unregister() {}
    }

    private let original = KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
    private let replacement = KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.option)

    private func makeController() -> (ConfigStore, ShortcutCenter, ShortcutRecorder) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        config.update { $0.shortcuts = [ShortcutAction.longShot.rawValue: original] }
        let center = ShortcutCenter(config: config, makeShortcut: { _, _ in Registration() },
                                    performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        let recorder = ShortcutRecorder(center: center)
        addTeardownBlock {
            recorder.cancel()
            center.unregisterAll()
            try? FileManager.default.removeItem(at: directory)
        }
        return (config, center, recorder)
    }

    private func event(_ code: Int, _ flags: NSEvent.ModifierFlags = [],
                       type: NSEvent.EventType = .keyDown, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: repeatKey, keyCode: UInt16(code))!
    }

    func testCapturesPhysicalKeyAndOnlySupportedModifiers() {
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_ANSI_1, [.control, .capsLock, .function])),
                       .binding(KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: GlobalShortcut.Combo.control)))
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_ANSI_R, [.command, .shift])),
                       .binding(KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)))
    }

    func testPlainTypingAndShiftOnlyAreRejectedButFunctionKeysWork() {
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_ANSI_A)), .invalid)
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_ANSI_A, [.shift])), .invalid)
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_F6)), .binding(KeyBinding(keyCode: UInt32(kVK_F6), modifiers: 0)))
    }

    func testEscapeCancelDeleteClearAndRepeatsDoNotBecomeBindings() {
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_Escape)), .cancel)
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_Delete)), .clear)
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_ANSI_1, [.control], repeatKey: true)), .ignore)
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_Command, [.command], type: .flagsChanged)), .ignore)
        XCTAssertEqual(ShortcutRecorder.input(from: event(kVK_Delete, [.command])),
                       .binding(KeyBinding(keyCode: UInt32(kVK_Delete), modifiers: GlobalShortcut.Combo.command)))
    }

    func testRecordingPreviewsKeyDownAndCommitsOnlyMatchingKeyUp() {
        let (config, center, recorder) = makeController()
        recorder.begin(.longShot)
        XCTAssertTrue(center.isRecording)
        recorder.handle(event(kVK_ANSI_K, [.command, .option]))
        XCTAssertEqual(recorder.preview, replacement.displayString)
        XCTAssertEqual(config.binding(for: .longShot), original)
        recorder.handle(event(kVK_ANSI_A, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot), original)
        XCTAssertTrue(center.isRecording)
        // 即使先松修饰键，仍保存按下时的完整组合。
        recorder.handle(event(kVK_ANSI_K, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot), replacement)
        XCTAssertNil(recorder.action)
        XCTAssertFalse(center.isRecording)
        XCTAssertFalse(recorder.hasError)
        XCTAssertTrue(recorder.message?.contains(replacement.displayString) == true)
    }

    func testDuplicateStaysInRecordingAndCanBeCorrected() {
        let (config, center, recorder) = makeController()
        config.setBinding(replacement, for: .screenshot)
        recorder.begin(.longShot)
        recorder.handle(event(kVK_ANSI_K, [.command, .option]))
        recorder.handle(event(kVK_ANSI_K, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot), original)
        XCTAssertEqual(config.binding(for: .screenshot), replacement)
        XCTAssertEqual(recorder.action, .longShot)
        XCTAssertTrue(center.isRecording)
        XCTAssertTrue(recorder.hasError)
        XCTAssertTrue(recorder.message?.contains(ShortcutAction.screenshot.displayName) == true)
        recorder.handle(event(kVK_ANSI_J, [.command, .option]))
        recorder.handle(event(kVK_ANSI_J, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot)?.keyCode, UInt32(kVK_ANSI_J))
        XCTAssertNil(recorder.action)
        XCTAssertFalse(center.isRecording)
        XCTAssertFalse(recorder.hasError)
    }

    func testEscapeCancelsPendingBindingAndRestoresShortcuts() {
        let (config, center, recorder) = makeController()
        recorder.begin(.longShot)
        recorder.handle(event(kVK_ANSI_K, [.command, .option]))
        recorder.handle(event(kVK_Escape))
        recorder.handle(event(kVK_ANSI_K, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot), original)
        XCTAssertNil(recorder.action)
        XCTAssertFalse(center.isRecording)
        XCTAssertFalse(recorder.hasError)
    }

    func testDeleteClearsOnlyAfterRelease() {
        let (config, center, recorder) = makeController()
        recorder.begin(.longShot)
        recorder.handle(event(kVK_Delete))
        XCTAssertEqual(config.binding(for: .longShot), original)
        XCTAssertEqual(recorder.preview, "清除快捷键")
        recorder.handle(event(kVK_Delete, type: .keyUp))
        XCTAssertNil(config.binding(for: .longShot))
        XCTAssertNil(recorder.action)
        XCTAssertFalse(center.isRecording)
    }

    func testLosingApplicationFocusCancelsWithoutSavingPendingInput() {
        let (config, center, recorder) = makeController()
        recorder.begin(.longShot)
        recorder.handle(event(kVK_ANSI_K, [.command, .option]))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        recorder.handle(event(kVK_ANSI_K, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot), original)
        XCTAssertNil(recorder.action)
        XCTAssertFalse(center.isRecording)
    }

    func testSwitchingRowsDiscardsPreviousPendingInput() {
        let (config, center, recorder) = makeController()
        recorder.begin(.longShot)
        recorder.handle(event(kVK_ANSI_K, [.command, .option]))
        recorder.begin(.screenshot)
        recorder.handle(event(kVK_ANSI_K, type: .keyUp))
        XCTAssertEqual(config.binding(for: .longShot), original)
        XCTAssertNil(config.binding(for: .screenshot))
        XCTAssertEqual(recorder.action, .screenshot)
        XCTAssertTrue(center.isRecording)
        recorder.handle(event(kVK_ANSI_K, [.command, .option]))
        recorder.handle(event(kVK_ANSI_K, type: .keyUp))
        XCTAssertEqual(config.binding(for: .screenshot), replacement)
        XCTAssertFalse(center.isRecording)
    }

    func testModifierOnlyPreviewAndInvalidTypingDoNotSave() {
        let (config, center, recorder) = makeController()
        recorder.begin(.longShot)
        recorder.handle(event(kVK_Command, [.command, .option], type: .flagsChanged))
        XCTAssertEqual(recorder.preview, "⌥⌘…")
        recorder.handle(event(kVK_ANSI_A))
        recorder.handle(event(kVK_ANSI_A, type: .keyUp))
        XCTAssertTrue(recorder.hasError)
        XCTAssertTrue(center.isRecording)
        XCTAssertEqual(config.binding(for: .longShot), original)
        recorder.cancel()
    }

    func testResetShortcutsPreservesOtherPreferencesAndPersists() {
        let (config, _, recorder) = makeController()
        config.update {
            $0.capture.saveFormat = "jpeg"
            $0.record.frameRate = 60
            $0.annotate.defaultLineWidth = 8
            $0.appearance.useDarkTheme = false
        }
        let before = config.settings
        recorder.cancel()
        config.resetShortcutsToDefaults()
        XCTAssertEqual(config.settings.shortcuts, TapSnapConfig.Settings.withDefaultShortcuts().shortcuts)
        XCTAssertEqual(config.settings.capture, before.capture)
        XCTAssertEqual(config.settings.record, before.record)
        XCTAssertEqual(config.settings.annotate, before.annotate)
        XCTAssertEqual(config.settings.appearance, before.appearance)
    }
}
