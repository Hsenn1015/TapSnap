# 选区流光边框

2026-11-11

按用户参考图，将截图、录屏框选的区域提示改为淡彩细线、柔和光晕与小方形手柄，外框相对实际选区留 8 点间距。屏幕边缘自动收紧；间距只用于提示，实际截图/录制坐标不变。

根据用户对首版「不够炫酷」的反馈，颜色改为更鲜明的青蓝、紫、粉，约 4.8 秒完成一轮流动；两束带短尾迹的亮光沿边框循环，约 5.6 秒走完一圈，光晕轻微呼吸。由 Core Animation 合成，无逐帧重绘桌面的定时器。截图的手柄、尺寸、确认按钮与放大镜独立绘制在光晕上方，交互仍由原选区视图处理。拖动外框手柄时补偿装饰间距，防止成品多出边距。

录屏开始准备时显示透明、点击穿透、不抢焦点的区域窗口，暂停时静止变淡；完成、取消、失败时清理。系统开启减少动态效果时保留静态颜色。截图退出也明确停止动画。

截图输出来自覆盖层显示前缓存的屏幕帧，录屏的 ScreenCaptureKit 过滤器排除本应用；录屏期间再截图时，也显式排除录屏边框窗口，避免依赖新版 macOS 对窗口 sharingType 的处理。

## 验证

- 154 项自动测试通过，0 失败，2026-11-11 19:07。
- HUD 子树真实离屏绘制覆盖了 CoreText；网格命中检测确认子视图不截获鼠标。
- 外框右侧手柄拖 20 点，真实选区仅扩大 20 点；首次确认的 140×90 选区不受 8 点边距影响。
- 无选区隐藏；暂停/恢复、移除/重新挂载、结束后的动画清理均覆盖。
- 真实边框组件在浅底/深底离屏渲染可见、中心透明；动画配置循环闭合。离屏验证不等同于屏幕上流畅度或实际录屏排除验证。
- 发布版签名验证通过，沿用 SenSnap Local 身份，已安装到 `/Applications/SenSnap.app`，19:08 启动；旧版备份 `/tmp/SenSnap-before-aurora-border.app`。
- 首版用户反馈动态不够明显，增强版再次通过 12 项边框生命周期和截图交互测试（19:12）；尚未宣称增强版完成主观视觉验收。
- 增强版通过签名验证并于 19:14 重启，旧版备份 `/tmp/SenSnap-before-aurora-v2.app`。浅/深背景真实组件离屏渲染确认亮光与尾迹可见、内部透明；追光初始相位和完整周期末相位的渲染逐像素相同，闭合处无相位跳变。

参考：[Apple 渐变图层](https://developer.apple.com/documentation/quartzcore/cagradientlayer)、[关键帧值](https://developer.apple.com/documentation/quartzcore/cakeyframeanimation/values)、[减少动态效果](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)。
