import Combine
import Foundation
import TapSnapCore

/// 配置读写入口。
///
/// 将应用设置缓存在内存并持久化，通过 Combine 发布变更。
public final class ConfigStore: ObservableObject {
    public static let shared = ConfigStore()

    @Published public private(set) var settings: Settings
    public let privacyAIKeys: PrivacyAIKeyStore

    private let store: LocalStore<Settings>
    private let log = Log(subsystem: AppPaths.bundleIdentifier, category: "config")

    public init(fileURL: URL = AppPaths.configFile) {
        self.store = LocalStore(fileURL: fileURL)
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("privacy-ai-keys", isDirectory: true)
        self.privacyAIKeys = PrivacyAIKeyStore(directory: directory)
        let logger = Log(subsystem: AppPaths.bundleIdentifier, category: "config")
        do {
            var loaded = try store.load() ?? Settings.withDefaultShortcuts()
            // 老配置里没有新加的默认快捷键：补一次，之后用户删掉就不会再加回来。
            let version = loaded.schemaVersion ?? 0
            func isAvailable(_ binding: KeyBinding) -> Bool {
                !loaded.shortcuts.values.contains(binding) && loaded.operationShortcuts?.values.contains(binding) != true
            }
            if version < 1 {
                for (key, binding) in Settings.withDefaultShortcuts().shortcuts
                where loaded.shortcuts[key] == nil && isAvailable(binding) {
                    loaded.shortcuts[key] = binding
                }
            }
            if version < 2 {
                let oldDefault = KeyBinding(keyCode: 20, modifiers: 768) // 旧版 ⌘⇧3
                let replacement = Settings.withDefaultShortcuts().shortcuts[ShortcutAction.longShot.rawValue]!
                // 只迁移旧版发放的默认组合；不恢复用户取消的绑定，也不占用其自定义组合。
                if loaded.shortcuts[ShortcutAction.longShot.rawValue] == oldDefault,
                   isAvailable(replacement) {
                    loaded.shortcuts[ShortcutAction.longShot.rawValue] = replacement
                }
            }
            if version < 5 {
                // Replace the old default texture. Users can still choose it from the style panel.
                if loaded.privacy.appearance.style == .mosaic {
                    loaded.privacy.appearance.style = .frosted
                }
            }
            if version < 6 {
                // 普通截图在版本 0–2、3、4–5 分别使用 ⌘⇧1、⌘1、⌃1。
                // 版本 0–2 的默认值已经是这次的目标；其余版本只替换当时发放的键位。
                let screenshot = ShortcutAction.screenshot.rawValue
                let previousScreenshot = KeyBinding(keyCode: 18, flags: version == 3 ? .command : .control)
                let commandShiftOne = KeyBinding(keyCode: 18, flags: [.command, .shift])
                if version >= 3, loaded.shortcuts[screenshot] == previousScreenshot, isAvailable(commandShiftOne) {
                    loaded.shortcuts[screenshot] = commandShiftOne
                }
                let shiftP = KeyBinding(keyCode: 35, flags: .shift)
                let commandT = KeyBinding(keyCode: 17, flags: .command)
                if loaded.operationShortcuts?["pin"] == shiftP, isAvailable(commandT) {
                    loaded.operationShortcuts?["pin"] = commandT
                }
                loaded.schemaVersion = Settings.currentSchemaVersion
                try? store.save(loaded)
            }
            self.settings = loaded
        } catch {
            logger.error("读取配置失败，使用默认值：\(error.localizedDescription)")
            self.settings = Settings.withDefaultShortcuts()
        }
    }

    /// 修改配置并立即落盘。
    public func update(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        save()
    }

    public func save() {
        do {
            try store.save(settings)
        } catch {
            log.error("保存配置失败：\(error.localizedDescription)")
        }
    }

    public func resetToDefaults() {
        settings = Settings.withDefaultShortcuts()
        save()
    }

    public func resetShortcutsToDefaults() {
        update {
            $0.shortcuts = Settings.withDefaultShortcuts().shortcuts
            $0.operationShortcuts = nil
        }
    }

    public func binding(for action: ShortcutAction) -> KeyBinding? {
        settings.shortcuts[action.rawValue]
    }

    public func setBinding(_ binding: KeyBinding?, for action: ShortcutAction) {
        update { settings in
            if let binding {
                settings.shortcuts[action.rawValue] = binding
            } else {
                settings.shortcuts.removeValue(forKey: action.rawValue)
            }
        }
    }
}
