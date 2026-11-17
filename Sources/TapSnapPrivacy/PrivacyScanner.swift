import CoreGraphics
import Foundation
import os
import Vision

public struct PrivacyScanResult {
    public let findings: [PrivacyFinding]
    let text: [PrivacyTextLocation]
    let matches: [PrivacyTextMatch]
    let imageBounds: CGRect

    func finding(for match: PrivacyTextMatch) -> PrivacyFinding {
        text[match.line].finding(for: match, inside: imageBounds)
    }
}

struct PrivacyTextLocation {
    let candidate: VNRecognizedText
    let tile: CGRect
    let line: PrivacyTextLine

    func promotingProviderToken(_ match: PrivacyTextMatch, settings: PrivacySettings) -> PrivacyTextMatch {
        // The known prefix plus a complete masked value identifies the same secret in either OCR candidate.
        guard match.label == PrivacyRule.token.title, settings[.token] == .automatic,
              let range = Range(match.range, in: line.normalized),
              TextRules.isMaskedProviderToken(String(line.normalized[range])) else { return match }
        return PrivacyTextMatch(label: match.label, line: match.line, range: match.range, covered: true)
    }

    func finding(for match: PrivacyTextMatch, inside imageBounds: CGRect) -> PrivacyFinding {
        let fragment = Range(match.range, in: candidate.string).flatMap { range in
            (try? candidate.boundingBox(for: range)).map { PrivacyScanner.pixels($0.boundingBox, in: tile) }
        }
        let rect = PrivacyScanner.coverageRect(fragment: fragment, line: line.rect, inside: imageBounds)
        return PrivacyFinding(label: match.label, bounds: rect, isCovered: match.covered)
    }
}

public enum PrivacyScanner {
    private static let queue = DispatchQueue(label: "com.sensnap.privacy-scan", qos: .userInitiated)

    public static func scan(_ image: CGImage, settings: PrivacySettings) async throws -> [PrivacyFinding] {
        try await inspect(image, settings: settings, includeText: false).findings
    }

    public static func inspect(_ image: CGImage, settings: PrivacySettings, includeText: Bool) async throws -> PrivacyScanResult {
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try scanImage(image, settings: settings, includeText: includeText,
                                      cancelled: { cancellation.withLock { $0 } })
                    })
                }
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }

    private static func scanImage(_ image: CGImage, settings: PrivacySettings, includeText: Bool,
                                  cancelled: () -> Bool) throws -> PrivacyScanResult {
        if cancelled() { throw CancellationError() }
        let suffixes = settings.domainSuffixes
        let readsText = includeText || PrivacyRule.allCases.contains {
            !$0.isVisual && settings[$0] != .off && ($0 != .internalDomain || !suffixes.isEmpty)
        } || settings.customRules.contains { $0.mode != .off }
        let scansFaces = settings[.face] != .off
        let scansCodes = settings[.barcode] != .off
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard readsText || scansFaces || scansCodes else {
            return PrivacyScanResult(findings: [], text: [], matches: [], imageBounds: imageBounds)
        }
        let rules = try TextRules(settings: settings)
        let tiles = tileRects(width: image.width, height: image.height)
        var textLocations: [PrivacyTextLocation] = []
        var alternatives: [Int: PrivacyTextLocation] = [:]
        var findings: [PrivacyFinding] = []

        for rect in tiles {
            if cancelled() { throw CancellationError() }
            try autoreleasepool {
                guard let patch = tiles.count == 1 ? image : image.cropping(to: rect) else {
                    throw PrivacyScanError.imageProcessingFailed
                }
                let text = VNRecognizeTextRequest()
                text.recognitionLevel = .accurate
                text.usesLanguageCorrection = false
                text.automaticallyDetectsLanguage = false
                if readsText {
                    let supported = try text.supportedRecognitionLanguages()
                    let languages = ["zh-Hans", "en-US"].filter(supported.contains)
                    if !languages.isEmpty { text.recognitionLanguages = languages }
                }
                let codes = VNDetectBarcodesRequest()
                let faces = VNDetectFaceRectanglesRequest()
                let requests: [VNRequest] = [readsText ? text : nil, scansCodes ? codes : nil, scansFaces ? faces : nil].compactMap { $0 }
                try VNImageRequestHandler(cgImage: patch).perform(requests)
                if readsText {
                    for observation in text.results ?? [] {
                        let candidates = observation.topCandidates(2)
                        guard let candidate = candidates.first, !candidate.string.isEmpty else { continue }
                        let bounds = pixels(observation.boundingBox, in: rect)
                        // Keep a complete line from either side of a tile seam.
                        if (rect.minY > 0 && bounds.minY < rect.minY + 2)
                            || (rect.maxY < imageBounds.maxY && bounds.maxY > rect.maxY - 2) { continue }
                        func location(_ text: VNRecognizedText) -> PrivacyTextLocation {
                            PrivacyTextLocation(candidate: text, tile: rect,
                                                line: .init(text: text.string, rect: bounds, confidence: text.confidence))
                        }
                        if let alternative = candidates.dropFirst().first,
                           alternative.confidence >= 0.4, alternative.string != candidate.string {
                            alternatives[textLocations.count] = location(alternative)
                        }
                        textLocations.append(location(candidate))
                    }
                }
                if scansCodes {
                    for observation in codes.results ?? [] {
                        appendVisual(.barcode, rect: pixels(observation.boundingBox, in: rect), confidence: observation.confidence)
                    }
                }
                if scansFaces {
                    for observation in faces.results ?? [] {
                        appendVisual(.face, rect: pixels(observation.boundingBox, in: rect), confidence: observation.confidence)
                    }
                }
            }
        }

        if cancelled() { throw CancellationError() }
        let lines = textLocations.map(\.line)
        let matches = try rules.matches(in: lines, cancelled: cancelled)
        for match in matches {
            if cancelled() { throw CancellationError() }
            let location = textLocations[match.line]
            findings.append(location.finding(for: location.promotingProviderToken(match, settings: settings), inside: imageBounds))
        }
        if !alternatives.isEmpty {
            let alternateLines = lines.enumerated().map { alternatives[$0.offset]?.line ?? $0.element }
            for match in try rules.matches(in: alternateLines, includeCustom: false, cancelled: cancelled) {
                guard let alternate = alternatives[match.line] else { continue }
                let suggestion = PrivacyTextMatch(label: match.label, line: match.line, range: match.range, covered: false)
                findings.append(alternate.finding(for: alternate.promotingProviderToken(suggestion, settings: settings), inside: imageBounds))
            }
        }
        return PrivacyScanResult(findings: coalesced(findings.filter { !$0.bounds.isEmpty }),
                                 text: includeText ? textLocations : [], matches: includeText ? matches : [],
                                 imageBounds: imageBounds)

        func appendVisual(_ rule: PrivacyRule, rect: CGRect, confidence: Float) {
            let margin = rule == .face ? max(rect.width, rect.height) * 0.18 : max(4, min(rect.width, rect.height) * 0.06)
            let padded = padding(rect, amount: margin, inside: imageBounds)
            guard !padded.isEmpty else { return }
            findings.append(.init(label: rule.title, bounds: padded,
                                  isCovered: settings[rule] == .automatic && confidence >= 0.5))
        }
    }

    /// Overlapping bands keep text near a seam at its original resolution.
    static func tileRects(width: Int, height: Int) -> [CGRect] {
        let tileHeight = 2_048
        let overlap = 192
        var top = 0
        var rects: [CGRect] = []
        while top < height {
            let length = min(tileHeight, height - top)
            rects.append(CGRect(x: 0, y: top, width: width, height: length))
            if top + length == height { break }
            top += tileHeight - overlap
        }
        return rects
    }

    fileprivate static func pixels(_ rect: CGRect, in tile: CGRect) -> CGRect {
        CGRect(x: tile.minX + rect.minX * tile.width, y: tile.minY + (1 - rect.maxY) * tile.height,
               width: rect.width * tile.width, height: rect.height * tile.height)
    }

    static func coverageRect(fragment: CGRect?, line: CGRect, inside bounds: CGRect) -> CGRect {
        // Vision's word bounds can be tighter vertically than the observed text line.
        let slice: CGRect
        if let fragment, !fragment.isEmpty, fragment.intersects(line) {
            slice = fragment.union(CGRect(x: fragment.minX, y: line.minY, width: fragment.width, height: line.height))
        } else {
            slice = line
        }
        return padding(slice, amount: max(3, line.height * 0.15), inside: bounds)
    }

    fileprivate static func padding(_ rect: CGRect, amount: CGFloat, inside bounds: CGRect) -> CGRect {
        let padded = rect.insetBy(dx: -amount, dy: -amount).integral.intersection(bounds)
        return padded.isNull ? .zero : padded
    }

    private static func coalesced(_ findings: [PrivacyFinding]) -> [PrivacyFinding] {
        var rows: [PrivacyFinding] = []
        for finding in findings.sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
            let rect = finding.bounds
            if let index = rows.indices.reversed().prefix(30).first(where: { index in
                let previous = rows[index]
                guard previous.label == finding.label else { return false }
                let other = previous.bounds
                let overlap = rect.intersection(other)
                return !overlap.isNull && overlap.width * overlap.height >= 0.65 * min(rect.width * rect.height, other.width * other.height)
            }) {
                let previous = rows[index]
                rows[index] = .init(label: finding.label, bounds: previous.bounds.union(rect),
                                    isCovered: previous.isCovered || finding.isCovered)
            } else {
                rows.append(finding)
            }
        }
        return rows
    }
}
