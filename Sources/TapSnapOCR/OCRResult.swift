import CoreGraphics
import Foundation

/// 一行识别出的文本。
public struct OCRTextLine: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var text: String
    /// 归一化坐标（原点左下，Vision 约定）。
    public var normalizedBounds: CGRect
    public var confidence: Float

    public init(text: String, normalizedBounds: CGRect, confidence: Float) {
        self.text = text
        self.normalizedBounds = normalizedBounds
        self.confidence = confidence
    }
}

/// 由若干行组成的识别文本块。
public struct OCRTextBlock: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var lines: [OCRTextLine]
    public var normalizedBounds: CGRect

    public init(lines: [OCRTextLine], normalizedBounds: CGRect) {
        self.lines = lines
        self.normalizedBounds = normalizedBounds
    }

    public var fullText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// 用于连续阅读。只决定两行之间插入什么，保留 OCR 返回的文字。
    public var paragraphText: String {
        guard let first = lines.first else { return "" }
        var previous = first.text
        var result = previous
        for line in lines.dropFirst() {
            result += OCRParagraphSeparator.between(previous, line.text)
            result += line.text
            previous = line.text
        }
        return result
    }
}

/// 一次识别结果。
public struct OCRDocument: Sendable {
    public var blocks: [OCRTextBlock]
    /// 识别所用语言标识，例如 zh-Hans / en-US。
    public var languages: [String]
    public var sourceSize: CGSize
    private let sourceLines: [OCRTextLine]?

    public init(blocks: [OCRTextBlock], languages: [String], sourceSize: CGSize, originalLines: [OCRTextLine]? = nil) {
        self.blocks = blocks
        self.languages = languages
        self.sourceSize = sourceSize
        self.sourceLines = originalLines
    }

    public var plainText: String {
        blocks.map(\.fullText).joined(separator: "\n\n")
    }

    public var paragraphText: String {
        blocks.map(\.paragraphText).joined(separator: "\n\n")
    }

    /// 识别到的原图行，按图中位置顺序排列。
    public var originalLines: [OCRTextLine] {
        sourceLines ?? blocks.flatMap(\.lines)
    }

    public var originalLinesText: String {
        originalLines.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool { blocks.isEmpty }
}

private enum OCRParagraphSeparator {
    static func between(_ previous: String, _ next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "\n" }
        if last.isWhitespace || first.isWhitespace { return "" }
        if last == "\u{00AD}" { return "\n" } // Keep OCR's explicit soft hyphen without rewriting the text.
        if last == "-", previous.dropLast().last.map(isSpacedWordCharacter) == true, isSpacedWordCharacter(first) {
            return "\n" // A visible hyphen may belong to the word or mark a split.
        }
        if looksLikeSplitLink(previous, first: first) { return "\n" }
        if "([{“‘«¿¡".contains(last) || ",.;:!?%)]}”’»".contains(first) { return "" }
        if usesUnspacedWrap(last) || usesUnspacedWrap(first) { return "" }
        return " "
    }

    private static func isSpacedWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !usesUnspacedWrap(character)
    }

    private static func usesUnspacedWrap(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF9F, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    private static func looksLikeSplitLink(_ previous: String, first: Character) -> Bool {
        guard let last = previous.last, "./?#&=@%".contains(last) || "./?#&=@%".contains(first),
              let tail = previous.split(whereSeparator: \.isWhitespace).last else { return false }
        let token = tail.lowercased()
        return token.contains("://") || token.hasPrefix("www.") || token.contains("@")
    }
}

/// 翻译由应用层的系统 TranslationSession 执行，语言包和授权由 macOS 管理。
