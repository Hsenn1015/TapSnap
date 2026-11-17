import CoreGraphics

struct SelectionSnapRegion: Sendable {
    let bounds: CGRect
    let confidence: Float
}

enum SelectionSnap {
    static func target(at point: CGPoint, in bounds: CGRect, windows: [CGRect],
                       detected: [SelectionSnapRegion]) -> CGRect? {
        guard bounds.contains(point) else { return nil }
        let window = windows.first { $0.contains(point) }?.intersection(bounds)
        guard windows.isEmpty || window != nil else { return nil }
        let container = window ?? bounds
        let limit = container.insetBy(dx: -2, dy: -2)

        let candidates = detected.compactMap { region -> SelectionSnapRegion? in
            let frame = region.bounds
            guard region.confidence >= 0.65, frame.contains(point), limit.contains(frame) else { return nil }
            let clipped = frame.intersection(container)
            guard clipped.width >= 20, clipped.height >= 14,
                  area(clipped) < area(container) * 0.92 else { return nil }
            return SelectionSnapRegion(bounds: clipped, confidence: region.confidence)
        }
        let bestConfidence = candidates.map(\.confidence).max() ?? 0
        // 先排除置信度明显偏低的候选，再在可信的嵌套区域里选最具体的一个。
        return candidates.filter { $0.confidence >= bestConfidence - 0.10 }
            .min { area($0.bounds) < area($1.bounds) }?.bounds ?? window
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}
