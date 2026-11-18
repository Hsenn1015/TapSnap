# 本地处理依赖

所有识别输入、截图和录屏在本机处理。以下网络访问仅用于首次安装公共软件包、权重或系统语言包。

| 组件 | 用途与来源 | 发布方式 |
| --- | --- | --- |
| libwebp 1.6.0 | [Google WebP](https://developers.google.com/speed/webp)，BSD 授权 | C 源码静态链接，app 内含 WebP-LICENSE，不依赖 Homebrew |
| KaTeX 0.16.22 | [KaTeX](https://katex.org/docs/browser.html)，MIT | JS/CSS/字体本地捆绑，CSP 禁止网络连接，关闭可信 HTML 指令 |
| pix2tex 0.1.4 / LaTeX-OCR | [作者项目](https://github.com/lukas-blecher/LaTeX-OCR)，MIT | 独立 Python 3.12 环境按需启动，退出即释放模型；依赖版本在 Resources/formula-requirements.txt |
| Apple Translation | [TranslationSession](https://developer.apple.com/documentation/Translation/TranslationSession) | macOS 15+；系统按需下载语言包，正文不上传到自建服务 |

源归档 SHA-256：

- libwebp-1.6.0.tar.gz：`e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`
- katex-0.16.22.tgz：`e9e0d167db3175481cbadaff38e8d90b130f6a3ddb451a47e43c577fd511f365`

公式模型从作者 GitHub Release v0.0.1 下载，权重校验值见 `Resources/formula-models.json`。安装脚本核对文件 SHA-256；识别助手开启离线模式并阻断 socket 连接。公式模型不会在 TapSnap 启动时常驻。

公式识别运行环境约占 1.2 GiB。安装 Python 3.12 后，再运行发布目录的 `Install Formula.command`。安装失败不会修改截图、快捷键或历史设置。

## macOS 应用更新

TapSnap 使用 Sparkle 2.10.1 验证和安装更新。`Vendor/Sparkle/Downloader-2.10.1.tar.gz` 收录了上游 Downloader 目标的 7 个实现文件、所需头文件和许可证。打包时应用同目录的 `update-session.patch`，将 TapSnap 的网络策略接入 Downloader。源码子集的 SHA-256 为 `71a1fcaf1f0032c2cc1f38a7ea4a93a885a7880af6d6bd26e777de2c2f3959c3`。[上游源码](https://github.com/sparkle-project/Sparkle/tree/2.10.1)
