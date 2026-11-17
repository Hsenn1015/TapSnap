import Foundation
import TapSnapStitching

/// Keep enough visual overlap even when saved settings contain extreme values.
struct AutomaticScrollPolicy {
    let step: Int32
    let interval: TimeInterval
    init(viewportHeight: CGFloat, configuredStep: Int, intervalMilliseconds: Int, overlap: Double) {
        let ratio = overlap.isFinite ? min(0.9, max(0.35, overlap)) : 0.35
        let height = viewportHeight.isFinite && viewportHeight > 0 ? viewportHeight : 1
        let maximum = max(1, floor(height * (1 - ratio)))
        step = Int32(min(10_000, max(1, min(Double(configuredStep), maximum))))
        interval = min(5, max(0.3, Double(intervalMilliseconds) / 1000))
    }

    @MainActor
    func scrollAndStitch(post: (Int32) -> Bool, stitch: (Date) async throws -> Bool) async throws -> Bool? {
        let count = min(step, 8)
        var sent = false
        for index in 0..<count {
            if index > 0 { try await Task.sleep(for: .milliseconds(22)) }
            try Task.checkCancellation()
            let delta = step / count + (index < step % count ? 1 : 0)
            guard post(-delta) else { break }
            sent = true
        }
        // Stitch any movement already sent, even if the pointer left during this step.
        guard sent else { return nil }
        var earliestFrame = Date().addingTimeInterval(0.02)
        // A transition or late paint can spoil one frame. Retry at the same
        // scroll position so a second movement cannot skip the overlap.
        var retries = 2
        while true {
            try await Task.sleep(for: .milliseconds(120))
            do {
                return try await stitch(earliestFrame)
            } catch StitchingError.ambiguousDisplacement where retries > 0,
                    StitchingError.reverseScroll where retries > 0 {
                retries -= 1
                earliestFrame = Date()
            }
        }
    }
}
