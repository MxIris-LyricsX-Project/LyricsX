# 0016 - 重新评估 LSUIElement：这个应用还算不算纯菜单栏应用

- **状态**: Draft
- **创建日期**: 2026-09-12
- **最后更新**: 2026-09-12
- **所属愿景**: 无

## 摘要

`LSUIElement = true` 写在 `LyricsX/Supporting Files/Info.plist` 里，是从上游 `ddddxxx/LyricsX`
继承下来的设定 —— 那时它确实是纯菜单栏应用。现在这个 fork 有了 Apple Music 风格歌词面板这样一个
正经的大窗口，前提未必还成立。

后台应用这个身份不是免费的，账单已经出现了两次：

- 窗口拿不到隐式全屏。`-[NSWindow _implicitlyAllowsFullScreenPrimary]` 第一条就是
  `_NXIsBackgroundOnly()`，命中直接返回 NO，所以歌词面板必须手动
  `collectionBehavior.insert(.fullScreenPrimary)`，绿灯才是全屏而不是 zoom。
- 全屏标题栏的自动隐藏与唤出走的是「跟随自动隐藏的菜单栏」那套机制，而纯菜单栏应用没有菜单栏
  参与其中。踩坑经过见 [0014-panel-full-screen-titlebar](0014-panel-full-screen-titlebar.md)。
- 代码里有四五处 `NSApp.activate(ignoringOtherApps: true)`（打开面板、搜索歌词、关于面板等），
  本质都是在补偿「后台应用的窗口默认到不了前台」。

另外，storyboard 里的主菜单是**齐的**（35 项，含标准 Window 菜单），一直被 `LSUIElement` 压着
没显示过 —— 也就是说切换身份的成本比看上去低。

## 方案

三条路，尚未选定：

1. **维持现状**。代价是继续为每个原生窗口行为写补丁。
2. **关掉 `LSUIElement`，变成常规应用**。全屏、Cmd+Tab、窗口管理、菜单栏全部回归原生，那行手动
   `insert(.fullScreenPrimary)` 也能删掉。代价是 Dock 常驻一个图标 —— 对一个大部分时间没有窗口、
   只在菜单栏待着的歌词工具，这是产品定位的改变，开机自启时也会在 Dock 冒出来。
3. **运行时切换 activation policy**。平时 `.accessory`，打开歌词面板或设置窗口时切 `.regular`，
   最后一个窗口关闭再切回。**有一条前提没验证**：`_NXIsBackgroundOnly()` 读的是 LaunchServices
   报告的 application type，而不是 activation policy。按常理 `setActivationPolicy(.regular)` 会
   一并更新进程在 LaunchServices 里的类型（Dock 图标出现就是 LS 层的效果），但这一条当时想用 IDA
   坐实而 server 连不上，没做成。真要走这条，先补这个验证。

需要一并考虑的面：登录项与 `LyricsXHelper` 的行为、菜单栏图标是否与 Dock 图标重复、
`applicationShouldTerminateAfterLastWindowClosed` 的取舍、以及关掉之后 Widget 与快捷键的影响。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-12 | 开题记录，不与全屏黑条的修复混在一批 | 那是 bug 修复，这是应用性质的变更，两者的风险和回退成本不在一个量级 |
| 2026-09-12 | 方案 3 的可行性待验证 | `_NXIsBackgroundOnly()` 查的是 LaunchServices 类型，与 activation policy 是否同步尚未坐实 |
