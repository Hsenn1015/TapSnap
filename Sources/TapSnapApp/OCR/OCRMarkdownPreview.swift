import Foundation
import SwiftUI
import TapSnapTheme
import WebKit

struct OCRMarkdownPreview: NSViewRepresentable {
    let source: String
    let theme: Theme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = NSColor(theme.token(.card))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.source != source || coordinator.isDark != theme.isDark else { return }
        coordinator.source = source
        coordinator.isDark = theme.isDark
        webView.loadHTMLString(OCRMarkdownHTML.document(source, isDark: theme.isDark), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var source: String?
        var isDark: Bool?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isPreview = action.navigationType == .other && action.request.url?.absoluteString == "about:blank"
            decisionHandler(isPreview ? .allow : .cancel)
        }
    }
}

/// Foundation parses Markdown. These tags render its presentation intents without running source HTML.
enum OCRMarkdownHTML {
    static func document(_ source: String, isDark: Bool) -> String {
        let themeClass = isDark ? "dark" : "light"
        return """
        <!doctype html><html lang="zh-Hans" class="\(themeClass)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root {color-scheme:light;--surface:#fff;--text:#171717;--muted:#616161;--line:#e5e5e5;--code:#f4f4f5;--link:#315cb0}
        .dark {color-scheme:dark;--surface:#1b1b1b;--text:#fafafa;--muted:#b0b0b0;--line:#414141;--code:#292929;--link:#a7bbfa}
        html,body {background:var(--surface);color:var(--text)}
        body {margin:0;padding:15px 18px 20px;font:14px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}
        body > :first-child {margin-top:0} body > :last-child {margin-bottom:0}
        h1,h2,h3,h4,h5,h6 {line-height:1.3;margin:1em 0 .4em} h1{font-size:24px} h2{font-size:20px} h3{font-size:17px}
        p,ul,ol,pre,blockquote,table {margin:.65em 0} ul,ol {padding-inline-start:1.7em}
        li p {margin:.18em 0} li:has(>p>.task) {list-style:none} .task {margin:0 .4em 0 0}
        blockquote {color:var(--muted);border-inline-start:3px solid var(--line);padding-inline-start:12px}
        code {background:var(--code);border-radius:4px;padding:1px 4px;font:12px ui-monospace,monospace}
        pre {background:var(--code);border-radius:8px;padding:10px 12px;overflow:auto;white-space:pre;line-height:1.5}
        pre code {padding:0;background:none} hr{border:0;border-top:1px solid var(--line);margin:1em 0}
        .table {overflow:auto} table {border-collapse:collapse;min-width:100%;text-align:start}
        th,td {border:1px solid var(--line);padding:5px 9px} th{background:var(--code);font-weight:600}
        .link {color:var(--link);text-decoration:underline}
        </style></head><body>
        \(body(source))
        </body></html>
        """
    }

    static func body(_ source: String) -> String {
        guard let parsed = try? AttributedString(markdown: source) else {
            return "<pre>\(escaped(source))</pre>"
        }
        var html = ""
        var open: [PresentationIntent.IntentType] = []
        var nextCell = 0

        func closeLast() {
            let kind = open.removeLast().kind
            switch kind {
            case .paragraph: html += "</p>"
            case .header(let level): html += "</h\(level)>"
            case .orderedList: html += "</ol>"
            case .unorderedList: html += "</ul>"
            case .listItem: html += "</li>"
            case .codeBlock: html += "</code></pre>"
            case .blockQuote: html += "</blockquote>"
            case .table: html += "</table></div>"
            case .tableRow, .tableHeaderRow:
                if case .table(let columns) = open.last?.kind {
                    let empty = kind == .tableHeaderRow ? "<th></th>" : "<td></td>"
                    html += String(repeating: empty, count: max(0, columns.count - nextCell))
                }
                html += "</tr>"
            case .tableCell: html += open.last?.kind == .tableHeaderRow ? "</th>" : "</td>"
            default: break
            }
        }

        for run in parsed.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            let common = zip(open, path).prefix { $0.identity == $1.identity }.count
            while open.count > common { closeLast() }
            var beginsListItem = false
            for (index, component) in path.enumerated().dropFirst(common) {
                switch component.kind {
                case .paragraph: html += "<p>"
                case .header(let level): html += "<h\(level)>"
                case .orderedList:
                    if index + 1 < path.count, case .listItem(let ordinal) = path[index + 1].kind {
                        html += "<ol start=\"\(ordinal)\">"
                    } else { html += "<ol>" }
                case .unorderedList: html += "<ul>"
                case .listItem:
                    html += "<li>"
                    beginsListItem = true
                case .codeBlock: html += "<pre><code>"
                case .blockQuote: html += "<blockquote>"
                case .thematicBreak: html += "<hr>"
                case .table: html += "<div class=\"table\"><table>"
                case .tableRow, .tableHeaderRow:
                    html += "<tr>"
                    nextCell = 0
                case .tableCell(let column):
                    let tag = open.last?.kind == .tableHeaderRow ? "th" : "td"
                    html += String(repeating: "<\(tag)></\(tag)>", count: max(0, column - nextCell))
                    let alignment = tableAlignment(for: column, in: open)
                    html += "<\(tag) style=\"text-align:\(alignment)\">"
                    nextCell = column + 1
                @unknown default: break
                }
                open.append(component)
            }
            guard open.last?.kind != .thematicBreak else { continue }
            var text = String(parsed[run.range].characters)
            if beginsListItem, text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                let checked = text.hasPrefix("[ ] ") ? "" : " checked"
                html += "<input class=\"task\" type=\"checkbox\" disabled\(checked)>"
                text.removeFirst(4)
            }
            html += inline(text, style: run.inlinePresentationIntent, link: run.link)
        }
        while !open.isEmpty { closeLast() }
        return html
    }

    private static func tableAlignment(for column: Int, in path: [PresentationIntent.IntentType]) -> String {
        for component in path.reversed() {
            guard case .table(let columns) = component.kind, columns.indices.contains(column) else { continue }
            switch columns[column].alignment {
            case .left: return "left"
            case .right: return "right"
            case .center: return "center"
            @unknown default: return "start"
            }
        }
        return "start"
    }

    private static func inline(_ text: String, style: InlinePresentationIntent?, link: URL?) -> String {
        var fragment = escaped(text)
        if let style {
            if style.contains(.lineBreak) { return "<br>" }
            if style.contains(.code) { fragment = "<code>\(fragment)</code>" }
            if style.contains(.emphasized) { fragment = "<em>\(fragment)</em>" }
            if style.contains(.stronglyEmphasized) { fragment = "<strong>\(fragment)</strong>" }
            if style.contains(.strikethrough) { fragment = "<del>\(fragment)</del>" }
        }
        if let link { fragment = "<span class=\"link\" title=\"\(escaped(link.absoluteString))\">\(fragment)</span>" }
        return fragment
    }

    private static func escaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
