import CoreGraphics
import Foundation

/// Restores row boundaries in striped tables before assigning OCR text to cells.
public enum OCRTableBands {
    private struct TextBox {
        let line: OCRTextLine
        let rect: CGRect
    }

    private struct Edge {
        let firstY: Int
        var lastY: Int
        var left: Int
        var right: Int
        let lightens: Bool

        var y: Int { (firstY + lastY + 1) / 2 }
        var width: Int { right - left + 1 }

        func spansSameColumns(as other: Edge) -> Bool {
            let tolerance = max(3, min(width, other.width) / 15)
            return abs(left - other.left) <= tolerance && abs(right - other.right) <= tolerance
        }
    }

    public static func tables(in document: OCRDocument, image: CGImage) -> [OCRTableRegion] {
        guard document.originalLines.count >= 8, let raster = Raster(image) else { return [] }
        let boxes = document.originalLines.compactMap { line -> TextBox? in
            let bounds = line.normalizedBounds
            guard !bounds.isEmpty, bounds.minX.isFinite, bounds.minY.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite else { return nil }
            return TextBox(line: line, rect: CGRect(x: bounds.minX * CGFloat(raster.width),
                y: (1 - bounds.maxY) * CGFloat(raster.height), width: bounds.width * CGFloat(raster.width),
                height: bounds.height * CGFloat(raster.height)))
        }
        guard let lineHeight = median(boxes.map(\.rect.height)), lineHeight >= 4 else { return [] }
        let edges = raster.edges(samplingDistance: max(1, min(4, Int(lineHeight / 6))))
        let horizontalFontSize = lineHeight * CGFloat(raster.width) * CGFloat(image.height)
            / (CGFloat(raster.height) * CGFloat(image.width))
        var regions: [OCRTableRegion] = []
        var start = 0
        while start + 4 < edges.count {
            let boundaries = alternatingEdges(in: edges, startingAt: start, lineHeight: lineHeight)
            if boundaries.count >= 5, let region = table(from: boundaries.map { edges[$0] }, boxes: boxes,
                raster: raster, lineHeight: lineHeight, horizontalFontSize: horizontalFontSize) {
                regions.append(region)
                start = boundaries[boundaries.count - 1] + 1
            } else {
                start += 1
            }
        }
        return regions
    }

    private static func alternatingEdges(in edges: [Edge], startingAt start: Int, lineHeight: CGFloat) -> [Int] {
        let first = edges[start]
        var matches = [start]
        var last = first
        for index in (start + 1)..<edges.count {
            let next = edges[index]
            let pitch = CGFloat(next.y - last.y)
            if pitch > lineHeight * 8 { break }
            guard pitch >= max(8, lineHeight * 1.05), next.lightens != last.lightens,
                  first.spansSameColumns(as: next) else { continue }
            matches.append(index)
            last = next
        }
        return matches
    }

    private static func table(from edges: [Edge], boxes: [TextBox], raster: Raster,
                              lineHeight: CGFloat, horizontalFontSize: CGFloat) -> OCRTableRegion? {
        let left = median(edges.map { CGFloat($0.left) })!
        let right = median(edges.map { CGFloat($0.right) })!
        var cuts = edges.map { CGFloat($0.y) }
        let tolerance = max(2, horizontalFontSize * 0.65)
        let withinWidth = boxes.filter { $0.rect.midX >= left && $0.rect.midX <= right }
        // A crop can cut away the first color transition while keeping the complete heading.
        if cuts[0] >= lineHeight, cuts[0] <= lineHeight * 3.5 {
            let clipped = withinWidth.filter { $0.rect.midY < cuts[0] }
            if headerAnchors(in: clipped, lineHeight: lineHeight, tolerance: tolerance).count >= 2 {
                cuts.insert(0, at: 0)
            }
        }
        var bands = zip(cuts, cuts.dropFirst()).map { top, bottom in
            withinWidth.filter { $0.rect.midY >= top && $0.rect.midY < bottom }
        }
        // The first baseline provides a column seed. The following rows must confirm every column.
        let anchors = headerAnchors(in: bands[0], lineHeight: lineHeight, tolerance: tolerance)
        guard anchors.count >= 2, anchors.count <= 20 else { return nil }

        func cells(_ band: [TextBox]) -> [[TextBox]] {
            var columns = Array(repeating: [TextBox](), count: anchors.count)
            for box in band {
                let index = anchors.lastIndex { $0 <= box.rect.minX + tolerance } ?? 0
                columns[index].append(box)
            }
            return columns
        }

        let body = bands.dropFirst().map(cells)
        let populatedRows = body.count { $0.count(where: { !$0.isEmpty }) >= 2 }
        guard populatedRows >= 2, populatedRows * 3 >= body.count * 2 else { return nil }
        var hasTextSpanningColumns = false
        for (index, anchor) in anchors.enumerated() {
            var populated = 0
            var coveredByNeighbor = 0
            for row in body {
                if !row[index].isEmpty {
                    populated += 1
                } else if index > 0, row[index - 1].contains(where: {
                    $0.rect.maxX >= anchor + tolerance * 2
                }) {
                    coveredByNeighbor += 1
                }
            }
            guard populated + coveredByNeighbor >= 2 else { return nil }
            hasTextSpanningColumns = hasTextSpanningColumns || coveredByNeighbor >= 2
        }

        // A last plain row can be indistinguishable from the background. Require multiple seeded
        // columns and the usual distance from the previous rule before extending into that space.
        var bottom = cuts[cuts.count - 1]
        let lastPitches = zip(cuts, cuts.dropFirst()).map { $1 - $0 }.suffix(5)
        if let pitch = median(Array(lastPitches)) {
            let limit = min(CGFloat(raster.height), bottom + pitch * 1.08)
            let after = withinWidth.filter { $0.rect.midY >= bottom && $0.rect.midY < limit }
            let continuation = cells(after)
            if continuation.count(where: { column in
                column.contains { $0.rect.midY - bottom <= lineHeight * 2.1 }
            }) >= 2 {
                bands.append(after)
                bottom = limit
            }
        }

        let rows = bands.map { band in
            cells(band).map { column -> String in
                let lines = readingOrder(column, lineHeight: lineHeight).map(\.line)
                return OCRTextBlock(lines: lines, normalizedBounds: .zero).paragraphText
            }
        }
        return OCRTableRegion(rows: rows, lineIDs: Set(bands.flatMap { $0.map(\.line.id) }),
            normalizedBounds: CGRect(x: left / CGFloat(raster.width), y: 1 - bottom / CGFloat(raster.height),
                width: (right - left) / CGFloat(raster.width), height: (bottom - cuts[0]) / CGFloat(raster.height)),
            hasTextSpanningColumns: hasTextSpanningColumns)
    }

    private static func headerAnchors(in band: [TextBox], lineHeight: CGFloat, tolerance: CGFloat) -> [CGFloat] {
        guard let first = band.map(\.rect.midY).min() else { return [] }
        let baseline = band.filter { $0.rect.midY - first <= lineHeight * 0.5 }.sorted { $0.rect.minX < $1.rect.minX }
        guard zip(baseline, baseline.dropFirst()).allSatisfy({ $1.rect.minX - $0.rect.maxX > tolerance * 0.6 }) else { return [] }
        return baseline.map(\.rect.minX)
    }

    private static func readingOrder(_ boxes: [TextBox], lineHeight: CGFloat) -> [TextBox] {
        var baselines: [[TextBox]] = []
        for box in boxes.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let previous = baselines.last?.first, box.rect.midY - previous.rect.midY < lineHeight * 0.4 {
                baselines[baselines.count - 1].append(box)
            } else {
                baselines.append([box])
            }
        }
        return baselines.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    private struct Raster {
        let width: Int
        let height: Int
        let gray: [UInt8]

        init?(_ image: CGImage) {
            let width = min(image.width, 512)
            let height = min(image.height, 16_000)
            guard width >= 32, height >= 32 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            gray = pixels
        }

        func edges(samplingDistance distance: Int) -> [Edge] {
            let far = distance * 2 + 1
            let minimumWidth = max(24, width / 5)
            var detected: [Edge] = []
            for y in far..<(height - far) {
                let nearAbove = (y - distance) * width
                let nearBelow = (y + distance) * width
                let farAbove = (y - far) * width
                let farBelow = (y + far) * width
                var start = 0, last = -9, polarity = 0, support = 0
                func keep() {
                    let span = last - start + 1
                    guard span >= minimumWidth, support * 5 >= span * 4 else { return }
                    let edge = Edge(firstY: y, lastY: y, left: start, right: last, lightens: polarity > 0)
                    if let previous = detected.indices.reversed().prefix(while: { y - detected[$0].lastY <= 2 }).first(where: {
                        detected[$0].lightens == edge.lightens && detected[$0].spansSameColumns(as: edge)
                    }) {
                        detected[previous].lastY = y
                        detected[previous].left = min(detected[previous].left, start)
                        detected[previous].right = max(detected[previous].right, last)
                    } else { detected.append(edge) }
                }
                for x in 0..<width {
                    let first = Int(gray[nearAbove + x]), second = Int(gray[nearBelow + x])
                    let outerFirst = Int(gray[farAbove + x]), outerSecond = Int(gray[farBelow + x])
                    let delta = second - first, outerDelta = outerSecond - outerFirst
                    guard abs(first - outerFirst) <= 5, abs(second - outerSecond) <= 5,
                          abs(delta) >= 4, abs(outerDelta) >= 4, delta.signum() == outerDelta.signum() else { continue }
                    let sign = delta.signum()
                    if x - last > 8 || sign != polarity {
                        keep()
                        start = x
                        polarity = sign
                        support = 0
                    }
                    last = x
                    support += 1
                }
                keep()
            }
            return detected.sorted { $0.y < $1.y }
        }
    }
}
