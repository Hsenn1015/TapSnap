import AppKit
import SwiftUI
import Translation
import TapSnapOCR

final class TranslationPanel {
    private var window: NSWindow?

    func show(text: String) {
        guard #available(macOS 15, *) else {
            let alert = NSAlert()
            alert.messageText = "设备端翻译需要 macOS 15 或更新版本"
            alert.informativeText = "文字识别仍可使用。升级系统后可下载语言包并离线翻译。"
            alert.runModal()
            return
        }
        window?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: TranslationView(text: text)))
        window.title = "TapSnap 翻译"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 690, height: 480))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

@available(macOS 15, *)
private struct TranslationView: View {
    @State var text: String
    @State private var result = ""
    @State private var target = "zh-Hans"
    @State private var source = "auto"
    @State private var status = "首次使用可能需要下载系统语言包。翻译在本机完成。"
    @State private var busy = false
    @State private var configuration: TranslationSession.Configuration?
    private let languages = [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
                             ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("原文", selection: $source) {
                    Text("自动识别").tag("auto")
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("译文", selection: $target) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }.disabled(busy)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("原文（可修改）").font(.headline)
                    TextEditor(text: $text).disabled(busy)
                }
                VStack(alignment: .leading) {
                    Text("翻译结果").font(.headline)
                    TextEditor(text: $result)
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("复制译文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                }.disabled(result.isEmpty || busy)
                Button(busy ? "翻译中…" : "翻译", action: translate)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 380)
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(text)
                guard !Task.isCancelled else { return }
                result = response.targetText
                status = "翻译完成。可修改原文或切换语言后重新翻译。"
            } catch {
                status = "翻译未完成：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func translate() {
        busy = true
        result = ""
        status = "正在准备设备端翻译…"
        let next = TranslationSession.Configuration(
            source: source == "auto" ? nil : Locale.Language(identifier: source),
            target: Locale.Language(identifier: target))
        if configuration?.source == next.source && configuration?.target == next.target {
            configuration?.invalidate()
        } else { configuration = next }
    }
}

extension AppEnvironment {
    func translateImage(_ image: CGImage) {
        toast.info("正在识别待翻译文字…")
        Task { @MainActor in
            do {
                let document = try await ocr.recognize(image, options: .init(languages: config.settings.ocr.languages))
                guard !document.isEmpty else { toast.warning("没有识别到文字"); return }
                translationPanel.show(text: document.plainText)
            } catch { toast.error("文字识别失败：\(error.localizedDescription)") }
        }
    }
}
