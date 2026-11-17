import Foundation
import CoreGraphics

/// 公式排版接口。
public protocol FormulaRenderer: AnyObject {
    /// 把 LaTeX 源码排成可绘制的元素列表。
    func layout(latex: String, width: CGFloat, fontSize: CGFloat) throws -> FormulaLayout
}

public enum FormulaError: Error {
    case parseFailed(String)
    case unsupportedCommand(String)
}

/// 一次排版的结果。
public struct FormulaLayout: Sendable {
    public var size: CGSize
    /// 可绘制的字形（位置 + 字体 + 字符），由渲染层消费。
    public var glyphs: [FormulaGlyph]

    public init(size: CGSize, glyphs: [FormulaGlyph] = []) {
        self.size = size
        self.glyphs = glyphs
    }
}

public struct FormulaGlyph: Sendable {
    public var character: Character
    public var origin: CGPoint
    public var fontSize: CGFloat
    /// 斜体/正体/粗体等字形类别。
    public var style: FormulaGlyphStyle

    public init(character: Character, origin: CGPoint, fontSize: CGFloat, style: FormulaGlyphStyle) {
        self.character = character
        self.origin = origin
        self.fontSize = fontSize
        self.style = style
    }
}

public enum FormulaGlyphStyle: String, Sendable {
    case mathItalic
    case roman
    case bold
    case calligraphic
}

/// 编辑中的公式文档。
public final class FormulaDocument: @unchecked Sendable {
    public private(set) var latex: String
    public var fontSize: CGFloat
    public var renderer: FormulaRenderer?

    public init(latex: String = "", fontSize: CGFloat = 14) {
        self.latex = latex
        self.fontSize = fontSize
    }

    public func update(latex: String) throws -> FormulaLayout {
        self.latex = latex
        guard let renderer else { throw FormulaError.parseFailed("未设置渲染器") }
        return try renderer.layout(latex: latex, width: .infinity, fontSize: fontSize)
    }
}
