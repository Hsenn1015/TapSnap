import AppKit
import Foundation
import TapSnapCore
import TapSnapImageIO
import TapSnapScreen

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

        guard let image = image(from: pasteboard) else {
            environment.toast.warning("剪贴板里没有图片")
            return
        }

        let meta = readMeta(from: pasteboard)
        let scale = meta?.scale ?? 1
        environment.pinGroups.show(image, scale: scale)
        environment.toast.success("已贴图")
    }

    @discardableResult
    func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general,
              successMessage: String = "已复制到剪贴板") -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let item = NSPasteboardItem()
        guard let data = bitmap.representation(using: .png, properties: [:]), item.setData(data, forType: .png) else {
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

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func image(from pasteboard: NSPasteboard) -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = try? ImageCodec.decode(data) { return image }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL, let data = try? Data(contentsOf: url) {
            return try? ImageCodec.decode(data)
        }
        return nil
    }

    private func readMeta(from pasteboard: NSPasteboard) -> ClipMetaData? {
        guard let text = pasteboard.string(forType: NSPasteboard.PasteboardType(ClipMetaData.pasteboardType)),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ClipMetaData.self, from: data)
    }
}
