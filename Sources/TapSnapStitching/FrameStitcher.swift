import CoreGraphics
import Foundation

/// 两帧之间在垂直方向上的位移估计。
///
/// 匹配当前帧与上一帧的重叠区域，估计裁剪拼接所需的滚动位移。
public struct Displacement: Sendable {
    /// 垂直位移（像素，向下为正）。
    public var dy: CGFloat
    /// 水平位移，用于处理轻微横向抖动。
    public var dx: CGFloat
    /// 匹配置信度 0...1，过低则视为不连续（例如页面跳转）。
    public var confidence: Double

    public init(dy: CGFloat, dx: CGFloat = 0, confidence: Double = 1) {
        self.dy = dy
        self.dx = dx
        self.confidence = confidence
    }

    public static let unknown = Displacement(dy: 0, dx: 0, confidence: 0)
}

public enum StitchingError: Error {
    case frameTooSmall
    case ambiguousDisplacement
    case incompatibleFrame
    case invalidScrollingRegion
    case layoutChanged
    case reverseScroll
    case imageTooLarge
    case noFrames
}

/// 位移估计器。
///
/// 在相邻原始帧的重叠区做 NCC 平移匹配，并检查独立次峰。
/// 只压缩横向采样，纵向保留原始像素行，避免 Retina 上反复四舍五入丢行。
/// 参考：OpenCV Template Matching；Szeliski, Image Alignment and Stitching。
public final class DisplacementEstimator {
    /// 最小重叠高度（原图像素，最多使用帧高的四分之一）。
    public var searchBand: Int
    /// 参与匹配的降采样宽度。太大慢，太小细节不够。
    public var sampleWidth: Int

    public init(searchBand: Int = 200, sampleWidth: Int = 480) {
        self.searchBand = searchBand
        self.sampleWidth = sampleWidth
    }

    /// 估计 `previous` 的内容在 `next` 中向上滚动了多少像素。
    public func estimate(previous: CGImage, next: CGImage) throws -> Displacement {
        try match(previous: previous, next: next).displacement
    }

    fileprivate struct Match {
        var displacement: Displacement
        /// 当前帧从这一行开始替换累计图的重叠尾部，单位为原图像素。
        var seam: Int
    }

    fileprivate func match(previous: CGImage, next: CGImage) throws -> Match {
        guard previous.width > 16, previous.height > 32,
              next.width > 16, next.height > 32
        else { throw StitchingError.frameTooSmall }
        guard previous.width == next.width, previous.height == next.height else {
            throw StitchingError.incompatibleFrame
        }
        guard let a = GrayFrame(previous, maxWidth: sampleWidth),
              let b = GrayFrame(next, maxWidth: sampleWidth)
        else { throw StitchingError.frameTooSmall }
        // 空白页面和到达底部也是合法的静止帧，无需依赖纹理方差。
        if a.bytes == b.bytes {
            return Match(displacement: Displacement(dy: 0), seam: 0)
        }

        // 连续不动的头尾（吸顶栏/底栏）不参与位移估计。只检测边缘，
        // 不把正文中偶然相同的空白行当作固定界面删除。
        func sameRow(_ y: Int) -> Bool {
            let start = y * a.width
            var difference = 0
            for x in 0..<a.width {
                difference += abs(Int(a.bytes[start + x]) - Int(b.bytes[start + x]))
            }
            return Double(difference) / Double(a.width) < 0.5
        }
        var top = 0
        while top < a.height, sameRow(top) { top += 1 }
        var bottom = a.height
        while bottom > top, sameRow(bottom - 1) { bottom -= 1 }
        let height = bottom - top
        guard height > 32 else { throw StitchingError.ambiguousDisplacement }
        let minimumOverlap = max(24, min(max(24, searchBand), height / 4))
        let maximumShift = height - minimumOverlap
        var scores = [Double](repeating: -2, count: maximumShift * 2 + 1)
        var best = (shift: 0, score: -2.0)

        a.bytes.withUnsafeBufferPointer { lhs in
            b.bytes.withUnsafeBufferPointer { rhs in
                for shift in -maximumShift...maximumShift {
                    let startA = top + max(0, shift)
                    let startB = top + max(0, -shift)
                    let overlap = height - abs(shift)
                    let score = correlation(lhs, rhs, width: a.width,
                                            startA: startA, startB: startB,
                                            height: overlap, rowStep: max(1, overlap / 80))
                    scores[shift + maximumShift] = score
                    if score > best.score { best = (shift, score) }
                }
            }
        }
        guard best.score > -1 else { throw StitchingError.ambiguousDisplacement }
        // 找到全局主峰后再排除其邻域；逐项更新次峰会把主峰旁边的点误作歧义。
        var second = -2.0
        for shift in -maximumShift...maximumShift where abs(shift - best.shift) > 2 {
            second = max(second, scores[shift + maximumShift])
        }
        let verified = a.bytes.withUnsafeBufferPointer { lhs in
            b.bytes.withUnsafeBufferPointer { rhs in
                correlation(lhs, rhs, width: a.width, startA: top + max(0, best.shift),
                            startB: top + max(0, -best.shift), height: height - abs(best.shift), rowStep: 1)
            }
        }
        var confidence = max(0, min(1, min(best.score, verified)))
        if best.score - second < 0.02 { confidence *= 0.5 }
        return Match(displacement: Displacement(dy: CGFloat(best.shift), confidence: confidence),
                     seam: best.shift > 0 ? seamRow(a, b, top: top, bottom: bottom, shift: best.shift) : 0)
    }

    /// 在重叠区选硬切缝。固定浮层在视口原位置不动，却与滚动后的正文不一致：
    /// 旧浮层应使用当前帧已露出的像素，新浮层应保留旧帧仍可见的像素。
    /// 只选择复制边界，不涂白、不融合，也不生成被遮挡的内容。
    private func seamRow(_ a: GrayFrame, _ b: GrayFrame, top: Int, bottom: Int, shift: Int) -> Int {
        let count = bottom - top - shift
        let middle = count / 2
        var oldCost = [Int](repeating: 0, count: count)
        var newCost = [Int](repeating: 0, count: count)

        func hasDetail(_ frame: GrayFrame, x: Int, y: Int) -> Bool {
            let index = y * frame.width + x
            let value = Int(frame.bytes[index])
            return abs(value - Int(frame.bytes[index - 1])) > 1
                || abs(value - Int(frame.bytes[index + 1])) > 1
                || abs(value - Int(frame.bytes[index - frame.width])) > 1
                || abs(value - Int(frame.bytes[index + frame.width])) > 1
        }

        for row in 0..<count {
            let y = top + row
            guard y > 0, y + shift < a.height - 1 else { continue }
            for x in 1..<(a.width - 1) {
                let previous = (y + shift) * a.width + x
                let current = y * a.width + x
                let av = Int(a.bytes[previous]), bv = Int(b.bytes[current])
                let difference = abs(av - bv)
                guard difference > 2 else { continue }
                let oldStable = abs(av - Int(b.bytes[previous])) <= 1
                let newStable = abs(bv - Int(a.bytes[current])) <= 1
                // 单侧稳定也可能是遮住文字的纯色底；双侧都稳定时用纹理区分控件和空白。
                let oldOverlay = oldStable && (!newStable || hasDetail(a, x: x, y: y + shift))
                let newOverlay = newStable && (!oldStable || hasDetail(b, x: x, y: y))
                guard oldOverlay || newOverlay else { continue }
                // 给抗锯齿边缘留两行余量，避免只切掉按钮主体而留下边框。
                for edge in max(0, row - 2)...min(count - 1, row + 2) {
                    if oldOverlay { oldCost[edge] += difference }
                    if newOverlay { newCost[edge] += difference }
                }
            }
        }

        var cost = newCost.reduce(0, +)
        var bestCost = cost
        var seam = 0
        for boundary in 0...count {
            if boundary > 0 { cost += oldCost[boundary - 1] - newCost[boundary - 1] }
            if cost < bestCost || (cost == bestCost && abs(boundary - middle) < abs(seam - middle)) {
                bestCost = cost
                seam = boundary
            }
        }
        return top + seam
    }

    private func correlation(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>,
                             width: Int, startA: Int, startB: Int, height: Int, rowStep: Int) -> Double {
        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0, count = 0.0
        // 忽略最外侧的滚动条/边框；样本分布在整个重叠区，底部空白不会单独决定结果。
        let inset = max(1, width / 32)
        for y in stride(from: 0, to: height, by: rowStep) {
            for x in stride(from: inset, to: width - inset, by: max(1, width / 80)) {
                let av = Double(a[(startA + y) * width + x])
                let bv = Double(b[(startB + y) * width + x])
                sumA += av; sumB += bv
                sumAA += av * av; sumBB += bv * bv; sumAB += av * bv
                count += 1
            }
        }
        guard count > 0 else { return -2 }
        let varianceA = sumAA - sumA * sumA / count
        let varianceB = sumBB - sumB * sumB / count
        guard varianceA > count, varianceB > count else { return -2 }
        return (sumAB - sumA * sumB / count) / (varianceA * varianceB).squareRoot()
    }

    /// 单帧的灰度缓冲（已按宽度缩放）。
    private struct GrayFrame {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: CGImage, maxWidth: Int) {
            let w = max(16, min(maxWidth, image.width))
            let h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h)
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            self.bytes = buffer
            self.width = w
            self.height = h
        }
    }
}

/// 长截图拼帧器。
///
/// 在这里估计位移并拼接画面，由 `LongShotSession` 负责滚动与采集。
public final class FrameStitcher {
    public struct Configuration: Sendable {
        /// 允许的最小位移，小于它认为页面没滚动。
        public var minimumDisplacement: CGFloat
        /// 低于该置信度时停止拼接，避免把错误内容拼进去。
        public var confidenceThreshold: Double

        public init(minimumDisplacement: CGFloat = 1, confidenceThreshold: Double = 0.9) {
            self.minimumDisplacement = minimumDisplacement
            self.confidenceThreshold = confidenceThreshold
        }
    }

    public var configuration: Configuration
    private let estimator: DisplacementEstimator
    private var accumulated: CGImage?
    private var previousFrame: CGImage?
    private var firstFrame: CGImage?
    private var contentStitcher: FrameStitcher?
    private var maximumHeight = Int.max
    public private(set) var scrollingRect: CGRect?

    public init(
        configuration: Configuration = Configuration(),
        estimator: DisplacementEstimator = DisplacementEstimator(),
        scrollingRect: CGRect? = nil
    ) {
        self.configuration = configuration
        self.estimator = estimator
        self.scrollingRect = scrollingRect
    }

    public var currentImage: CGImage? { accumulated }
    public var hasFixedRegions: Bool {
        guard let scrollingRect, let firstFrame else { return false }
        return scrollingRect != CGRect(x: 0, y: 0, width: firstFrame.width, height: firstFrame.height)
    }

    /// 滚动边界来自系统视口或用户框选，不从控件外观猜测。开始拼接后不得改换视口。
    public func setScrollingRect(_ rect: CGRect) throws {
        let rect = try validated(rect, in: firstFrame)
        if let firstFrame, let accumulated, accumulated.height != firstFrame.height {
            throw StitchingError.layoutChanged
        }
        var replacement: FrameStitcher?
        if let firstFrame {
            let content = try makeContentStitcher(for: firstFrame, rect: rect)
            guard let cropped = firstFrame.cropping(to: rect) else { throw StitchingError.invalidScrollingRegion }
            _ = try content.append(cropped)
            replacement = content
        }
        scrollingRect = rect
        contentStitcher = replacement
    }

    private func validated(_ rect: CGRect, in frame: CGImage?) throws -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.minX >= 0, rect.minY >= 0, rect.width > 16, rect.height > 32 else {
            throw StitchingError.invalidScrollingRegion
        }
        let integral = rect.integral
        if let frame {
            guard integral.maxX <= CGFloat(frame.width), integral.maxY <= CGFloat(frame.height) else {
                throw StitchingError.invalidScrollingRegion
            }
        }
        return integral
    }

    private func makeContentStitcher(for frame: CGImage, rect: CGRect) throws -> FrameStitcher {
        let availableHeight = 64_000_000 / frame.width - (frame.height - Int(rect.height))
        guard availableHeight >= Int(rect.height) else { throw StitchingError.imageTooLarge }
        let content = FrameStitcher(configuration: configuration, estimator: estimator)
        content.maximumHeight = availableHeight
        return content
    }

    private func appendInViewport(_ frame: CGImage, rect: CGRect) throws -> CGImage {
        if let firstFrame {
            guard frame.width == firstFrame.width, frame.height == firstFrame.height else {
                throw StitchingError.incompatibleFrame
            }
        }
        let rect = try validated(rect, in: frame)
        guard let cropped = frame.cropping(to: rect) else { throw StitchingError.invalidScrollingRegion }
        let content = try contentStitcher ?? makeContentStitcher(for: frame, rect: rect)
        let body = try content.append(cropped)
        let original = firstFrame ?? frame
        let height = original.height + body.height - Int(rect.height)
        if accumulated == nil {
            firstFrame = frame
            contentStitcher = content
            scrollingRect = rect
            accumulated = frame
            return frame
        }
        if height == accumulated?.height { return accumulated! }
        guard let context = CGContext(data: nil, width: frame.width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchingError.frameTooSmall }
        context.interpolationQuality = .none
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frame.width, height: height))
        func draw(_ source: CGImage, _ sourceRect: CGRect, top: CGFloat) throws {
            guard sourceRect.width > 0, sourceRect.height > 0 else { return }
            guard let part = source.cropping(to: sourceRect) else { throw StitchingError.invalidScrollingRegion }
            context.draw(part, in: CGRect(x: sourceRect.minX, y: CGFloat(height) - top - sourceRect.height,
                                         width: sourceRect.width, height: sourceRect.height))
        }
        // 首屏顶部与两侧仅保留一次；底部位于结果末尾，滚动视口在原横向位置增长。
        try draw(original, CGRect(x: 0, y: 0, width: CGFloat(frame.width), height: rect.minY), top: 0)
        try draw(original, CGRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height), top: rect.minY)
        try draw(original, CGRect(x: rect.maxX, y: rect.minY, width: CGFloat(frame.width) - rect.maxX,
                                  height: rect.height), top: rect.minY)
        let footerHeight = CGFloat(frame.height) - rect.maxY
        try draw(frame, CGRect(x: 0, y: rect.maxY, width: CGFloat(frame.width), height: footerHeight),
                 top: CGFloat(height) - footerHeight)
        context.draw(body, in: CGRect(x: rect.minX, y: footerHeight, width: rect.width, height: CGFloat(body.height)))
        guard let output = context.makeImage() else { throw StitchingError.frameTooSmall }
        accumulated = output
        contentStitcher = content
        scrollingRect = rect
        return output
    }

    /// 加入一帧，返回累计后的结果。
    public func append(_ frame: CGImage) throws -> CGImage {
        if let scrollingRect { return try appendInViewport(frame, rect: scrollingRect) }
        guard let existing = accumulated else {
            guard frame.width > 16, frame.height > 32 else { throw StitchingError.frameTooSmall }
            accumulated = frame
            previousFrame = frame
            firstFrame = frame
            return frame
        }

        guard let previousFrame else { throw StitchingError.noFrames }
        let match = try estimator.match(previous: previousFrame, next: frame)
        let displacement = match.displacement
        guard displacement.confidence >= configuration.confidenceThreshold else {
            throw StitchingError.ambiguousDisplacement
        }

        let shift = Int(displacement.dy.rounded())
        guard shift >= 0 else { throw StitchingError.reverseScroll }
        guard shift >= Int(configuration.minimumDisplacement.rounded()) else {
            // 静止帧只更新配准基线，首屏输出仍保留，避免跨捕获来源的差异持续影响匹配。
            self.previousFrame = frame
            return existing
        }
        guard shift > 0, shift < frame.height else {
            // 位移方向可疑或超过一屏，说明匹配错了，丢掉这一帧。
            throw StitchingError.ambiguousDisplacement
        }

        let width = existing.width
        let totalHeight = existing.height + shift
        // 限制单张结果为 64M 像素（RGBA 约 256 MB），避免会话无限增长。
        guard totalHeight <= min(maximumHeight, 64_000_000 / width) else { throw StitchingError.imageTooLarge }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw StitchingError.frameTooSmall
        }

        // 上下文原点在左下。保留接缝上方的已有内容，用当前帧替换整个重叠尾部，
        // 让后续帧真正露出的正文覆盖旧的固定按钮残片。
        context.interpolationQuality = .none
        let tailHeight = frame.height - match.seam
        let keptHeight = totalHeight - tailHeight
        guard let top = existing.cropping(to: CGRect(x: 0, y: 0, width: width, height: keptHeight)) else {
            throw StitchingError.frameTooSmall
        }
        context.draw(top, in: CGRect(x: 0, y: tailHeight, width: width, height: keptHeight))
        let stripRect = CGRect(
            x: 0,
            y: match.seam,
            width: width,
            height: tailHeight
        )
        guard let strip = frame.cropping(to: stripRect) else {
            throw StitchingError.frameTooSmall
        }
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: tailHeight))

        guard let stitched = context.makeImage() else {
            throw StitchingError.frameTooSmall
        }
        accumulated = stitched
        self.previousFrame = frame
        return stitched
    }

    /// 结束拼接，返回最终长图。
    public func finish() throws -> CGImage {
        guard let accumulated else { throw StitchingError.noFrames }
        return accumulated
    }

    public func reset() {
        accumulated = nil
        previousFrame = nil
        firstFrame = nil
        contentStitcher = nil
        scrollingRect = nil
    }
}
