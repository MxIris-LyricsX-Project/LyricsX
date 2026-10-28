# Draft - 歌词面板进度条改用 UIFoundation 的 PlaybackSlider，移除 AppKitPlus

- **状态**: Accepted
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

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-28 | Created as Draft | 用户看过接入 AppKitPlus 的影响评估后，决定不再集成它，进度条搬到 UIFoundation 用 Swift 实现 |
| 2026-10-28 | RC2 之前一起升级 UIFoundation | 用户选定。代价是一并带进 0.34–0.41 的改动，逐条核对后再发 RC2 |
| 2026-10-28 | 打开 UIFoundation 的 `AppleInternal` trait | 用户选定。plus-lighter 混合是私有 API，UIFoundation 只在这个 trait 下使用；LyricsX 不上 App Store |
| 2026-10-29 | 用户批准，开始实现 | UIFoundation 的新版本要等用户批准才能发布，所以先依赖 UIFoundation 的 `feature/playback-slider` 分支实现；发版后在收尾时改成版本号要求 |
