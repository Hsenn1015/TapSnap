import Foundation
import CoreGraphics
import TapSnapCore
import TapSnapImageIO

/// 本机历史的原子清单与图片文件；文件名只由 UUID 生成，不使用用户文本。
final class LocalImageArchive<Manifest: Codable> {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.sensnap.image-history")
    private let lock = NSLock()
    private var pending: (Manifest, [UUID: CGImage])?

    init(directory: URL) { self.directory = directory }

    func load() -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    func image(_ id: UUID) -> CGImage? {
        guard let data = try? Data(contentsOf: imageURL(id)) else { return nil }
        return try? ImageCodec.decode(data)
    }

    func save(_ manifest: Manifest, images: [UUID: CGImage]) {
        lock.lock()
        pending = (manifest, images)
        lock.unlock()
        // 多次拖动/缩放只保留最新快照，避免排队持有整屏图片。
        queue.async { [self] in writeLatest() }
    }

    func flush() { queue.sync { writeLatest() } }

    private func imageURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    private func writeLatest() {
        lock.lock()
        let snapshot = pending
        pending = nil
        lock.unlock()
        guard let (manifest, images) = snapshot else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            for (id, image) in images {
                let url = imageURL(id)
                if !manager.fileExists(atPath: url.path) {
                    try ImageCodec.encode(image, as: .png).write(to: url, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            let retained = Set(images.keys)
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard url.pathExtension == "png", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !retained.contains(id) else { continue }
                try manager.removeItem(at: url)
            }
        } catch {
            Log.shared.warn("本地历史保存失败：\(error.localizedDescription)")
        }
    }
}
