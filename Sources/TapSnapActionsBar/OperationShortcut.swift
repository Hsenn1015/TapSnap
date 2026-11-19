import AppKit
import Carbon.HIToolbox
import TapSnapConfig

/// 框选和编辑器内的操作键位。
public enum OperationShortcut: Hashable, Identifiable, Sendable {
    case action(ActionKind)
    case zoomIn, zoomOut, fitImage

    public var id: String {
        switch self {
        case .action(let action): return action.rawValue
        case .zoomIn: return "zoomIn"
        case .zoomOut: return "zoomOut"
        case .fitImage: return "fitImage"
        }
    }

    public var title: String {
        switch self {
        case .action(let action): return action.title
        case .zoomIn: return "放大画布"
        case .zoomOut: return "缩小画布"
        case .fitImage: return "适合窗口"
        }
    }

    public var selectionAction: ActionKind? {
        guard case .action(let action) = self else { return nil }
        return action.isAnnotationTool || [.crop, .copy, .save, .pin].contains(action) ? action : nil
    }

    private static let keys: [(OperationShortcut, Int, NSEvent.ModifierFlags)] = [
        (.action(.pin), kVK_ANSI_P, .shift),
        (.action(.copy), kVK_ANSI_C, .command),
        (.action(.save), kVK_ANSI_S, .command),
        (.action(.undo), kVK_ANSI_Z, .command),
        (.action(.redo), kVK_ANSI_Z, [.shift, .command]),
        (.zoomIn, kVK_ANSI_Equal, [.shift, .command]),
        (.zoomOut, kVK_ANSI_Minus, .command),
        (.fitImage, kVK_ANSI_0, .command),
        (.action(.arrow), kVK_ANSI_A, []),
        (.action(.rectangle), kVK_ANSI_R, []),
        (.action(.ellipse), kVK_ANSI_O, []),
        (.action(.line), kVK_ANSI_L, []),
        (.action(.pen), kVK_ANSI_B, []),
        (.action(.text), kVK_ANSI_T, []),
        (.action(.mosaic), kVK_ANSI_M, []),
        (.action(.highlight), kVK_ANSI_H, []),
        (.action(.serialNumber), kVK_ANSI_N, []),
        (.action(.polygon), kVK_ANSI_P, []),
        (.action(.spotlight), kVK_ANSI_S, []),
        (.action(.eraser), kVK_ANSI_E, []),
        (.action(.magnifier), kVK_ANSI_G, []),
        (.action(.watermark), kVK_ANSI_W, []),
        (.action(.pathTag), kVK_ANSI_U, []),
        (.action(.privacy), kVK_ANSI_D, []),
        (.action(.crop), kVK_ANSI_C, []),
    ]

    public static let all = keys.map(\.0)
    public static let defaults = Dictionary(uniqueKeysWithValues: keys.map {
        ($0.id, KeyBinding(keyCode: UInt32($1), flags: $2))
    })

    public func binding(in settings: Settings) -> KeyBinding? {
        (settings.operationShortcuts ?? Self.defaults)[id]
    }

    public func displayTitle(in settings: Settings, title: String? = nil) -> String {
        let title = title ?? self.title
        guard let key = binding(in: settings) else { return title }
        return "\(title) \(key.displayString)"
    }

    public static func matching(_ event: NSEvent, in settings: Settings, selection: Bool = false) -> Self? {
        guard event.type == .keyDown else { return nil }
        let input = KeyBinding(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
        if let operation = all.first(where: { (!selection || $0.selectionAction != nil) && $0.binding(in: settings) == input }) {
            return operation
        }
        guard !selection else { return nil }
        // 保留默认键位的等号和数字小键盘写法。录制新键位后以录制结果为准。
        let alternative: Self
        switch Int(event.keyCode) {
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: alternative = .zoomIn
        case kVK_ANSI_KeypadMinus: alternative = .zoomOut
        case kVK_ANSI_Keypad0: alternative = .fitImage
        default: return nil
        }
        return input.combo.cocoaModifiers == .command && alternative.binding(in: settings) == defaults[alternative.id]
            ? alternative : nil
    }
}
