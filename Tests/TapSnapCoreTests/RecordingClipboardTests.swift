import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TapSnapApp

@MainActor
final class RecordingClipboardTests: XCTestCase {
    private func withPasteboard(_ test: (URL, NSPasteboard) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapsnap-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tapsnap-tests-\(UUID().uuidString)"))
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(pasteboard.setString("保留原内容", forType: .string))
        try test(directory.appendingPathComponent("录屏 测试.gif"), pasteboard)
    }

    private func imageData(type: UTType = .gif, frameCount: Int = 2) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString,
                                                                        frameCount, nil))
        for index in 0..<frameCount {
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
                                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(index == 0 ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testCopiesAnimatedGIFAndFileURLAsOneItem() throws {
        try withPasteboard { url, pasteboard in
            let original = try imageData()
            try original.write(to: url)
            try RecordingClipboard.copyGIF(at: url, to: pasteboard)

            let items = try XCTUnwrap(pasteboard.pasteboardItems)
            XCTAssertEqual(items.count, 1)
            let data = try XCTUnwrap(items.first?.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)))
            XCTAssertEqual(data, original)
            XCTAssertNil(items.first?.data(forType: .png))
            XCTAssertNil(items.first?.data(forType: .tiff))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 2)
            for index in 0..<2 {
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
                let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
                XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime as String] as? Double), 0.2, accuracy: 0.001)
            }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]
            XCTAssertEqual(urls, [url])
            XCTAssertEqual(try Data(contentsOf: url), original, "复制后必须保留文件供接收方读取")
        }
    }

    func testSingleFrameGIFIsStillAValidGIF() throws {
        try withPasteboard { url, pasteboard in
            let original = try imageData(frameCount: 1)
            try original.write(to: url)
            try RecordingClipboard.copyGIF(at: url, to: pasteboard)
            XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)), original)
        }
    }

    func testMissingFileDoesNotClearExistingClipboard() throws {
        try withPasteboard { url, pasteboard in
            XCTAssertThrowsError(try RecordingClipboard.copyGIF(at: url, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "保留原内容")
        }
    }

    func testMissingOrEmptyVideoDoesNotClearClipboard() throws {
        try withPasteboard { url, pasteboard in
            let video = url.deletingPathExtension().appendingPathExtension("mp4")
            XCTAssertThrowsError(try RecordingClipboard.copyVideo(at: video, to: pasteboard))
            try Data().write(to: video)
            XCTAssertThrowsError(try RecordingClipboard.copyVideo(at: video, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "保留原内容")
        }
    }

    func testNonGIFAndTruncatedGIFDoNotClearExistingClipboard() throws {
        try withPasteboard { url, pasteboard in
            let gif = try imageData()
            let emptyGIF = Data("GIF89a".utf8) + Data([1, 0, 1, 0, 0, 0, 0, 0x3b])
            for invalid in [try imageData(type: .png, frameCount: 1), Data(gif.prefix(gif.count / 2)), emptyGIF] {
                try invalid.write(to: url)
                XCTAssertThrowsError(try RecordingClipboard.copyGIF(at: url, to: pasteboard))
                XCTAssertEqual(pasteboard.string(forType: .string), "保留原内容")
            }
        }
    }
}
