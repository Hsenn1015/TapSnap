import CoreText
import SwiftUI

/// 同一张示例图，第一行保留原样，第二行由编辑器渲染选中的效果。
struct RedactionStylePreview: View, Equatable {
    private static let sampleWidth = 98
    private static let sampleHeight = 56
    private static let scale: CGFloat = 2
    let mode: MosaicItem.Mode
    var blockSize = 12

    var body: some View {
        let image = Self.render(mode, blockSize: blockSize)
        Image(decorative: image, scale: Self.scale)
            .resizable()
            .interpolation(.high)
            .frame(height: CGFloat(Self.sampleHeight))
            .clipShape(.rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.09), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private static let demoBounds = CGRect(x: 13, y: 33, width: 72, height: 15)
    private static let source: CGImage = {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: sampleWidth * Int(scale), height: sampleHeight * Int(scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        context.setFillColor(CGColor(red: 0.71, green: 0.76, blue: 0.84, alpha: 1))
        context.fill(CGRect(x: sampleWidth / 2, y: 0, width: sampleWidth / 2, height: sampleHeight))
        context.setFillColor(CGColor(red: 0.86, green: 0.89, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 6, y: 28, width: CGFloat(sampleWidth - 12), height: 0.5))

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 9, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.14, green: 0.22, blue: 0.35, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "DEMO 4281", attributes: attributes))
        for center in [16, 42] {
            context.setFillColor(CGColor(red: 0.19, green: 0.45, blue: 0.83, alpha: 1))
            context.fillEllipse(in: CGRect(x: 16, y: center - 3, width: 5, height: 5))
            context.setFillColor(CGColor(red: 0.84, green: 0.42, blue: 0.22, alpha: 1))
            context.fillEllipse(in: CGRect(x: 77, y: center - 3, width: 5, height: 5))
            context.textPosition = CGPoint(x: 25, y: center - 3)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }()

    static func render(_ mode: MosaicItem.Mode, blockSize: Int = 12) -> CGImage {
        let item = MosaicItem(bounds: demoBounds, mode: mode, blockSize: blockSize)
        let document = EditDocument(baseImage: source, scale: scale, items: [item])
        return (try? document.render()) ?? source
    }
}
