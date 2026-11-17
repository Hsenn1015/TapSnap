import AppKit
import SwiftUI
import WebKit
import TapSnapCore
import TapSnapImageIO
import TapSnapTheme

/// One request = one process: the neural model is released when recognition finishes.
final class LocalFormulaRecognizer {
    private let runtime = FormulaRuntime()
    private let lock = NSLock()
    private var activeID: UUID?
    private var process: Process?

    func cancel() {
        lock.lock()
        activeID = nil
        let running = process
        process = nil
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func recognize(_ image: CGImage, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let id = UUID()
        lock.lock(); activeID = id; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TapSnap-formula-\(id)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let result: Result<String, Error> = Result {
                guard runtime.isReady, let helper = runtime.recognitionScript else {
                    throw FormulaRecognitionError.needsInstallation
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let input = directory.appendingPathComponent("input.png")
                try ImageCodec.encode(image, as: .png).write(to: input, options: .atomic)
                let errorLog = directory.appendingPathComponent("stderr.log")
                FileManager.default.createFile(atPath: errorLog.path, contents: nil)
                let errorHandle = try FileHandle(forWritingTo: errorLog)
                defer { try? errorHandle.close() }
                let child = Process(), output = Pipe()
                child.executableURL = runtime.python
                child.arguments = [helper.path, input.path]
                child.standardOutput = output
                child.standardError = errorHandle
                child.environment = ProcessInfo.processInfo.environment.merging([
                    "NO_ALBUMENTATIONS_UPDATE": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                    "PYTHONDONTWRITEBYTECODE": "1"
                ], uniquingKeysWith: { _, value in value })
                lock.lock()
                guard activeID == id else { lock.unlock(); throw CancellationError() }
                do { try child.run(); process = child; lock.unlock() }
                catch { lock.unlock(); throw error }
                let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
                defer { timeout.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                guard let payload = try? JSONDecoder().decode(FormulaResponse.self, from: data) else {
                    throw FormulaRecognitionError.message("识别已取消、超时或模型未能启动，请缩小公式选区后重试。")
                }
                if payload.needsInstallation == true { throw FormulaRecognitionError.needsInstallation }
                guard child.terminationStatus == 0, let latex = payload.latex, !latex.isEmpty else {
                    throw FormulaRecognitionError.message(payload.error ?? "没有识别到公式")
                }
                return latex
            }
            DispatchQueue.main.async { [self] in
                lock.lock()
                let deliver = activeID == id
                if deliver { process = nil; activeID = nil }
                lock.unlock()
                if deliver { completion(result) }
            }
        }
    }
    deinit { cancel() }
}

private struct FormulaResponse: Decodable {
    var latex: String?
    var error: String?
    var needsInstallation: Bool?
}
private enum FormulaRecognitionError: LocalizedError {
    case needsInstallation
    case message(String)
    var errorDescription: String? {
        switch self {
        case .needsInstallation: return "公式识别环境需要安装或修复。"
        case .message(let message): return message
        }
    }
}

final class FormulaPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = FormulaViewModel()
    private let theme: () -> Theme

    init(theme: @escaping () -> Theme) {
        self.theme = theme
        super.init()
    }

    func captureWhenReady(_ capture: @escaping () -> Void) {
        if model.requiresInstallation {
            if window?.isVisible != true || model.installation == nil { model.prepareCapture(capture) }
            showWindow()
        } else {
            capture()
        }
    }

    func show(image: CGImage) {
        model.recognize(image)
        showWindow()
    }

    private func showWindow() {
        let theme = theme()
        let view = FormulaResultView(model: model, theme: theme, onDismiss: { [weak self] in self?.window?.close() },
                                     onBeginRecognition: { [weak self] in
            guard let self, let capture = model.captureAfterInstallation else { return }
            window?.close()
            capture()
        })
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "TapSnap 公式识别"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 680, height: 480))
            window.center()
            self.window = window
        }
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { model.close() }
}

private final class FormulaViewModel: ObservableObject {
    @Published var latex = ""
    @Published var status = ""
    @Published var busy = false
    @Published private(set) var installation: FormulaInstallationView.State?
    private let recognizer = LocalFormulaRecognizer()
    private let runtime = FormulaRuntime()
    private var image: CGImage?
    private var pythonCheckID: UUID?
    private var installProcess: Process?
    private var isCancellingInstall = false
    private var needsRepair = false
    private(set) var captureAfterInstallation: (() -> Void)?
    weak var preview: WKWebView?

    var requiresInstallation: Bool { installProcess != nil || needsRepair || !runtime.isReady }

    func prepareCapture(_ capture: @escaping () -> Void) {
        image = nil
        captureAfterInstallation = capture
        checkPython()
    }

    func recognize(_ image: CGImage) {
        recognizer.cancel()
        busy = false
        self.image = image
        captureAfterInstallation = nil
        guard !requiresInstallation else { checkPython(); return }
        recognizeInstalled(image)
    }

    private func recognizeInstalled(_ image: CGImage) {
        installation = nil
        latex = ""; busy = true; status = "正在本机识别公式，首次加载模型需要几秒…"
        recognizer.recognize(image) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let text):
                self.image = nil
                latex = text
                status = "识别完成，请核对公式。修改 LaTeX 后预览会同步更新。"
            case .failure(FormulaRecognitionError.needsInstallation):
                needsRepair = true
                checkPython()
            case .failure(let error):
                self.image = nil
                status = error.localizedDescription
            }
        }
    }

    func checkPython() {
        guard installProcess == nil else { return }
        guard runtime.canInstall else {
            installation = .failed(message: FormulaRuntime.InstallError.resourcesMissing.localizedDescription)
            return
        }
        let id = UUID()
        pythonCheckID = id
        installation = .checking
        runtime.checkPython { [weak self] available in
            guard let self, pythonCheckID == id else { return }
            pythonCheckID = nil
            installation = available ? .readyToInstall : .missingPython
        }
    }

    func install() {
        guard installProcess == nil else { return }
        installation = .installing(stage: FormulaRuntime.Stage.environment.title)
        do {
            installProcess = try runtime.install(onStage: { [weak self] stage in
                guard let self, !isCancellingInstall else { return }
                installation = .installing(stage: stage.title)
            }, completion: { [weak self] result in self?.finishInstallation(result) })
        } catch {
            installation = .failed(message: error.localizedDescription)
        }
    }

    private func finishInstallation(_ result: Result<Void, Error>) {
        installProcess = nil
        let wasCancelled = isCancellingInstall
        isCancellingInstall = false
        switch result {
        case .success:
            needsRepair = false
            if let image { recognizeInstalled(image) }
            else { installation = captureAfterInstallation == nil ? nil : .installed }
        case .failure where wasCancelled:
            checkPython()
        case .failure(let error):
            installation = .failed(message: error.localizedDescription)
        }
    }

    func cancelInstallation() {
        guard let installProcess, installProcess.isRunning, !isCancellingInstall else { return }
        isCancellingInstall = true
        installation = .cancelling
        installProcess.terminate()
    }

    func cancelRecognition() {
        recognizer.cancel()
        image = nil
        busy = false
        status = "已取消识别"
    }

    func close() {
        cancelRecognition()
        pythonCheckID = nil
        captureAfterInstallation = nil
        if installProcess == nil { installation = nil }
    }
    func copyImage() {
        preview?.takeSnapshot(with: nil) { [weak self] image, error in
            guard let image else { self?.status = error?.localizedDescription ?? "预览尚未就绪"; return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            self?.status = "已复制公式图片"
        }
    }
}

private struct FormulaResultView: View {
    @ObservedObject var model: FormulaViewModel
    let theme: Theme
    let onDismiss: () -> Void
    let onBeginRecognition: () -> Void

    var body: some View {
        Group {
            if let installation = model.installation {
                FormulaInstallationView(theme: theme, state: installation, onInstall: model.install,
                                        onCancel: model.cancelInstallation, onDismiss: onDismiss, onRecheckPython: model.checkPython,
                                        onBeginRecognition: onBeginRecognition)
            } else {
                result
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LaTeX").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button("取消") { model.cancelRecognition() } }
            }
            TextEditor(text: $model.latex).font(.system(.body, design: .monospaced)).frame(minHeight: 90, maxHeight: 150)
            Text("公式预览").font(.headline)
            FormulaWebPreview(model: model).frame(minHeight: 150)
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("复制公式图片") { model.copyImage() }.disabled(model.latex.isEmpty || model.busy)
                Button("复制 LaTeX") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.latex, forType: .string)
                }.disabled(model.latex.isEmpty || model.busy)
            }
        }.padding(20)
    }
}

private struct FormulaWebPreview: NSViewRepresentable {
    @ObservedObject var model: FormulaViewModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        model.preview = view
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("KaTeX") {
            view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.latex = model.latex
        context.coordinator.render(view)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var latex = ""
        var loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render(webView) }
        func render(_ view: WKWebView) {
            guard loaded, let data = try? JSONSerialization.data(withJSONObject: [latex]),
                  let argument = String(data: data, encoding: .utf8) else { return }
            view.evaluateJavaScript("window.renderFormula(\(argument)[0]);", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}

extension AppEnvironment {
    func recognizeFormula(_ image: CGImage) { formulaPanel.show(image: image) }
}
