import AppKit
import TapSnapCore
import TapSnapTheme
import SwiftUI

/// 贴图分组与窗口操作面板；鼠标穿透的贴图也可从这里恢复操作。
final class PinGroupsPanel {
    private let groups: PinGroupManager
    private let theme: () -> Theme
    private var window: NSWindow?

    init(groups: PinGroupManager, theme: @escaping () -> Theme) {
        self.groups = groups
        self.theme = theme
    }

    func toggle() {
        window == nil ? show() : close()
    }

    func show() {
        guard window == nil else { return }

        let view = PinGroupsView(
            groups: groups,
            theme: theme(),
            onClose: { [weak self] in self?.close() }
        )
        let panel = PinGroupsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 420, height: 520))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: min(max(visible.minX + 8, mouse.x - 210), visible.maxX - 428),
            y: min(max(visible.minY + 8, mouse.y - 532), visible.maxY - 528)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        window = panel
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class PinGroupsWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PinGroupsView: View {
    @ObservedObject var groups: PinGroupManager
    let theme: Theme
    let onClose: () -> Void
    @State private var newGroup = ""
    @State private var renamingGroup: String?
    @State private var renameValue = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("贴图分组").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(groups.isHidden ? "显示全部" : "隐藏全部") { groups.toggleVisibility() }
                Button(action: onClose) { Image(systemName: "xmark") }
            }
            .buttonStyle(.plain)
            .padding(12)
            Divider()
            HStack(spacing: 8) {
                TextField("新分组名称", text: $newGroup).onSubmit(createGroup)
                Button("新建", action: createGroup)
                    .disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Toggle("其他应用全屏时隐藏贴图", isOn: $groups.hidesForFullScreen)
                .font(.system(size: 11))
                .padding(.horizontal, 12).padding(.vertical, 10)
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups.groupSummary, id: \.key) { group in
                        groupHeader(group.key, count: group.count)
                        ForEach(groups.items.filter { ($0.group ?? "") == group.key }) { item in
                            pinRow(item)
                        }
                        if group.count == 0 {
                            Text("暂无贴图，可从贴图右键菜单移入")
                                .font(.system(size: 11)).foregroundStyle(theme.token(.mutedForeground))
                                .padding(.horizontal, 14).padding(.bottom, 12)
                        }
                        Divider()
                    }
                }
            }
            Divider()
            HStack {
                Text("仅本机保存 · 最近关闭 \(groups.closedStack.count) 张")
                    .font(.system(size: 10)).foregroundStyle(theme.token(.mutedForeground))
                Spacer()
                Button("恢复关闭", action: groups.restoreLastClosed).disabled(!groups.canRestoreLastClosed)
                Button("清空记录", action: groups.clearClosedHistory).disabled(!groups.canRestoreLastClosed)
            }
            .padding(12)
        }
        .frame(width: 420, height: 520)
        .background(theme.token(.popover))
        .foregroundStyle(theme.token(.foreground))
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radiusMD, style: .continuous)
                .strokeBorder(theme.token(.border), lineWidth: 1)
        }
        .onExitCommand(perform: onClose)
    }

    private func createGroup() {
        if groups.createGroup(newGroup) { newGroup = ""; errorMessage = nil }
        else { errorMessage = "名称需为 1–60 个字符，且不能与已有分组重名" }
    }

    @ViewBuilder
    private func groupHeader(_ key: String, count: Int) -> some View {
        HStack(spacing: 8) {
            if renamingGroup == key {
                TextField("分组名称", text: $renameValue).onSubmit { renameGroup(key) }
                Button("保存") { renameGroup(key) }
                Button("取消") { renamingGroup = nil }
            } else {
                Text(key.isEmpty ? "默认分组" : key).font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(count)").font(.system(size: 10)).foregroundStyle(theme.token(.mutedForeground))
                Spacer()
                Toggle("显示分组", isOn: Binding(get: { groups.isGroupVisible(key) },
                                                set: { groups.setGroup(key, visible: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help("显示或隐藏这个分组")
                if !key.isEmpty {
                    Menu {
                        Button("重命名") { renamingGroup = key; renameValue = key }
                        Button("删除分组，贴图移回默认组") { groups.deleteGroup(key) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func renameGroup(_ key: String) {
        if groups.renameGroup(key, to: renameValue) { renamingGroup = nil; errorMessage = nil }
        else { errorMessage = "名称需为 1–60 个字符，且不能与已有分组重名" }
    }

    private func pinRow(_ item: PinItem) -> some View {
        HStack(spacing: 9) {
            Button { groups.reveal(item.id) } label: {
                Image(decorative: item.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 38)
            }.buttonStyle(.plain).help("显示这张贴图")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(item.image.width) × \(item.image.height)")
                    .font(.system(size: 11).monospacedDigit())
                if item.isClickThrough {
                    Button("恢复鼠标操作") { groups.setClickThrough(item.id, enabled: false) }
                        .font(.system(size: 10))
                }
            }
            Spacer()
            Menu {
                Menu("移到分组") {
                    Button("默认分组") { groups.move(item.id, toGroup: nil) }
                    ForEach(groups.groupNames, id: \.self) { name in
                        Button(name) { groups.move(item.id, toGroup: name) }
                    }
                }
                Button(item.isClickThrough ? "关闭鼠标穿透" : "开启鼠标穿透") {
                    groups.setClickThrough(item.id, enabled: !item.isClickThrough)
                }
                Button(item.isAlwaysOnTop ? "取消置顶" : "保持置顶") {
                    groups.setAlwaysOnTop(item.id, enabled: !item.isAlwaysOnTop)
                }
                Button("复制") { groups.copyToPasteboard(item.id) }
                Button("另存为…") { groups.save(item.id) }
                Button("关闭贴图") { groups.close(item.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }
}
