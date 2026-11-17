import CoreGraphics
import Foundation
import TapSnapVision
import Vision

public enum OCRError: Error {
    case unsupportedLanguage(String)
    case recognitionFailed(underlying: Error?)
}

/// 文字识别服务。
///
/// 使用 macOS Vision 在设备端识别文字。
public final class OCRService {
    public struct Options: Sendable {
        /// 例如 ["zh-Hans", "en-US"]。
        public var languages: [String]
        /// 是否把相邻行合并成段落。
        public var recognizeParagraphs: Bool

        public init(languages: [String] = ["zh-Hans", "en-US"], recognizeParagraphs: Bool = true) {
            self.languages = languages
            self.recognizeParagraphs = recognizeParagraphs
        }
    }

    public init() {}

    /// 识别整张图。
    public func recognize(_ image: CGImage, options: Options = Options()) async throws -> OCRDocument {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.performRecognize(image, options: options))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 只识别指定区域（区域截图 OCR）。`rect` 用图像像素坐标。
    public func recognize(_ image: CGImage, in rect: CGRect, options: Options = Options()) async throws -> OCRDocument {
        let clamped = rect.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !clamped.isEmpty, let cropped = image.cropping(to: clamped) else {
            return OCRDocument(blocks: [], languages: options.languages, sourceSize: .zero)
        }
        return try await recognize(cropped, options: options)
    }

    /// Uses the existing OCR observations first and retries only table crops with ambiguous cell text.
    public func recognizeTables(in document: OCRDocument, image: CGImage) async -> [OCRTableRegion] {
        let detected = await Task.detached(priority: .userInitiated) { Self.detectTables(in: document, image: image) }.value
        var tables: [OCRTableRegion] = []
        for table in detected {
            if table.hasTextSpanningColumns, let recovered = await recoverTable(table, document: document, image: image) {
                tables.append(recovered)
            } else {
                tables.append(table)
            }
        }
        return tables
    }

    private static func detectTables(in document: OCRDocument, image: CGImage) -> [OCRTableRegion] {
        var tables: [OCRTableRegion] = []
        if let ruled = OCRTableGrid.detect(in: image)?.table(in: document) {
            tables.append(ruled)
        }
        let bands = OCRTableBands.tables(in: document, image: image)
        let aligned = OCRTableLayout.tables(in: document)
        for table in bands + aligned where tables.allSatisfy({ $0.lineIDs.isDisjoint(with: table.lineIDs) }) {
            tables.append(table)
        }
        return tables
    }

    private func recoverTable(_ table: OCRTableRegion, document: OCRDocument, image: CGImage) async -> OCRTableRegion? {
        let bounds = table.normalizedBounds
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let crop = CGRect(x: bounds.minX * width, y: (1 - bounds.maxY) * height,
                          width: bounds.width * width, height: bounds.height * height).insetBy(dx: -2, dy: -2)
        guard let cropped = image.cropping(to: crop.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))),
              let recognized = try? await recognize(cropped, options: .init(languages: document.languages, recognizeParagraphs: false))
        else { return nil }

        let candidates = await Task.detached(priority: .userInitiated) { Self.detectTables(in: recognized, image: cropped) }.value
        let columnCount = table.rows.first?.count
        let filled = table.rows.flatMap { $0 }.count { !$0.isEmpty }
        guard let replacement = candidates.first(where: {
            !$0.hasTextSpanningColumns && $0.rows.count == table.rows.count && $0.rows.first?.count == columnCount
                && $0.rows.flatMap { $0 }.count(where: { !$0.isEmpty }) > filled
        }) else { return nil }
        return OCRTableRegion(rows: replacement.rows, lineIDs: table.lineIDs, normalizedBounds: bounds)
    }

    /// 系统当前可用的识别语言。
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    // MARK: - 实现

    private static func performRecognize(_ image: CGImage, options: Options) throws -> OCRDocument {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false

        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = supported.isEmpty
            ? options.languages
            : options.languages.filter { supported.contains($0) }
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw OCRError.recognitionFailed(underlying: error)
        }

        let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRTextLine(
                text: text,
                normalizedBounds: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
        let sourceSize = CGSize(width: image.width, height: image.height)
        let layout = OCRParagraphLayout.layout(lines, sourceSize: sourceSize, groupParagraphs: options.recognizeParagraphs)

        return OCRDocument(
            blocks: layout.blocks,
            languages: languages.isEmpty ? options.languages : languages,
            sourceSize: sourceSize,
            originalLines: layout.originalLines
        )
    }
}
