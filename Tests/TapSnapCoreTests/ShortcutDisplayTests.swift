import XCTest
import Carbon.HIToolbox
import TapSnapConfig
import TapSnapSystem

/// 快捷键的可读文本（设置界面里用 kbd 标签展示）。
final class ShortcutDisplayTests: XCTestCase {
    private let cmdShift = GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift
    private let cmd = GlobalShortcut.Combo.command

    func testCommandShiftDigit() {
        // keyCode 19 = "2"；macOS 约定修饰键按 ⌃⌥⇧⌘ 的顺序、⌘ 紧贴按键。
        let binding = KeyBinding(keyCode: 19, modifiers: cmdShift)
        XCTAssertEqual(binding.displayString, "⇧⌘2")
    }

    func testCommandOnlyLetter() {
        let binding = KeyBinding(keyCode: 8, modifiers: cmd) // C
        XCTAssertEqual(binding.displayString, "⌘C")
    }

    func testModifierOrderIsControlOptionShiftCommand() {
        let all = GlobalShortcut.Combo.command
            | GlobalShortcut.Combo.shift
            | GlobalShortcut.Combo.option
            | GlobalShortcut.Combo.control
        let binding = KeyBinding(keyCode: 0, modifiers: all) // A
        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘A")
    }

    func testNoModifierShowsKeyOnly() {
        XCTAssertEqual(KeyBinding(keyCode: 49, modifiers: 0).displayString, "Space")
    }

    func testUnknownKeyCodeStillReadable() {
        // 未收录的键码不应返回空串，否则设置界面会出现空白快捷键。
        let text = KeyBinding(keyCode: 200, modifiers: cmd).displayString
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.hasPrefix("⌘"))
    }

    func testDigitsCoverAllNumberKeys() {
        // Apple 虚拟键码并非按数字连续排列：26 对应 7，25 对应 9。
        XCTAssertEqual(KeyBinding(keyCode: 18, modifiers: cmd).displayString, "⌘1")
        XCTAssertEqual(KeyBinding(keyCode: 26, modifiers: cmd).displayString, "⌘7")
        XCTAssertEqual(KeyBinding(keyCode: 29, modifiers: cmd).displayString, "⌘0")
    }

    func testRecordedFunctionKeysHaveReadableNames() {
        XCTAssertEqual(KeyBinding(keyCode: UInt32(kVK_F2), modifiers: 0).displayString, "F2")
        XCTAssertEqual(KeyBinding(keyCode: UInt32(kVK_F4), modifiers: cmd).displayString, "⌘F4")
    }
}
