# 首次点击框选

2026-11-12

用户反馈快捷键唤起后，第一下不能框选，需要第二次。选区视图此前只接受 first responder，未覆盖 `acceptsFirstMouse`；在命中真实视图后调用该 AppKit 回调，旧版本返回 false。按 Apple 的事件分发规则，非 key 窗口的第一次鼠标按下可能只用于激活，未传给视图。

最小修复是让 SelectionOverlayView 的 `acceptsFirstMouse(for:)` 返回 true。光晕与 HUD 保持鼠标穿透，不改选区坐标、裁剪边距、快捷键或系统权限。当前视图的 `needsPanelToBecomeKey` 已返回 true，因此未增加重复覆盖。

验证：

- 修复前真实 hit view 的首击接收断言失败，修复后通过。
- 15 项相关测试通过：首轮拖动与 Enter 确认、已识别区域的首次单击吸附、原选区绘制/手柄/边距与动画清理。
- 尝试对未显示的离屏 NSWindow 使用 sendEvent，修前修后均未创建选区；该路径无法替代系统窗口激活测试，已移除这条无区分能力的测试，改为真实 hit view 回调与鼠标/键盘方法流。未宣称离屏测试验证了实际全局快捷键或 OS 焦点切换。
- 自动吸附仍依赖异步区域识别；识别未完成时的早期单击，与首击被窗口激活消耗是不同情形，已向用户询问具体表现。
- 发布版构建及 SenSnap Local 签名验证通过，已安装到 `/Applications/SenSnap.app` 并重启；旧版备份 `/tmp/SenSnap-before-first-click-20261112.app`。
- 用户明确原问题为「第一次按住拖动没反应，要再拖一次」，并在 09:18 更新后实测确认「第一次就能框选了」。首击接收修复已通过真实应用切换与鼠标拖动验证。

依据：[Apple 首击接收说明](https://developer.apple.com/documentation/appkit/nsview/acceptsfirstmouse(for:)) 与 [鼠标事件分发](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingMouseEvents/HandlingMouseEvents.html)。
