import AppKit
import Carbon.HIToolbox
import Foundation
import TapSnapCore

/// 全局快捷键。
///
/// 正常使用不依赖辅助功能权限的 Carbon `RegisterEventHotKey`。
/// 调用者允许优先响应时，第三方占用的组合可回退到需要辅助功能权限的事件拦截。
public final class GlobalShortcut {
    /// 一个组合键：虚拟键码 + 修饰键（Carbon 的 cmdKey / optionKey 等）。
    public struct Combo: Codable, Hashable, Sendable {
        public var keyCode: UInt32
        public var carbonModifiers: UInt32

        public init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }

        public static let command = UInt32(cmdKey)
        public static let shift = UInt32(shiftKey)
        public static let option = UInt32(optionKey)
        public static let control = UInt32(controlKey)

        /// 例：⌘⇧2 用于「截图并贴图」。
        public static func commandShift(_ keyCode: UInt32) -> Combo {
            Combo(keyCode: keyCode, carbonModifiers: command | shift)
        }

        public var displayString: String {
            var text = ""
            if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + Self.keyName(for: keyCode)
        }

        /// 与全局注册同一组修饰键，供菜单展示与触发使用。
        public var cocoaModifiers: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if carbonModifiers & Self.command != 0 { flags.insert(.command) }
            if carbonModifiers & Self.shift != 0 { flags.insert(.shift) }
            if carbonModifiers & Self.option != 0 { flags.insert(.option) }
            if carbonModifiers & Self.control != 0 { flags.insert(.control) }
            return flags
        }

        public var menuKeyEquivalent: String? {
            switch Int(keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: return "\r"
            case kVK_Tab: return "\t"
            case kVK_Space: return " "
            case kVK_Escape: return "\u{1b}"
            case kVK_Delete: return "\u{7f}"
            case kVK_ForwardDelete: return String(UnicodeScalar(NSDeleteFunctionKey)!)
            case kVK_Home: return String(UnicodeScalar(NSHomeFunctionKey)!)
            case kVK_End: return String(UnicodeScalar(NSEndFunctionKey)!)
            case kVK_PageUp: return String(UnicodeScalar(NSPageUpFunctionKey)!)
            case kVK_PageDown: return String(UnicodeScalar(NSPageDownFunctionKey)!)
            case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
            default:
                let name = Self.keyName(for: keyCode)
                if name.count == 1 { return name.lowercased() }
                if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...20).contains(number) {
                    return String(UnicodeScalar(Int(NSF1FunctionKey) + number - 1)!)
                }
                return nil
            }
        }

        /// Carbon 虚拟键码 -> 显示字符。覆盖可绑定的常用键，
        /// 未列出的键码显示为 `#键码`，至少能看出已绑定。
        static func keyName(for keyCode: UInt32) -> String {
            switch Int(keyCode) {
            case 0: return "A"
            case 1: return "S"
            case 2: return "D"
            case 3: return "F"
            case 4: return "H"
            case 5: return "G"
            case 6: return "Z"
            case 7: return "X"
            case 8: return "C"
            case 9: return "V"
            case 11: return "B"
            case 12: return "Q"
            case 13: return "W"
            case 14: return "E"
            case 15: return "R"
            case 16: return "Y"
            case 17: return "T"
            case kVK_ANSI_1: return "1"
            case kVK_ANSI_2: return "2"
            case kVK_ANSI_3: return "3"
            case kVK_ANSI_4: return "4"
            case kVK_ANSI_5: return "5"
            case kVK_ANSI_6: return "6"
            case kVK_ANSI_7: return "7"
            case kVK_ANSI_8: return "8"
            case kVK_ANSI_9: return "9"
            case kVK_ANSI_Equal: return "="
            case kVK_ANSI_Minus: return "-"
            case 29: return "0"
            case 30: return "]"
            case 31: return "O"
            case 32: return "U"
            case 33: return "["
            case 34: return "I"
            case 35: return "P"
            case 36: return "↩"
            case 37: return "L"
            case 38: return "J"
            case 39: return "'"
            case 40: return "K"
            case 41: return ";"
            case 42: return "\\"
            case 43: return ","
            case 44: return "/"
            case 45: return "N"
            case 46: return "M"
            case 47: return "."
            case 48: return "⇥"
            case 49: return "Space"
            case 50: return "`"
            case 51: return "⌫"
            case 53: return "⎋"
            case kVK_ANSI_KeypadPlus: return "小键盘+"
            case kVK_ANSI_KeypadMinus: return "小键盘−"
            case kVK_ANSI_Keypad0: return "小键盘0"
            case kVK_F13: return "F13"
            case kVK_F14: return "F14"
            case kVK_F15: return "F15"
            case kVK_F16: return "F16"
            case kVK_F17: return "F17"
            case kVK_F18: return "F18"
            case kVK_F19: return "F19"
            case kVK_F20: return "F20"
            case kVK_F2: return "F2"
            case kVK_F4: return "F4"
            case 96: return "F5"
            case 97: return "F6"
            case 98: return "F7"
            case 99: return "F3"
            case 100: return "F8"
            case 101: return "F9"
            case 103: return "F11"
            case 109: return "F10"
            case 111: return "F12"
            case 115: return "↖"
            case 116: return "⇞"
            case 117: return "⌦"
            case 119: return "↘"
            case 121: return "⇟"
            case 122: return "F1"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            default: return "#\(keyCode)"
            }
        }
    }

    public enum RegistrationError: Error {
        case alreadyRegistered
        case systemReserved
        case systemRefused(OSStatus)
        case handlerInstallFailed(OSStatus)
        case accessibilityRequired
        case priorityCaptureFailed
    }

    private let combo: Combo
    private let prefersPriorityOnConflict: Bool
    private var hotKeyRef: EventHotKeyRef?
    private var priorityTap: PriorityShortcutTap?
    /// 在本类型静态注册表里的序号，0 表示未注册。
    private(set) var identifier: UInt32 = 0
    public var onTrigger: (() -> Void)?

    public init(combo: Combo, prefersPriorityOnConflict: Bool = false, onTrigger: (() -> Void)? = nil) {
        self.combo = combo
        self.prefersPriorityOnConflict = prefersPriorityOnConflict
        self.onTrigger = onTrigger
    }

    deinit {
        unregister()
    }

    public var isRegistered: Bool { hotKeyRef != nil || priorityTap?.isRunning == true }
    public var usesPriorityEventTap: Bool { priorityTap != nil }

    // MARK: - 进程级的按键分发

    /// 一次性安装的键盘事件处理器：所有热键共用，按 hotKeyID 分发给对应实例。
    private static let signature: OSType = 0x536E_5370 // 'SnSp'
    private final class WeakShortcut {
        weak var value: GlobalShortcut?
        init(_ value: GlobalShortcut) { self.value = value }
    }
    private static var registry: [UInt32: WeakShortcut] = [:]
    private static var nextIdentifier: UInt32 = 1

    private static let hotKeyHandler: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == GlobalShortcut.signature else {
            return OSStatus(eventNotHandledErr)
        }
        if let shortcut = GlobalShortcut.registry[hotKeyID.id]?.value {
            Log.shared.debug("热键触发 id=\(hotKeyID.id) \(shortcut.combo.displayString)")
            shortcut.onTrigger?()
        } else {
            Log.shared.warn("热键触发但找不到注册项 id=\(hotKeyID.id)")
        }
        return noErr
    }

    private static func installHandlerIfNeeded() -> OSStatus {
        if handlerRef != nil { return noErr }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyHandler,
            1,
            &spec,
            nil,
            &ref
        )
        if status == noErr { handlerRef = ref }
        Log.shared.info("热键事件处理器安装结果 OSStatus=\(status)")
        return status
    }

    private static var handlerRef: EventHandlerRef?

    static func conflictsWithSystemShortcut(_ combo: Combo, hotKeys: [[String: Any]]) -> Bool {
        hotKeys.contains { hotKey in
            (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (hotKey[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == combo.keyCode
                && (hotKey[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == combo.carbonModifiers
        }
    }

    // MARK: - 注册 / 注销

    /// 注册热键。必须在主线程调用。
    public func register() throws {
        guard hotKeyRef == nil, priorityTap == nil else { throw RegistrationError.alreadyRegistered }
        var symbolicHotKeys: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolicHotKeys) == noErr,
           let hotKeys = symbolicHotKeys?.takeRetainedValue() as? [[String: Any]],
           Self.conflictsWithSystemShortcut(combo, hotKeys: hotKeys) {
            throw RegistrationError.systemReserved
        }
        let handlerStatus = Self.installHandlerIfNeeded()
        guard handlerStatus == noErr else {
            throw RegistrationError.handlerInstallFailed(handlerStatus)
        }

        let id = Self.nextIdentifier
        Self.nextIdentifier += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        if status == eventHotKeyExistsErr, prefersPriorityOnConflict {
            let tap = PriorityShortcutTap(combo: combo) { [weak self] in self?.onTrigger?() }
            try tap.start()
            priorityTap = tap
            Log.shared.info("快捷键启用优先响应：\(combo.displayString)")
            return
        }
        guard status == noErr, let ref else {
            throw RegistrationError.systemRefused(status)
        }

        hotKeyRef = ref
        identifier = id
        Self.registry[id] = WeakShortcut(self)
    }

    public func unregister() {
        priorityTap?.stop()
        priorityTap = nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if identifier != 0 {
            Self.registry[identifier] = nil
            identifier = 0
        }
    }
}
