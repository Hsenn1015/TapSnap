import Foundation

/// 轻量的 JSON 落盘封装，配置、色板、贴图分组都用它存。
public struct LocalStore<Value: Codable> {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 允许在不同模块间共享同一个 Key 而不必反复拼字符串。
public enum StorageKey {
    public static let settings = "settings.json"
    public static let palette = "palette.json"
    public static let pinGroups = "pin-groups.json"
}
