# Draft - 歌词面板进度条换成 AppKitPlus 的 NSPlaybackSlider

- **状态**: In Progress
- **创建日期**: 2026-10-28
- **最后更新**: 2026-10-28
- **实现分支 / PR**: `feature/panel-playback-slider`

## 摘要

Apple Music 歌词面板左栏的进度条是手写的 `PlaybackProgressView`：一根 4 pt 细条加白色填充，按下和拖动时每个鼠标
事件都立即 seek。AppKitPlus 从 0.18.0 起提供 `NSPlaybackSlider`，移植的是 Music 全屏播放器那根时间条——没有滑块的
7 pt 胶囊，以 plus-lighter 叠在背景上，按下时用弹簧长到 16 pt。这次把进度条换成它，并为此给 `LyricsXPackage` 加上
AppKitPlus 依赖，版本要求 `from: "0.19.0"`。

## 方案

- **依赖**：`LyricsXPackage/Package.swift` 加 `AppKitSupportProgram/AppKitPlus-Release`（`from: "0.19.0"`），
  `AppleMusicLyricsPanel` 及其测试 target 依赖 `AppKitPlus` product；刷新 Xcode 工程的 `Package.resolved`（新增
  `appkitplus-release` 0.19.0），resolve 顺带推进的其他依赖一律还原。此前 AppKitPlus 不在依赖图里：UIFoundation 虽然
  声明了它（`from: "0.6.0"`），但只在 UIFoundation 的 `AppKitPlus` trait 打开时生效，LyricsX 没有打开。
- **控件**：`PlaybackProgressView` 的对外接口（`onSeek`、`update(currentTime:duration:)`）不变，内部的 track / fill
  两个 view 和 `mouseDown` / `mouseDragged` 换成一个 `NSPlaybackSlider`。时间标签照 Music 放在滑块下方 6 pt；面板给
  进度区定的 24 pt 高度去掉，改由内容决定（约 36 pt），左栏因此高出约 12 pt。
- **seek 时机**：按住拖动期间只让时间标签跟着指针走、不 seek，10 Hz 的 chrome 刷新也不再推动滑块；松手时 seek 一次。
  方向键和 VoiceOver 的调整不经过拖动，立即 seek。结果是拖动时歌词不再实时跟着跳，松手才跳到新位置。
- **点击**：`hitTest` 在滑块范围内返回滑块本身而不是外层容器——用 macOS 27 SDK 构建时，系统控件靠 gesture
  recognizer 跟踪鼠标，窗口的 hit-test 必须落在控件或其后代上它才收得到点击。时间标签仍不接点击，点它照旧是拖窗口。
- **测试**：改写 `PlaybackScrubberProbes`。在窗口的 hit-test 上断言条上每一点都到达滑块、时间标签到达不了；经滑块
  cell 的 tracking 方法驱动按下、拖动、松手，断言只在松手时 seek 一次且落在松手处，按住期间的播放刷新不移动滑块，
  不经拖动的调整立即 seek。
- **文档**：`CLAUDE.md` 的依赖清单与测试命令；`Internal/AppleMusicLyricsAnimation.md` 补一段进度条的实现说明。

**落地步骤**：

1. [x] 依赖：`Package.swift` 加 AppKitPlus-Release，刷新 Xcode 工程的 `Package.resolved`；app 构建通过，
   `AppKitPlus.framework` 嵌进 app 包（Debug 包里 13 MB，已签名，经 `@rpath` 链接）。
2. [x] 进度条：`PlaybackProgressView` 换成 `NSPlaybackSlider`，面板去掉固定高度，改写 `PlaybackScrubberProbes`，
   连同 `CLAUDE.md` 与实现说明一起提交。`PlaybackScrubberProbes` 的 10 个测试全过；逐一把实现改坏（hit-test 返回容器、
   标签可点、按住时跟随播放、无时长也 seek、拖动中逐事件 seek、松手补发的 action 重复 seek、松手本身不 seek），每一处
   都有对应的测试变红。面板探针整组 172 个全过，app 的 Debug 构建通过，app 与 AppKitPlus 之间没有重名的 Objective-C 类。

**未经询问采用的假设**：外观完全照 Music（已播放部分白 45%、其余白 18%，按下时变白长高；这个控件本身不支持改色）；
时长未知（0）时滑块照常显示、按下不 seek，不设为 disabled（disabled 会把整条画到 1/4 不透明度，几乎看不见）；时间
标签的字体和颜色不变；不打开 UIFoundation 的 `AppKitPlus` trait。

**影响**：app 包多出约 13 MB 的 `AppKitPlus.framework`（含 x86_64、arm64、arm64e 的动态框架，随 app 一起签名分发）。
它的进程级 method hook 都在对应功能第一次被用到时才安装，只用这个滑块不会改变 app 其他界面的 AppKit 行为。AppKitPlus
自述仍在测试、不承诺 API 稳定；`from:` 允许升到 1.0.0 以下的任何版本，但 `Package.resolved` 把它钉在 0.19.0，只有
主动 resolve 才会升级。CI 用 Xcode 26.4（macOS 26 SDK）走经典 tracking loop，本机 Xcode 27.2 走 gesture recognizer，
`NSPlaybackSlider` 两条路径都支持。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-28 | Created as Draft | 进度条改用 AppKitPlus 的 `NSPlaybackSlider`，外观与交互对齐 Music 的时间条，并去掉手写的绘制与事件处理 |
| 2026-10-28 | 松手时 seek 一次，不再逐事件 seek | `NSPlaybackSlider` 文档推荐的用法；逐事件 seek 会给播放器连发一串 seek 请求 |
| 2026-10-28 | 直接依赖 AppKitPlus，不打开 UIFoundation 的 `AppKitPlus` trait | 只需要这一个控件；打开 trait 会把面板里所有 `LayerBackedView` 的基类换成 `NSLayerBackedView`。代价：trait 关着时 UIFoundation 自带一份 `NSEdgeInsets` 的 `==`，与 AppKitPlus 的重名，同时看得见两者的文件里比较 `NSEdgeInsets` 会报歧义（目前没有这样的代码） |
| 2026-10-28 | 用户批准，开始实现 | — |
| 2026-10-28 | 拆出两个落地步骤：先只加依赖，再换控件 | 加依赖本身就要单独验证一次：resolve 没有推进别的依赖，框架确实嵌进了 app 包 |
| 2026-10-28 | 松手的 seek 放在 `playbackSliderDidEndScrubbing`；AppKit 随后补发的那次 action 值与刚 seek 的相同，按值跳过 | AppKitPlus 自带示例的同一做法；方向键与 VoiceOver 走同一个 action，值一变就 seek，不必分辨 action 从哪来 |
| 2026-10-28 | 测试按 AppKitPlus 自己的测试那样直接调滑块 cell 的 `startTracking` / `continueTracking` / `stopTracking`，不投递真实鼠标事件 | 投递的点击能否复现取决于测试宿主链接的 SDK 和窗口是否为 key，测试进程保证不了；点击落点另在窗口的 hit-test 上断言 |
| 2026-10-28 | 实现完成，待合并 | 验证见落地步骤 2。`LyricsXFoundationTests` 里 `SystemLyricsTranslatorProbes.anEnglishLineInAJapaneseSongIsTranslatedWithTheRest` 失败，但 develop 上同样失败——它取决于本机系统翻译的输出，与本改动无关。没有做界面上的交互验证（实际点按、拖动的手感要在 app 里看） |
