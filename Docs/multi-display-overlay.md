# 多屏截图蒙层偏移修复

2026-11-12

用户反馈：外接扩展屏时，笔记本内置屏在进入截图的瞬间整幅画面/蒙层错位。

## 复现

当前真实排列：外接 G25H1 是主显示屏（1920×1080，1×），内置屏位于左侧（1512×982，2×），两屏顶部对齐。

| 屏幕 | CGDisplayBounds（左上原点） | NSScreen.frame（左下原点） | 修复前蒙层 |
| --- | --- | --- | --- |
| 外接主屏 | `(0, 0, 1920, 1080)` | `(0, 0, 1920, 1080)` | 正确 |
| 内置屏 | `(-1512, 0, 1512, 982)` | `(-1512, 98, 1512, 982)` | y=0，向下偏98点 |

隐藏的真实 `SelectionOverlayWindow` 测试复现 2 项测试、3 处断言失败：窗口 frame、画布全局位置和非零局部选框均偏 98 点。画布尺寸正确，未发生 32 点刘海安全区扣除或 Retina 二次缩放。

红测试命令：

```sh
swift test --disable-sandbox --scratch-path /tmp/tapsnap-multidisplay-build --filter MultiDisplayOverlayTests
```

真实屏幕测试需能连接 WindowServer；受限环境无屏幕时会跳过，跳过不计作复现或验证。红日志为 `/tmp/tapsnap-multidisplay-red-live.log`，修复后相同两项测试的绿日志为 `/tmp/tapsnap-multidisplay-green-live.log`。

## 原因与修改

`ScreenDescriptor.frame` 有意使用 CG 全局坐标，但选择蒙层把它直接交给 AppKit 窗口。主屏两种 frame 通常相同，导致单屏检查没有发现问题；次屏高度或排列不同就会错位。

- 添加显式 `appKitFrame(primaryDisplayHeight:)` 转换，仅供窗口定位。
- 选择蒙层的初始化和最终 frame 均使用转换后的矩形；已有正确转换的录屏提示层共用同一方法。
- 转换基准取 `NSScreen.screens.first` 的主显示屏高度，不能使用随焦点变化的 `NSScreen.main`，也不额外乘 Retina 比例。
- 保留 `ScreenDescriptor.frame` 的 CG 语义、裁剪逻辑、长图/录屏局部坐标和已采用 AppKit 坐标的 `visibleFrame`。

坐标边界依据：[Apple CGDisplayBounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:))、[Apple NSScreen.screens 主显示屏定义](https://developer.apple.com/documentation/appkit/nsscreen/screens)。

## 验证与安装

- 新增5项回归：真实双屏窗口/内容坐标，上下左右及错位排列，1×/2×且焦点屏切换，主显示器改为内置屏的布局，以及负坐标屏幕的裁剪尺寸和首尾像素。
- 最终完整测试188项通过，0失败、0跳过（11:39）。测试不显示窗口，不发送系统输入，也不修改屏幕设置。
- release 构建及严格签名验证通过，与旧版签名要求一致。11:41 安装并启动 `/Applications/TapSnap.app`；启动日志确认Ctrl+1优先响应及其余快捷键注册成功。
- 旧版备份：`/private/tmp/TapSnap-before-multidisplay-20261112.app`。
- 用户已在笔记本内置屏按 Ctrl+1 实测，确认“已经对齐，没有偏移”。当前双屏布局下的安装版视觉效果验收通过；其他合成布局仍以自动测试结果为准。
