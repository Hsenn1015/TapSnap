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
/// 在相邻原始帧的真正滚动区域内做 NCC 平移匹配，自动屏蔽固定侧栏、吸顶栏/底栏（含局部时钟或闪烁光标）
/// 并检查独立次峰。只压缩横向采样，纵向保留原始像素行，避免 Retina 上反复四舍五入丢行。
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
        /// 自动检测到的可信固定侧栏排除后的滚动视口（原图像素）；无固定侧栏时为 nil。
        var detectedScrollingRect: CGRect? = nil
    }

    fileprivate func match(previous: CGImage, next: CGImage, detectSidebars: Bool = false) throws -> Match {
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

        // 1. 先按列统计帧间运动，识别出真正发生滚动的水平范围 [activeLeft, activeRight)，
        //    避免固定左右侧栏（微信聊天列表、Notion/GitHub/IDE 侧栏等）在 shift=0 制造假峰并拉低真实位移置信度。
        let activeColumns = activeHorizontalBand(a, b)
        let activeWidth = activeColumns.upperBound - activeColumns.lowerBound

        // 2. 在水平活动列内裁剪连续静止的头尾（吸顶栏/底栏），同时容忍头尾内的局部微小变化（时钟、闪烁光标）。
        let verticalBand = activeVerticalBand(a, b, columns: activeColumns)
        let top = verticalBand.lowerBound
        let bottom = verticalBand.upperBound
        let height = bottom - top
        guard height > 32 else { throw StitchingError.ambiguousDisplacement }

        let minimumOverlap = max(24, min(max(24, searchBand), height / 4))
        let maximumShift = height - minimumOverlap
        var scores = [Double](repeating: -2, count: maximumShift * 2 + 1)
        var best = (shift: 0, score: -2.0)

        // 仅在紧贴外框边缘的一侧留 scrollbar inset；已被侧栏裁剪出的内边界直接用满活动宽度。
        let edgeInset = max(1, a.width / 32)
        let corrLeft = activeColumns.lowerBound == 0 ? min(edgeInset, activeWidth / 4) : activeColumns.lowerBound
        let corrRight = activeColumns.upperBound == a.width
            ? max(corrLeft + 1, a.width - min(edgeInset, activeWidth / 4))
            : activeColumns.upperBound
        let corrColumns = corrLeft..<corrRight

        a.bytes.withUnsafeBufferPointer { lhs in
            b.bytes.withUnsafeBufferPointer { rhs in
                if maximumShift <= 48 {
                    for shift in -maximumShift...maximumShift {
                        let startA = top + max(0, shift)
                        let startB = top + max(0, -shift)
                        let overlap = height - abs(shift)
                        let score = correlation(lhs, rhs, width: a.width, columns: corrColumns,
                                                startA: startA, startB: startB,
                                                height: overlap, rowStep: max(1, overlap / 80))
                        scores[shift + maximumShift] = score
                        if score > best.score { best = (shift, score) }
                    }
                } else {
                    // 真 4× 纵向盒式滤波金字塔粗搜：即使 1px 纯白噪声在 4 行均值层也能形成宽峰，不会漏峰！
                    let factor = 4
                    let pyrCols = corrColumns.lowerBound..<corrColumns.upperBound
                    let pyrColW = max(1, pyrCols.upperBound - pyrCols.lowerBound)
                    let pyrXStep = max(1, pyrColW / 48)
                    let pyrW = (pyrColW + pyrXStep - 1) / pyrXStep
                    let pyrH = height / factor
                    let pyrMaxShift = max(1, maximumShift / factor)

                    var pyrA = [UInt8](repeating: 0, count: pyrW * pyrH)
                    var pyrB = [UInt8](repeating: 0, count: pyrW * pyrH)
                    for py in 0..<pyrH {
                        let baseRow = top + py * factor
                        let dstRow = py * pyrW
                        var px = 0
                        for x in stride(from: pyrCols.lowerBound, to: pyrCols.upperBound, by: pyrXStep) {
                            var sa = 0, sb = 0
                            for dy in 0..<factor {
                                let idx = (baseRow + dy) * a.width + x
                                sa += Int(lhs[idx])
                                sb += Int(rhs[idx])
                            }
                            pyrA[dstRow + px] = UInt8(sa / factor)
                            pyrB[dstRow + px] = UInt8(sb / factor)
                            px += 1
                        }
                    }

                    var coarsePeaks: [(shift: Int, score: Double)] = []
                    coarsePeaks.reserveCapacity(12)
                    pyrA.withUnsafeBufferPointer { pLhs in
                        pyrB.withUnsafeBufferPointer { pRhs in
                            for pShift in -pyrMaxShift...pyrMaxShift {
                                let sA = max(0, pShift)
                                let sB = max(0, -pShift)
                                let ov = pyrH - abs(pShift)
                                guard ov >= 6 else { continue }
                                let pScore = correlation(pLhs, pRhs, width: pyrW, columns: 0..<pyrW,
                                                         startA: sA, startB: sB,
                                                         height: ov, rowStep: max(1, ov / 48), maxCols: pyrW)
                                let fullShift = min(maximumShift, max(-maximumShift, pShift * factor))
                                scores[fullShift + maximumShift] = max(scores[fullShift + maximumShift], pScore)
                                if pScore > -1 {
                                    if coarsePeaks.count < 10 {
                                        coarsePeaks.append((fullShift, pScore))
                                    } else if let minIdx = coarsePeaks.indices.min(by: { coarsePeaks[$0].score < coarsePeaks[$1].score }),
                                              pScore > coarsePeaks[minIdx].score {
                                        coarsePeaks[minIdx] = (fullShift, pScore)
                                    }
                                }
                            }
                        }
                    }

                    var refineCenters = Set(coarsePeaks.map(\.shift))
                    refineCenters.insert(0)
                    refineCenters.insert(maximumShift)
                    refineCenters.insert(-maximumShift)

                    var refined = [Bool](repeating: false, count: maximumShift * 2 + 1)
                    for center in refineCenters {
                        let lo = max(-maximumShift, center - factor)
                        let hi = min(maximumShift, center + factor)
                        for shift in lo...hi {
                            let idx = shift + maximumShift
                            guard !refined[idx] else { continue }
                            refined[idx] = true
                            let startA = top + max(0, shift)
                            let startB = top + max(0, -shift)
                            let overlap = height - abs(shift)
                            let score = correlation(lhs, rhs, width: a.width, columns: corrColumns,
                                                    startA: startA, startB: startB,
                                                    height: overlap, rowStep: max(1, overlap / 80))
                            scores[idx] = score
                            if score > best.score { best = (shift, score) }
                        }
                    }

                    // 极端低信噪比回退：若金字塔精搜最高分仍偏低，补扫剩余偏移确保绝不漏解。
                    if best.score < 0.85 {
                        for shift in -maximumShift...maximumShift {
                            let idx = shift + maximumShift
                            guard !refined[idx] else { continue }
                            let startA = top + max(0, shift)
                            let startB = top + max(0, -shift)
                            let overlap = height - abs(shift)
                            let score = correlation(lhs, rhs, width: a.width, columns: corrColumns,
                                                    startA: startA, startB: startB,
                                                    height: overlap, rowStep: max(1, overlap / 80))
                            scores[idx] = score
                            if score > best.score { best = (shift, score) }
                        }
                    }
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
                correlation(lhs, rhs, width: a.width, columns: corrColumns,
                            startA: top + max(0, best.shift),
                            startB: top + max(0, -best.shift),
                            height: height - abs(best.shift), rowStep: 1)
            }
        }
        var confidence = max(0, min(1, min(best.score, verified)))
        if best.score - second < 0.02 { confidence *= 0.5 }

        let seam = best.shift > 0
            ? seamRow(a, b, top: top, bottom: bottom, columns: 1..<(a.width - 1), shift: best.shift)
            : 0
        var detectedRect: CGRect?
        if detectSidebars, best.shift >= 12, confidence >= 0.85,
           (activeColumns.lowerBound > 0 || activeColumns.upperBound < a.width) {
            detectedRect = detectFixedSidebarViewport(
                a, b,
                originalWidth: previous.width,
                originalHeight: previous.height,
                activeColumns: activeColumns,
                top: top,
                bottom: bottom,
                shift: best.shift
            )
        }
        return Match(displacement: Displacement(dy: CGFloat(best.shift), confidence: confidence),
                     seam: seam,
                     detectedScrollingRect: detectedRect)
    }

    /// 统计每一列的帧间变化与静态纹理比例，收缩掉左右两侧完全静止（或仅极局部徽标变动）的侧栏/空白列。
    private func activeHorizontalBand(_ a: GrayFrame, _ b: GrayFrame) -> Range<Int> {
        let w = a.width, h = a.height
        guard w >= 32, h >= 32 else { return 0..<w }
        let yStep = max(1, h / 200)
        var sampledRows = 0
        var changed = [Int](repeating: 0, count: w)
        var textured = [Int](repeating: 0, count: w)
        var staticTextured = [Int](repeating: 0, count: w)

        for y in stride(from: 1, to: h - 1, by: yStep) {
            sampledRows += 1
            let rowOffset = y * w
            for x in 1..<(w - 1) {
                let idx = rowOffset + x
                let av = Int(a.bytes[idx])
                let bv = Int(b.bytes[idx])
                let diff = abs(av - bv)
                if diff > 2 { changed[x] += 1 }
                let grad = max(
                    abs(av - Int(a.bytes[idx - 1])),
                    abs(av - Int(a.bytes[idx + 1])),
                    abs(av - Int(a.bytes[idx - w])),
                    abs(av - Int(a.bytes[idx + w]))
                )
                if grad > 4 {
                    textured[x] += 1
                    if diff <= 2 { staticTextured[x] += 1 }
                }
            }
        }
        guard sampledRows > 0 else { return 0..<w }

        func isInactiveColumn(_ x: Int) -> Bool {
            if x == 0 || x == w - 1 { return true }
            let changeRatio = Double(changed[x]) / Double(sampledRows)
            if changed[x] <= 1 && changeRatio < 0.015 { return true }
            // 侧栏里偶有单个 hover 项或未读红点变动时，其绝大多数静态纹理仍保持不动。
            if textured[x] >= 6,
               Double(staticTextured[x]) / Double(textured[x]) >= 0.86,
               changeRatio <= 0.10 {
                return true
            }
            return false
        }

        var left = 0
        while left < w, isInactiveColumn(left) { left += 1 }
        var right = w
        while right > left, isInactiveColumn(right - 1) { right -= 1 }

        // 防止误缩成极窄噪点（例如仅有细滚动条在动）；活动列太窄时回退整幅宽度。
        let minActiveWidth = max(16, w / 6)
        guard right - left >= minActiveWidth else { return 0..<w }
        // 若裁剪后几乎就是整宽，则直接返回 0..<w，保持原有精确边缘逻辑。
        let trimmedLeft = left >= max(8, w / 24) ? left : 0
        let trimmedRight = (w - right) >= max(8, w / 24) ? right : w
        return trimmedLeft..<trimmedRight
    }

    /// 在活动列范围内裁剪顶/底固定栏（如吸顶导航栏、底部聊天输入框），
    /// 不仅去除 100% 静止行，也能跨越头尾内带时钟/闪烁光标的局部动态行。
    private func activeVerticalBand(_ a: GrayFrame, _ b: GrayFrame, columns: Range<Int>) -> Range<Int> {
        let w = a.width, h = a.height
        let colStart = max(1, columns.lowerBound)
        let colEnd = min(w - 1, columns.upperBound)
        let colCount = max(1, colEnd - colStart)

        func isExactStaticRow(_ y: Int) -> Bool {
            let start = y * w
            var diffSum = 0
            for x in colStart..<colEnd {
                diffSum += abs(Int(a.bytes[start + x]) - Int(b.bytes[start + x]))
            }
            return Double(diffSum) / Double(colCount) < 0.5
        }

        // 某行虽有极小区域变化（时钟、闪烁光标、加载点），但本行大部分像素与静态纹理均未移动。
        func isMostlyStaticChromeRow(_ y: Int) -> Bool {
            guard y > 0, y < h - 1 else { return isExactStaticRow(y) }
            let start = y * w
            var changed = 0
            var textured = 0
            var staticTextured = 0
            for x in colStart..<colEnd {
                let idx = start + x
                let av = Int(a.bytes[idx])
                let bv = Int(b.bytes[idx])
                let diff = abs(av - bv)
                if diff > 2 { changed += 1 }
                let grad = max(
                    abs(av - Int(a.bytes[idx - 1])),
                    abs(av - Int(a.bytes[idx + 1])),
                    abs(av - Int(a.bytes[idx - w])),
                    abs(av - Int(a.bytes[idx + w]))
                )
                if grad > 4 {
                    textured += 1
                    if diff <= 2 { staticTextured += 1 }
                }
            }
            let changedRatio = Double(changed) / Double(colCount)
            guard changedRatio <= 0.14 else { return false }
            if textured == 0 { return changedRatio <= 0.03 }
            return Double(staticTextured) / Double(textured) >= 0.80
        }

        // 第一阶段：严格静止边缘裁剪
        var top = 0
        while top < h, isExactStaticRow(top) { top += 1 }
        var bottom = h
        while bottom > top, isExactStaticRow(bottom - 1) { bottom -= 1 }

        // 第二阶段：若紧挨着边缘有一小段带局部动态（时钟/光标）的固定栏，且其后仍有静止底色/分隔线，则一并剔除。
        let maxEdgeChrome = h / 2
        if top < maxEdgeChrome {
            var scan = top
            var lastStaticAnchor = top
            while scan < min(bottom, maxEdgeChrome), isMostlyStaticChromeRow(scan) {
                if isExactStaticRow(scan) { lastStaticAnchor = scan + 1 }
                scan += 1
            }
            // 仅当跨过局部动态后确实重新遇到静止分隔线/底色（证实它属于固定头栏），才推进 top。
            if lastStaticAnchor > top, bottom - lastStaticAnchor > 32 {
                top = lastStaticAnchor
            }
        }
        if h - bottom < maxEdgeChrome {
            var scan = bottom
            var firstStaticAnchor = bottom
            while scan > max(top, h - maxEdgeChrome), isMostlyStaticChromeRow(scan - 1) {
                if isExactStaticRow(scan - 1) { firstStaticAnchor = scan - 1 }
                scan -= 1
            }
            if firstStaticAnchor < bottom, firstStaticAnchor - top > 32 {
                bottom = firstStaticAnchor
            }
        }

        return top..<bottom
    }

    /// 4 重防误判校验：只有能明确证明边缘列是「多段分布、0 位移静止、且非周期性」的真实固定侧栏时，
    /// 才返回扣除固定侧栏后的滚动视口；绝不误伤局部悬浮按钮、纯白页边或周期性表格复选框。
    private func detectFixedSidebarViewport(
        _ a: GrayFrame,
        _ b: GrayFrame,
        originalWidth: Int,
        originalHeight: Int,
        activeColumns: Range<Int>,
        top: Int,
        bottom: Int,
        shift: Int
    ) -> CGRect? {
        let w = a.width
        let h = bottom - top
        guard h > 64, shift > 0, shift < h - 16 else { return nil }
        let scaleX = Double(originalWidth) / Double(w)

        func provesFixedSidebar(colRange: Range<Int>) -> Bool {
            let stripW = colRange.upperBound - colRange.lowerBound
            let origStripW = Double(stripW) * scaleX
            guard stripW >= 12, origStripW >= 48, origStripW <= Double(originalWidth) * 0.75 else { return false }

            // Gate 2：在 8 个纵向分带中统计静态纹理分布（排除仅在角落出现的 1~2 个小悬浮按钮）
            let bandCount = 8
            var staticTexturedBands = 0
            var interiorStaticBands = 0
            var movingBands = 0
            var totalSamples = 0
            var totalStaticPixels = 0
            var totalStaticDiff = 0
            var totalTextured = 0
            var totalStaticTextured = 0
            var staticTexturedRows = 0

            let innerLeft = max(1, colRange.lowerBound + 2)
            let innerRight = min(w - 1, colRange.upperBound - 2)
            guard innerRight > innerLeft + 4 else { return false }

            for band in 0..<bandCount {
                let y0 = top + (h * band) / bandCount
                let y1 = top + (h * (band + 1)) / bandCount
                var bandStaticTextured = 0
                var bandTotalTextured = 0
                var bandMoving = 0
                var bandSamples = 0
                for y in max(1, y0)..<min(a.height - 1, y1) {
                    var rowHasStaticTex = false
                    let rowBase = y * w
                    for x in innerLeft..<innerRight {
                        let idx = rowBase + x
                        let av = Int(a.bytes[idx])
                        let bv = Int(b.bytes[idx])
                        let diff = abs(av - bv)
                        bandSamples += 1
                        totalSamples += 1
                        totalStaticDiff += diff
                        if diff <= 3 { totalStaticPixels += 1 }
                        if diff > 4 { bandMoving += 1 }
                        let grad = max(
                            abs(av - Int(a.bytes[idx - 1])),
                            abs(av - Int(a.bytes[idx + 1])),
                            abs(av - Int(a.bytes[idx - w])),
                            abs(av - Int(a.bytes[idx + w]))
                        )
                        if grad > 6 {
                            bandTotalTextured += 1
                            totalTextured += 1
                            if diff <= 2 {
                                bandStaticTextured += 1
                                totalStaticTextured += 1
                                rowHasStaticTex = true
                            }
                        }
                    }
                    if rowHasStaticTex { staticTexturedRows += 1 }
                }
                if bandStaticTextured >= 12,
                   bandTotalTextured > 0,
                   Double(bandStaticTextured) / Double(bandTotalTextured) >= 0.85 {
                    staticTexturedBands += 1
                    if band >= 1 && band <= bandCount - 2 { interiorStaticBands += 1 }
                }
                if (bandSamples > 0 && Double(bandMoving) / Double(bandSamples) > 0.08)
                    || (bandTotalTextured >= 12 && Double(bandStaticTextured) / Double(bandTotalTextured) < 0.70) {
                    movingBands += 1
                }
            }

            guard totalSamples > 0, totalTextured >= 36 else { return false }
            let staticPixelRatio = Double(totalStaticPixels) / Double(totalSamples)
            let staticTexturedRatio = Double(totalStaticTextured) / Double(totalTextured)
            let staticMAD = Double(totalStaticDiff) / Double(totalSamples)
            let texturedRowRatio = Double(staticTexturedRows) / Double(h)

            // 必须分布于至少 3 个纯静态纵带（含中间带）、纹理像素本身静止占比 ≥ 88%、静态纹理行数占比 ≥ 12%。
            guard staticTexturedBands >= 3,
                  interiorStaticBands >= 1,
                  texturedRowRatio >= 0.12,
                  movingBands <= 1,
                  staticPixelRatio >= 0.92,
                  staticTexturedRatio >= 0.88 else {
                return false
            }

            // Gate 4：非周期性校验——如果该列在 shift 位移下同样高度匹配（如周期重复复选框列或纯色竖线），绝不判作固定侧栏！
            let overlapH = h - shift
            guard overlapH >= 24 else { return false }
            var shiftedTexturedDiff = 0
            var shiftedTexturedTotal = 0
            var shiftedTexturedMatch = 0
            let yStep = max(1, overlapH / 160)
            for row in stride(from: 1, to: overlapH - 1, by: yStep) {
                let yA = top + row + shift
                let yB = top + row
                guard yA < a.height - 1, yB < b.height - 1 else { continue }
                for x in innerLeft..<innerRight {
                    let idxA = yA * w + x
                    let idxB = yB * w + x
                    let av = Int(a.bytes[idxA])
                    let bv = Int(b.bytes[idxB])
                    let diff = abs(av - bv)
                    let grad = max(
                        abs(av - Int(a.bytes[idxA - 1])),
                        abs(av - Int(a.bytes[idxA + 1])),
                        abs(av - Int(a.bytes[idxA - w])),
                        abs(av - Int(a.bytes[idxA + w]))
                    )
                    if grad > 6 {
                        shiftedTexturedTotal += 1
                        shiftedTexturedDiff += diff
                        if diff <= 3 { shiftedTexturedMatch += 1 }
                    }
                }
            }
            guard shiftedTexturedTotal >= 12 else { return false }
            let shiftedTexturedMAD = Double(shiftedTexturedDiff) / Double(shiftedTexturedTotal)
            let shiftedTexMatchRatio = Double(shiftedTexturedMatch) / Double(shiftedTexturedTotal)
            return shiftedTexturedMAD > max(8.0, staticMAD * 4.0) && shiftedTexMatchRatio < 0.72
        }

        // 收紧侧栏边界到静态纹理外缘（不吞掉正文白边，避免截断后续出现的宽图）
        func tightSidebarEnd(fromLeft: Bool, limit: Int) -> Int {
            let yStep = max(1, h / 160)
            func columnHasStaticContent(_ x: Int) -> Bool {
                guard x > 0, x < w - 1 else { return false }
                var tex = 0
                for y in stride(from: max(1, top), to: min(a.height - 1, bottom), by: yStep) {
                    let idx = y * w + x
                    let av = Int(a.bytes[idx])
                    let bv = Int(b.bytes[idx])
                    guard abs(av - bv) <= 2 else { continue }
                    let grad = max(
                        abs(av - Int(a.bytes[idx - 1])),
                        abs(av - Int(a.bytes[idx + 1])),
                        abs(av - Int(a.bytes[idx - w])),
                        abs(av - Int(a.bytes[idx + w]))
                    )
                    if grad > 5 { tex += 1 }
                }
                return tex >= 3
            }

            if fromLeft {
                var edge = limit
                while edge > 0, !columnHasStaticContent(edge - 1) { edge -= 1 }
                return min(limit, edge + 2)
            } else {
                var edge = limit
                while edge < w, !columnHasStaticContent(edge) { edge += 1 }
                return max(limit, edge - 2)
            }
        }

        var leftOrigX = 0
        if activeColumns.lowerBound > 0, provesFixedSidebar(colRange: 0..<activeColumns.lowerBound) {
            let tight = tightSidebarEnd(fromLeft: true, limit: activeColumns.lowerBound)
            leftOrigX = min(originalWidth, max(0, Int((Double(tight) * scaleX).rounded())))
        }
        var rightOrigX = originalWidth
        if activeColumns.upperBound < w, provesFixedSidebar(colRange: activeColumns.upperBound..<w) {
            let tight = tightSidebarEnd(fromLeft: false, limit: activeColumns.upperBound)
            rightOrigX = min(originalWidth, max(leftOrigX, Int((Double(tight) * scaleX).rounded())))
        }

        guard leftOrigX > 0 || rightOrigX < originalWidth else { return nil }
        let bodyWidth = rightOrigX - leftOrigX
        guard bodyWidth >= max(120, originalWidth / 4) else { return nil }
        return CGRect(x: leftOrigX, y: top, width: bodyWidth, height: bottom - top)
    }

    /// 在重叠区选硬切缝。固定浮层在视口原位置不动，却与滚动后的正文不一致：
    /// 旧浮层应使用当前帧已露出的像素，新浮层应保留旧帧仍可见的像素。
    /// 只选择复制边界，不涂白、不融合，也不生成被遮挡的内容。
    private func seamRow(_ a: GrayFrame, _ b: GrayFrame, top: Int, bottom: Int,
                         columns: Range<Int>, shift: Int) -> Int {
        let count = bottom - top - shift
        guard count > 0 else { return top }
        let middle = count / 2
        var oldCost = [Int](repeating: 0, count: count)
        var newCost = [Int](repeating: 0, count: count)
        var hasVisibleDifference = false
        let xStart = max(1, columns.lowerBound)
        let xEnd = min(a.width - 1, columns.upperBound)

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
            for x in xStart..<xEnd {
                let previous = (y + shift) * a.width + x
                let current = y * a.width + x
                let av = Int(a.bytes[previous]), bv = Int(b.bytes[current])
                let difference = abs(av - bv)
                guard difference > 2 else { continue }
                hasVisibleDifference = true
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

        guard hasVisibleDifference else { return top + middle }
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
        return top + seamAvoidingSoftEdge(seam, previous: a, next: b, top: top, count: count,
                                          columns: xStart..<xEnd, shift: shift)
    }

    /// 半透明边缘会让滚过的文字变淡，原屏幕坐标上的像素也随之变化。
    /// 只有重叠正文中有足够长的连续吻合区，才考虑把原接缝移进它。
    private func seamAvoidingSoftEdge(_ seam: Int, previous: GrayFrame, next: GrayFrame,
                                      top: Int, count: Int, columns: Range<Int>, shift: Int) -> Int {
        let width = next.width
        let inset = max(1, width / 32) // 与位移估计一样，跳过两侧的滚动条。
        let safeStart = max(columns.lowerBound, inset)
        let safeEnd = min(columns.upperBound, width - inset)
        guard safeEnd > safeStart else { return seam }
        let safeColumns = safeStart..<safeEnd
        var matching = 0..<0
        var start = 0
        for row in 0..<count {
            let current = (top + row) * width
            let prior = current + shift * width
            let agrees = safeColumns.allSatisfy { x in
                abs(Int(previous.bytes[prior + x]) - Int(next.bytes[current + x])) <= 1
            }
            if !agrees {
                start = row + 1
            } else if row + 1 - start > matching.count {
                matching = start..<(row + 1)
            }
        }
        guard matching.count > count / 3,
              seam < matching.lowerBound || seam > matching.upperBound else { return seam }

        // 向下滚动时，重叠区上端在新帧更靠近顶部，下端在旧帧更靠近底部。
        let nearTop = seam < matching.lowerBound
        let suspectRows = nearTop ? 0..<matching.lowerBound : matching.upperBound..<count
        var clearEnergy = 0.0, edgeEnergy = 0.0, sharedGradient = 0.0
        var tintedRows = 0
        for row in suspectRows {
            let y = top + row
            guard y > 0, y + shift < previous.height - 1 else { continue }
            var tintedSamples = 0
            for x in safeColumns {
                let current = y * width + x
                let prior = current + shift * width
                let difference = abs(Int(previous.bytes[prior]) - Int(next.bytes[current]))
                guard difference > 0 else { continue }
                let fixed = nearTop ? current : prior
                if difference <= 16 && abs(Int(previous.bytes[fixed]) - Int(next.bytes[fixed])) <= 1 {
                    tintedSamples += 1
                }
                let ax = Int(previous.bytes[prior + 1]) - Int(previous.bytes[prior - 1])
                let ay = Int(previous.bytes[prior + width]) - Int(previous.bytes[prior - width])
                let bx = Int(next.bytes[current + 1]) - Int(next.bytes[current - 1])
                let by = Int(next.bytes[current + width]) - Int(next.bytes[current - width])
                let ae = Double(ax * ax + ay * ay), be = Double(bx * bx + by * by)
                clearEnergy += nearTop ? ae : be
                edgeEnergy += nearTop ? be : ae
                sharedGradient += Double(ax * bx + ay * by)
            }
            if tintedSamples > safeColumns.count / 2 { tintedRows += 1 }
        }
        // 对齐后的笔画应同向。平滑会减弱梯度；渐变在少字处主要表现为固定的轻微底色。
        let sameStructure = sharedGradient > 0.5 * sqrt(clearEnergy * edgeEnergy)
        let gradientDifference = clearEnergy + edgeEnergy - 2 * sharedGradient
        let softer = clearEnergy - edgeEnergy > max(0.05 * edgeEnergy, 0.5 * gradientDifference)
        let fixedTint = tintedRows >= max(3, suspectRows.count / 4)
        guard sameStructure && (softer || fixedTint) else { return seam }
        return matching.lowerBound + matching.count / 2
    }

    private func correlation(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>,
                             width: Int, columns: Range<Int>, startA: Int, startB: Int,
                             height: Int, rowStep: Int, maxCols: Int = 80) -> Double {
        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0, count = 0.0
        let colWidth = max(1, columns.upperBound - columns.lowerBound)
        let xStep = max(1, colWidth / maxCols)
        for y in stride(from: 0, to: height, by: rowStep) {
            let rowA = (startA + y) * width
            let rowB = (startB + y) * width
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: xStep) {
                let av = Double(a[rowA + x])
                let bv = Double(b[rowB + x])
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
    private var accumulatedBuffer: Data?
    private var previousFrame: CGImage?
    private var firstFrame: CGImage?
    private var contentStitcher: FrameStitcher?
    private var maximumHeight = Int.max
    private let allowsAutomaticSidebarDetection: Bool
    public private(set) var scrollingRect: CGRect?

    public init(
        configuration: Configuration = Configuration(),
        estimator: DisplacementEstimator = DisplacementEstimator(),
        scrollingRect: CGRect? = nil
    ) {
        self.configuration = configuration
        self.estimator = estimator
        self.scrollingRect = scrollingRect
        self.allowsAutomaticSidebarDetection = true
    }

    private init(
        configuration: Configuration,
        estimator: DisplacementEstimator,
        allowsAutomaticSidebarDetection: Bool
    ) {
        self.configuration = configuration
        self.estimator = estimator
        self.scrollingRect = nil
        self.allowsAutomaticSidebarDetection = allowsAutomaticSidebarDetection
    }

    public var currentImage: CGImage? { accumulated }
    public var hasFixedRegions: Bool {
        if let contentStitcher, contentStitcher.hasFixedRegions { return true }
        guard let scrollingRect, let firstFrame else { return false }
        return scrollingRect != CGRect(x: 0, y: 0, width: firstFrame.width, height: firstFrame.height)
    }

    /// 设置滚动视口（来自系统 AX 视口、用户框选或首帧自动检测）。开始拼接增长后不得改换视口。
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
        // 若当前视口就是整张画面（如 Chrome/Electron 外层 WebView），仍允许内部自动识别 CSS 固定侧栏。
        let isFullFrame = rect == CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let content = FrameStitcher(configuration: configuration, estimator: estimator,
                                    allowsAutomaticSidebarDetection: isFullFrame)
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
        let canAutoDetectSidebar = allowsAutomaticSidebarDetection
            && firstFrame.map { existing.height == $0.height } ?? false
        let match = try estimator.match(previous: previousFrame, next: frame,
                                        detectSidebars: canAutoDetectSidebar)
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

        // 首段滚动即自动识别出真实固定侧栏时，升级为视口拼接模式，固定侧栏仅保留一次，不重复切条！
        if canAutoDetectSidebar, let autoRect = match.detectedScrollingRect,
           let validRect = try? validated(autoRect, in: frame) {
            try setScrollingRect(validRect)
            return try appendInViewport(frame, rect: validRect)
        }

        let width = existing.width
        let totalHeight = existing.height + shift
        // 限制单张结果为 64M 像素（RGBA 约 256 MB），避免会话无限增长。
        guard totalHeight <= min(maximumHeight, 64_000_000 / width) else { throw StitchingError.imageTooLarge }
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        // 惰性将首帧规范化为连续 sRGB RGBA 顶向下缓冲；后续拼接直接 memcpy 前缀行，不再重绘整张历史画布。
        let previousBuffer: Data
        if let existingBuffer = accumulatedBuffer, existingBuffer.count == existing.height * bytesPerRow {
            previousBuffer = existingBuffer
        } else {
            var rendered = Data(count: existing.height * bytesPerRow)
            let ok = rendered.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: existing.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(existing, in: CGRect(x: 0, y: 0, width: width, height: existing.height))
                return true
            }
            guard ok else { throw StitchingError.frameTooSmall }
            previousBuffer = rendered
        }

        let tailHeight = frame.height - match.seam
        let keptHeight = totalHeight - tailHeight
        guard keptHeight >= 0, keptHeight <= existing.height, tailHeight > 0 else {
            throw StitchingError.frameTooSmall
        }
        guard let strip = frame.cropping(to: CGRect(x: 0, y: match.seam, width: width, height: tailHeight)) else {
            throw StitchingError.frameTooSmall
        }

        var nextBuffer = Data(count: totalHeight * bytesPerRow)
        let composed = nextBuffer.withUnsafeMutableBytes { dstRaw -> Bool in
            guard let dstBase = dstRaw.baseAddress else { return false }
            if keptHeight > 0 {
                previousBuffer.withUnsafeBytes { srcRaw in
                    if let srcBase = srcRaw.baseAddress {
                        memcpy(dstBase, srcBase, keptHeight * bytesPerRow)
                    }
                }
            }
            let tailPtr = dstBase.advanced(by: keptHeight * bytesPerRow)
            guard let tailCtx = CGContext(data: tailPtr, width: width, height: tailHeight,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return false }
            tailCtx.interpolationQuality = .none
            tailCtx.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: tailHeight))
            return true
        }
        guard composed,
              let provider = CGDataProvider(data: nextBuffer as CFData),
              let stitched = CGImage(width: width, height: totalHeight,
                                     bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                     space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw StitchingError.frameTooSmall
        }

        accumulatedBuffer = nextBuffer
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
        accumulatedBuffer = nil
        previousFrame = nil
        firstFrame = nil
        contentStitcher = nil
        scrollingRect = nil
    }
}
