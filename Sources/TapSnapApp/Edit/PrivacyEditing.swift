import CoreGraphics
import SwiftUI
import TapSnapPrivacy
import TapSnapTheme

/// Detection results that have not yet been applied to the document.
final class PrivacyEditing: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, failed }
    enum ModelScan {
        case text(PrivacyAIConfiguration, key: String?)
        case image(PrivacyAIConfiguration, key: String?, region: CGRect, masks: [CGRect])
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var suggestions: [PrivacyFinding] = []
    @Published private(set) var status = ""
    @Published var focusedID: UUID?
    @Published var showsSuggestions = false
    private var task: Task<Void, Never>?
    private var known: [PrivacyFinding] = []
    private var ignoredIDs: Set<UUID> = []
    private var cachedScan: (image: CGImage, settings: PrivacySettings, result: PrivacyScanResult)?

    var blocksOutput: Bool { phase == .scanning }
    var hasCompletedLocalScan: Bool { cachedScan != nil }

    func scan(_ image: CGImage, settings: PrivacySettings, modelScan: ModelScan? = nil,
              apply: @escaping ([PrivacyFinding]) -> Void) {
        cancel()
        phase = .scanning
        status = "正在本机识别…"
        var scanSettings = settings
        scanSettings.ai = nil
        scanSettings.enabled = false
        scanSettings.appearance = PrivacyMaskAppearance()
        if cachedScan?.image !== image || cachedScan?.settings != scanSettings { cachedScan = nil }
        task = Task { @MainActor [weak self] in
            defer { if !Task.isCancelled { self?.task = nil } }
            do {
                let result: PrivacyScanResult
                if let cached = self?.cachedScan {
                    result = cached.result
                    if modelScan == nil {
                        self?.receive(result.findings, refreshingSuggestions: false, apply: apply)
                    }
                } else {
                    result = try await PrivacyScanner.inspect(image, settings: scanSettings, includeText: true)
                    try Task.checkCancellation()
                    self?.cachedScan = (image, scanSettings, result)
                    self?.receive(result.findings, refreshingSuggestions: true, apply: apply)
                }
                guard self != nil else { return }
                switch modelScan {
                case .text(let configuration, let key):
                    self?.status = "本机识别完成，正在补查文字…"
                    let limited = try await PrivacyAI.supplement(result, settings: settings, configuration: configuration,
                                                                 key: key) { [weak self] findings in
                        await MainActor.run { [weak self] in
                            guard !Task.isCancelled else { return }
                            self?.receive(findings, refreshingSuggestions: false, apply: apply)
                        }
                    }
                    try Task.checkCancellation()
                    self?.status = limited ? "AI 已补查部分文字，本机规则已检查全图" : ""
                case .image(let configuration, let key, let region, let masks):
                    self?.status = "本机识别完成，正在定位图片…"
                    try await PrivacyAI.locate(in: image, scan: result, covering: masks, within: region,
                                               settings: settings, configuration: configuration, key: key) { [weak self] findings, completed, total in
                        await MainActor.run { [weak self] in
                            guard let self, !Task.isCancelled else { return }
                            self.receive(findings, refreshingSuggestions: false, apply: apply)
                            self.status = "图片定位 \(completed)/\(total)"
                        }
                    }
                    try Task.checkCancellation()
                    self?.status = ""
                case nil:
                    self?.status = ""
                }
                self?.phase = .ready
            } catch {
                guard !Task.isCancelled, let self else { return }
                if let error = error as? PrivacyAIError {
                    let progress = self.status.hasPrefix("图片定位 ") ? "（\(self.status)）" : ""
                    self.status = error.message + progress
                } else {
                    switch error as? PrivacyScanError {
                    case .invalidCustomRule: self.status = "自定义规则无效，请检查规则设置"
                    case .customRuleTimedOut: self.status = "自定义规则耗时过长，请检查规则设置"
                    default: self.status = "本机识别失败，可重试或拖动手动打码"
                    }
                }
                self.phase = .failed
            }
        }
    }

    func receive(_ findings: [PrivacyFinding], refreshingSuggestions: Bool, apply: ([PrivacyFinding]) -> Void) {
        // Keep manual edits and deletions on rescans. A rule changed to automatic
        // can still apply a previously unapplied suggestion.
        let current = refreshingSuggestions ? [] : suggestions
        var covered: [PrivacyFinding] = []
        for finding in findings where finding.isCovered {
            guard !known.contains(where: { Self.sameRegion($0, finding) }),
                  !covered.contains(where: { Self.sameRegion($0, finding) }) else { continue }
            covered.append(finding)
        }
        known.append(contentsOf: covered)
        suggestions = current.filter { old in !covered.contains { Self.sameRegion($0, old) } }
        for finding in findings where !finding.isCovered {
            guard !known.contains(where: { Self.sameRegion($0, finding) }),
                  !suggestions.contains(where: { Self.sameRegion($0, finding) }) else { continue }
            suggestions.append(finding)
        }
        apply(covered)
    }

    func markHandled(_ findings: [PrivacyFinding], ignoring: Bool = false) {
        let ids = Set(findings.map(\.id))
        known.append(contentsOf: suggestions.filter { ids.contains($0.id) })
        if ignoring { ignoredIDs.formUnion(ids) }
        suggestions.removeAll { ids.contains($0.id) }
        if let focusedID, ids.contains(focusedID) { self.focusedID = nil }
    }

    func uncoveredFindings(in output: CGRect, coveredBy masks: [CGRect]) -> [PrivacyFinding] {
        (suggestions + known).filter { finding in
            guard !ignoredIDs.contains(finding.id) else { return false }
            let visible = finding.bounds.integral.intersection(output)
            return !visible.isEmpty && !masks.contains { $0.contains(visible) }
        }
    }

    private static func sameRegion(_ a: PrivacyFinding, _ b: PrivacyFinding) -> Bool {
        let overlap = a.bounds.intersection(b.bounds)
        return !overlap.isNull && overlap.width * overlap.height >= 0.8 * max(
            a.bounds.width * a.bounds.height, b.bounds.width * b.bounds.height
        )
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .scanning {
            phase = .ready
            status = "已停止识别，当前打码已保留"
        }
    }

    deinit { task?.cancel() }
}

struct PrivacyStatusView: View {
    static let height: CGFloat = 30

    @ObservedObject var controller: EditController
    @ObservedObject var privacy: PrivacyEditing
    let theme: Theme
    var locate: (CGRect) -> Void = { _ in }

    var body: some View {
        let suggestions = controller.privacySuggestions
        let message = statusMessage(hasSuggestions: !suggestions.isEmpty)
        return HStack(spacing: 8) {
            if privacy.blocksOutput { ProgressView().controlSize(.small) }
            else {
                Image(systemName: privacy.phase == .failed || !suggestions.isEmpty ? "exclamationmark.shield" : "checkmark.shield")
            }
            Text(message).lineLimit(1).help(message)
            Spacer(minLength: 0)
            if privacy.blocksOutput {
                Button("停止识别") { privacy.cancel() }
            }
            if !suggestions.isEmpty {
                Button("待打码 \(suggestions.count)") { privacy.showsSuggestions.toggle() }
                    .popover(isPresented: $privacy.showsSuggestions, arrowEdge: .bottom) { suggestionsPanel }
            }
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .foregroundStyle(theme.token(.foreground))
        .background(theme.token(.popover))
        .accessibilityIdentifier("privacy-status")
    }

    private func statusMessage(hasSuggestions: Bool) -> String {
        if !privacy.status.isEmpty { return privacy.status }
        let count = controller.document.items.lazy.filter { $0.privacyMask != nil }.count
        if count == 0, !hasSuggestions { return "未识别到敏感内容" }
        return "已打码 \(count) 处"
    }

    private var suggestionsPanel: some View {
        let suggestions = controller.privacySuggestions
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待打码").font(.headline)
                Spacer()
                Button("全部打码") { controller.applyAllPrivacySuggestions(); privacy.showsSuggestions = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestions) { finding in
                        HStack {
                            Text(finding.label)
                            Spacer()
                            Button("定位") {
                                privacy.focusedID = finding.id
                                locate(controller.documentRect(for: finding))
                                privacy.showsSuggestions = false
                            }
                            Button("打码") { controller.applyPrivacySuggestion(finding.id) }
                            Button {
                                privacy.markHandled([finding], ignoring: true)
                                if controller.privacySuggestions.isEmpty { privacy.showsSuggestions = false }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .help("忽略这处，保留原图内容")
                            .accessibilityLabel("忽略\(finding.label)，保留原图内容")
                        }
                    }
                }
            }
            .frame(idealHeight: min(220, CGFloat(suggestions.count) * 26), maxHeight: 220)
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 300)
    }
}
