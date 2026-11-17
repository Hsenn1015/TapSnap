import AppKit
import ImageIO
import UniformTypeIdentifiers

enum RecordingClipboardError: LocalizedError {
    case invalidVideo
    case invalidGIF
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "找不到可复制的 MP4 文件"
        case .invalidGIF: return "GIF 文件不完整或无法读取"
        case .writeFailed: return "无法写入剪贴板，请重试"
        }
    }
}

enum RecordingClipboard {
    static func copyVideo(at url: URL, to pasteboard: NSPasteboard = .general) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4",
              let file = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              file.isRegularFile == true, (file.fileSize ?? 0) > 0
        else { throw RecordingClipboardError.invalidVideo }

        // 与 Finder 复制文件使用同一种表示。无需把整段视频读入剪贴板进程。
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { throw RecordingClipboardError.writeFailed }
    }

    static func copyGIF(at url: URL, to pasteboard: NSPasteboard = .general) throws {
        guard url.isFileURL else { throw RecordingClipboardError.invalidGIF }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              (0..<CGImageSourceGetCount(source)).allSatisfy({
                  CGImageSourceGetStatusAtIndex(source, $0) == .statusComplete
              }) else { throw RecordingClipboardError.invalidGIF }

        // 同一项提供动图数据和文件地址，接收方可按支持的格式读取。
        let item = NSPasteboardItem()
        guard item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier)),
              item.setString(url.absoluteString, forType: .fileURL)
        else { throw RecordingClipboardError.writeFailed }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw RecordingClipboardError.writeFailed }
        // 文件供接收方稍后读取，复制或关闭预览时不要删除。
    }
}
