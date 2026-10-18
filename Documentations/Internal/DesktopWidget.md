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

### 刷新要攒着发：WidgetKit 每 5 秒只执行一次 app 发起的刷新

app 调 `WidgetCenter.shared.reloadAllTimelines()` 之后，系统里负责小组件时间线的进程 `chronod` 并不保证立刻执行。
它的 `externalRequestTimelineReloadFilter` 只让 5 秒内的第一次请求立即生效，其余请求记一条
「Throttling additional refresh request while foreground」，再挂一个计时器，到 5 秒期满时执行一次。

原来 app 每有一处变化就请求一次刷新，而换歌恰好是一串变化，结果每首歌开头约 5 秒，小组件显示的都是错的。
2026-10-18 在 macOS 27.2 上录到的一次换歌（19:44:52）：

- 第一次刷新立即执行，读到的快照是「暂停、新歌的第 0.15 秒、上一首的 51 行歌词」：播放器先报了暂停，大约半秒后
  `currentTrackChanged()` 才清掉旧歌词。
- 接下来 2 秒里，又有 13 次请求被推迟。
- 正确的 timeline（播放中、新歌的 36 行）在 5.0 秒后才生成。

现在 app 不再直接请求刷新。变化先交给 `WidgetReloadCoordinator`，它在 `DispatchQueue.lyricsDisplay` 上按
`WidgetReloadPolicy.Schedule` 算出的时刻刷新一次：

- **播放状态变化后要稳定 1 秒。** 换歌开头那次暂停比换歌通知早约半秒到；经 MediaRemote 恢复播放时，播放器先报一个
  错的进度，0.16～0.9 秒后才报对的。原来恢复播放那条订阅的 1 秒防抖就是为了后者，现在并进了这条规则。
- **歌词变化后等 0.3 秒**，把一起发生的变化（例如换候选歌词时先清空、再设新的）并成一次。
- **换歌后等新歌的歌词，最多 2.5 秒。** 没等到，就先显示没有歌词的新歌。
- **不管变化多么接连不断，最长等 3 秒。**

刷新前，协调器把新快照和上次刷新用的快照比一比（`WidgetReloadPolicy.snapshotNeedsReload`）。歌名、歌词、配色、
是否播放都相同时，播放中只要两份快照推出的「歌曲从 0 秒开始的时刻」相差不到 0.25 秒，暂停中只要当前行相同，就不刷新，
把 5 秒一次的机会留给真正的变化。app 每换一行都会重写快照，这些快照之间只差在拍下的时刻。

不等更久，是因为网络搜歌词可能要好几秒，等太久小组件就一直停在上一首。

### 按钮的 intent 返回之前写好新状态

Apple 文档（*Adding interactivity to widgets and Live Activities*）写明：`perform()` 返回后，系统用 timeline provider
重新加载被按的那个小组件，「Interactions with a toggle or button always guarantee a timeline reload」；刷新要用的数据
必须在返回之前写好。原来三个 intent 发完命令就返回，这次一定会有的刷新读到的还是按下之前的状态。新状态要等 app
自己请求的刷新，而那一次可能被上一节说的节流推迟到 5 秒后。

现在三个 intent 调 `AppController` 里对应的方法，等快照写好才返回：

- **播放/暂停**直接写入切换之后的状态：暂停就停在当前进度，播放就从当前进度接着走，不等播放器回报。之后照常记一次
  播放状态变化，1 秒后拿播放器实际回报的状态和写进去的比一比，不一样才刷新。万一播放器没照做，小组件会改回来。
- **上一首/下一首**等协调器为这次换歌刷新的那一刻再返回，那时新歌和它的歌词已经写进快照。最多等 4 秒：在一首歌
  开头按「上一首」通常只是从头播放，不会换歌，这时等满 4 秒再返回。
- 两种情况都顺带调一次 `reloadAllTimelines()`。Apple 没说按钮之后那次刷新会不会顾及桌面上其他尺寸的小组件。

## 模块结构

| 文件 | 内容 |
|---|---|
| `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetLyricsLayoutPolicy.swift` | 纯函数：给定每行高度，决定显示哪些行、每行的上边缘在哪 |
| `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetReloadPolicy.swift` | 纯规则：一串变化之后什么时候刷新，新快照值不值得刷新 |
| `LyricsX/Component/WidgetReloadCoordinator.swift` | 在 `lyricsDisplay` 队列上执行上面的规则：记下变化、到点写快照、该刷新才刷新 |
| `LyricsXWidget/Views/LyricsWindowView.swift` | 大号和超大号共用的歌词区，以及量高度、调用策略、摆放行的 `LyricsWindowLayout` |
| `LyricsX/Intents/WidgetPlaybackIntents.swift` | 三个播放按钮的 intent，同时编进 app 和小组件；在 app 里调 `AppController` 的 `togglePlaybackFromWidget()` 等方法 |

## 验证

```bash
# 挑行策略，8 个用例（<1 秒）。第一个用例在原来的固定 9 行行为上是红的：
# 它显示第 6–14 行，360 pt 塞进 200 pt
cd LyricsXPackage && swift test --filter WidgetLyricsLayoutPolicyTests

# 刷新规则，7 个用例（其中一个按 5 种变化参数化，<1 秒）。换歌那个用例在原来「有变化就立即刷新」的行为上是红的：
# 刷新 4 次，第一次在 0 秒，那时还是上一首的歌词
cd LyricsXPackage && swift test --filter WidgetReloadPolicyTests
```

刷新实际怎么发生，要看系统日志。下面这条录下 app 的刷新决定（`[LXWG][Reload]`）、小组件每次生成 timeline
时读到的快照（`[LXWG][Provider]`），以及 `chronod` 对每次请求的处理：`record reload: … = externalRequest(`
是立即执行，`Throttling additional refresh request` 是被推迟。

```bash
/usr/bin/log stream --level info --style compact --predicate '(subsystem == "com.JH.LyricsX.diagnostics")
  OR (process == "chronod" AND (category == "externalRequestTimelineReloadFilter"
  OR (category == "timeline.store" AND eventMessage CONTAINS "record reload" AND eventMessage CONTAINS "dev.JH.LyricsX")))'
```

```bash
# 三个按钮 intent 的元数据：应为 openAppWhenRun false，且 systemProtocols 含 AudioStarting
products=<DerivedData>/Build/Products/Debug
jq -c '.actions | to_entries[] | select(.key | test("PlayPause|NextTrack|PreviousTrack"))
       | {intent: .key, openAppWhenRun: .value.openAppWhenRun, systemProtocols: .value.systemProtocols}' \
   "$products/LyricsX-Debug.app/Contents/PlugIns/LyricsXWidget.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"
```

下面这些只能在桌面上人工确认：

- 按钮：在桌面放一个大号或超大号小组件，点播放、上一首、下一首，播放器应当响应，且不弹出设置窗口。播放/暂停的
  图标约 1 秒内就变；下一首约 2～3 秒内连同歌词一起换好。日志里，按下之后第一条
  `[LXWG][Provider] timeline(for:) called` 读到的就应该是新状态。
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
- 刷新攒着发的代价：换歌后歌名也要等到那一次刷新才换（约 1.5～2.5 秒，原来立刻换，但配着错的状态）；在音乐 app
  里暂停，小组件约 1 秒后才停（原来立即请求刷新）。小组件上的播放按钮不受影响。
- 5 秒的节流是从 `chronod` 日志里量出来的，Apple 没有写进文档，系统版本变了可能跟着变。
- 按钮写好状态再返回这一段没有自动化测试：intent 由系统在 app 进程里调用，只能看日志、在桌面上点按钮来确认。

## 后续工作

- 小组件设置里的「翻译语言」不起作用：app 写数据时只取歌词的第一种翻译（`AppController` 里的
  `availableTranslationLanguages.first`），小组件也没有用配置里的语言去挑。
- 播放器不给封面时，小组件只显示音符占位图（#147）。歌词面板已经会联网找封面（`HighResolutionArtworkService`），
  但它只在面板窗口开着时运行，结果也不写给小组件。
