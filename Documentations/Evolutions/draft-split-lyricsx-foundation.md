# Draft - 拆分 LyricsXFoundation，包里的模块统一以 Lyrics 开头

- **状态**: Draft
- **创建日期**: 2026-11-15
- **最后更新**: 2026-11-15

## 摘要

`LyricsXFoundation` 现在有 29 个文件、约 3,700 行，里面混着五类东西：纯策略、两套歌词翻译、菜单栏和窗口用的 AppKit 视图、
MusicPlayer 类型的扩展，以及一层 `@_exported import LyricsKit` / `FoundationToolbox` 的转发。它的三个使用方各只用到其中一块：
歌词面板只用两个 MusicPlayer 扩展和转发过来的 `Lyrics` / `LyricsLine`，菜单栏探针宿主（`StatusItemProbeSupport`）只用
菜单栏歌词行、偏移行和 `KaraokeLineTiming`，但两者都要连带编译 AI 翻译和 Translation 框架的代码。
这次按内容拆成 `LyricsPolicies`、`LyricsTranslation`、`LyricsUI` 三个模块，总入口只负责转发；同时把 `LyricsXPackage` 里的模块
统一改成以 `Lyrics` 开头、不带 X。拆分让依赖关系更清楚：面板和探针不会因为翻译或菜单栏视图的改动而重编，策略层也引用不到界面层，
这一点由编译器检查。编译时间本身省不了多少，3,700 行本来就编得很快。

## 方案

### 拆分

| 模块 | 放什么 | 依赖 |
|------|--------|------|
| `LyricsPolicies`（新） | 19 个文件：`AutomaticLyricsReplacementWindow`、`HighResolutionArtworkPolicy`、`KaraokeLineTiming`、`LyricsDisplayEligibilityPolicy`、`LyricsEditingPolicy`、`LyricsOffsetStepPolicy`、`LyricsPlaybackPositionPolicy`、`LyricsSearchCompletion`、`LyricsSearchPanelResults`、`LyricsSelectionOverrideTable`、`LyricsSourceOrderingPolicy`、`LyricsStoragePolicy`、`LyricsUserPickMark`、`LyricsWindowPresentationDecision`、`MenuBarLyricsLinePolicy`、`MenuItemTitleAlignmentPolicy`、`PriorityOrderedCandidatePool`、`StringNormalization`、`MusicPlayerExtensions` | LyricsKit、MusicPlayer |
| `LyricsTranslation`（新） | `AILyricsTranslation`、`SystemLyricsTranslation`、`LyricsTranslationEngine`。前两个互相调用（共用语言标识归一化、输入行整理、「原样返回」判断），只能放在一起 | LyricsKit |
| `LyricsUI`（新） | `MenuBarMarqueeLabel` 与它的 cell、`TitleAlignedMenuItemView`、`LyricsInteractionViews`、`AppleMusicLyricsWindowConfiguration`、`LyricsHUDWindowConfiguration` | LyricsPolicies（用到 `KaraokeLineTiming`、`MenuItemTitleAlignmentPolicy`）、OSToolbox |
| `LyricsFoundation`（总入口） | 只剩一个 `LyricsFoundation.swift`：`@_exported import` 上面三个以及 LyricsKit、FoundationToolbox | 上面三个、LyricsKit、FoundationToolbox |

### 改名

| 现名 | 新名 |
|------|------|
| `LyricsXFoundation`（target 与 product） | `LyricsFoundation` |
| `AppleMusicLyricsPanel`（target 与 product） | `LyricsAppleMusicUI` |
| `LyricsXWidgetShared`（target 与 product） | `LyricsWidgetShared` |
| `LyricsXFoundationTests` | `LyricsFoundationTests` |
| `AppleMusicLyricsPanelTests` | `LyricsAppleMusicUITests` |
| `LyricsXWidgetSharedTests` | `LyricsWidgetSharedTests` |

源码与测试目录跟着 target 名一起改（`Sources/LyricsAppleMusicUI/` 等），用 `git mv`，文件内容除 import 外不改。

### 使用方怎么接

- **app**：26 处 `import LyricsXFoundation` 换成 `import LyricsFoundation`，2 处 `import AppleMusicLyricsPanel` 换成
  `import LyricsAppleMusicUI`，4 处 `import LyricsXWidgetShared` 换成 `import LyricsWidgetShared`。
- **小组件扩展**：10 处 `import LyricsXWidgetShared` 换成 `import LyricsWidgetShared`。
- **Xcode 工程**：`project.pbxproj` 里四个 package product 依赖改名（app 的三个，小组件扩展的一个）。改之前先确认 Xcode
  没开着这个工程，否则它会用内存里的旧版本覆盖掉改动。
- **面板**改为依赖 `LyricsPolicies` 和 `LyricsKit`，不再依赖总入口；6 个文件的 `import LyricsXFoundation` 换成这两个。
- **`StatusItemProbeSupport`** 改为依赖 `LyricsUI`。
- **测试**：`LyricsFoundationTests` 仍是一个 target，改为依赖三个新模块。21 处 `@testable import LyricsXFoundation` 改成
  `@testable import` 被测类型所在的模块，因为 `@testable` 不会穿过总入口的转发。面板测试的 27 处 import、三个背景渲染测试里写死的
  `Sources/AppleMusicLyricsPanel/ArtworkGradientShaders.metal` 路径，以及小组件测试的 5 处 import 和它的 suite 名一并改。
- **Metal 着色器**：`Bundle.module` 跟着模块名走，资源包会变成 `LyricsXPackage_LyricsAppleMusicUI.bundle`，代码不用改，
  但要实测 app 里着色器还能加载。
- **访问级别**：只有跨模块用到 internal 符号时才补 `package` 或 `public`；目前查到的两处跨组引用（`KaraokeLineTiming`、
  `MenuItemTitleAlignmentPolicy`）本来就是 `public`。

### 验证

- 经 workspace 做一次 Debug 构建，在 Xcode 外启动，确认面板的渐变背景正常显示（着色器从改名后的资源包里加载）。
- 跑完整的 `LyricsFoundationTests`、`LyricsWidgetSharedTests`，面板的 headless 测试（`SyllableSweepPlanTests` 等）和背景渲染测试
  （`NowPlayingBackdrop|ArtworkBackdrop|ArtworkGradient|ArtworkRendering`），以及 `StatusItemTextParityProbes`、
  `StatusItemKaraokeProbes`、`StatusMenuTitleAlignmentProbes`。
- 下次发版前跑一次 CI 试运行（`gh workflow run release.yml --ref develop`），确认改名后的 product 与资源包能签名、能过公证。

### 文档同批更新

`CLAUDE.md` 与 `AGENTS.md` 里的模块名、内容描述和测试命令（`AGENTS.md` 那段还写着 `LyricsXFoundation` 只是转发壳，早已过时）；
写了旧模块名、旧源码路径或旧测试名的实现说明：`AppleMusicLyricsAnimation`、`AppleMusicMetalGradient`、`DesktopWidget`、
`LyricsCandidatePool`、`HighResolutionPanelArtwork`、`MenuBarLyricsRendering`、`StatusMenuTitleAlignment`、`LyricsLibraryCacheBypass`；
`LyricsTranslation.md` 里的测试命令；`Glossary.md` 里的定义位置。已落地的提案是当时的快照，不改。

### 没有询问就采用的假设

- **命名规则只管 `LyricsXPackage` 里的产品模块和它们的测试 target。** 以下不改：包名 `LyricsXPackage`（它不是模块，改目录名
  要动 Xcode 工程的本地包引用和每条 `cd LyricsXPackage`）；测试专用的 `StatusItemProbeSupport`、`StatusItemProbeHost`、
  `MenuBarLyricsTests`；Xcode 里的 `LyricsX`、`LyricsXHelper`、`LyricsXWidget` 三个 target；app 侧的 `LyricsX/AppleMusicLyrics/` 目录。
- **类型名不跟着改**：`AppleMusicLyrics.HostEnvironment` 这类命名空间与类型照旧，这次只改模块名。
- **日志 subsystem 不改**：`com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics` / `.Backdrop` 写在实现说明的 `log show` 命令里，
  改了旧命令就查不到日志。
- **MusicPlayer 扩展和 `LyricsUserPickMark`**（给 LyricsKit 类型加的扩展）也归策略层，不再为它们单建模块。
- **策略层不保证不 import AppKit**：MusicPlayer 自己在 `MusicTrack.artwork` 上就暴露了 `NSImage`，`resolvedArtwork` 只能 import AppKit。
  编译器检查的只是「策略层引用不到界面层」。
- **只有总入口转发 LyricsKit**，新模块不加 `@_exported`；要用 LyricsKit 的地方自己声明依赖。
- **`LyricsFoundationTests` 不跟着拆**：拆成三个只多出三条 `--filter`，没有别的收益。
- **`AppleMusicLyricsWindowConfiguration` 留在 `LyricsUI`**，不挪进面板：它只有 app 在用，面板还是 Swift 5 语言模式，挪进去要另外讨论。

### 开工前提

这次要搬目录、改 import，和正在进行的改动同时做会处处冲突，所以先让下面这些落进 `develop`，再开工：

- **菜单栏卡拉OK进度**收尾：它改的正是要搬走的 `MenuBarMarqueeLabel`、`KaraokeLineTiming`。
- **往 `LyricsXFoundation` 里加文件的两个 PR**：合进来之后，再按本提案的分层把新文件归位，并把结果补进上面的拆分表。
  - #217（本地歌词子菜单）：`LocalLyricsSource` 及其测试。
  - #201（优先用网易云、QQ 音乐客户端的歌曲 ID）：`ClientPlaybackIdentity`、`NetEaseClientTrackResolver`、
    `NetEasePlaybackState`、`QQMusicClientTrackResolver` 及其测试。
- **只改 app 的 PR**（#220、#218、#199、#183）：不碰包里的文件，但 app 里的 import 要全部改写，先合进来能省得贡献者再 rebase 一次。
  打算不合的，不必等。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-15 | Created as Draft | 用户看过模块内容的分组后，选定按「纯策略 / 翻译 / AppKit 视图」拆成三个 target，原名保留为总入口 |
| 2026-11-15 | 三个新模块定名为 `LyricsPolicies`、`LyricsTranslation`、`LyricsUI` | 用户定下命名规则：模块一律以 `Lyrics` 开头、不带 X。这三个名字与 LyricsKit 的 `LyricsCore`、`LyricsService`、`LyricsServiceUI` 都不重名 |
| 2026-11-15 | 总入口改名为 `LyricsFoundation`，测试 target 改名为 `LyricsFoundationTests` | 按同一条命名规则。原先「app 与工程不改」的好处不再成立：app 的 import、工程里的 product 引用和文档里的测试命令都要跟着改 |
| 2026-11-15 | 面板模块改名为 `LyricsAppleMusicUI`，`LyricsXWidgetShared` 改名为 `LyricsWidgetShared` | 用户指定了面板的新名字，命名规则因此覆盖包里所有产品模块；小组件共享模块按同一规则改名 |
