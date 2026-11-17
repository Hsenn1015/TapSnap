# TapSnap 架构说明

本文说明 TapSnap macOS 版的模块职责、依赖关系和图像处理流程。Windows 版工程见 [Windows 版说明](windows/README.md)。

## 一、总体设计

1. Swift Package Manager 按职责拆分模块，由主程序组合各模块。
2. 设置和工具栏使用 SwiftUI，截图覆盖层、标注画布和贴图窗口使用 AppKit。
3. ScreenCaptureKit 负责抓屏，AVFoundation 负责编码录屏，Vision 负责文字识别，ImageIO 处理系统支持的图片格式。

## 二、分层

依赖只允许向下，同级之间尽量不互相依赖（少数例外在 `Package.swift` 里能一眼看到）。

```
L4  TapSnapApp                 主程序（可执行）
L3  Config ImageIO Media OCR Stitching Privacy      服务
L2  ActionsBar Palette Toast Tutorial       功能界面
L1  UI Formula                              通用控件
L0  Core Theme Icons System Screen Vision   基础设施
```

| 层 | target | 职责 |
| --- | --- | --- |
| L0 | `TapSnapCore` | 路径、日志、几何换算、颜色、本地 JSON 存储、剪贴板元信息 |
| L0 | `TapSnapTheme` | 语义色与阴影 |
| L0 | `TapSnapIcons` | SF Symbols 到工具图标的映射 |
| L0 | `TapSnapSystem` | 权限检查、Carbon 全局热键、键鼠监听、单实例 |
| L0 | `TapSnapScreen` | 屏幕枚举、ScreenCaptureKit 抓屏与推流、光标快照 |
| L0 | `TapSnapVision` | 条码 / 二维码识别 |
| L1 | `TapSnapUI` | 浮动面板、气泡菜单、取色器、加载与组合控件 |
| L1 | `TapSnapFormula` | 公式（LaTeX）渲染接口 |
| L2 | `TapSnapActionsBar` | 截图工具栏：动作枚举、视图、布局模型 |
| L2 | `TapSnapPalette` | 调色板与最近使用色 |
| L2 | `TapSnapToast` | 轻提示 |
| L2 | `TapSnapTutorial` | 新手引导 |
| L3 | `TapSnapConfig` | 设置模型、快捷键绑定、持久化 |
| L3 | `TapSnapImageIO` | png/jpeg/heic/tiff/gif/webp 读写 |
| L3 | `TapSnapMedia` | 录制会话、视频编码、GIF 导出 |
| L3 | `TapSnapOCR` | Vision 文字识别 |
| L3 | `TapSnapPrivacy` | 本地 OCR 与码／人脸检测、可配置规则、实心遮盖；只向预览返回类别和像素框 |
| L3 | `TapSnapStitching` | 滚动截图的位移估计与拼帧 |
| L4 | `TapSnapApp` | 编排以上所有模块，实现具体流程 |

## 三、主程序的目录

`Sources/TapSnapApp/` 按功能分目录。

| 目录 | 内容 |
| --- | --- |
| `App/` | `TapSnapApp` 入口、`AppDelegate`、`AppEnvironment`（依赖容器）、菜单栏、快捷键中心 |
| `Capture/` | `CaptureCoordinator`（框选流程编排）、`ScreenshotSession`（会话状态）、`SelectionOverlayWindow`（覆盖层与交互） |
| `Edit/` | `EditController`（窗口+动作）、`EditCanvasView`（画布）、`Items/`（标注图元与工厂） |
| `Pin/` | `PinGroupManager`（窗口与分组管理）、`PinPanel`、`PinItem`、`PinTransfer`（剪贴板搬运） |
| `LongShot/` | `LongShotSession`（滚动截图流程） |
| `OCR/` | `OCRCoordinator`（文字识别）、`TableRecognizer`（表格识别） |
| `Record/` | `RecordController`（录屏）、`RecordControlBar`（录制控制条） |
| `Desktop/` | `ToolBallController`（悬浮球）、`DesktopBarController`（桌面工具条） |
| `Settings/` | `SettingsView`（用 SwiftUI 写的设置窗口） |

## 四、几个关键设计

### 依赖容器

`AppEnvironment` 持有配置、色板、提示、抓屏、识别、拼接和贴图管理等服务。控制器通过环境访问服务，测试可提供独立配置和替代依赖。

常驻控制器（截图、长截图、录制、识别、贴图搬运）也挂在环境上。它们在菜单点击后还要继续存活到流程结束，临时创建会被立刻释放。

### 坐标系

三个坐标系必须分清，这是截图类程序最容易出错的地方：

- **屏幕全局坐标**：`CGDisplayBounds` 的坐标系，原点在主屏左上，y 向下。跨屏选区、贴图位置用它。
- **视图坐标**：`NSView` 的坐标系，原点在左下，y 向上。覆盖层和画布内部的绘制用它。
- **像素坐标**：`CGImage` 的坐标系，原点左上，单位是像素。和屏幕坐标差一个 `scale`。

换算工具集中在 `TapSnapCore/Geometry.swift`（`flippedVertically(in:)`、`snapped(to:)`）和 `TapSnapScreen/ImageCrop.swift`（磅转像素裁剪）。

### 图像流水线

```
ScreenCaptureKit 整屏帧
  -> 覆盖层上框选（视图坐标）
  -> 翻转成屏幕全局坐标
  -> ImageCrop 按 scale 裁成像素图
  -> 编辑画布 / 直接贴图 / 送 OCR
```

编辑完成后由 `EditDocument.render()` 合成：建 `CGBitmapContext`，先画底图，再按顺序画每个图元，最后按 `cropRect` 裁切。

## 五、编译与验证

```bash
swift build            # 编译全部 target
swift test             # 跑 TapSnapCoreTests
Scripts/build-app.sh   # 打包成 dist/TapSnap.app
```

`swift build` 不产出 `.app`，`Info.plist` 不会被读取——所以菜单栏图标、权限文案、URL scheme 这些只有在打包后的 `.app` 里才生效。
