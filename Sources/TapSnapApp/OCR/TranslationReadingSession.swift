import AppKit
import Combine
import CoreGraphics
import SwiftUI
import TapSnapCore
import TapSnapOCR

/// 一次原图查看中，选区优先于悬停。请求身份防止旧译文覆盖新选区。
@MainActor
final class TranslationReadingSession: ObservableObject {
    enum Trigger { case hover, selection, whole }
    struct Focus {
        var text: String
        var bounds: CGRect
        var trigger: Trigger
    }
    struct Request: Identifiable {
        let id = UUID()
        let text: String
        let allowDownload: Bool
    }
    enum Phase: Equatable {
        case waiting, languageDownload, translated(String), failed(String)
    }

    @Published private(set) var focus: Focus?
    @Published private(set) var request: Request?
    @Published private(set) var phase: Phase = .waiting
    @Published var isPinned = false {
        didSet {
            if isPinned {
                hoverTask?.cancel()
            } else if !pointerOnCard && hoverText == nil && focus?.trigger == .hover {
                scheduleDismiss()
            }
        }
    }
    private var cached: [String: String] = [:]
    private var hoverTask: Task<Void, Never>?
    private var pointerOnCard = false
    private var hoverText: String?
    var isConfiguring = false {
        didSet { if isConfiguring { hoverTask?.cancel() } }
    }
    var isInteracting = false {
        didSet { if isInteracting { hoverTask?.cancel() } }
    }

    func hover(_ text: String?, bounds: CGRect) {
        hoverText = text
        hoverTask?.cancel()
        guard !isConfiguring, !isInteracting, request?.allowDownload != true,
              focus?.trigger != .selection, focus?.trigger != .whole else { return }
        guard let text, !text.isEmpty else {
            if !pointerOnCard && !isPinned { scheduleDismiss() }
            return
        }
        if focus?.text == text {
            if !isPinned, focus?.bounds != bounds { focus?.bounds = bounds }
            return
        }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(580)) } catch { return }
            self?.show(text, bounds: bounds, trigger: .hover)
        }
    }

    func cardHover(_ inside: Bool) {
        pointerOnCard = inside
        guard focus?.trigger == .hover, !isConfiguring, !isInteracting, request?.allowDownload != true else { return }
        if inside || isPinned { hoverTask?.cancel() }
        else if hoverText == nil { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        hoverTask?.cancel()
        guard !isPinned, !isInteracting else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(520)) } catch { return }
            guard let self, self.focus?.trigger == .hover, !self.isConfiguring, !self.isInteracting,
                  !self.isPinned, !self.pointerOnCard, self.hoverText == nil else { return }
            self.dismiss()
        }
    }

    func select(_ text: String?, bounds: CGRect) {
        guard !isConfiguring, !isInteracting else { return }
        if let text, !text.isEmpty {
            show(text, bounds: bounds, trigger: .selection)
        } else if focus?.trigger == .selection && !isPinned {
            dismiss()
        }
    }

    func show(_ text: String, bounds: CGRect, trigger: Trigger) {
        hoverTask?.cancel()
        guard !text.isEmpty else { dismiss(); return }
        let reusesResult = focus?.text == text
        focus = Focus(text: text, bounds: bounds, trigger: trigger)
        if !reusesResult { start() }
    }

    func refresh() {
        cached.removeAll()
        start()
    }

    func start(allowDownload: Bool = false) {
        request = nil
        phase = .waiting
        guard let text = focus?.text else { return }
        if let result = cached[text] { phase = .translated(result) }
        else { request = Request(text: text, allowDownload: allowDownload) }
    }

    func needsDownload(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
        phase = .languageDownload
    }

    func authorizeDownload() {
        hoverTask?.cancel()
        start(allowDownload: true)
    }

    func finish(_ id: UUID, result: Result<String, Error>) {
        guard let current = request, current.id == id else { return }
        request = nil
        switch result {
        case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            cached[current.text] = text
            phase = .translated(text)
        case .success: phase = .failed("翻译服务返回了空译文。")
        case .failure(let error): phase = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        hoverTask?.cancel()
        hoverTask = nil
        pointerOnCard = false
        hoverText = nil
        isPinned = false
        isInteracting = false
        request = nil
        focus = nil
        phase = .waiting
    }
}

/// 从原图对应文本区域采样得到的融合底色，用于“原位覆译”自然贴合原图。
struct TranslationBlockBackdrop: Equatable, Sendable {
    var background: RGBAColor
    var isDark: Bool

    static let fallbackLight = TranslationBlockBackdrop(
        background: RGBAColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 0.96),
        isDark: false
    )
    static let fallbackDark = TranslationBlockBackdrop(
        background: RGBAColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 0.96),
        isDark: true
    )

    var fillColor: Color { background.color }
    var textColor: Color { isDark ? Color(white: 0.96) : Color(white: 0.10) }
    var borderColor: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10) }

    /// 采样文本块外圈边框附近像素的中位/均值颜色，尽量避开文字前景像素。
    static func sample(from image: CGImage, normalizedBounds: CGRect) -> TranslationBlockBackdrop {
        let clamped = normalizedBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isEmpty, image.width > 0, image.height > 0 else { return .fallbackLight }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        // Vision normalizedBounds: origin bottom-left -> CGImage pixel origin top-left
        let pxRect = CGRect(
            x: clamped.minX * imgW,
            y: (1 - clamped.maxY) * imgH,
            width: max(2, clamped.width * imgW),
            height: max(2, clamped.height * imgH)
        ).insetBy(dx: -3, dy: -3).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard pxRect.width >= 2, pxRect.height >= 2,
              let cropped = image.cropping(to: pxRect.integral) else {
            return .fallbackLight
        }

        let sampleW = min(24, cropped.width)
        let sampleH = min(24, cropped.height)
        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .fallbackLight
        }
        ctx.interpolationQuality = .low
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        // 优先采样四条边缘像素（大概率是背景而非文字笔画）
        var rSum: Double = 0
        var gSum: Double = 0
        var bSum: Double = 0
        var count: Double = 0

        for y in 0..<sampleH {
            for x in 0..<sampleW {
                let isBorder = x == 0 || y == 0 || x == sampleW - 1 || y == sampleH - 1
                guard isBorder else { continue }
                let idx = (y * sampleW + x) * 4
                let alpha = Double(pixels[idx + 3]) / 255.0
                guard alpha > 0.2 else { continue }
                rSum += Double(pixels[idx]) / 255.0 / alpha
                gSum += Double(pixels[idx + 1]) / 255.0 / alpha
                bSum += Double(pixels[idx + 2]) / 255.0 / alpha
                count += 1
            }
        }

        guard count > 0 else { return .fallbackLight }
        let r = min(1, max(0, rSum / count))
        let g = min(1, max(0, gSum / count))
        let b = min(1, max(0, bSum / count))
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return TranslationBlockBackdrop(
            background: RGBAColor(red: r, green: g, blue: b, alpha: 0.94),
            isDark: luminance < 0.52
        )
    }
}

/// 整图自动段落翻译会话：管理每个 OCR 块的自动翻译、逐块更新、行内重译与缓存。
@MainActor
final class TranslationDocumentSession: ObservableObject {
    enum BlockPhase: Equatable {
        case idle
        case waiting
        case languageDownload
        case translated(String)
        case failed(String)

        var translatedText: String? {
            if case .translated(let text) = self { return text }
            return nil
        }
    }

    struct BlockItem: Identifiable, Equatable {
        let id: UUID
        let originalText: String
        var sourceText: String
        let normalizedBounds: CGRect
        let lineCount: Int
        let backdrop: TranslationBlockBackdrop
        var phase: BlockPhase
    }

    struct BatchJob: Identifiable {
        let id = UUID()
        let items: [(id: UUID, text: String)]
        let allowDownload: Bool
    }

    @Published private(set) var blocks: [BlockItem] = []
    @Published private(set) var batchJob: BatchJob?
    @Published private(set) var deletedBatches: [[(index: Int, item: BlockItem)]] = []
    private var cache: [String: String] = [:]

    var totalCount: Int { blocks.count }
    var deletedCount: Int { deletedBatches.reduce(0) { $0 + $1.count } }
    var completedCount: Int {
        blocks.filter {
            if case .translated = $0.phase { return true }
            return false
        }.count
    }
    var untranslatedCount: Int {
        blocks.filter { $0.phase == .idle }.count
    }
    var hasUntranslatedBlocks: Bool { untranslatedCount > 0 }
    var isTranslating: Bool {
        batchJob != nil || blocks.contains { $0.phase == .waiting }
    }
    var needsLanguageDownload: Bool {
        blocks.contains { $0.phase == .languageDownload }
    }
    var hasFailures: Bool {
        blocks.contains {
            if case .failed = $0.phase { return true }
            return false
        }
    }
    var combinedTranslatedText: String {
        blocks.compactMap(\.phase.translatedText).joined(separator: "\n\n")
    }
    var combinedBilingualText: String {
        blocks.compactMap { item -> String? in
            guard let translated = item.phase.translatedText else { return nil }
            return "\(item.sourceText)\n\(translated)"
        }.joined(separator: "\n\n")
    }

    func load(document: OCRDocument, image: CGImage?, autoStart: Bool) {
        batchJob = nil
        deletedBatches.removeAll()
        blocks = document.blocks.compactMap { block in
            let text = block.paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let backdrop = image.map { TranslationBlockBackdrop.sample(from: $0, normalizedBounds: block.normalizedBounds) }
                ?? .fallbackLight
            return BlockItem(
                id: block.id,
                originalText: text,
                sourceText: text,
                normalizedBounds: block.normalizedBounds,
                lineCount: max(1, block.lines.count),
                backdrop: backdrop,
                phase: .idle
            )
        }
        if autoStart {
            startPending(allowDownload: false)
        }
    }

    func startPending(for targetIDs: Set<UUID>? = nil, allowDownload: Bool = false) {
        var pending: [(UUID, String)] = []
        for idx in blocks.indices {
            if let targetIDs, !targetIDs.contains(blocks[idx].id) { continue }
            let text = blocks[idx].sourceText
            if let hit = cache[text] {
                blocks[idx].phase = .translated(hit)
                continue
            }
            switch blocks[idx].phase {
            case .translated:
                continue
            case .idle, .waiting, .failed, .languageDownload:
                blocks[idx].phase = .waiting
                pending.append((blocks[idx].id, text))
            }
        }
        batchJob = pending.isEmpty ? nil : BatchJob(items: pending, allowDownload: allowDownload)
    }

    func invalidateAndRestart(autoStart: Bool) {
        cache.removeAll()
        batchJob = nil
        for idx in blocks.indices {
            blocks[idx].phase = .idle
        }
        if autoStart {
            startPending(allowDownload: false)
        }
    }

    func authorizeDownload() {
        startPending(allowDownload: true)
    }

    func retry(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let text = blocks[idx].sourceText
        cache.removeValue(forKey: text)
        blocks[idx].phase = .waiting
        batchJob = BatchJob(items: [(blockID, text)], allowDownload: false)
    }

    func retranslate(blockID: UUID, editedText: String) {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[idx].sourceText = trimmed
        if let hit = cache[trimmed] {
            blocks[idx].phase = .translated(hit)
            return
        }
        blocks[idx].phase = .waiting
        batchJob = BatchJob(items: [(blockID, trimmed)], allowDownload: false)
    }

    func updateTranslatedText(blockID: UUID, editedTranslation: String) {
        let trimmed = editedTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        if trimmed.isEmpty {
            remove(blockID: blockID)
            return
        }
        cache[blocks[idx].sourceText] = trimmed
        blocks[idx].phase = .translated(trimmed)
    }

    func remove(blockID: UUID) {
        remove(blockIDs: [blockID])
    }

    @discardableResult
    func remove(blockIDs: Set<UUID>) -> Int {
        guard !blockIDs.isEmpty else { return 0 }
        var removedEntries: [(index: Int, item: BlockItem)] = []
        var kept: [BlockItem] = []
        kept.reserveCapacity(blocks.count)
        for (idx, item) in blocks.enumerated() {
            if blockIDs.contains(item.id) {
                removedEntries.append((index: idx, item: item))
            } else {
                kept.append(item)
            }
        }
        guard !removedEntries.isEmpty else { return 0 }
        blocks = kept
        deletedBatches.append(removedEntries)
        return removedEntries.count
    }

    @discardableResult
    func keepOnly(blockIDs: Set<UUID>) -> Int {
        let toRemove = Set(blocks.map(\.id)).subtracting(blockIDs)
        return remove(blockIDs: toRemove)
    }

    @discardableResult
    func removeAll() -> Int {
        let allIDs = Set(blocks.map(\.id))
        return remove(blockIDs: allIDs)
    }

    @discardableResult
    func undoLastRemoval() -> UUID? {
        guard let batch = deletedBatches.popLast(), !batch.isEmpty else { return nil }
        for entry in batch.sorted(by: { $0.index < $1.index }) {
            let insertion = min(max(0, entry.index), blocks.count)
            blocks.insert(entry.item, at: insertion)
        }
        return batch.first?.item.id
    }

    func restoreAllRemoved() {
        while undoLastRemoval() != nil {}
    }

    func suspectedNoiseIDs() -> Set<UUID> {
        TranslationNoiseDetector.suspectedNoiseIDs(in: blocks)
    }

    func finishBlock(_ jobID: UUID, blockID: UUID, result: Result<String, Error>) {
        guard batchJob?.id == jobID,
              let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        switch result {
        case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            cache[blocks[idx].sourceText] = cleaned
            blocks[idx].phase = .translated(cleaned)
        case .success:
            blocks[idx].phase = .failed("翻译服务返回了空译文。")
        case .failure(let error):
            blocks[idx].phase = .failed(error.localizedDescription)
        }
    }

    func markDownloadRequired(_ jobID: UUID) {
        guard let job = batchJob, job.id == jobID else { return }
        let ids = Set(job.items.map(\.id))
        for idx in blocks.indices where ids.contains(blocks[idx].id) {
            if blocks[idx].phase == .waiting {
                blocks[idx].phase = .languageDownload
            }
        }
        batchJob = nil
    }

    func failJob(_ jobID: UUID, message: String) {
        guard let job = batchJob, job.id == jobID else { return }
        let ids = Set(job.items.map(\.id))
        for idx in blocks.indices where ids.contains(blocks[idx].id) {
            if blocks[idx].phase == .waiting {
                blocks[idx].phase = .failed(message)
            }
        }
        batchJob = nil
    }

    func completeJob(_ jobID: UUID) {
        guard batchJob?.id == jobID else { return }
        batchJob = nil
    }

    func cancel() {
        batchJob = nil
    }
}

/// 启发式识别截图中常见的冗余/杂项 OCR 块（用于「选中杂项」自动预选，不盲目自动删除）。
enum TranslationNoiseDetector {
    static func suspectedNoiseIDs(in blocks: [TranslationDocumentSession.BlockItem]) -> Set<UUID> {
        var result = Set<UUID>()
        for block in blocks where isLikelyNoise(block) {
            result.insert(block.id)
        }
        return result
    }

    static func isLikelyNoise(_ block: TranslationDocumentSession.BlockItem) -> Bool {
        let raw = block.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return true }

        // 1. 纯符号 / 标点 / 图标误识别碎片
        let alphanumerics = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        if alphanumerics.isEmpty { return true }

        // 2. 单字符噪声（单英文字母/单数字/单符号；保留单汉字以外的孤立字符，或单数字）
        if raw.count == 1 {
            let scalar = raw.unicodeScalars.first!
            let isCJK = (0x4E00...0x9FFF).contains(scalar.value)
            if !isCJK { return true }
        }

        // 3. 纯数字、百分比、页码或简单进度分数（如 "12", "156%", "3/5", "20 / 20"）
        if matches(raw, pattern: #"^[\d\s.,:%/+\-<>·•|()\[\]]+$"#) {
            return true
        }

        // 4. 孤立的时间戳、日期或耗时/步骤状态条（如 "14:30", "2026-11-24", "Worked for 6m>", "Worked for 7m > ○ 5/5 steps", "3m ago"）
        if matches(raw, pattern: #"^(\d{1,4}[-/.]\d{1,2}([-/.]\d{1,4})?|\d{1,2}:\d{2}(:\d{2})?(\s?[AaPp][Mm])?)$"#) {
            return true
        }
        if matches(raw, pattern: #"(?i)^worked\s+for\s+\d+\s*[smhd].*$"#) {
            return true
        }
        if matches(raw, pattern: #"(?i)^(\d+\s*(s|sec|secs|m|min|mins|h|hr|hrs|d|days?)\s*(ago)?|\d+\s*/\s*\d+\s*steps?)$"#) {
            return true
        }

        // 5. 极短且位于画面极端边缘（顶/底状态栏）的单行碎片
        let bounds = block.normalizedBounds
        let isTinyEdgeStrip = block.lineCount == 1
            && raw.count <= 4
            && !bounds.isEmpty
            && (bounds.minY > 0.94 || bounds.maxY < 0.06)
        if isTinyEdgeStrip { return true }

        return false
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
