import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TapSnapSystem

@MainActor
final class GlobalShortcutTests: XCTestCase {
    private let modifiers = GlobalShortcut.Combo.command | GlobalShortcut.Combo.option
        | GlobalShortcut.Combo.control | GlobalShortcut.Combo.shift

    private func makeShortcut(_ code: UInt32 = UInt32(kVK_F17), action: @escaping () -> Void = {}) -> GlobalShortcut {
        GlobalShortcut(combo: .init(keyCode: code, carbonModifiers: modifiers), onTrigger: action)
    }

    private func send(_ id: UInt32, to target: EventTargetRef, signature: OSType = 0x536E_5370) throws -> OSStatus {
        var createdEvent: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &createdEvent), noErr)
        let event = try XCTUnwrap(createdEvent)
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID), noErr)
        return SendEventToEventTarget(event, target)
    }

    func testCarbonEventReachesRegisteredHandlerExactlyOnce() throws {
        _ = NSApplication.shared
        var count = 0
        let shortcut = makeShortcut { count += 1 }
        try shortcut.register()
        defer { shortcut.unregister() }
        XCTAssertEqual(try send(shortcut.identifier, to: GetEventDispatcherTarget()), noErr)
        XCTAssertEqual(count, 1)
    }

    func testDispatcherRoutesOnlyToMatchingShortcut() throws {
        _ = NSApplication.shared
        var count = 0
        let shortcut = makeShortcut { count += 1 }
        var otherCount = 0
        let otherShortcut = makeShortcut(UInt32(kVK_F18)) { otherCount += 1 }
        try shortcut.register()
        defer { shortcut.unregister() }
        try otherShortcut.register()
        defer { otherShortcut.unregister() }
        let status = try send(shortcut.identifier, to: GetEventDispatcherTarget())
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(otherCount, 0)
    }

    func testReleasedShortcutUnregistersInsteadOfStayingInRegistry() throws {
        _ = NSApplication.shared
        var shortcut: GlobalShortcut? = makeShortcut(UInt32(kVK_F18))
        weak var released = shortcut
        try shortcut?.register()
        shortcut = nil
        XCTAssertNil(released, "注册表不应强持有快捷键，阻止析构注销")
        let replacement = makeShortcut(UInt32(kVK_F18))
        defer { replacement.unregister(); released?.unregister() }
        XCTAssertNoThrow(try replacement.register(), "释放后应能立即注册相同组合")
    }

    func testUnregisteredAndForeignEventsDoNotTriggerActions() throws {
        _ = NSApplication.shared
        var count = 0
        let shortcut = makeShortcut(UInt32(kVK_F19)) { count += 1 }
        try shortcut.register()
        let id = shortcut.identifier
        XCTAssertEqual(try send(id, to: GetEventDispatcherTarget(), signature: 0x7465_7374), OSStatus(eventNotHandledErr))
        shortcut.unregister()
        _ = try send(id, to: GetEventDispatcherTarget())
        XCTAssertEqual(count, 0)
    }

    func testSystemConflictRequiresEnabledExactCombination() {
        let combo = GlobalShortcut.Combo.commandShift(UInt32(kVK_ANSI_3))
        var entry: [String: Any] = [kHISymbolicHotKeyCode as String: NSNumber(value: combo.keyCode),
                                  kHISymbolicHotKeyModifiers as String: NSNumber(value: combo.carbonModifiers),
                                  kHISymbolicHotKeyEnabled as String: true]
        XCTAssertTrue(GlobalShortcut.conflictsWithSystemShortcut(combo, hotKeys: [entry]))
        entry[kHISymbolicHotKeyEnabled as String] = false
        XCTAssertFalse(GlobalShortcut.conflictsWithSystemShortcut(combo, hotKeys: [entry]))
        entry[kHISymbolicHotKeyEnabled as String] = true
        entry[kHISymbolicHotKeyModifiers as String] = NSNumber(value: GlobalShortcut.Combo.command)
        XCTAssertFalse(GlobalShortcut.conflictsWithSystemShortcut(combo, hotKeys: [entry]))
    }

    func testEnabledSystemScreenshotShortcutIsReportedAsReserved() throws {
        var copied: Unmanaged<CFArray>?
        XCTAssertEqual(CopySymbolicHotKeys(&copied), noErr)
        let keys = try XCTUnwrap(copied?.takeRetainedValue() as? [[String: Any]])
        let combo = GlobalShortcut.Combo.commandShift(UInt32(kVK_ANSI_3))
        guard GlobalShortcut.conflictsWithSystemShortcut(combo, hotKeys: keys) else {
            throw XCTSkip("此系统没有启用 ⇧⌘3")
        }
        let shortcut = GlobalShortcut(combo: combo, prefersPriorityOnConflict: true)
        defer { shortcut.unregister() }
        XCTAssertThrowsError(try shortcut.register()) { error in
            guard case GlobalShortcut.RegistrationError.systemReserved = error else {
                return XCTFail("应明确报告系统冲突，得到 \(error)")
            }
        }
        XCTAssertFalse(shortcut.isRegistered)
    }

    func testMenuEquivalentUsesSamePhysicalKeysAndModifiers() {
        let digit = GlobalShortcut.Combo(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: modifiers)
        XCTAssertEqual(digit.menuKeyEquivalent, "7")
        XCTAssertEqual(digit.cocoaModifiers, [.command, .option, .control, .shift])
        XCTAssertEqual(GlobalShortcut.Combo(keyCode: UInt32(kVK_F17), carbonModifiers: 0).menuKeyEquivalent,
                       String(UnicodeScalar(NSF17FunctionKey)!))
        XCTAssertEqual(GlobalShortcut.Combo(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: 0).menuKeyEquivalent,
                       String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertNil(GlobalShortcut.Combo(keyCode: 200, carbonModifiers: 0).menuKeyEquivalent)
    }

    func testPriorityConflictUsesOnlyAvailablePermission() throws {
        _ = NSApplication.shared
        let holder = makeShortcut(UInt32(kVK_F20))
        try holder.register()
        defer { holder.unregister() }
        let priority = GlobalShortcut(combo: .init(keyCode: UInt32(kVK_F20), carbonModifiers: modifiers),
                                      prefersPriorityOnConflict: true)
        defer { priority.unregister() }
        if Permissions.status(of: .accessibility) == .authorized {
            try priority.register()
            XCTAssertTrue(priority.isRegistered)
            priority.unregister()
        } else {
            XCTAssertThrowsError(try priority.register()) { error in
                guard case GlobalShortcut.RegistrationError.accessibilityRequired = error else {
                    return XCTFail("应明确说明优先响应需要权限，得到 \(error)")
                }
            }
        }
        XCTAssertFalse(priority.isRegistered)
        XCTAssertTrue(holder.isRegistered)
    }

    func testPhysicalNumberAndPunctuationKeyNames() {
        let keys: [(Int, String)] = [(kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
                                     (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"),
                                     (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
                                     (kVK_ANSI_0, "0"), (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-")]
        for (code, name) in keys {
            XCTAssertEqual(GlobalShortcut.Combo(keyCode: UInt32(code), carbonModifiers: 0).displayString, name)
        }
    }
}
