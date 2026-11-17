# 录屏与 GIF 复制

2026-11-11

## 问题与改动

原有录制底层存在，但停止后仅提示视频已缓存；GIF 只有菜单里的另存入口，没有播放预览和复制入口。录制快捷键也未实现第二次按下结束，取消控制条未调用会话取消。

现在流程为：框选确认 → 悬浮录制控制条 → 完成 → 循环播放预览 → 复制 GIF / 保存 GIF / 保存 MP4。预览操作固定在窗口底部，转换时显示进度并可取消；重复打开最近录制会前置已有预览，不中断当前转换。

会话等待首帧才进入录制，启动失败或超时会结束等待；取消时停止流和编码，迟到回调不能重新启动。暂停不计入时长，结束时排空待编码内容。静止屏幕可能只有一个完整帧，编码结束时间明确取会话时长，避免几秒的录制生成瞬间结束的视频。屏幕流排除本应用，光标按设置采集。

视频转 GIF 默认每秒 15 帧，长边不超过 1280 像素，循环播放。顺序抽帧并写入，不收集整段原始帧数组；按百分之一秒时间边界分配帧延迟，避免 15fps 每帧四舍五入后累积变慢。先写临时文件，完成后替换目标；取消或错误不会破坏已有文件。未测量 ImageIO 整体内存峰值。

复制前校验 GIF 完整性，在同一个剪贴板条目提供原始 `com.compuserve.gif` 数据和文件 URL。没有转成 PNG/TIFF；关闭窗口后保留缓存文件，让接收方仍能读取。目标应用是否播放动画取决于其 GIF 粘贴支持。

## 验证

- 完整自动测试：146 项通过，0 失败（2026-11-11 18:50，正常 macOS 服务环境）。
- 真实 H.264 视频转多帧 GIF：帧内容不同、默认帧率、尺寸、循环、进度、总时长、短视频、损坏数据和取消清理均覆盖。
- 静止录制：单帧编码为 3 秒视频，在 2.9 秒处仍能取到有效画面。
- 独立测试剪贴板：验证原始动画数据、帧数、延时、单条目与文件地址；测试未改用户通用剪贴板。
- 模拟采集与授权：覆盖启动失败、超时、取消、重复完成、暂停、释放清理，以及取消后麦克风授权迟到。没有实际申请麦克风权限或录音；本次未验证系统音频和麦克风同时混音。
- 发布版构建与签名验证通过，已替换 `/Applications/SenSnap.app` 并于 18:52:32 启动；保持原 `SenSnap Local` 签名身份，日志确认 Ctrl+1 优先响应和录屏快捷键注册成功。旧版本保留于 `/tmp/SenSnap-before-record-gif.app`。
- 用户实测确认 `⌘⇧R` 启动后可完成录制并看到预览和「复制 GIF」。UI 读取到「GIF 已复制，可粘贴到支持动图的应用」，播放时长显示约 7 秒，底部三个保存/复制按钮可用；实际生成文件包含 100 帧，GIF 总时长 6.62 秒，ImageIO 状态完整。
- 未在聊天应用发送或验证接收方粘贴播放。自动操作工具不能可靠触发系统全局热键，本次该入口由用户实体键盘验证。

## 技术依据

- [Apple：AVAssetImageGenerator 抽帧](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:)) 与 [输出尺寸限制](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/maximumsize)。
- [Apple：取消待处理抽帧](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/cancelallcgimagegeneration())。
- [Apple：GIF 帧延迟](https://developer.apple.com/documentation/imageio/kcgimagepropertygifunclampeddelaytime) 与 [完成图片写入](https://developer.apple.com/documentation/imageio/cgimagedestinationfinalize(_:))。
- [Apple：剪贴板条目与多种表示](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/PasteboardGuide106/Articles/pbConcepts.html)、[GIF 类型](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/gif) 与 [写入条目](https://developer.apple.com/documentation/appkit/nspasteboard/writeobjects(_:))。
