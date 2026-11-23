import AppKit
import Foundation
import TapSnapCore
import TapSnapImageIO

/// 剪贴板与贴图之间的搬运。
///
/// 复制时写入贴图元数据，重新粘贴到 TapSnap 后可还原为可编辑的贴图。
final class PinTransfer {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 把剪贴板里的图贴到屏幕上（⌘⇧V 或菜单「贴图」）。
    func pinFromPasteboard() {
        let pasteboard = NSPasteboard.general

        guard let (image, meta) = imagePayload(from: pasteboard) else {
            environment.toast.warning("剪贴板里没有图片")
            return
        }

        environment.pinGroups.show(image, from: meta?.sourceTopLeft, scale: meta?.scale ?? 1)
        environment.toast.success("已贴图")
    }

    @discardableResult
    func copy(_ image: CGImage, scale: CGFloat = 1, sourceTopLeft: CGPoint? = nil,
              kind: ClipMetaData.Kind = .screenshot, to pasteboard: NSPasteboard = .general,
              successMessage: String = "已复制到剪贴板") -> Bool {
        let meta = ClipMetaData(kind: kind, pixelWidth: image.width, pixelHeight: image.height,
                                scale: scale, sourceTopLeft: sourceTopLeft)
        guard let item = Self.pasteboardItem(for: image, metadata: meta) else {
            environment.toast.error("无法生成剪贴板图片")
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            environment.toast.error("无法写入剪贴板，请重试")
            return false
        }
        environment.toast.success(successMessage)
        return true
    }

    static func pasteboardItem(for image: CGImage, metadata: ClipMetaData) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), item.setData(png, forType: .png)
        else { return nil }
        if let data = try? JSONEncoder().encode(metadata) {
            let type = NSPasteboard.PasteboardType(ClipMetaData.pasteboardType)
            item.setString(String(decoding: data, as: UTF8.self), forType: type)
        }
        return item
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func imagePayload(from pasteboard: NSPasteboard) -> (image: CGImage, metadata: ClipMetaData?)? {
        if let payload = Self.bitmapPayload(from: pasteboard.pasteboardItems ?? []) { return payload }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL, let data = try? Data(contentsOf: url),
           let image = try? ImageCodec.decode(data) {
            return (image, nil)
        }
        return nil
    }

    static func bitmapPayload(from items: [NSPasteboardItem]) -> (image: CGImage, metadata: ClipMetaData?)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            for item in items where item.types.contains(type) {
                if let data = item.data(forType: type), let image = try? ImageCodec.decode(data) {
                    return (image, metadata(for: image, from: item))
                }
            }
        }
        return nil
    }

    private static func metadata(for image: CGImage, from item: NSPasteboardItem) -> ClipMetaData? {
        // 用户可缩放至 8 倍；超长贴图在显示器断开后适应屏幕时可能进一步缩小。
        let maximumScale = Double(max(8, max(image.width, image.height)))
        guard let text = item.string(forType: NSPasteboard.PasteboardType(ClipMetaData.pasteboardType)),
              let meta = try? JSONDecoder().decode(ClipMetaData.self, from: Data(text.utf8)),
              meta.pixelWidth == image.width, meta.pixelHeight == image.height,
              (0.1...maximumScale).contains(meta.scale)
        else { return nil }
        return meta
    }
}
