import CWebP
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 支持的导出图片格式。
public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case heic
    case webp
    case avif
    case tiff
    case gif

    public var uti: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        }
    }

    public var fileExtension: String {
        self == .jpeg ? "jpg" : rawValue
    }

    /// 是否支持有损压缩质量参数。
    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .webp, .avif: return true
        case .png, .tiff, .gif: return false
        }
    }

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        }
    }

    public init?(fileExtension: String) {
        let normalized = fileExtension.lowercased()
        self.init(rawValue: normalized == "jpg" ? "jpeg" : normalized)
    }
}

public enum ImageIOError: Error {
    case unsupportedFormat(ImageFormat)
    case encodeFailed(ImageFormat)
    case decodeFailed
    case writeFailed(URL)
}

/// 图片编解码。
public enum ImageCodec {
    /// 编码为指定格式。`quality` 仅对 `isLossy` 的格式生效。
    public static func encode(_ image: CGImage, as format: ImageFormat, quality: Double = 0.9) throws -> Data {
        if format == .webp { return try encodeWebP(image, quality: quality) }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            format.uti as CFString,
            1,
            nil
        ) else {
            throw ImageIOError.unsupportedFormat(format)
        }

        var options: [CFString: Any] = [:]
        if format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality))
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageIOError.encodeFailed(format)
        }
        return buffer as Data
    }

    private static func encodeWebP(_ image: CGImage, quality: Double) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16383, height <= 16383,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageIOError.encodeFailed(.webp)
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let result: Data? = rgba.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            // CoreGraphics stores premultiplied pixels; libwebp expects straight RGBA.
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(pixels[offset + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 {
                        pixels[offset + channel] = UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
            var output: UnsafeMutablePointer<UInt8>?
            let q = quality.isFinite ? max(0, min(1, quality)) : 0.9
            let count = q == 1
                ? WebPEncodeLosslessRGBA(pixels, Int32(width), Int32(height), Int32(width * 4), &output)
                : WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(width * 4), Float(q * 100), &output)
            guard count > 0, let output else { return nil }
            defer { WebPFree(output) }
            return Data(bytes: output, count: count)
        }
        guard let result else { throw ImageIOError.encodeFailed(.webp) }
        return result
    }

    public static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageIOError.decodeFailed
        }
        return image
    }

    /// 写到磁盘。返回实际写入的 URL（会自动补齐扩展名）。
    @discardableResult
    public static func write(
        _ image: CGImage,
        to directory: URL,
        fileName: String? = nil,
        format: ImageFormat,
        quality: Double = 0.9
    ) throws -> URL {
        try AppPathsBridge.ensureDirectory(directory)
        let name = fileName ?? Self.defaultFileName()
        let url = directory.appendingPathComponent("\(name).\(format.fileExtension)")
        let data = try encode(image, as: format, quality: quality)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImageIOError.writeFailed(url)
        }
        return url
    }

    /// 默认命名示例 TapSnap_2026-01-30_14-05-33。
    public static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "TapSnap_\(formatter.string(from: now))"
    }
}

/// 让 `TapSnapImageIO` 不直接依赖整个 Core 的路径逻辑。
enum AppPathsBridge {
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
