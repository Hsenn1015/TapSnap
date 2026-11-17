import CoreGraphics
import Foundation

/// A deterministic second pass and gently bowed curves imitate a pen on paper.
enum HandDrawnStroke {
    static func draw(_ path: CGPath, style: EditItemStyle, in context: CGContext) {
        let width = style.resolvedLineWidth
        let color = style.resolvedColor
        context.setLineJoin(.round)

        guard style.strokePattern == .solid else {
            context.addPath(roughened(path, width: width, roughness: style.handDrawnRoughness))
            context.strokePath()
            return
        }

        // Composite both traces together so crossings do not become more opaque than the chosen color.
        let padding = width * 2 + 5
        context.clip(to: path.boundingBoxOfPath.insetBy(dx: -padding, dy: -padding))
        context.setAlpha(color.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(color.copy(alpha: 1) ?? color)
        context.setLineWidth(width * 0.9)
        context.addPath(roughened(path, width: width, roughness: style.handDrawnRoughness))
        context.strokePath()
        context.setAlpha(0.42)
        context.setLineWidth(width * 0.62)
        context.addPath(roughened(path, width: width, roughness: style.handDrawnRoughness, secondTrace: true))
        context.strokePath()
        context.endTransparencyLayer()
    }

    static func hatch(_ path: CGPath, color: CGColor, width: CGFloat, crossHatched: Bool, in context: CGContext) {
        let bounds = path.boundingBoxOfPath
        guard !bounds.isEmpty else { return }
        let span = bounds.width + bounds.height
        // Bound the number of strokes for large areas and keep the phase tied to the shape when it moves.
        let spacing = max(5.5, width * 2, span / 240)
        let count = Int(ceil(span / spacing))
        let firstOffset = (span - CGFloat(count - 1) * spacing) / 2

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setStrokeColor(color)
        context.setLineWidth(min(2.2, max(0.65, width * 0.5)))
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [])

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
        context.strokePath()
        context.restoreGState()
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
        let sizeLimit = isClosed ? minorDimension * 0.17 : CGFloat.infinity
        let roughnessScale: CGFloat
        switch roughness {
        case .subtle: roughnessScale = 0.48
        case .natural: roughnessScale = 1
        case .pronounced: roughnessScale = 1.9
        }
        let naturalAmount = min(3.1, 1.1 + width * 0.38, sizeLimit)
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
            secondTrace ? shifted(point, by: amount * 0.75) : point
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
