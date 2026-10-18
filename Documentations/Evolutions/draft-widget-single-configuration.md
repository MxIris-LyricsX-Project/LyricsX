# Draft - 小组件统一成一种配置，显示翻译跟随「双语歌词」设置

- **状态**: In Progress
- **创建日期**: 2026-10-18
- **最后更新**: 2026-10-18
- **实现分支 / PR**: `feature/widget-single-configuration`

## 摘要

小组件现在有每个实例自己的设置：「显示翻译」和「翻译语言」。在编辑界面改过设置的小组件，系统当成另一套配置。app
请求一次刷新时，系统按配置拆成几个请求，每 5 秒只立即执行其中一个，于是总有一部分小组件每次更新都晚约 5 秒：
2026-10-18 实测晚 4.7～5.8 秒，删掉的小组件留下的配置还会继续占名额。详见
[`Internal/DesktopWidget.md`](../Internal/DesktopWidget.md)「节流按小组件种类算，请求按配置拆分」。

这份提案去掉小组件的每实例设置：

- 显示不显示翻译，改由 LyricsX 现有的「Prefer bilingual lyrics」决定，经 App Group 里的快照传给小组件；
- 翻译语言暂不提供选择，留给正在审的 AI 翻译 PR #204 接入。

所有小组件从此同属一套配置，app 请求一次刷新，全部立即生效。

## 方案

1. **小组件不再有设置项。** `AppIntentConfiguration` 加 `LyricsWidgetConfigurationIntent` 换成 `StaticConfiguration`，
   `LyricsTimelineProvider` 改为普通的 `TimelineProvider`；删掉 `LyricsWidgetConfigurationIntent` 和 `TranslationLanguage`
   实体，编辑小组件时不再有设置项。只给翻译语言选单用的快照字段 `availableTranslationLanguages` 一并删掉。播放按钮的
   `Button(intent:)` 不受影响。
2. **显示翻译跟随「Prefer bilingual lyrics」。** `LyricsWidgetData` 加 `showsTranslation`，`AppController` 写快照时填
   `defaults[.preferBilingualLyrics]`。小组件按快照决定是否显示：大号只在当前行显示译文，超大号每行显示，和现在一样。
   旧版本写的快照里没有这个键，解码时按「不显示」处理。
3. **改了设置就刷新。** 订阅 `.preferBilingualLyrics` 的变化，交给 `WidgetReloadCoordinator`。刷新规则新增一种变化
   「显示设置变了」，和歌词变化一样等 0.3 秒合并；`snapshotNeedsReload` 把 `showsTranslation` 也算作看得见的变化。
4. **翻译语言占位。** app 写快照时挑哪种译文，集中到一处（`AppController.widgetTranslation(of:in:)`），取法和桌面
   歌词一样：先取第一种带语言代码的译文，没有就取不带代码的那份。#204 新增的
   `preferredLyricsTranslationLanguage` 和 `Lyrics.displayTranslation(for:)` 落地后，把这一处换成它们，小组件就跟着 app
   的显示语言走。#204 也改了 `writeWidgetSnapshot` 附近的几行，和这次的改动会有小冲突，后合并的一方解决。
5. **已经放在桌面上、编辑过的小组件**：换成静态配置后，系统会不会把它们并回同一套配置，要在桌面上实测。如果不会，
   发布说明里提示用户把小组件删掉、重新添加一次。
6. **测试与文档。**
   - `WidgetReloadPolicyTests` 加两个用例：「显示设置变了会刷新」，「`showsTranslation` 不同算看得见的变化」。
   - `LyricsWidgetDataTests` 加一个用例：旧版本写的快照读成不显示译文。
   - `DesktopWidget.md` 改写「节流按小组件种类算」一节的结论，新增「小组件没有自己的设置项」一节，改写「已知降级」
     和「后续工作」。

没有问就采用的假设：

- 中文环境下「Prefer bilingual lyrics」默认是开的，所以这些用户升级后，小组件会开始显示译文。原来小组件的「显示翻译」
  默认是关的。这是有意的：小组件和桌面歌词、歌词面板保持一致。
- 不迁移旧设置。在小组件里单独开过翻译的用户，升级后以「Prefer bilingual lyrics」为准。
- 小组件仍不跟随 app 的简繁转换（`chineseConversionIndex`），和现在一样；要跟随的话另开一项。

## 落地步骤

每一步都能单独构建、测试通过。

- [x] **1. 快照带上「显示翻译」，改了设置就刷新**：方案第 2、3、4 条和对应的测试。这一步小组件仍按自己的设置项显示。
- [x] **2. 小组件换成静态配置**：方案第 1 条，小组件改从快照读「显示翻译」；`DesktopWidget.md` 同步。
- [ ] **3. 桌面实测**：方案第 5 条。要在 JH 的桌面上跑这个分支的构建，结论写进本提案和 `DesktopWidget.md`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-18 | Created as Draft：「把配置都挪到主 App，用 AppGroup 传给小组件，小组件全部统一到一种配置」 | JH 的原话。实测编辑过的小组件自成一套配置，每次更新晚约 5 秒 |
| 2026-10-18 | 显示翻译跟随现有的「Prefer bilingual lyrics」，不另加小组件开关 | JH 选定：和桌面歌词、歌词面板一致，不加新设置 |
| 2026-10-18 | 翻译语言先占位，不做选择界面 | JH：后面会接入翻译功能，已经有 PR（#204） |
| 2026-10-18 | 用户批准，开始实现 | `/accept-proposal` |
| 2026-10-18 | 补上三个落地步骤：先让快照带上显示设置，再换静态配置，最后桌面实测 | 草案只有方案，没有能逐步验证的步骤 |
| 2026-10-18 | 挑译文那一处（`AppController.widgetTranslation(of:in:)`）照桌面歌词的取法：先取第一种带语言代码的译文，歌词里没有带代码的就取不带代码的那份 | 原来的写法只取带语言代码的译文。网易云、QQ 音乐、酷狗的译文都不带代码，小组件从来显示不出它们，桌面歌词却能。#204 的 `displayTranslation(for:)` 也会取不带代码的那份 |
| 2026-10-18 | 快照字段 `availableTranslationLanguages` 随翻译语言实体一起删掉 | 它只给小组件的翻译语言选单用；旧快照里多出的这个键，解码时直接忽略 |
