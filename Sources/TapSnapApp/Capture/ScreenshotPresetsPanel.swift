import AppKit
import Combine
import SwiftUI
import TapSnapCore
import TapSnapImageIO
import TapSnapScreen

final class ScreenshotPresetStore: ObservableObject {
    @Published private(set) var presets: [ScreenshotPreset]
    @Published private(set) var loadError: String?
    private let storage: LocalStore<[ScreenshotPreset]>

    init(fileURL: URL = AppPaths.applicationSupport.appendingPathComponent("screenshot-presets.json")) {
        storage = LocalStore(fileURL: fileURL)
        do { presets = try storage.load() ?? [] }
        catch { presets = []; loadError = "读取预设失败：\(error.localizedDescription)" }
    }

    func save(_ preset: ScreenshotPreset) throws {
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) { updated[index] = preset }
        else { updated.append(preset) }
        try storage.save(updated)
        presets = updated
        loadError = nil
    }

    func remove(id: UUID) throws {
        let updated = presets.filter { $0.id != id }
        try storage.save(updated)
        presets = updated
    }
}

final class ScreenshotPresetsPanel {
    private let environment: AppEnvironment
    private let store: ScreenshotPresetStore
    private var window: NSWindow?

    init(environment: AppEnvironment, store: ScreenshotPresetStore = ScreenshotPresetStore()) {
        self.environment = environment
        self.store = store
    }

    func show() {
        let view = ScreenshotPresetsView(store: store,
            lastSelection: environment.config.settings.capture.lastSelection,
            screens: ScreenLayout.current(),
            capture: { [weak self] preset in
                guard let self else { return }
                self.window?.orderOut(nil)
                self.environment.captureCoordinator.startPreset(preset)
            })
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "截图预设"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 660, height: 430))
        window.minSize = CGSize(width: 600, height: 400)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ScreenshotPresetsView: View {
    @ObservedObject var store: ScreenshotPresetStore
    let lastSelection: CGRect?
    let screens: [ScreenDescriptor]
    let capture: (ScreenshotPreset) -> Void
    @State private var selection: UUID?
    @State private var draft = ScreenshotPreset(name: "新预设")
    @State private var fixedRegion = false
    @State private var region = CGRect(x: 0, y: 0, width: 800, height: 600)
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.presets) { preset in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name)
                            Text("\(preset.format.uppercased()) · \(preset.rect == nil ? "每次框选" : "固定区域")")
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(preset.id)
                    }
                }
                HStack {
                    Button("新增", systemImage: "plus") { newDraft() }
                    Button("删除", systemImage: "minus") {
                        guard let selection else { return }
                        do { try store.remove(id: selection); newDraft() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(selection == nil)
                }.padding(10)
            }.frame(minWidth: 180, idealWidth: 200)

            VStack(alignment: .leading, spacing: 14) {
                TextField("预设名称", text: $draft.name)
                Picker("图片格式", selection: $draft.format) {
                    ForEach(ImageFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                Toggle("确认截图时自动保存文件", isOn: $draft.autoSave)
                Toggle("使用固定区域", isOn: $fixedRegion)
                if fixedRegion {
                    Picker("屏幕", selection: $draft.screenID) {
                        Text("按区域自动定位").tag(UInt32?.none)
                        ForEach(screens) { screen in
                            Text(screen.localizedName).tag(UInt32?.some(screen.id))
                        }
                    }
                    HStack {
                        coordinate("X", value: $region.origin.x)
                        coordinate("Y", value: $region.origin.y)
                    }
                    HStack {
                        coordinate("宽", value: $region.size.width)
                        coordinate("高", value: $region.size.height)
                    }
                    Button("使用最近一次框选区域") {
                        guard let lastSelection else { return }
                        region = lastSelection
                        draft.screenID = screens.first { $0.frame.contains(lastSelection) }?.id
                    }.disabled(lastSelection == nil)
                    Text("坐标以屏幕左上角为原点，扩展屏可以使用负坐标。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("启动后手动框选，本次截图使用预设格式和保存方式。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = error ?? store.loadError {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("保存预设") { save(andCapture: false) }
                    Spacer()
                    Button("使用此预设截图") { save(andCapture: true) }
                        .buttonStyle(.borderedProminent)
                }
            }.textFieldStyle(.roundedBorder).padding(20).frame(minWidth: 360)
        }
        .onChange(of: selection) { _, id in
            guard let preset = store.presets.first(where: { $0.id == id }) else { return }
            draft = preset
            fixedRegion = preset.rect != nil
            region = preset.rect ?? region
            error = nil
        }
    }

    private func coordinate(_ title: String, value: Binding<CGFloat>) -> some View {
        HStack {
            Text(title).frame(width: 20)
            TextField(title, value: Binding<Double>(get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = CGFloat($0) }), format: .number.precision(.fractionLength(0...1)))
        }
    }

    private func newDraft() {
        selection = nil
        draft = ScreenshotPreset(name: "新预设")
        fixedRegion = false
        error = nil
    }

    private func save(andCapture: Bool) {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { error = "请输入预设名称"; return }
        guard !fixedRegion || (region.width >= 2 && region.height >= 2 &&
              region.minX.isFinite && region.minY.isFinite && region.width.isFinite && region.height.isFinite) else {
            error = "请输入有效区域，宽和高至少为 2"
            return
        }
        draft.rect = fixedRegion ? region : nil
        if !fixedRegion { draft.screenID = nil }
        do {
            try store.save(draft)
            selection = draft.id
            error = nil
            if andCapture { capture(draft) }
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}
