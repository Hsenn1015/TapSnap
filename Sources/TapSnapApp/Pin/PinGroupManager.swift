import AppKit
import Combine
import Foundation
import TapSnapConfig
import TapSnapCore
import TapSnapImageIO
import TapSnapScreen
import TapSnapSystem
import TapSnapTheme

/// 贴图、分组及最近关闭记录均只保存在本机。
final class PinGroupManager: ObservableObject {
    private struct SavedPin: Codable {
        let id: UUID
        let imageID: UUID
        let frame: CGRect
        let opacity: Double
        let alwaysOnTop: Bool
        let clickThrough: Bool
        let scale: CGFloat
        let group: String?
        let createdAt: Date

        init(_ item: PinItem) {
            id = item.id; imageID = item.imageID; frame = item.frame; opacity = item.opacity
            alwaysOnTop = item.isAlwaysOnTop; clickThrough = item.isClickThrough
            scale = item.scale; group = item.group; createdAt = item.createdAt
        }
        func item(image: CGImage) -> PinItem? {
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
                  scale.isFinite, scale > 0 else { return nil }
            return PinItem(id: id, imageID: imageID, image: image, frame: frame,
                           opacity: min(1, max(0.1, opacity)), isAlwaysOnTop: alwaysOnTop,
                           isClickThrough: clickThrough, scale: scale, group: group, createdAt: createdAt)
        }
    }
    private struct Manifest: Codable {
        var active: [SavedPin]
        var closed: [SavedPin]
        var groups: [String]
        var hiddenGroups: [String]
        var isHidden: Bool
        var hideForFullScreen: Bool
    }

    static let maximumActivePins = 40
    static let maximumClosedPins = 20
    static let maximumContentBytes = 512 * 1_024 * 1_024
    @Published private(set) var items: [PinItem] = []
    @Published private(set) var groupNames: [String] = []
    @Published private(set) var isHidden = false
    @Published var hidesForFullScreen = false {
        didSet { updateFullScreenMonitoring(); refreshVisibility(); persist() }
    }
    @Published private(set) var closedStack: [PinItem] = []
    private var hiddenGroups: Set<String> = []
    private var panels: [UUID: PinPanel] = [:]
    private let archive: LocalImageArchive<Manifest>
    private let presentsWindows: Bool
    private let byteLimit: Int
    private var pinSettings: TapSnapConfig.Settings.Pin
    private var observation: AnyCancellable?
    private let fullScreenMonitor = WindowLayerMonitor()
    private var isOtherAppFullScreen = false
    private var started = false

    init(config: ConfigStore = .shared,
         storageDirectory: URL = AppPaths.applicationSupport.appendingPathComponent("pins", isDirectory: true),
         presentsWindows: Bool = true, byteLimit: Int = PinGroupManager.maximumContentBytes) {
        archive = LocalImageArchive(directory: storageDirectory)
        self.presentsWindows = presentsWindows
        self.byteLimit = byteLimit
        pinSettings = config.settings.pin
        if let saved = archive.load() {
            func restore(_ records: [SavedPin], limit: Int) -> [PinItem] {
                records.suffix(limit).compactMap { record in
                    guard let image = archive.image(record.imageID) else { return nil }
                    return record.item(image: image)
                }
            }
            items = restore(saved.active, limit: Self.maximumActivePins)
            closedStack = restore(saved.closed, limit: Self.maximumClosedPins)
            groupNames = Array(Set(saved.groups + items.compactMap(\.group))).filter { !$0.isEmpty }.sorted()
            hiddenGroups = Set(saved.hiddenGroups)
            isHidden = saved.isHidden
            hidesForFullScreen = saved.hideForFullScreen
            enforceLimits()
        }
        observation = config.$settings.map(\.pin).removeDuplicates().sink { [weak self] in self?.applySettings($0) }
    }

    /// 应用完成初始化后恢复窗口；测试和数据读取不会意外显示贴图。
    func start() {
        guard !started else { return }
        started = true
        if presentsWindows {
            for index in items.indices {
                items[index].frame = Self.visibleFrame(items[index].frame, screens: NSScreen.screens.map(\.visibleFrame))
                items[index].scale = CGFloat(items[index].image.width) / items[index].frame.width
                present(items[index])
            }
            fullScreenMonitor.onChange = { [weak self] change in
                self?.isOtherAppFullScreen = change.isFullScreen
                self?.refreshVisibility()
            }
            updateFullScreenMonitoring()
        }
    }

    func flushPersistence() { archive.flush() }

    private func updateFullScreenMonitoring() {
        guard started, presentsWindows else { return }
        if hidesForFullScreen { fullScreenMonitor.start() }
        else { fullScreenMonitor.stop(); isOtherAppFullScreen = false }
    }

    var groupSummary: [(key: String, count: Int)] {
        var counts = Dictionary(uniqueKeysWithValues: ([""] + groupNames).map { ($0, 0) })
        for item in items { counts[item.group ?? "", default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    func isGroupVisible(_ key: String) -> Bool { !hiddenGroups.contains(key) }

    func setGroup(_ key: String, visible: Bool) {
        objectWillChange.send()
        if visible { hiddenGroups.remove(key) } else { hiddenGroups.insert(key) }
        refreshVisibility()
        persist()
    }

    @discardableResult
    func createGroup(_ proposed: String) -> Bool {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !groupNames.contains(name) else { return false }
        groupNames.append(name)
        groupNames.sort()
        persist()
        return true
    }

    @discardableResult
    func renameGroup(_ old: String, to proposed: String) -> Bool {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard groupNames.contains(old), !name.isEmpty, name.count <= 60,
              name == old || !groupNames.contains(name) else { return false }
        guard name != old else { return true }
        groupNames = groupNames.map { $0 == old ? name : $0 }.sorted()
        for index in items.indices where items[index].group == old { items[index].group = name }
        for index in closedStack.indices where closedStack[index].group == old { closedStack[index].group = name }
        if hiddenGroups.remove(old) != nil { hiddenGroups.insert(name) }
        for item in items { updatePanel(item) }
        persist()
        return true
    }

    /// 删除分组不删除图片，成员移回默认分组。
    func deleteGroup(_ name: String) {
        guard !name.isEmpty else { return }
        groupNames.removeAll { $0 == name }
        hiddenGroups.remove(name)
        for index in items.indices where items[index].group == name { items[index].group = nil }
        for index in closedStack.indices where closedStack[index].group == name { closedStack[index].group = nil }
        for item in items { updatePanel(item) }
        refreshVisibility()
        persist()
    }

    func move(_ id: UUID, toGroup group: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              group == nil || group == "" || groupNames.contains(group!) else { return }
        items[index].group = group?.isEmpty == false ? group : nil
        updatePanel(items[index])
        refreshVisibility()
        persist()
    }

    @discardableResult
    func show(_ image: CGImage, at origin: CGPoint? = nil, scale: CGFloat = 1, group: String? = nil) -> PinItem {
        let scale = max(0.1, scale)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let item = PinItem(image: image, frame: CGRect(origin: origin ?? defaultOrigin(for: size), size: size),
                           opacity: pinSettings.defaultOpacity, isAlwaysOnTop: pinSettings.alwaysOnTop,
                           scale: scale, group: group)
        add(item)
        return item
    }

    func add(_ item: PinItem) {
        if let group = item.group, !groupNames.contains(group) { groupNames.append(group); groupNames.sort() }
        items.removeAll { $0.id == item.id }
        items.append(item)
        if presentsWindows { present(item) }
        enforceLimits()
        refreshVisibility()
        persist()
    }

    private func present(_ item: PinItem) {
        guard panels[item.id] == nil else { updatePanel(item); return }
        let panel = PinPanel(frame: item.frame)
        let view = PinImageView(item: item)
        view.onClose = { [weak self] in self?.close(item.id) }
        view.onCopy = { [weak self] in self?.copyToPasteboard(item.id) }
        view.onSave = { [weak self] in self?.save(item.id) }
        view.onRotate = { [weak self] clockwise in self?.rotate(item.id, clockwise: clockwise) }
        view.onFlip = { [weak self] horizontal in self?.flip(item.id, horizontal: horizontal) }
        view.onScaleChange = { [weak self] scale in self?.rescale(item.id, to: scale) }
        view.onOpacityChange = { [weak self] value in self?.setOpacity(item.id, value: value) }
        view.onToggleClickThrough = { [weak self, weak view] in
            guard let view else { return }; self?.setClickThrough(item.id, enabled: !view.item.isClickThrough)
        }
        view.onToggleAlwaysOnTop = { [weak self, weak view] in
            guard let view else { return }; self?.setAlwaysOnTop(item.id, enabled: !view.item.isAlwaysOnTop)
        }
        view.groupChoices = { [weak self] in self?.groupNames ?? [] }
        view.onMoveToGroup = { [weak self] in self?.move(item.id, toGroup: $0) }
        panel.onFrameChanged = { [weak self] frame in self?.updatePosition(item.id, frame: frame) }
        panel.contentView = view
        panels[item.id] = panel
        updatePanel(item)
        refreshVisibility()
    }

    private func updatePanel(_ item: PinItem) {
        guard let panel = panels[item.id], let view = panel.contentView as? PinImageView else { return }
        panel.alphaValue = CGFloat(item.opacity)
        panel.level = item.isAlwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = item.isClickThrough
        panel.updateHalo(enabled: pinSettings.showShadow)
        view.doubleClickToClose = pinSettings.doubleClickToClose
        view.item = item
        view.frame = CGRect(origin: .zero, size: item.frame.size)
    }

    private func applySettings(_ settings: TapSnapConfig.Settings.Pin) {
        let previous = pinSettings
        pinSettings = settings
        for index in items.indices {
            if previous.alwaysOnTop != settings.alwaysOnTop { items[index].isAlwaysOnTop = settings.alwaysOnTop }
            if previous.defaultOpacity != settings.defaultOpacity { items[index].opacity = settings.defaultOpacity }
            updatePanel(items[index])
        }
        if previous != settings { persist() }
    }

    func setClickThrough(_ id: UUID, enabled: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isClickThrough = enabled
        updatePanel(items[index])
        persist()
    }

    func setAlwaysOnTop(_ id: UUID, enabled: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isAlwaysOnTop = enabled
        updatePanel(items[index])
        persist()
    }

    func setOpacity(_ id: UUID, value: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].opacity = min(1, max(0.1, value))
        updatePanel(items[index])
        persist()
    }

    func updatePosition(_ id: UUID, frame: CGRect) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
        let adjusted = pinSettings.snapToEdges && screen != nil
            ? Self.snapped(frame, to: screen!.visibleFrame) : frame
        items[index].frame = adjusted
        if panels[id]?.frame != adjusted { panels[id]?.setFrame(adjusted, display: true) }
        updatePanel(items[index])
        persist()
    }

    static func snapped(_ frame: CGRect, to screen: CGRect, distance: CGFloat = 12) -> CGRect {
        var result = frame
        if abs(frame.minX - screen.minX) <= distance { result.origin.x = screen.minX }
        else if abs(frame.maxX - screen.maxX) <= distance { result.origin.x = screen.maxX - frame.width }
        if abs(frame.minY - screen.minY) <= distance { result.origin.y = screen.minY }
        else if abs(frame.maxY - screen.maxY) <= distance { result.origin.y = screen.maxY - frame.height }
        return result
    }

    static func visibleFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard !screens.contains(where: { $0.intersects(frame) }), let screen = screens.first else { return frame }
        var result = frame
        let factor = min(1, screen.width / frame.width, screen.height / frame.height)
        result.size = CGSize(width: frame.width * factor, height: frame.height * factor)
        result.origin = CGPoint(x: screen.midX - result.width / 2, y: screen.midY - result.height / 2)
        return result
    }

    func close(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) { closedStack.append(item) }
        panels.removeValue(forKey: id)?.orderOut(nil)
        items.removeAll { $0.id == id }
        enforceLimits()
        persist()
    }

    func restoreLastClosed() {
        guard var item = closedStack.popLast() else { return }
        item.frame = Self.visibleFrame(item.frame, screens: NSScreen.screens.map(\.visibleFrame))
        item.scale = CGFloat(item.image.width) / item.frame.width
        add(item)
    }

    var canRestoreLastClosed: Bool { !closedStack.isEmpty }

    func clearClosedHistory() {
        closedStack.removeAll()
        persist()
        archive.flush()
    }

    func closeAll() {
        closedStack.append(contentsOf: items)
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        items.removeAll()
        enforceLimits()
        persist()
    }

    func toggleVisibility() {
        isHidden.toggle()
        refreshVisibility()
        persist()
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        isHidden = false
        hiddenGroups.remove(item.group ?? "")
        refreshVisibility()
        panels[id]?.orderFrontRegardless()
        persist()
    }

    private func refreshVisibility() {
        for item in items {
            let visible = !isHidden && !hiddenGroups.contains(item.group ?? "")
                && !(hidesForFullScreen && isOtherAppFullScreen)
            if visible { panels[item.id]?.orderFrontRegardless() } else { panels[item.id]?.orderOut(nil) }
        }
    }

    private func enforceLimits() {
        if closedStack.count > Self.maximumClosedPins { closedStack.removeFirst(closedStack.count - Self.maximumClosedPins) }
        var bytes = (items + closedStack).reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        while bytes > byteLimit, let removed = closedStack.first {
            bytes -= removed.image.bytesPerRow * removed.image.height
            closedStack.removeFirst()
        }
        while items.count > Self.maximumActivePins || (bytes > byteLimit && items.count > 1) {
            let removed = items.removeFirst()
            bytes -= removed.image.bytesPerRow * removed.image.height
            panels.removeValue(forKey: removed.id)?.orderOut(nil)
        }
    }

    private func persist() {
        let all = items + closedStack
        // 过大的单张贴图可继续显示，但不把无上限的大文件写入历史。
        let storable = Set(all.filter { $0.image.bytesPerRow * $0.image.height <= byteLimit }.map(\.id))
        var images: [UUID: CGImage] = [:]
        for item in all where storable.contains(item.id) { images[item.imageID] = item.image }
        archive.save(Manifest(active: items.filter { storable.contains($0.id) }.map(SavedPin.init),
                              closed: closedStack.filter { storable.contains($0.id) }.map(SavedPin.init),
                              groups: groupNames, hiddenGroups: Array(hiddenGroups), isHidden: isHidden,
                              hideForFullScreen: hidesForFullScreen), images: images)
    }
    func copyToPasteboard(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let bitmap = NSBitmapImageRep(cgImage: item.image)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(data, forType: .png)
        }
        pasteboard.setString(
            String(data: (try? JSONEncoder().encode(item.clipMeta)) ?? Data(), encoding: .utf8) ?? "",
            forType: NSPasteboard.PasteboardType(ClipMetaData.pasteboardType)
        )
    }

    /// 右键「另存为…」。
    func save(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(ImageCodec.defaultFileName()).png"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ImageCodec.encode(item.image, as: .png)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    func rotate(_ id: UUID, clockwise: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let image = items[index].image.rotated(clockwise: clockwise) else { return }
        items[index].image = image
        items[index].imageID = UUID()
        items[index].frame.size = CGSize(width: CGFloat(image.width) / items[index].scale,
                                         height: CGFloat(image.height) / items[index].scale)
        panels[id]?.setContentSize(items[index].frame.size)
        updatePanel(items[index])
        persist()
    }

    func flip(_ id: UUID, horizontal: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let image = items[index].image.flipped(horizontally: horizontal) else { return }
        items[index].image = image
        items[index].imageID = UUID()
        updatePanel(items[index])
        persist()
    }

    func rescale(_ id: UUID, to scale: CGFloat) {
        guard let index = items.firstIndex(where: { $0.id == id }), scale.isFinite, scale > 0 else { return }
        let scale = min(8, max(0.1, scale))
        items[index].scale = scale
        items[index].frame.size = CGSize(width: CGFloat(items[index].image.width) / scale,
                                         height: CGFloat(items[index].image.height) / scale)
        panels[id]?.setContentSize(items[index].frame.size)
        updatePanel(items[index])
        persist()
    }

    private func defaultOrigin(for size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first { $0.visibleFrame.contains(mouse) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(items.count % 8) * 18
        return CGPoint(x: max(visible.minX, visible.maxX - size.width - 40 - offset),
                       y: max(visible.minY, visible.maxY - size.height - 60 - offset))
    }

    deinit { fullScreenMonitor.stop(); archive.flush() }
}
