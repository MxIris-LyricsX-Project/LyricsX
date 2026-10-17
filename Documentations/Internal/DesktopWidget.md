# 桌面小组件：实现说明

> 最初的设计稿是 [`docs/superpowers/specs/2026-03-28-desktop-widget-design.md`](../../docs/superpowers/specs/2026-03-28-desktop-widget-design.md)。
> 本文记录**实际落地的实现**、为什么这样做，以及已知降级。面向维护者。

## 背景与目标

小组件有小、中、大、超大四个尺寸，大号和超大号带播放控制按钮。数据单向流动：主 app 把当前歌曲、
当前行前后各 50 行歌词和播放进度写进 App Group 的 `UserDefaults`（`WidgetDataStore`），封面写成共享容器里的
`cover.jpg`；小组件的 `LyricsTimelineProvider` 按每行的开始时间生成 timeline entry，由 WidgetKit 在对应时刻换上。
小组件自己不跑任何代码去推进歌词。

## 关键设计决策

### 播放按钮走 `AudioPlaybackIntent`，不用 `openAppWhenRun`

小组件扩展是沙盒进程，发不了 Apple Event，也没有 MusicPlayer 的播放器后端，所以三个按钮的 intent
（`PlayPauseIntent`、`NextTrackIntent`、`PreviousTrackIntent`）必须在主 app 里执行。

设计稿用 `openAppWhenRun = true` 做到这一点，理由是 LyricsX 是 `LSUIElement` 应用，打开它用户看不见。
**这个前提不成立**：系统为执行 intent 去打开一个已经在运行的 app，对 app 来说就是一次 reopen，而
`AppDelegate.applicationShouldHandleReopen` 对 reopen 的回应是弹出设置窗口。于是每按一次按钮就弹一次设置窗口
（issue #142）。`applicationShouldHandleReopen` 本身没有错——用户在 Finder 里再次双击 LyricsX 时，就该看到设置——
所以不改它，改的是 intent。

遵循 `AudioPlaybackIntent`（macOS 14 起）后，系统把 intent 放进 app 进程执行，**不打开 app**
（Apple 文档 *Adding interactivity to widgets and Live Activities*：遵循 `AudioPlaybackIntent` 或
`LiveActivityIntent` 的 intent 在 app 进程里执行）。区别在构建产物里看得到，见「验证」一节：改之前三个 intent 是
`openAppWhenRun: true`、`systemProtocols` 为空；改之后是 `false`，并带
`com.apple.link.systemProtocol.AudioStarting`。

这个文件同时编进 app 和小组件两个 target：小组件要用这些类型构造 `Button(intent:)`。小组件里那一份的
`perform()` 被 `#if !WIDGET_EXTENSION` 掏空，系统不会调用它。

### 歌词区按剩下的高度挑行，不再固定行数

原来大号固定排 7 行、超大号固定排 9 行，每行要多高就多高。超大号开了翻译，每行下面再多一行译文，粗算约
500 pt 的内容要塞进约 350 pt 高的小组件。放不下时外层 `VStack` 向上下两头同时溢出，顶部的封面标题和底部的
播放按钮被挤出小组件（issue #142 第 2 条、#193；macOS 26 上被裁掉，macOS 27 上画到了小组件外面）。
大号在有折行的句子时也会超高，SwiftUI 就把当前行压成一行加省略号（#142 第 6 条）。

现在标题和按钮先按自己的高度排好，歌词区（`LyricsWindowView`）只占剩下的空间，并且裁剪。它用一个自定义
`Layout` 按整个宽度量出每一行的高度，交给 `WidgetLyricsLayoutPolicy` 决定显示哪些行、每行放在哪：

- 当前行居中，上下两侧各在自己那一半里放整行。
- 一侧遇到第一行放不下的，这一侧就到此为止，**不跳过它去放后面更短的行**，否则显示出来的歌词会断档。
- 靠近开头或结尾时，没有行可放的一侧把空间让给另一侧：开头时第一行贴顶、结尾时最后一行贴底，和原来的固定窗口
  滑到边上时一样，不会空出半个小组件。

**放不下的行也要摆位置，而且要摆在歌词区外面、按阅读顺序接着排**。WidgetKit 在两个 timeline entry 之间按视图
身份做动画；被隐藏的行要是统一堆在某一处，换行时会从歌词区中间横穿过去。按顺序排在区外，换行时就是旧行从上边
出去、新行从下边进来，像滚动一样。

候选行只取当前行前后各 16 行，哪个尺寸的小组件都放不下更多。行的身份用它在 `lyricsLines` 里的位置：同一个
timeline 里这个数组不会变；每 60 秒重新生成 timeline 时窗口起点会移动，位置对不上，那一次换行退化成淡入淡出，
和改之前一样。

## 模块结构

| 文件 | 内容 |
|---|---|
| `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetLyricsLayoutPolicy.swift` | 纯函数：给定每行高度，决定显示哪些行、每行的上边缘在哪 |
| `LyricsXWidget/Views/LyricsWindowView.swift` | 大号和超大号共用的歌词区，以及量高度、调用策略、摆放行的 `LyricsWindowLayout` |
| `LyricsX/Intents/WidgetPlaybackIntents.swift` | 三个播放按钮的 intent，同时编进 app 和小组件 |

## 验证

```bash
# 挑行策略，8 个用例（<1 秒）。第一个用例在原来的固定 9 行行为上是红的：
# 它显示第 6–14 行，360 pt 塞进 200 pt
cd LyricsXPackage && swift test --filter WidgetLyricsLayoutPolicyTests
```

```bash
# 三个按钮 intent 的元数据：应为 openAppWhenRun false，且 systemProtocols 含 AudioStarting
products=<DerivedData>/Build/Products/Debug
jq -c '.actions | to_entries[] | select(.key | test("PlayPause|NextTrack|PreviousTrack"))
       | {intent: .key, openAppWhenRun: .value.openAppWhenRun, systemProtocols: .value.systemProtocols}' \
   "$products/LyricsX-Debug.app/Contents/PlugIns/LyricsXWidget.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"
```

下面这些只能在桌面上人工确认：

- 按钮：在桌面放一个大号或超大号小组件，点播放、上一首、下一首，播放器应当响应，且不弹出设置窗口。
- 超大号：在小组件的编辑界面打开翻译，放一首带翻译的歌，封面、标题和播放按钮都应留在小组件里，歌词区里没有
  被切掉半截的行。
- 大号：放一首有长句的歌，折行的句子应当居中，当前行不再变成一行加省略号。

## 已知降级

- **SwiftUI 那一层没有自动化测试。** 小组件的视图在 widget target 里，不在可测试的 package 里，WidgetKit 的渲染
  也只能在桌面上看，所以自动化测试只覆盖挑行策略。自定义 `Layout` 在小组件里能工作，依据是推断：小组件的视图在
  扩展进程里排版，`GeometryReader` 在小组件里同样可用。这一点要在桌面上确认。
- 折行后整句偏左（#142 第 6 条里的第三种情况）的原因没有坐实。推测是溢出时的挤压造成的，现在歌词区不再溢出，
  预计随之消失，同样要在桌面上确认。
- 三个 intent 的最低系统从 macOS 13 提到 14，这是 `AudioPlaybackIntent` 的要求。它们在快捷指令（Shortcuts）里
  也显示为 LyricsX 的动作，macOS 13 上不再有这三个动作。小组件本身最低 macOS 15，不受影响。

## 后续工作

- 小组件设置里的「翻译语言」不起作用：app 写数据时只取歌词的第一种翻译（`AppController` 里的
  `availableTranslationLanguages.first`），小组件也没有用配置里的语言去挑。
- 播放器不给封面时，小组件只显示音符占位图（#147）。歌词面板已经会联网找封面（`HighResolutionArtworkService`），
  但它只在面板窗口开着时运行，结果也不写给小组件。
