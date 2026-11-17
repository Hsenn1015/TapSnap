import AppKit
import Foundation
import XCTest
import TapSnapConfig
import TapSnapSystem
@testable import TapSnapApp

final class ShortcutCenterTests: XCTestCase {
    private final class Registration: ShortcutRegistration {
        var usesPriorityEventTap = false
        var registered = 0
        var unregistered = 0
        var error: Error?
        var onRegister: (() throws -> Void)?
        var onUnregister: (() -> Void)?
        let trigger: () -> Void

        init(trigger: @escaping () -> Void) { self.trigger = trigger }
        func register() throws {
            registered += 1
            if let error { throw error }
            try onRegister?()
        }
        func unregister() { unregistered += 1; onUnregister?() }
    }

    private let firstBinding = KeyBinding(keyCode: 37, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
    private let secondBinding = KeyBinding(keyCode: 40, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.option)

    private func makeConfig() -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        config.update { $0.shortcuts = [:] }
        return config
    }

    func testChangedBindingReplacesRegistrationImmediately() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [(GlobalShortcut.Combo, Registration)] = []
        var triggered: [ShortcutAction] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let shortcut = Registration(trigger: handler)
            created.append((combo, shortcut))
            return shortcut
        }, performAction: { triggered.append($0) }, reportFailure: { _ in })
        center.registerAll()
        config.setBinding(secondBinding, for: .longShot)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.first?.1.unregistered, 1)
        XCTAssertEqual(created.last?.0, secondBinding.combo)
        created.last?.1.trigger()
        XCTAssertEqual(triggered, [.longShot])
        center.unregisterAll()
    }

    func testUnrelatedSettingsDoNotReregisterShortcuts() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [Registration] = []
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            let shortcut = Registration(trigger: handler)
            created.append(shortcut)
            return shortcut
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        config.update { $0.appearance.useDarkTheme.toggle() }
        config.setBinding(firstBinding, for: .longShot)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].unregistered, 0)
        center.unregisterAll()
    }

    func testRemovingBindingUnregistersAndStoppingCancelsObservation() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [Registration] = []
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            let shortcut = Registration(trigger: handler)
            created.append(shortcut)
            return shortcut
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        config.setBinding(nil, for: .longShot)
        XCTAssertEqual(created[0].unregistered, 1)
        center.unregisterAll()
        config.setBinding(secondBinding, for: .longShot)
        XCTAssertEqual(created.count, 1)
    }

    func testRegistrationFailureIsReportedToTheUser() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var messages: [String] = []
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            let shortcut = Registration(trigger: handler)
            shortcut.error = GlobalShortcut.RegistrationError.systemRefused(-9878)
            return shortcut
        }, performAction: { _ in }, reportFailure: { messages.append($0) })
        center.registerAll()
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.contains("长截图") == true)
        XCTAssertTrue(messages.first?.contains(firstBinding.displayString) == true)
        center.unregisterAll()
    }

    func testDuplicateBindingsAreVisibleAndRemovingConflictRecovers() {
        let config = makeConfig()
        config.update {
            $0.shortcuts[ShortcutAction.longShot.rawValue] = firstBinding
            $0.shortcuts[ShortcutAction.screenshot.rawValue] = firstBinding
        }
        var registered = 0
        var failures: [ShortcutAction: String] = [:]
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            registered += 1
            return Registration(trigger: handler)
        }, performAction: { _ in }, reportFailure: { _ in })
        center.onRegistrationFailuresChanged = { failures = $0 }
        center.registerAll()
        XCTAssertEqual(registered, 0)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(config.binding(for: .longShot), firstBinding)
        config.setBinding(nil, for: .screenshot)
        XCTAssertEqual(registered, 1)
        XCTAssertTrue(failures.isEmpty)
        center.unregisterAll()
    }

    func testPermissionRetryRecoversOnlyFailedBindings() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        config.setBinding(secondBinding, for: .screenshot)
        var permissionMissing = true
        var created: [(GlobalShortcut.Combo, Registration)] = []
        var messages: [String] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            if combo == self.firstBinding.combo, permissionMissing {
                registration.error = GlobalShortcut.RegistrationError.accessibilityRequired
            }
            created.append((combo, registration))
            return registration
        }, performAction: { _ in }, reportFailure: { messages.append($0) })
        center.registerAll()
        XCTAssertTrue(messages.first?.contains("辅助功能") == true)
        XCTAssertTrue(messages.first?.contains("优先响应") == true)
        permissionMissing = false
        center.retryFailedRegistrations()
        XCTAssertTrue(center.registrationFailures.isEmpty)
        XCTAssertEqual(created.count, 3)
        let unaffected = created.filter { $0.0 == secondBinding.combo }
        XCTAssertEqual(unaffected.count, 1)
        XCTAssertEqual(unaffected.first?.1.unregistered, 0)
        center.retryFailedRegistrations()
        XCTAssertEqual(created.count, 3)
        center.unregisterAll()
    }

    func testSwappingBindingsReleasesBothBeforeRegistering() {
        let config = makeConfig()
        config.update {
            $0.shortcuts[ShortcutAction.longShot.rawValue] = firstBinding
            $0.shortcuts[ShortcutAction.screenshot.rawValue] = secondBinding
        }
        var active: Set<GlobalShortcut.Combo> = []
        var messages: [String] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            registration.onRegister = {
                if active.contains(combo) { throw GlobalShortcut.RegistrationError.alreadyRegistered }
                active.insert(combo)
            }
            registration.onUnregister = { active.remove(combo) }
            return registration
        }, performAction: { _ in }, reportFailure: { messages.append($0) })
        center.registerAll()
        config.update {
            $0.shortcuts[ShortcutAction.longShot.rawValue] = secondBinding
            $0.shortcuts[ShortcutAction.screenshot.rawValue] = firstBinding
        }
        XCTAssertEqual(active, [firstBinding.combo, secondBinding.combo])
        XCTAssertTrue(messages.isEmpty)
        center.unregisterAll()
        XCTAssertTrue(active.isEmpty)
    }

    func testMenuUsesConfiguredShortcutAndClearsRemovedBinding() {
        let item = NSMenuItem(title: "长截图", action: nil, keyEquivalent: "3")
        MenuBarController.updateShortcutMenuItem(item, title: "长截图", binding: firstBinding, failure: nil)
        XCTAssertEqual(item.keyEquivalent, "l")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        MenuBarController.updateShortcutMenuItem(item, title: "长截图", binding: secondBinding, failure: "组合键被占用")
        XCTAssertEqual(item.keyEquivalent, "k")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        XCTAssertTrue(item.title.contains("快捷键不可用"))
        XCTAssertTrue(item.toolTip?.contains("组合键被占用") == true)
        MenuBarController.updateShortcutMenuItem(item, title: "长截图", binding: nil, failure: nil)
        XCTAssertEqual(item.title, "长截图")
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertEqual(item.keyEquivalentModifierMask, [])
    }

    func testSecureInputOnlyMarksPriorityShortcutsAndKeepsMenuAction() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .screenshot)
        config.setBinding(secondBinding, for: .longShot)
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            registration.usesPriorityEventTap = combo == self.firstBinding.combo
            return registration
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        defer { center.unregisterAll() }

        XCTAssertFalse(center.isBlockedBySecureInput(.longShot, secureInputEnabled: true))
        let action = #selector(NSResponder.cancelOperation(_:))
        let item = NSMenuItem(title: "截图", action: action, keyEquivalent: "")
        let blocked = center.isBlockedBySecureInput(.screenshot, secureInputEnabled: true)
        XCTAssertTrue(blocked)
        MenuBarController.updateShortcutMenuItem(item, title: "截图", binding: firstBinding, failure: nil,
                                                 secureInputBlocked: blocked)
        XCTAssertEqual(item.action, action)
        XCTAssertTrue(item.title.contains("安全输入"))
        XCTAssertTrue(item.toolTip?.contains("仍可点击") == true)

        let unblocked = center.isBlockedBySecureInput(.screenshot, secureInputEnabled: false)
        XCTAssertFalse(unblocked)
        MenuBarController.updateShortcutMenuItem(item, title: "截图", binding: firstBinding, failure: nil,
                                                 secureInputBlocked: unblocked)
        XCTAssertEqual(item.title, "截图")
        XCTAssertEqual(item.keyEquivalent, firstBinding.combo.menuKeyEquivalent)
    }

    func testRecordingSuspendsActionsAndResumesCurrentConfiguration() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [(GlobalShortcut.Combo, Registration)] = []
        var triggered: [ShortcutAction] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            created.append((combo, registration))
            return registration
        }, performAction: { triggered.append($0) }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        center.beginRecording()
        XCTAssertTrue(center.isRecording)
        XCTAssertEqual(created[0].1.unregistered, 1)
        created[0].1.trigger()
        config.setBinding(secondBinding, for: .longShot)
        XCTAssertEqual(created.count, 1)
        center.endRecording()
        center.endRecording()
        XCTAssertFalse(center.isRecording)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].0, secondBinding.combo)
        created[1].1.trigger()
        XCTAssertEqual(triggered, [.longShot])
        center.unregisterAll()
    }

    func testQueuedCallbackFromBeforeRecordingDoesNotTriggerAfterCancellation() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [Registration] = []
        var triggered: [ShortcutAction] = []
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            let registration = Registration(trigger: handler)
            created.append(registration)
            return registration
        }, performAction: { triggered.append($0) }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        center.endRecording()
        created[0].trigger()
        XCTAssertTrue(triggered.isEmpty)
        created[1].trigger()
        XCTAssertEqual(triggered, [.longShot])
        center.unregisterAll()
    }

    func testRecordingValidatesRegistrationBeforeSavingAndReleasesProbe() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [Registration] = []
        var triggered: [ShortcutAction] = []
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            let registration = Registration(trigger: handler)
            created.append(registration)
            return registration
        }, performAction: { triggered.append($0) }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        XCTAssertNil(center.setRecordedBinding(secondBinding, for: .longShot))
        XCTAssertEqual(config.binding(for: .longShot), secondBinding)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].registered, 1)
        XCTAssertEqual(created[1].unregistered, 1)
        created[1].trigger()
        center.endRecording()
        created[1].trigger()
        XCTAssertTrue(triggered.isEmpty)
        created[2].trigger()
        XCTAssertEqual(triggered, [.longShot])
        center.unregisterAll()
    }

    func testFailedRecordingPreservesPreviousBindingAndCanRetry() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var refused = true
        var created: [(GlobalShortcut.Combo, Registration)] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            if combo == self.secondBinding.combo, refused {
                registration.error = GlobalShortcut.RegistrationError.systemReserved
            }
            created.append((combo, registration))
            return registration
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        let error = center.setRecordedBinding(secondBinding, for: .longShot)
        XCTAssertTrue(error?.contains("macOS") == true)
        XCTAssertEqual(config.binding(for: .longShot), firstBinding)
        XCTAssertEqual(created.last?.1.unregistered, 1)
        XCTAssertTrue(center.isRecording)
        refused = false
        XCTAssertNil(center.setRecordedBinding(secondBinding, for: .longShot))
        center.endRecording()
        XCTAssertEqual(config.binding(for: .longShot), secondBinding)
        XCTAssertEqual(created.last?.0, secondBinding.combo)
        XCTAssertTrue(center.registrationFailures.isEmpty)
        center.unregisterAll()
    }

    func testRecordingRejectsDuplicateWithoutChangingEitherAction() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        config.setBinding(secondBinding, for: .screenshot)
        var created = 0
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            created += 1
            return Registration(trigger: handler)
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        let error = center.setRecordedBinding(secondBinding, for: .longShot)
        XCTAssertTrue(error?.contains(ShortcutAction.screenshot.displayName) == true)
        XCTAssertEqual(config.binding(for: .longShot), firstBinding)
        XCTAssertEqual(config.binding(for: .screenshot), secondBinding)
        XCTAssertEqual(created, 2)
        center.endRecording()
        center.unregisterAll()
    }

    func testClearingBindingDoesNotProbeAndRestoresOtherShortcuts() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        config.setBinding(secondBinding, for: .screenshot)
        var created: [(GlobalShortcut.Combo, Registration)] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            created.append((combo, registration))
            return registration
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        XCTAssertNil(center.setRecordedBinding(nil, for: .longShot))
        XCTAssertNil(config.binding(for: .longShot))
        XCTAssertEqual(created.count, 2)
        center.endRecording()
        XCTAssertEqual(created.count, 3)
        XCTAssertEqual(created.last?.0, secondBinding.combo)
        center.unregisterAll()
    }

    func testStoppingCenterDuringRecordingDoesNotResumeRegistrations() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created = 0
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            created += 1
            return Registration(trigger: handler)
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        center.beginRecording()
        center.unregisterAll()
        center.endRecording()
        XCTAssertEqual(created, 1)
        XCTAssertFalse(center.isRecording)
    }

    func testFailedUpdateOutsideRecordingRestoresOldRegistration() {
        let config = makeConfig()
        config.setBinding(firstBinding, for: .longShot)
        var created: [(GlobalShortcut.Combo, Registration)] = []
        let center = ShortcutCenter(config: config, makeShortcut: { combo, handler in
            let registration = Registration(trigger: handler)
            if combo == self.secondBinding.combo {
                registration.error = GlobalShortcut.RegistrationError.systemReserved
            }
            created.append((combo, registration))
            return registration
        }, performAction: { _ in }, reportFailure: { _ in })
        center.registerAll()
        XCTAssertNotNil(center.setRecordedBinding(secondBinding, for: .longShot))
        XCTAssertFalse(center.isRecording)
        XCTAssertEqual(config.binding(for: .longShot), firstBinding)
        XCTAssertEqual(created.last?.0, firstBinding.combo)
        XCTAssertEqual(created.last?.1.registered, 1)
        center.unregisterAll()
    }

    func testRecordedBindingSurvivesReloadWithoutChangingOtherSettings() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let config = ConfigStore(fileURL: file)
        config.update { $0.capture.saveFormat = "heic" }
        let center = ShortcutCenter(config: config, makeShortcut: { _, handler in
            Registration(trigger: handler)
        }, performAction: { _ in }, reportFailure: { _ in })
        XCTAssertNil(center.setRecordedBinding(secondBinding, for: .longShot))
        let reloaded = ConfigStore(fileURL: file)
        XCTAssertEqual(reloaded.binding(for: .longShot), secondBinding)
        XCTAssertEqual(reloaded.settings.capture.saveFormat, "heic")
        XCTAssertEqual(reloaded.binding(for: .screenshot), config.binding(for: .screenshot))
    }
}
