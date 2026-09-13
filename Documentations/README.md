# LyricsX 文档索引

**新增或重命名任何文档都必须同步更新这份索引。**

> **项目类型：App（macOS）**。提案的「影响」一节关注用户可见变化、可发现性、
> 数据与配置兼容、平台与最低版本、发布流程，不涉及 ABI。

## 提案

- [提案索引](Evolutions/README.md) —— 所有 evolution 提案及其状态。**新功能与架构级改动动手前必须
  先有一篇被批准的提案。**
  - [0001 切换到下一条歌词候选](Evolutions/0001-next-lyrics-candidate.md) —— 让自动搜索保留候选池，
    并用一个快捷键在候选之间循环切换。
  - [0002 总是忽略歌词库缓存](Evolutions/0002-always-ignore-cached-lyrics.md) —— 一个开关，
    让自动匹配不再读 LyricsX 自己存的歌词库，每次都联网搜。
  - [0003 歌词源排序模式](Evolutions/0003-source-ordering-modes.md) —— 跨来源先比匹配分数，
    分数接近时才由歌词源顺序裁决。
  - [0004 手动应用过的歌词豁免于「忽略已保存的歌词」](Evolutions/0004-user-picked-lyrics-exemption.md)
    —— 给手动挑选/导入/编辑过的歌词打一个文件内标记，0002 的开关不再跳过它们。
  - [0005 换快捷键库](Evolutions/0005-keyboard-shortcuts-library-swap.md) —— MASShortcut 已归档
    且录制控件自绘、不跟随系统外观，换成 KeyboardShortcuts。
  - [0006 设置界面迁移到 SwiftUI](Evolutions/0006-swiftui-settings.md) —— 参照 RuntimeViewer 的
    设置模块架构逐页迁移，最低系统提到 macOS 14。
  - [0007 对齐 Apple Music 26.6 歌词动画](Evolutions/0007-apple-music-lyrics-animation-parity.md)
    —— 保存 Apple Music TTML 的 word/syllable timing，并对齐主歌词的逐字、行间与 blur 动画。
  - [0008 自绘 Metal 歌词渐变背景](Evolutions/0008-apple-music-metal-gradient.md)
    —— 用异步封面取色、低分辨率 `MTKView` 和窗口生命周期暂停替换 full-window artwork backdrop。
  - [0009 行间 cascade 对齐 Apple Music 26.6 并修复全屏掉帧](Evolutions/0009-apple-music-line-cascade-parity.md)
    —— 行 layer 光栅化，行间 cascade 与结构化行内 emphasis 各做成两档可切换，默认 Apple Music 原值。
  - [0010 歌词面板背景改按 Music 26「正在播放」的 MediaCoreUI 管线重做](Evolutions/0010-apple-music-now-playing-backdrop.md)
    —— 逆向确认对照窗口的背景是 `MediaCoreUI.Backdrop.CompositeRenderer` 而非 `TSLBackdropMetalView`，按其管线重做背景，
    旧管线以 `legacyTSL` 变体保留供并排比较。
  - [0011 行内抬高改成 Music 26.6 的逐音节软弹簧](Evolutions/0011-apple-music-syllable-lift.md)
    —— 行内抬高从「整词一次抬起」改成按音节起始时间逐个抬起，只有 Music 会拖长的词才额外做 swell。
  - [0012 行内标签歌词也走 Music 26.6 的逐音节抬高](Evolutions/0012-inline-tag-syllable-lift.md)
    —— 酷狗 / QQ / 部分网易的 `[tt]` 行内标签歌词按分段逐个抬高，旧的整行 emphasis 保留为可切换策略。
  - [0013 歌词面板的字号、行距、锚点与边缘渐隐改按 Music 26.6「正在播放」模式](Evolutions/0013-now-playing-lyrics-sizing-parity.md)
    —— 之前抄的是 Music 侧栏参数；「正在播放」窗口按歌词列宽把字号分成 28 / 38 / 50 / 72 四档、
    当前行锚在封面中心、上下各 128 pt 渐隐（手动滚动时 30 pt）；分档的输入取「同宽窗口下 Music 会给歌词
    多少宽度」，行距则不照抄 Music 的常量 50，改成跟着字号缩放。
  - [0014 歌词面板全屏时收起标题栏，pin 按钮改挂标题栏视图](Evolutions/0014-panel-full-screen-titlebar.md)
    —— 空 toolbar 与 titlebar accessory 会让 AppKit 把全屏标题栏钉在顶部，露出一条黑底；两者只在
    全屏期间摘掉，pin 按钮改成标题栏视图的普通子视图（不计入 accessory 计数）。
  - [0015 歌词面板封面改用联网取到的高清图](Evolutions/0015-high-resolution-panel-artwork.md)
    —— 换歌时并行查 iTunes Search API 和歌词候选自带的封面 URL，用现有的 dHash 指纹确认是同一张封面后，
    把面板封面换成像素更大的那张。

## 实现说明

- [歌词候选池](Internal/LyricsCandidatePool.md) —— 自动搜索为什么改成「擂台赛 + 完整名单」，
  「钉住」为什么不能省，以及用户选定的歌词靠什么活过下一次播放。
- [绕过歌词库缓存](Internal/LyricsLibraryCacheBypass.md) —— 「缓存」到底指哪一层，手选标记的
  判断为什么必须发生在读文件之后，回退为什么也要写在 catch 分支里，以及读文件名为什么改成
  两种拼法都试。
- [歌词候选的排序](Internal/LyricsSourceOrdering.md) —— 为什么用分数分桶而不是比分差
  （传递性），偏好迁移为什么必须跑在 `register(defaults:)` 之前。
- [设置窗口的尺寸](Internal/PreferenceWindowSizing.md) —— 切 tab 时窗口为什么会沿用上一页的
  尺寸，补的约束优先级为什么必须卡在 500 和 750 之间，量的为什么是选中页而不是 controller
  自己的 view，以及切 tab 为什么没有动画（试过的三种写法各自怎么失败的）。
- [Apple Music 26.6 歌词动画](Internal/AppleMusicLyricsAnimation.md) —— TTML 的 word/syllable timing
  如何经过 LRCX 保存，行内 factor 与可切换的结构化 emphasis 策略、Apple Music 真实的逐行 cascade 与
  可切换的两档参数、行 layer 光栅化、`.topRelative(40)`、多行坐标、contextual blur 与 viewport edge fade
  如何落地，以及 AppKit view geometry 和 Core Animation presentation 各自拥有什么状态。
- [Apple Music 歌词面板 Metal 渐变背景](Internal/AppleMusicMetalGradient.md) —— 一个 `MTKView` 驱动器带两条管线：
  默认复刻 Music 26「正在播放」的 `MediaCoreUI` 背景（128 pixel gamma 空间封面、三实例旋转、四分之一画布 pt 级模糊、
  细分网格、白混与 LUT 近似），`legacyTSL` 保留 MiniPlayer 管线；以及生命周期暂停、失败降级与离屏验证边界。
- [面板高清封面](Internal/HighResolutionPanelArtwork.md) —— 一首歌为什么要看三次、下载过的候选为什么
  留在内存里、`.noReference` 为什么不能当成拒绝、ScriptingBridge 的 `NSNull` 封面怎么补，以及
  `NSImage.size` 是点不是像素这个坑。
- [歌词 HUD 窗口显示与关闭](Internal/LyricsHUDPresentation.md) —— 为什么菜单动作必须读取实际窗口可见性和
  应用前台状态，以及隐藏、后台和前台三种状态分别如何处理。

## 术语

- [项目术语表](Glossary.md) —— 候选池、钉住、补充搜索、覆盖表、优先级窗口、Route B、
  歌词库缓存、手选标记、分数桶、同分容差等本项目自造词。

## 工程实践

- [已裁决的 code review 发现](ReviewDecisions.md) —— 判定为误报或不值得修的发现及其理由。
  **每次 code review 先对照这份清单**，已裁决的不再重复走四问。

## 发布与版本

- [Beta 更新通道](BetaUpdateChannel.md) —— 此前只通过 Sparkle 推送正式版；这篇记录 beta 通道的引入。
- [Build 号方案](BuildNumberScheme.md) —— 从手工维护的单调递增整数改为编码方案。
  **改发版流程前必读**，build 号的编码规则影响 Sparkle 的版本比较。
