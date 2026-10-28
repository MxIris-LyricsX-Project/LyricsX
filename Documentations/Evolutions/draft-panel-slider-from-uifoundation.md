# Draft - 歌词面板进度条改用 UIFoundation 的 PlaybackSlider，移除 AppKitPlus

- **状态**: In Progress
- **创建日期**: 2026-10-28
- **最后更新**: 2026-10-29
- **关联提案**: [0022 歌词面板进度条换成 AppKitPlus 的 NSPlaybackSlider](0022-panel-playback-slider.md)（本提案撤回其中的依赖选择）
- **实现分支**: `feature/panel-slider-from-uifoundation`

## 摘要

0022 把歌词面板的进度条换成了 AppKitPlus 的 `NSPlaybackSlider`。评估接入影响之后，决定不再集成 AppKitPlus，原因是：

- 它是约 13 MB 的预编译二进制，app 一启动就加载，不开面板的用户也一样；
- 安装包因此大约多 4～5 MB；
- 二进制里静态编进了 LGPL-2.1 授权的 OpenSoftLinking；
- 发版 CI 用的 Xcode 26.4 能不能编过它，还没有验证。

同一个控件用 Swift 移植进 UIFoundation，即 UIFoundation 的提案《PlaybackSlider：Music 全屏播放器的时间进度条》。LyricsX
改用那个实现，并去掉 AppKitPlus 依赖。进度条的外观和交互都不变。

## 方案

1. **前提**：UIFoundation 发出带 `PlaybackSlider` 的版本，预计是 0.42.0。
2. **升级 UIFoundation**，从现在锁定的 0.33.0 升到新版本，Xcode 工程里的引用和 LyricsXPackage 两处都改。
   - 两处都打开 `AppleInternal` trait，然后在构建日志里确认 `-DAppleInternal` 真的生效了。原因是：Music 那种颜色靠
     plus-lighter 混合，而 UIFoundation 只在这个 trait 下使用私有 API；LyricsX 不上 App Store，可以打开。
   - 这次升级会一起带进 0.34 到 0.41 的 58 个提交。逐条核对它们对 LyricsX 的影响，已知要重点看的有三处：
     - `Label` 会把带属性的文字同步成鼠标悬停提示；
     - 锁换成了 FrameworkToolbox 的 `Mutex`，要看它对 FrameworkToolbox 版本的要求；
     - 删掉了 macOS 12 以前的兼容代码。

     看得见的变化列出来，请用户检查。
   - `Package.resolved` 里其他依赖如果跟着变动，按发版流程第 5 步逐项核对，不是有意要带的就撤回。
3. **改代码**：`LyricsPanelControls.swift` 里
   - `NSPlaybackSlider` 改成 `PlaybackSlider`，`NSPlaybackSliderDelegate` 改成 `PlaybackSliderDelegate`；
   - 去掉 `import AppKitPlus`；
   - 进度条原来用 AppKitPlus 的闭包动作 `primaryAction = NSAction { … }`，改用 UIFoundation 自带的 `.box.actionBlock`。

   命中测试只交给滑块、松手时才跳转播放位置、键盘立即跳转，这些行为都不变。
4. **删掉 AppKitPlus 依赖**：`LyricsXPackage/Package.swift` 里的包声明和两个 target 的依赖都删掉，`Package.resolved`
   里它的锁定条目也删掉。
5. **测试**：`PlaybackScrubberProbes` 只改类型名，10 个测试照旧全部通过；再跑一遍面板的整套测试。
6. **文档**：
   - CLAUDE.md 的依赖一节删掉 AppKitPlus，改写 UIFoundation 那一条（打开 `AppleInternal` 的原因），进度条测试的说明里
     换成新类型名；
   - `AppleMusicLyricsAnimation.md` 的「进度条」一节改写；
   - 0022 保持原样：它是已经落地的决策记录。
7. **清理构建目录**：改了 trait 之后，Xcode 的增量构建感知不到这个变化，agent 的和用户自己的 DerivedData 都要清一次。
   到时会提醒用户。

## 落地进度

- [ ] 第 1 步：UIFoundation 还没发版。Xcode 工程和 `Package.swift` 暂时都依赖它的 `feature/playback-slider` 分支，发版后改成
  版本号要求；改之前不能发 RC2。
- [x] 第 2–6 步：依赖、代码、测试、文档。核对结果见下。
- [ ] 第 7 步：清理构建目录，合进 develop 后做。

2026-10-29 的核对结果：

- **构建**：app 的 Debug 构建通过，构建日志里有 21 处 `-DAppleInternal`，`UIFoundationAppleInternal` 模块参与了编译。
  app 包里不再有 `AppKitPlus.framework`，新增了 FrameworkToolbox 的 `ObjCRuntimeToolbox.framework`（约 450 KB）。
- **`Package.resolved`** 只变了三处：去掉 `appkitplus-release`；FrameworkToolbox 从 0.14.0 升到 0.15.0；UIFoundation 从
  0.33.0 改为 `feature/playback-slider` 分支的 `6292d0b`。没有带进别的依赖变动。
- **测试**（`--no-parallel`）全部通过，退出码 0：`PlaybackScrubberProbes` 10 个、面板整套 172 个、
  `LyricsXFoundationTests` 161 个（其中一个是已登记的 macOS 27 系统翻译 known issue）、`LyricsXWidgetSharedTests` 36 个。
  `MenuBarLyricsTests` 没有跑，因为菜单栏歌词不依赖 UIFoundation。
- **UIFoundation 从 0.33.0 到功能分支的改动**：逐个核对了 LyricsX 用到的 API。除了进度条本身，没有看得见的变化，
  也没有破坏源码兼容的改动（决策日志里记的 `ScrollLyricsView` 撞名是打开 trait 引起的，不是这些提交）。方案里点名的三处都与 LyricsX
  无关：
  - `Label` 的悬停提示同步：LyricsX 不用 `Label`。
  - 换成 `Mutex` 的锁：只在 `AsyncDocument`、工具栏构建器和 `QuickActionBar` 里，LyricsX 都不用；`Mutex` 基于
    `os_unfair_lock`，macOS 12 上可用。
  - 删掉的旧兼容代码：只在过滤控件和 TabBar 里。

  `LayerBackgroundRenderer` 现在每次都会写 `cornerCurve`，但默认值与 Core Animation 的默认值相同，外观不变。
- **`AppleInternal` 额外带进来的代码**：`BackdropView`、玻璃效果的复刻视图、自定义 tooltip 管理器等用私有 API 的代码
  也会编进来，但 LyricsX 都不调用。它们没有 `+load`，启动时不会运行任何代码。链接到的私有符号在 macOS 12.0.1 的
  dyld shared cache 里都存在，所以不会重演 `Logger.disabled` 那样的启动崩溃。
- **FrameworkToolbox 0.15.0** 只新增了 `NotificationCenter.Backport`，宏的展开与 0.14.0 相同，不引用 `Logger.disabled`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-28 | Created as Draft | 用户看过接入 AppKitPlus 的影响评估后，决定不再集成它，进度条搬到 UIFoundation 用 Swift 实现 |
| 2026-10-28 | RC2 之前一起升级 UIFoundation | 用户选定。代价是一并带进 0.34–0.41 的改动，逐条核对后再发 RC2 |
| 2026-10-28 | 打开 UIFoundation 的 `AppleInternal` trait | 用户选定。plus-lighter 混合是私有 API，UIFoundation 只在这个 trait 下使用；LyricsX 不上 App Store |
| 2026-10-29 | 用户批准，开始实现 | UIFoundation 的新版本要等用户批准才能发布，所以先依赖 UIFoundation 的 `feature/playback-slider` 分支实现；发版后在收尾时改成版本号要求 |
| 2026-10-29 | `ScrollLyricsView` 的 `delegate` 属性改名为 `lyricsViewDelegate` | 方案没有预料到这一处。打开 `AppleInternal` 后，UIFoundation 重新导出的 AppKit 私有头文件给 `NSScrollView` 声明了 `delegate`，同名的 Swift 属性就编不过了；它是打开 trait 的必要改动 |
| 2026-10-29 | 接受 FrameworkToolbox 从 0.14.0 升到 0.15.0 | UIFoundation 现在要求 `from: "0.15.0"`；这一版只新增 API，宏的展开不变 |
| 2026-10-29 | 接受新嵌入的 `ObjCRuntimeToolbox.framework` | UIFoundation 的 `AppleInternal` target 依赖它，FrameworkToolbox 把它声明成动态库。约 450 KB，随 app 一起签名；能否通过公证要等 CI 试运行确认 |
