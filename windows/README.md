# TapSnap for Windows

Windows 版和 macOS 版同仓库维护。`TapSnap.Windows.slnx` 是独立的 C# / WPF 解决方案，构建不依赖 Swift 或 Xcode。它以现有 macOS 版的功能和交互为对照；此版本已交叉编译，Windows 桌面效果仍待实机验收。

设置、截图工具条、编辑器及浮动面板沿用 macOS 版的布局和配色。「设置 → 通用 → 深色界面」可以切换主题；新安装默认深色，已有设置会保留。

## 运行与构建

建议在 Windows 11 上使用。运行试用包需安装与系统架构一致的 [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)；解压整个 ZIP 后运行 `TapSnap.exe`。应用出现在系统托盘，双击图标进入框选，右键查看功能。源码构建需要 .NET 10 SDK，从仓库根目录运行：

```powershell
dotnet build windows/TapSnap.Windows.slnx -c Release
dotnet run --project windows/TapSnap.Windows -c Release

dotnet publish windows/TapSnap.Windows -c Release -r win-x64 --self-contained false -o windows/publish/win-x64
dotnet publish windows/TapSnap.Windows -c Release -r win-arm64 --self-contained false -o windows/publish/win-arm64
```

如需无需安装 .NET 的单文件 EXE：

```powershell
dotnet publish windows/TapSnap.Windows -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeAllContentForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -o windows/publish/single-win-x64
```

ARM64 版使用 `win-arm64`，并输出到单独目录。

## 功能对照和验收

| 功能 | Windows 上优先核对 |
| --- | --- |
| 截图和快捷键 | 在其他应用按 `Ctrl+1` 后，到任一显示器立即拖动。检查不同缩放、负坐标、首次按下、移动及八个缩放控制点、HEX 取色、双击和回车确认。录制同一快捷键、实测普通冲突提示及可选的优先响应。 |
| 选区和编辑 | 框选后直接点箭头、画笔或其他工具即可开始标注。勾选或按 `Ctrl+C` 复制，按回车进入编辑器。窄屏可在「更多」中找齐工具。单屏选区可直接转长截图或录屏。 |
| 长截图 | 分别试手动、自动滚动和暂停。无法自动识别时在原选区框出正文。检查固定区域只出现一次、其下留白、正文连续；完成后在独立预览中切换适合宽度与原始像素，再贴图、复制或保存 PNG。 |
| 录屏和 GIF | 预览中按 `Ctrl+C` 复制当前片段的 MP4，也可点「复制 GIF」或「保存 GIF」。GIF 支持 10/15/24/30 FPS 和最长边设置，只写入变化区域，并保留静止画面的停留时间。可检查暂停恢复、声音和区间裁剪。 |
| 贴图和历史 | 贴图拖动/缩放、分组、鼠标穿透恢复、全屏隐藏；重启后恢复会话。剪贴板历史可拖动面板，清空后检查持久化记录。 |
| OCR、隐私和识别 | 本地识别后可移动/缩放/删除打码，同一套打码样式可从马赛克入口使用。修改规则后重启检查保存。分别试中英文 OCR、条码、表格 CSV、翻译、公式，以及明确选择发送的文字和视觉 AI 补查。 |
| 桌面入口及导出 | 托盘、桌面工具栏、悬浮球、开机启动和使用指南；试 PNG、JPEG、WebP、AVIF 和系统支持时的 HEIC 导出。 |

区域截图默认 `Ctrl+1`，长截图和录屏分别是 `Ctrl+Shift+L`、`Ctrl+Shift+R`。如果遇到普通快捷键冲突，可在「设置 → 快捷键」启用优先响应，Windows 保留组合仍由系统处理。录屏首选 Windows Graphics Capture，不可用时使用桌面抓屏。录制过程使用本地临时文件，首次打开预览时会准备有声视频。

## 可选本机组件

- 试用包随附简体中文和英语 OCR 字库。x64 版提供本地 Tesseract 后备。ARM64 便携版如需 Tesseract，可把本机 `tesseract.exe` 加到 `PATH`，或用 `TAPSNAP_TESSERACT` 指定完整路径。字库来自 Tesseract tessdata_fast 4.1.0，并按安装脚本中的 SHA-256 核对。
- 在「本机翻译设置」可独立配置和试译本机 OpenAI 兼容模型。隐私补查支持本机或远程模型，远程模式先提示并过滤文字规则命中的内容。API Key 按服务地址通过 Windows DPAPI 保存在当前用户目录。
- 本地公式识别需 Python 3.12、WebView2 Runtime，并运行产物目录中的 `Recognition\Install-Formula.ps1` 安装和校验模型。模型安装后在本机识别。
- HEIC 导出需要 Windows HEIF 图像扩展和支持编码的 HEVC 编解码器。WebP、AVIF 随包提供编码支持。

## 自动回归

以下测试使用合成素材，可在 Windows 或装有 .NET 10 SDK 的 macOS 上执行。它们检查像素拼接、识别规则和图片编码，不启动 Windows 界面：

```powershell
dotnet run --project windows/Tests/SelectionTests -c Release
dotnet run --project windows/Tests/LongShotTests -c Release
dotnet run --project windows/Tests/PrivacyTests -c Release
dotnet run --project windows/Tests/ImageFormatTests -c Release
```
