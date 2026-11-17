<p align="center">
  <img src="assets/readme/tapsnap-icon.png" alt="TapSnap 应用图标" width="120">
</p>

<h2 align="center">TapSnap</h2>

<p align="center">
  <sub>macOS 与 Windows 的截图、贴图、标注和录屏工具。</sub>
</p>

<p align="center">
  <img src="assets/readme/badge-macos.png" alt="macOS 14+" width="98" height="24">
  <img src="assets/readme/badge-windows.png" alt="Windows x64 / ARM64" width="160" height="24">
  <img src="assets/readme/badge-swift.png" alt="Swift" width="71" height="24">
  <img src="assets/readme/badge-dotnet.png" alt=".NET 10" width="83" height="24">
</p>

<p align="center">
  <sub>
    <a href="#功能介绍">功能介绍</a> ·
    <a href="#开源工具对比">开源工具对比</a> ·
    <a href="#操作演示">操作演示</a> ·
    <a href="#安装与构建">安装与构建</a> ·
    <a href="#使用指南">使用指南</a>
  </sub>
</p>

![TapSnap 功能插画。日程窗口居中展示流光框选和手绘标注，左侧是贴图和滚动长截图，右侧是文字识别、Markdown 和打码，底部是录屏时间轴。](assets/readme/capture-overview.webp)

## 功能介绍

- **截图与框选** 支持区域、窗口、全屏和延时截图。macOS 版可吸附到窗口或控件，框选后可直接复制、贴图、标注，也可切换到长截图或录屏。
- **滚动长截图** 手动或自动滚动拼接正文，固定区域只保留一次。长图完成后可继续编辑、复制、保存或贴图。
- **标注与高亮** 可添加箭头、形状、文字、序号和马赛克。手绘样式支持调整线条起伏与填充纹理，高亮笔可沿任意路径涂画。
- **贴图与剪贴板历史** 把截图或剪贴板图片固定在桌面上，支持置顶、分组、调节透明度和鼠标穿透，也可从历史记录找回图片。
- **录屏与编辑** 支持录制选定区域，录完可以裁剪、逐帧预览，并在单帧或指定时段加上箭头、文字或打码。可直接复制视频或 GIF，也可保存为 MP4 或 GIF。
- **文字、表格与公式识别** 文字可按原始行、段落或 Markdown 查看，表格可复制为 CSV。安装公式识别组件后，可以预览、编辑和复制 LaTeX。
- **隐私检查** 截图时可在本机检查敏感文字、二维码和人脸。复制、保存或贴图前可以调整遮盖范围与样式，确认后随图片一起输出。

列表与演示以 macOS 版为例。Windows 的操作和支持范围见 [Windows 版说明](windows/README.md)。

## 开源工具对比

| 功能 | TapSnap | [Snow Shot](https://snowshot.top/guides/index.html) | [ShareX](https://getsharex.com/) | [Flameshot](https://flameshot.org/) |
| --- | --- | --- | --- | --- |
| 发布平台 | macOS、Windows | macOS、Windows | Windows 正式版，[macOS 和 Linux 预览版](https://getsharex.com/artifacts/) | Linux、macOS、Windows |
| 截图方式 | 区域、窗口、全屏、延时 | 区域、窗口、显示器、延时 | 区域、窗口、全屏、显示器 | 区域、全屏、延时 |
| 滚动长截图 | 手动或自动拼接 | 竖向或横向拼接 | 滚动拼接 | — |
| 标注与打码 | 手绘、自由高亮、隐私检查 | 画笔、高亮、马赛克 | 画笔、高亮、模糊和像素化 | 画笔、高亮、像素化 |
| 桌面贴图 | 置顶、分组、历史 | 置顶、分组、恢复 | 置顶 | 置顶 |
| 录屏及后处理 | MP4 / GIF、裁剪、单帧或时段标注 | MP4 / GIF、裁剪、变速 | 录屏、GIF、视频和 GIF 裁剪 | — |
| 内容识别 | 本机 OCR、表格 CSV、公式 LaTeX | 本机 OCR、表格与公式在线识别 | Windows OCR | — |

TapSnap 功能以 macOS 版为例。对比依据为各项目的公开文档，`—` 表示文档未列出对应功能。

## 操作演示

### 录屏时间轴标注

![TapSnap 浅色录屏预览。为示例发布看板添加箭头，拖动时间轴上的标注末端调整显示时段。](assets/readme/recording-annotations.gif)

录完可精确裁剪所选片段，也可以拖动时间轴上的标注，让它只在指定时段出现。预览底部可直接点「复制视频」或「复制 GIF」。

<details>
<summary><strong>展开观看框选与直接复制</strong></summary>

![在浅色发布看板上拖出流光选区，悬停在底部工具栏的勾选按钮上查看复制提示。](assets/readme/quick-capture.gif)

</details>

## 安装与构建

| 平台 | 源码构建 |
| --- | --- |
| **macOS 14+** | 需要 Xcode 的 Swift 工具链。执行下方命令，生成 `dist/TapSnap.app`。 |
| **Windows x64 / ARM64** | 推荐 Windows 11。构建需要 .NET 10 SDK。框架依赖的构建产物需要对应架构的 .NET 10 Desktop Runtime。详见 [Windows 构建与运行](windows/README.md#运行与构建)。 |

```bash
# macOS：构建并打开应用
Scripts/build-app.sh
open dist/TapSnap.app
```

```powershell
# Windows：构建并运行
dotnet build windows/TapSnap.Windows.slnx -c Release
dotnet run --project windows/TapSnap.Windows -c Release
```

macOS 首次截图需要授予屏幕录制权限。全局快捷键发生冲突时可以启用优先响应，这需要辅助功能权限。应用启动后可从 macOS 菜单栏或 Windows 系统托盘进入。

## 使用指南

| macOS 默认快捷键 | 操作 |
| --- | --- |
| `⌃1` | 区域截图 |
| `⌘⇧2` | 截图并贴图 |
| `⌘⇧V` | 将剪贴板里的图贴到屏幕 |
| `⌘⇧L` | 滚动长截图 |
| `⌘⇧R` | 开始或结束录屏 |
| `⌘⇧O` | 区域文字识别 |
| `⌘⇧H` | 剪贴板历史 |

在「设置 → 快捷键」可以录入自己的组合键。框选后，点勾复制，按回车打开编辑器。开启截图隐私检查时，复制前会先进入复查。Windows 默认区域截图为 `Ctrl+1`。

<details>
<summary><strong>隐私检查与远程 AI</strong></summary>

普通截图和长图可用本机规则扫描。每条规则可以设为自动遮盖、仅提示或关闭，也可以添加自己的正则。检查结果可以逐处确认，遮盖会随复制、保存或贴图压平到图片。

可选的 AI 补查支持文字或图片定位。选择远程服务时，应用会先显示目的地并请求确认。图片定位会先在本机遮住已知敏感区域。录屏帧不经过截图隐私规则。

</details>

<details>
<summary><strong>公式识别与翻译</strong></summary>

macOS 菜单栏点「公式识别」，按提示准备 Python 3.12，再在应用内安装依赖和模型。安装会校验模型文件。识别在本机进行，可编辑、预览和复制 LaTeX。

设备端翻译需要 macOS 15+，首次使用时由系统准备语言包。Windows 的组件准备见 [可选本机组件](windows/README.md#可选本机组件)。

</details>

<details>
<summary><strong>更新与开发</strong></summary>

推送 `main`、提交面向 `main` 的 PR，或在 [GitHub Actions](https://github.com/Hsenn1015/TapSnap/actions/workflows/build.yml) 手动运行时，会执行 macOS 托管环境回归测试与 Windows 四组回归，并在运行详情的 Artifacts 提供 Apple Silicon DMG 和两种架构的自包含 Windows ZIP。需要实际桌面、系统编码器和识别环境的 macOS 用例可在本机运行 `swift test`。

发布时在目标提交创建并推送版本标签，例如 `v0.2.0`。所有构建通过后，流程会把三个安装包和 `SHA256SUMS.txt` 上传到 [GitHub Releases](https://github.com/Hsenn1015/TapSnap/releases)。如用 `v0.2.0-rc.1`，会发布为预发行版。CI 生成的 macOS 包是 ad-hoc 签名且未公证，Sparkle 更新源需单独配置。

配置更新源的 macOS 构建可通过菜单栏「检查更新…」查看新版。自动提醒会等截图、录屏和编辑结束后出现，由用户确认安装。打包时用 `TAPSNAP_UPDATE_FEED_URL` 和 `TAPSNAP_UPDATE_PUBLIC_KEY` 配置 Sparkle，使用 `TAPSNAP_VERSION` 和递增的 `TAPSNAP_BUILD_NUMBER` 标记版本。发布包需要 Sparkle 签名，更新源使用 HTTPS。本机调试支持回环 HTTP。

运行 `swift build` 编译 macOS 源码，`swift test` 跑回归测试。已有 macOS 构建沿用应用标识和配置路径，旧的 `sensnap://` 链接仍可用。

</details>

[架构说明](ARCHITECTURE.md) · [第三方组件](THIRD_PARTY.md)
