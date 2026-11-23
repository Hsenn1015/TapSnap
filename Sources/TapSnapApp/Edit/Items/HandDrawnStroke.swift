import CoreGraphics
import Foundation

/// Derive every trace from the path so drafts, redraws, and exports use the same ink.
enum HandDrawnStroke {
    static func draw(_ path: CGPath, style: EditItemStyle, in context: CGContext) {
        let width = style.resolvedLineWidth
        let color = style.resolvedColor
        let pen = style.handDrawnPen
        let primaryWidth = primaryWidth(for: style)
        let primary = roughened(path, width: width, roughness: style.handDrawnRoughness)
        context.setLineJoin(.round)
        context.setLineWidth(primaryWidth)

        guard pen != .single, style.strokePattern == .solid else {
            context.addPath(primary)
            context.strokePath()
            return
        }

        // Composite both traces together so crossings do not become more opaque than the chosen color.
        let secondary = roughened(path, width: width, roughness: style.handDrawnRoughness, secondTrace: true)
        let padding = primaryWidth / 2 + 1
        let inkBounds = primary.boundingBoxOfPath.union(secondary.boundingBoxOfPath)
        context.clip(to: inkBounds.insetBy(dx: -padding, dy: -padding))
        context.setAlpha(color.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(color.copy(alpha: 1) ?? color)
        context.addPath(primary)
        context.strokePath()
        context.setAlpha(pen == .ink ? 0.9 : 0.72)
        context.setLineWidth(width * (pen == .ink ? 1 : 0.76))
        context.addPath(secondary)
        context.strokePath()
        context.endTransparencyLayer()
    }

    static func hits(_ path: CGPath, at point: CGPoint, style: EditItemStyle, tolerance: CGFloat) -> Bool {
        let width = style.resolvedLineWidth
        let primary = roughened(path, width: width, roughness: style.handDrawnRoughness)
        if AnnotateDrawing.hitsStroke(primary, at: point, width: primaryWidth(for: style), tolerance: tolerance) {
            return true
        }
        guard style.handDrawnPen != .single, style.strokePattern == .solid else { return false }
        let secondary = roughened(path, width: width, roughness: style.handDrawnRoughness, secondTrace: true)
        return AnnotateDrawing.hitsStroke(secondary, at: point,
                                          width: width * (style.handDrawnPen == .ink ? 1 : 0.76), tolerance: tolerance)
    }

    private static func primaryWidth(for style: EditItemStyle) -> CGFloat {
        switch style.handDrawnPen {
        case .single: return style.resolvedLineWidth * 0.85
        case .sketch: return style.resolvedLineWidth
        case .ink: return style.resolvedLineWidth * 1.45
        }
    }

    static func fill(_ path: CGPath, color: CGColor, width: CGFloat, pattern: EditItemStyle.HandDrawnFill,
                     in context: CGContext) {
        let bounds = path.boundingBoxOfPath
        guard !bounds.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color)
        context.addPath(path)
        context.clip()
        let span = bounds.width + bounds.height
        let spacing = max(5.5, width * 1.9, span / 160)
        // Keep grids bounded on large captures and anchor the pattern to the shape.
        let gridSpacing = max(spacing, sqrt(bounds.width * bounds.height / 640))
        context.setStrokeColor(color)
        context.setLineWidth(min(3.2, max(1, width * 0.58)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: [])

        switch pattern {
        case .solid:
            context.fill(bounds.insetBy(dx: -1, dy: -1))
            return
        case .dots:
            let radius = min(2.2, max(1, width * 0.42))
            let firstRow = min(bounds.midY, bounds.minY + gridSpacing / 2)
            for (row, y) in stride(from: firstRow, to: bounds.maxY, by: gridSpacing).enumerated() {
                let offset = min(bounds.width / 2, gridSpacing * (row.isMultiple(of: 2) ? 0.52 : 0.22))
                for (column, x) in stride(from: bounds.minX + offset, to: bounds.maxX, by: gridSpacing).enumerated() {
                    let dotRadius = radius * (0.8 + CGFloat((column + row * 2) % 3) * 0.16)
                    let shift = column.isMultiple(of: 2) ? 0.5 : -0.5
                    context.addEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius + shift,
                                                  width: dotRadius * 2, height: dotRadius * 2))
                }
            }
            context.fillPath()
            return
        case .hachure, .crossHatch:
            addHatching(in: bounds, spacing: spacing, crossHatched: pattern == .crossHatch, to: context)
        case .horizontal:
            let firstRow = min(bounds.midY, bounds.minY + spacing / 2)
            for (row, y) in stride(from: firstRow, to: bounds.maxY, by: spacing).enumerated() {
                let bow: CGFloat = row.isMultiple(of: 2) ? 1.8 : -1.4
                context.move(to: CGPoint(x: bounds.minX, y: y))
                context.addQuadCurve(to: CGPoint(x: bounds.maxX, y: y + bow / 3),
                                     control: CGPoint(x: bounds.midX, y: y + bow))
            }
        case .zigzag:
            let step = gridSpacing * 0.65
            let amplitude = min(bounds.height / 3, gridSpacing * 0.27)
            let firstRow = min(bounds.midY, bounds.minY + gridSpacing / 2)
            for y in stride(from: firstRow, to: bounds.maxY, by: gridSpacing) {
                context.move(to: CGPoint(x: bounds.minX - step, y: y + amplitude))
                for (column, x) in stride(from: bounds.minX, through: bounds.maxX + step, by: step).enumerated() {
                    let offset = column.isMultiple(of: 2) ? -amplitude : amplitude
                    context.addLine(to: CGPoint(x: x, y: y + offset))
                }
            }
        }
        context.strokePath()
    }

    private static func addHatching(in bounds: CGRect, spacing: CGFloat, crossHatched: Bool, to context: CGContext) {
        let span = bounds.width + bounds.height
        let count = Int(ceil(span / spacing))
        let firstOffset = (span - CGFloat(count - 1) * spacing) / 2
        for line in 0..<count {
            let x = bounds.minX + firstOffset + CGFloat(line) * spacing
            let bow = line.isMultiple(of: 2) ? 1.6 : -1.4
            context.move(to: CGPoint(x: x - bounds.height, y: bounds.maxY))
            context.addQuadCurve(to: CGPoint(x: x, y: bounds.minY),
                                 control: CGPoint(x: x - bounds.height / 2 + bow, y: bounds.midY))
            if crossHatched {
                let reflected = bounds.maxX - firstOffset - CGFloat(line) * spacing
                context.move(to: CGPoint(x: reflected + bounds.height, y: bounds.maxY))
                context.addQuadCurve(to: CGPoint(x: reflected, y: bounds.minY),
                                     control: CGPoint(x: reflected + bounds.height / 2 - bow, y: bounds.midY))
            }
        }
    }

    static func roughened(_ path: CGPath, width: CGFloat, roughness: EditItemStyle.HandDrawnRoughness,
                          secondTrace: Bool = false) -> CGPath {
        let result = CGMutablePath()
        let bounds = path.boundingBoxOfPath
        let minorDimension = min(bounds.width, bounds.height)
        var isClosed = false
        path.applyWithBlock { element in
            if element.pointee.type == .closeSubpath { isClosed = true }
        }
        let sizeLimit = isClosed ? minorDimension * 0.2 : CGFloat.infinity
        let roughnessScale: CGFloat
        switch roughness {
        case .subtle: roughnessScale = 0.45
        case .natural: roughnessScale = 1
        case .pronounced: roughnessScale = 1.9
        case .expressive: roughnessScale = 3.1
        }
        let naturalAmount = min(4, 1.5 + width * 0.55)
        let amount = min(naturalAmount * roughnessScale, sizeLimit)
        var randomState: UInt32 = secondTrace ? 81 : 239
        var sourceStart = CGPoint.zero
        var sourcePoint = CGPoint.zero
        var targetStart = CGPoint.zero
        var targetPoint = CGPoint.zero

        func variation() -> CGFloat {
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            return CGFloat(randomState >> 16) / 32_768 - 1
        }

        func shifted(_ point: CGPoint, by amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + variation() * amount, y: point.y + variation() * amount)
        }

        func vertex(_ point: CGPoint) -> CGPoint {
            if secondTrace { return shifted(point, by: amount * 0.88) }
            return isClosed ? shifted(point, by: amount * 0.28) : point
        }

        func bowLine(to destination: CGPoint, endingAt endpoint: CGPoint) {
            let dx = destination.x - sourcePoint.x
            let dy = destination.y - sourcePoint.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let noise = variation()
            let direction: CGFloat = noise < 0 ? -1 : 1
            let bow = min(amount, length * 0.18) * direction * (0.8 + abs(noise) * 0.55)
            let nx = -dy / length * bow
            let ny = dx / length * bow
            let bend = secondTrace ? -0.65 : 0.60
            let first = CGPoint(x: targetPoint.x + (endpoint.x - targetPoint.x) * 0.30 + nx,
                                y: targetPoint.y + (endpoint.y - targetPoint.y) * 0.30 + ny)
            let second = CGPoint(x: targetPoint.x + (endpoint.x - targetPoint.x) * 0.70 + nx * bend,
                                 y: targetPoint.y + (endpoint.y - targetPoint.y) * 0.70 + ny * bend)
            result.addCurve(to: endpoint, control1: first, control2: second)
            sourcePoint = destination
            targetPoint = endpoint
        }

        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                sourceStart = points[0]
                sourcePoint = sourceStart
                targetStart = vertex(sourceStart)
                targetPoint = targetStart
                result.move(to: targetStart)
            case .addLineToPoint:
                bowLine(to: points[0], endingAt: vertex(points[0]))
            case .addQuadCurveToPoint:
                sourcePoint = points[1]
                targetPoint = vertex(sourcePoint)
                result.addQuadCurve(to: targetPoint, control: shifted(points[0], by: amount))
            case .addCurveToPoint:
                sourcePoint = points[2]
                targetPoint = sourcePoint == sourceStart ? targetStart : vertex(sourcePoint)
                let curveAmount = amount * (secondTrace ? 1.4 : 0.85)
                result.addCurve(to: targetPoint, control1: shifted(points[0], by: curveAmount),
                                control2: shifted(points[1], by: curveAmount))
            case .closeSubpath:
                bowLine(to: sourceStart, endingAt: targetStart)
                result.closeSubpath()
            @unknown default:
                break
            }
        }
        return result
    }
}
