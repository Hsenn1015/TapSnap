import AppKit
import QuartzCore
import TapSnapActionsBar
import TapSnapScreen
import XCTest
@testable import TapSnapApp

@MainActor
final class SelectionModeToolbarTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    private func drag(_ view: SelectionOverlayView, from: CGPoint, to: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: from))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: to))
        view.mouseUp(with: try mouse(.leftMouseUp, at: to))
    }

    private func makeView(size: CGSize = CGSize(width: 600, height: 400)) -> SelectionOverlayView {
        _ = NSApplication.shared
        return SelectionOverlayView(frame: CGRect(origin: .zero, size: size))
    }

    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func click(_ action: SelectionOverlayView.BarButton, in view: SelectionOverlayView) throws {
        let button = try XCTUnwrap(view.barLayout()?.buttons.first { $0.action == action })
        let point = CGPoint(x: button.rect.midX, y: button.rect.midY)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point))
    }

    func testModeChoicesAppearOnlyAfterValidDragIsReleased() throws {
        let view = makeView()
        view.onLongShot = { _ in XCTFail("拖动不能触发长截图") }
        view.onRecord = { _ in XCTFail("拖动不能触发录屏") }
        XCTAssertNil(view.barLayout())
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 350, y: 250)))
        XCTAssertNil(view.barLayout(), "选区仍在拖动时不能出现可操作工具栏")
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 350, y: 250)))
        XCTAssertEqual(view.barLayout()?.buttons.map(\.action), [.cancel, .longShot, .record, .confirm])
    }

    func testLongShotUsesAdjustedSelectionAndDoesNotConfirmScreenshot() throws {
        let view = makeView()
        var received: [CGRect] = []
        view.onLongShot = { received.append($0) }
        view.onFinish = { _ in XCTFail("切换长截图不能同时打开图片编辑器") }
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 350, y: 250))
        try drag(view, from: CGPoint(x: 200, y: 175), to: CGPoint(x: 220, y: 185))
        try click(.longShot, in: view)
        XCTAssertEqual(received, [CGRect(x: 120, y: 110, width: 250, height: 150)])
    }

    func testCopyButtonAndCommandCUseOnlyTheFinalSelection() throws {
        let view = makeView()
        var copied: [CGRect] = []
        view.confirmationTitle = "编辑 ⏎"
        view.onCopy = { copied.append($0) }
        view.onFinish = { _ in XCTFail("复制不能同时打开编辑器") }
        let copy = try key(8, .command, characters: "c")
        XCTAssertTrue(view.performKeyEquivalent(with: copy))
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 350, y: 250)))
        view.keyDown(with: copy)
        XCTAssertTrue(copied.isEmpty)
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 350, y: 250)))
        try drag(view, from: CGPoint(x: 200, y: 175), to: CGPoint(x: 220, y: 185))
        XCTAssertEqual(view.barLayout()?.primaryAction, .copy)
        XCTAssertEqual(view.barLayout()?.buttons.map(\.action), [.cancel, .confirm, .copy])
        let toolbar = try XCTUnwrap(view.subviews.first { $0 is SelectionActionBar })
        let layers = try XCTUnwrap(toolbar.layer?.sublayers)
        func backgroundOpacity(_ title: String) -> CGFloat? {
            layers.first {
                let label = $0.sublayers?.first as? CATextLayer
                return (label?.string as? NSAttributedString)?.string == title
            }?.backgroundColor?.alpha
        }
        XCTAssertEqual(backgroundOpacity("复制 ⌘C"), 1)
        XCTAssertEqual(backgroundOpacity("编辑 ⏎"), 0)
        XCTAssertFalse(view.performKeyEquivalent(with: try key(8, [.command, .shift], characters: "C")))
        XCTAssertTrue(view.performKeyEquivalent(with: copy))
        try click(.copy, in: view)
        XCTAssertEqual(copied, Array(repeating: CGRect(x: 120, y: 110, width: 250, height: 150), count: 2))
    }

    func testRecordUsesResizedSelectionWithoutDecorativeMargin() throws {
        let view = makeView()
        var received: [CGRect] = []
        view.onRecord = { received.append($0) }
        view.onFinish = { _ in XCTFail("切换录屏不能同时确认普通截图") }
        let selected = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        let outline = SelectionBorderView.outlineRect(for: selected, in: view.bounds)
        try drag(view, from: CGPoint(x: outline.maxX, y: outline.midY),
                 to: CGPoint(x: outline.maxX + 30, y: outline.midY))
        try click(.record, in: view)
        XCTAssertEqual(received, [CGRect(x: 100, y: 100, width: 280, height: 150)])
    }

    func testQuickToolbarStaysCenteredBelowSelectionAfterDraggingEitherWay() throws {
        let selected = CGRect(x: 200, y: 220, width: 350, height: 240)
        let opposite = CGPoint(x: selected.maxX, y: selected.maxY)
        var frames: [CGRect] = []
        for (start, end) in [(selected.origin, opposite), (opposite, selected.origin)] {
            let view = makeView(size: CGSize(width: 800, height: 720))
            view.onCopy = { _ in }
            view.onLongShot = { _ in }
            view.onRecord = { _ in }
            view.onQuickAction = { _, _ in XCTFail("悬停不能触发快捷操作") }
            view.mouseDown(with: try mouse(.leftMouseDown, at: start))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
            XCTAssertNil(view.quickToolbarLayout())
            view.mouseUp(with: try mouse(.leftMouseUp, at: end))

            let layout = try XCTUnwrap(view.quickToolbarLayout())
            let outline = SelectionBorderView.outlineRect(for: selected, in: view.bounds)
            XCTAssertNil(view.barLayout(), "共享工具栏出现时不应同时显示旧工具栏")
            XCTAssertTrue(view.bounds.contains(layout.background))
            XCTAssertLessThan(layout.background.maxY, outline.minY)
            XCTAssertEqual(layout.background.midX, selected.midX, accuracy: 0.5)
            XCTAssertTrue(Set(layout.actions.outputActions).isSuperset(of: [.longShot, .record, .pin, .edit, .save]))
            frames.append(layout.background)

            let hover = CGPoint(x: layout.background.midX, y: layout.background.midY)
            view.mouseMoved(with: try mouse(.mouseMoved, at: hover))
            XCTAssertEqual(view.quickToolbarLayout()?.background, layout.background)
        }
        XCTAssertEqual(frames.first, frames.last)
    }

    func testQuickToolbarMovesInsideBottomWhenSelectionTouchesScreenBottom() throws {
        let view = makeView(size: CGSize(width: 800, height: 720))
        view.onQuickAction = { _, _ in }
        let selected = CGRect(x: 160, y: 0, width: 480, height: 360)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))

        let layout = try XCTUnwrap(view.quickToolbarLayout())
        let outline = SelectionBorderView.outlineRect(for: selected, in: view.bounds)
        XCTAssertTrue(view.bounds.contains(layout.background))
        XCTAssertGreaterThan(layout.background.minY, outline.minY)
        XCTAssertLessThan(layout.background.maxY, outline.midY)
        XCTAssertEqual(layout.background.midX, selected.midX, accuracy: 0.5)
    }

    func testQuickToolbarDisplaysAVisibleHintWithShortcutAndHidesItOnExit() async throws {
        _ = NSApplication.shared
        guard let screen = ScreenLayout.current().first else { throw XCTSkip("工具栏提示需要 macOS WindowServer") }
        let window = SelectionOverlayWindow(screen: screen)
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        view.onQuickAction = { _, _ in XCTFail("悬停不能触发快捷操作") }
        view.quickToolbarToolTip = { $0 == .record ? "录制 ⇧⌘R" : $0.title }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try drag(view, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 460, y: 360))
        let layout = try XCTUnwrap(view.quickToolbarLayout())
        let recordIndex = try XCTUnwrap(layout.actions.outputActions.firstIndex(of: .record))
        let step = ActionsBarLayout.buttonSize + ActionsBarLayout.spacing
        let x = layout.background.minX + ActionsBarLayout.horizontalPadding
            + CGFloat(layout.actions.annotationTools.count + recordIndex) * step
            + ActionsBarLayout.dividerWidth + ActionsBarLayout.spacing + ActionsBarLayout.buttonSize / 2
        let point = CGPoint(x: x, y: layout.background.midY)

        view.mouseMoved(with: try mouse(.mouseMoved, at: point))
        try await Task.sleep(for: .milliseconds(400))
        let tip = try XCTUnwrap(view.subviews.filter { !$0.isHidden }
            .first { subview in subview.subviews.contains { ($0 as? NSTextField)?.stringValue == "录制 ⇧⌘R" } })
        let label = try XCTUnwrap(tip.subviews.compactMap { $0 as? NSTextField }.first)
        let cell = try XCTUnwrap(label.cell)
        XCTAssertGreaterThanOrEqual(label.bounds.width, ceil(cell.cellSize.width), "应为绘制内边距留出空间")
        let singleLineHeight = label.bounds.height
        XCTAssertTrue(view.bounds.contains(tip.frame))
        XCTAssertGreaterThan(tip.frame.minY, layout.background.maxY)
        XCTAssertNil(tip.hitTest(CGPoint(x: tip.frame.midX, y: tip.frame.midY)))

        view.mouseMoved(with: try mouse(.mouseMoved, at: CGPoint(x: 12, y: 100)))
        XCTAssertTrue(tip.isHidden)

        let longHint = String(repeating: "录制当前桌面并显示按键和麦克风状态",
                              count: max(2, Int(view.bounds.width) / 120)) + " ⇧⌃⌥⌘R"
        view.quickToolbarToolTip = { $0 == .record ? longHint : $0.title }
        view.mouseMoved(with: try mouse(.mouseMoved, at: point))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(tip.isHidden)
        XCTAssertEqual(label.stringValue, longHint)
        XCTAssertGreaterThan(cell.cellSize.width, label.bounds.width, "长提示应触发换行")
        XCTAssertGreaterThan(label.bounds.height, singleLineHeight)
        XCTAssertEqual(label.lineBreakMode, .byCharWrapping)
        XCTAssertEqual(label.maximumNumberOfLines, 0)
        XCTAssertGreaterThanOrEqual(label.bounds.height, ceil(cell.cellSize(forBounds: label.bounds).height))
        XCTAssertTrue(view.bounds.contains(tip.frame), "换行后提示语应留在屏幕内")
    }

    func testQuickToolbarKeepsCommonActionsVisibleInNarrowViewport() throws {
        let cases: [(CGFloat, [ActionKind])] = [(215, [.longShot, .record]), (224, [.longShot, .record, .edit])]
        for (width, actions) in cases {
            let view = makeView(size: CGSize(width: width, height: 400))
            view.onLongShot = { _ in }
            view.onRecord = { _ in }
            view.onQuickAction = { _, _ in }
            try drag(view, from: CGPoint(x: width - 30, y: 3), to: CGPoint(x: width - 4, y: 28))

            let layout = try XCTUnwrap(view.quickToolbarLayout())
            XCTAssertTrue(view.bounds.contains(layout.background))
            XCTAssertLessThan(layout.actions.outputActions.count, ActionsBarModel.defaultOutputActions.count + 2)
            for action in actions {
                XCTAssertTrue(layout.actions.outputActions.contains(action))
                XCTAssertFalse(layout.actions.overflow.contains(action))
            }
        }
    }

    func testQuickToolbarCheckmarkCopiesAndEditIsSeparate() throws {
        let view = makeView()
        var results: [(ActionKind, CGRect)] = []
        view.onQuickAction = { results.append(($0, $1)) }
        view.onFinish = { _ in XCTFail("点击工具栏按钮不应走默认的编辑入口") }
        view.performQuickAction(.confirm)
        XCTAssertTrue(results.isEmpty)
        let selected = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        let layout = try XCTUnwrap(view.quickToolbarLayout())
        XCTAssertTrue(layout.actions.outputActions.contains(.edit))
        XCTAssertFalse(layout.actions.outputActions.contains(.copy))

        view.performQuickAction(.confirm)
        XCTAssertEqual(results.map { $0.0 }, [.copy])
        XCTAssertEqual(results.first?.1, selected)

        view.performQuickAction(.edit)
        XCTAssertEqual(results.map { $0.0 }, [.copy, .edit])
        XCTAssertEqual(results.last?.1, selected)
    }

    func testQuickToolbarCanKeepCheckmarkForPresetOrPrivacyEditing() throws {
        let view = makeView()
        view.quickConfirmationCopies = false
        view.onQuickAction = { _, _ in XCTFail("这个入口的勾选应沿用确认流程") }
        var confirmed: [CGRect?] = []
        view.onFinish = { confirmed.append($0) }
        let selected = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        let layout = try XCTUnwrap(view.quickToolbarLayout())
        XCTAssertTrue(layout.actions.outputActions.contains(.copy))
        XCTAssertFalse(layout.actions.outputActions.contains(.edit))

        view.performQuickAction(.confirm)
        XCTAssertEqual(confirmed, [selected])
    }

    func testQuickActionsIgnoreDraggingAndUseSelectionAfterResize() throws {
        let view = makeView(size: CGSize(width: 800, height: 720))
        var results: [(ActionKind, CGRect)] = []
        view.onQuickAction = { results.append(($0, $1)) }
        view.onFinish = { _ in XCTFail("快捷操作不能同时触发普通确认") }
        view.performQuickAction(.pin)
        XCTAssertTrue(results.isEmpty)
        let selected = CGRect(x: 200, y: 200, width: 300, height: 200)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        let outline = SelectionBorderView.outlineRect(for: selected, in: view.bounds)
        let resizedEdge = CGPoint(x: outline.maxX + 30, y: outline.midY)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: outline.maxX, y: outline.midY)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: resizedEdge))
        XCTAssertNil(view.quickToolbarLayout())
        view.performQuickAction(.text)
        XCTAssertTrue(results.isEmpty)
        view.mouseUp(with: try mouse(.leftMouseUp, at: resizedEdge))

        view.performQuickAction(.pin)
        view.performQuickAction(.text)
        XCTAssertTrue(view.performKeyEquivalent(with: try key(8, .command, characters: "c")))
        XCTAssertEqual(results.map { $0.0 }, [.pin, .text, .copy])
        XCTAssertEqual(results.map { $0.1 }, Array(repeating: CGRect(x: 200, y: 200, width: 330, height: 200), count: 3))
    }

    func testOtherSelectionConsumersKeepConfirmAndCancelOnly() throws {
        let view = makeView()
        var received: [CGRect?] = []
        view.onFinish = { received.append($0) }
        let rect = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
        XCTAssertFalse(view.performKeyEquivalent(with: try key(8, .command, characters: "c")))
        XCTAssertEqual(view.confirmationTitle, "确认 ⏎")
        XCTAssertEqual(view.barLayout()?.primaryAction, .confirm)
        XCTAssertEqual(view.barLayout()?.buttons.map(\.action), [.cancel, .confirm])
        try click(.confirm, in: view)
        try click(.cancel, in: view)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], rect)
        XCTAssertNil(received[1])
    }

    func testEnterDoubleClickAndEscapeKeepTheirOriginalMeaning() throws {
        let view = makeView()
        var received: [CGRect?] = []
        view.onFinish = { received.append($0) }
        view.onCopy = { _ in XCTFail("高亮复制按钮不改变 Enter 或双击的编辑动作") }
        view.onLongShot = { _ in XCTFail("Enter 或双击不应改为长截图") }
        view.onRecord = { _ in XCTFail("Enter 或双击不应改为录屏") }
        view.onQuickAction = { _, _ in XCTFail("Enter 或双击不应触发快捷操作") }
        let rect = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
        view.keyDown(with: try key(36))
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: rect.midX, y: rect.midY), clicks: 2))
        view.keyDown(with: try key(53))
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0], rect)
        XCTAssertEqual(received[1], rect)
        XCTAssertNil(received[2])
    }

    func testToolbarStaysInsideScreenAndButtonsDoNotOverlap() throws {
        for size in [CGSize(width: 600, height: 400), CGSize(width: 160, height: 140)] {
            for rect in [CGRect(x: 0, y: 0, width: 40, height: 35),
                         CGRect(x: size.width - 40, y: size.height - 35, width: 40, height: 35),
                         CGRect(origin: .zero, size: size)] {
                let view = makeView(size: size)
                view.onCopy = { _ in }
                view.onLongShot = { _ in }
                view.onRecord = { _ in }
                try drag(view, from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
                let layout = try XCTUnwrap(view.barLayout())
                XCTAssertTrue(view.bounds.contains(layout.background))
                XCTAssertEqual(layout.buttons.count, 5)
                for (index, button) in layout.buttons.enumerated() {
                    XCTAssertTrue(layout.background.contains(button.rect))
                    XCTAssertGreaterThanOrEqual(button.rect.width, 58)
                    for other in layout.buttons.dropFirst(index + 1) {
                        XCTAssertFalse(button.rect.intersects(other.rect))
                    }
                }
            }
        }
    }

    func testToolbarGapDoesNotChangeSelection() throws {
        let view = makeView()
        var received: CGRect?
        view.onFinish = { received = $0 }
        view.onLongShot = { _ in XCTFail("间距内不能触发按钮") }
        view.onRecord = { _ in XCTFail("间距内不能触发按钮") }
        let rect = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
        let layout = try XCTUnwrap(view.barLayout())
        let point = CGPoint(x: layout.background.minX + 2, y: layout.background.midY)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point))
        view.keyDown(with: try key(36))
        XCTAssertEqual(received, rect)
    }

    func testConfirmHitTargetIncludesTheEdgeAndFiresOnlyOnReleaseInside() throws {
        let view = makeView()
        let selected = CGRect(x: 100, y: 100, width: 250, height: 150)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        let button = try XCTUnwrap(view.barLayout()?.buttons.first { $0.action == .confirm })
        XCTAssertGreaterThanOrEqual(button.rect.height, 32)
        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }
        let edge = CGPoint(x: button.rect.maxX - 1, y: button.rect.minY + 1)
        view.mouseDown(with: try mouse(.leftMouseDown, at: edge))
        XCTAssertTrue(results.isEmpty)
        let outside = CGPoint(x: button.rect.midX, y: button.rect.minY - 9)
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: outside))
        view.mouseUp(with: try mouse(.leftMouseUp, at: outside))
        XCTAssertTrue(results.isEmpty)
        view.mouseDown(with: try mouse(.leftMouseDown, at: edge))
        view.mouseUp(with: try mouse(.leftMouseUp, at: edge))
        XCTAssertEqual(results, [selected])
    }

    func testToolbarAboveBottomEdgeSelectionLeavesRoomForSizeLabel() throws {
        let view = makeView(size: CGSize(width: 360, height: 240))
        view.screenImage = CGContext(data: nil, width: 360, height: 240, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        view.onLongShot = { _ in }
        view.onRecord = { _ in }
        let selected = CGRect(x: 300, y: 10, width: 50, height: 50)
        try drag(view, from: selected.origin, to: CGPoint(x: selected.maxX, y: selected.maxY))
        let layout = try XCTUnwrap(view.barLayout())
        let outline = SelectionBorderView.outlineRect(for: selected, in: view.bounds)
        XCTAssertGreaterThanOrEqual(layout.background.minY, outline.maxY + 24,
                                   "翻到选区上方时必须给尺寸标签留出空间")
        try drag(view, from: CGPoint(x: 10, y: 230), to: CGPoint(x: 350, y: 10))
        let expanded = try XCTUnwrap(view.barLayout())
        XCTAssertLessThan(expanded.background.maxY, view.bounds.midY,
                          "选区几乎占满屏幕时，工具栏放内部下方，不能与顶部尺寸标签重叠")
    }
}
