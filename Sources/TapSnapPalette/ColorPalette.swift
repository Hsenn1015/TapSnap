import Foundation
import TapSnapCore

/// 色板。
///
/// 分别保存常用颜色和最近使用的颜色。
public struct ColorPalette: Codable, Hashable, Sendable {
    public var favorites: [RGBAColor]
    public var recents: [RGBAColor]
    /// 最近使用色最多保留多少个。
    public var recentLimit: Int

    public init(
        favorites: [RGBAColor] = ColorPalette.defaultFavorites,
        recents: [RGBAColor] = [],
        recentLimit: Int = 12
    ) {
        self.favorites = favorites
        self.recents = recents
        self.recentLimit = recentLimit
    }

    /// 默认常用颜色。
    public static let defaultFavorites: [RGBAColor] = [
        RGBAColor(rgb: 0xFF3B30),
        RGBAColor(rgb: 0xFF9500),
        RGBAColor(rgb: 0xFFCC00),
        RGBAColor(rgb: 0x34C759),
        RGBAColor(rgb: 0x007AFF),
        RGBAColor(rgb: 0xAF52DE),
        RGBAColor(rgb: 0x000000),
        RGBAColor(rgb: 0xFFFFFF),
    ]

    public mutating func recordUse(_ color: RGBAColor) {
        recents.removeAll { $0 == color }
        recents.insert(color, at: 0)
        if recents.count > recentLimit {
            recents.removeLast(recents.count - recentLimit)
        }
    }

    public mutating func addFavorite(_ color: RGBAColor) {
        guard !favorites.contains(color) else { return }
        favorites.append(color)
    }

    public mutating func removeFavorite(_ color: RGBAColor) {
        favorites.removeAll { $0 == color }
    }
}

/// 色板读写（文件在 Application Support 下）。
public final class ColorPaletteStore {
    private let store: LocalStore<ColorPalette>
    private(set) var palette: ColorPalette

    public init(fileURL: URL = AppPaths.applicationSupport.appendingPathComponent(StorageKey.palette)) {
        self.store = LocalStore(fileURL: fileURL)
        self.palette = (try? store.load()) ?? ColorPalette()
    }

    public func save() throws {
        try store.save(palette)
    }

    public func update(_ mutate: (inout ColorPalette) -> Void) throws {
        var copy = palette
        mutate(&copy)
        palette = copy
        try save()
    }
}
