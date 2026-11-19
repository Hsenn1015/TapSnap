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
            var needsSave = false
            let version = loaded.schemaVersion ?? 0
            if version < 1 {
                for (key, binding) in Settings.withDefaultShortcuts().shortcuts
                where loaded.shortcuts[key] == nil {
                    loaded.shortcuts[key] = binding
                }
                needsSave = true
            }
            if version < 2 {
                let oldDefault = KeyBinding(keyCode: 20, modifiers: 768) // 旧版 ⌘⇧3
                let replacement = Settings.withDefaultShortcuts().shortcuts[ShortcutAction.longShot.rawValue]!
                // 只迁移旧版发放的默认组合；不恢复用户取消的绑定，也不占用其自定义组合。
                if loaded.shortcuts[ShortcutAction.longShot.rawValue] == oldDefault,
                   !loaded.shortcuts.values.contains(replacement) {
                    loaded.shortcuts[ShortcutAction.longShot.rawValue] = replacement
                }
                needsSave = true
            }
            if version < 3 {
                let oldDefault = KeyBinding(keyCode: 18, modifiers: 768) // 旧版 ⌘⇧1
                let replacement = Settings.withDefaultShortcuts().shortcuts[ShortcutAction.screenshot.rawValue]!
                if loaded.shortcuts[ShortcutAction.screenshot.rawValue] == oldDefault,
                   !loaded.shortcuts.values.contains(replacement) {
                    loaded.shortcuts[ShortcutAction.screenshot.rawValue] = replacement
                }
                needsSave = true
            }
            if version < 4 {
                let oldDefault = KeyBinding(keyCode: 18, modifiers: 256) // 版本 3 的 ⌘1
                let replacement = Settings.withDefaultShortcuts().shortcuts[ShortcutAction.screenshot.rawValue]!
                if version == 3,
                   loaded.shortcuts[ShortcutAction.screenshot.rawValue] == oldDefault,
                   !loaded.shortcuts.values.contains(replacement) {
                    loaded.shortcuts[ShortcutAction.screenshot.rawValue] = replacement
                }
                needsSave = true
            }
            if version < 5 {
                // Replace the old default texture. Users can still choose it from the style panel.
                if loaded.privacy.appearance.style == .mosaic {
                    loaded.privacy.appearance.style = .frosted
                }
                loaded.schemaVersion = Settings.currentSchemaVersion
                needsSave = true
            }
            self.settings = loaded
            if needsSave { try? store.save(loaded) }
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
