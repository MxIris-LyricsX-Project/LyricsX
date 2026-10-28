# 桌面小组件：实现说明

> 最初的设计稿是 [`docs/superpowers/specs/2026-03-28-desktop-widget-design.md`](../../docs/superpowers/specs/2026-03-28-desktop-widget-design.md)。
> 本文记录**实际落地的实现**、为什么这样做，以及已知降级。面向维护者。

## 背景与目标

小组件有小、中、大、超大四个尺寸，大号和超大号带播放控制按钮。数据单向流动：主 app 把当前歌曲、
当前行前后各 50 行歌词、播放进度和显示设置写进 App Group 的 `UserDefaults`（`WidgetDataStore`），封面写成共享容器里的
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

候选行只取当前行前后各 8 行：按最小的行高，大号每侧大约露出 4 行、超大号大约 3 行，再各多一行藏在区外等着滚进来。
最初取的是前后各 16 行，结果每次刷新都慢，原因见下文「刷新的渲染开销」。行的身份用它在 `lyricsLines` 里的位置：同一个
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

- **单纯的暂停、从暂停处恢复播放，只等 0.15 秒**，用来把播放器对同一次变化的重复回报并进来。判断在
  `WidgetReloadPolicy.playbackChangeNeedsSettling`，下面这些回报之后还可能被更正，**要等播放状态稳定 1 秒**：
  - 离歌曲开头或结尾不到 1.5 秒的回报。换歌开头那次暂停报的就是新歌的第 0.15 秒，而且比换歌通知早约半秒到。
  - 和上一次回报接不上的回报，比如跳转进度；又如经 MediaRemote 恢复播放时，播放器先报一个差了好几秒的进度，
    0.16～0.9 秒后才报对的。原来恢复播放那条订阅的 1 秒防抖就是为了后者，现在并进了这条规则。
  - 第一次回报，没有可以对照的上一次。
- **歌词变化后等 0.3 秒**，把一起发生的变化（例如换候选歌词时先清空、再设新的）并成一次。
- **显示设置（「Prefer bilingual lyrics」、显示语言）改了之后也等 0.3 秒**，把来回切换并成一次。
- **换歌后等新歌的歌词，最多 2.5 秒。** 没等到，就先显示没有歌词的新歌。
- **不管变化多么接连不断，最长等 3 秒。**

刷新前，协调器把新快照和上次刷新用的快照比一比（`WidgetReloadPolicy.snapshotNeedsReload`）。歌名、歌词、配色、
是否显示翻译、是否播放都相同时，播放中只要两份快照推出的「歌曲从 0 秒开始的时刻」相差不到 0.25 秒，暂停中只要当前行相同，就不刷新，
把 5 秒一次的机会留给真正的变化。app 每换一行都会重写快照，这些快照之间只差在拍下的时刻。

不等更久，是因为网络搜歌词可能要好几秒，等太久小组件就一直停在上一首。

### 节流按小组件种类算，请求按配置拆分

上面说的 5 秒节流，对象是「扩展 + 小组件 kind」（日志里写作 `dev.JH.LyricsX.LyricsWidget-com.JH.LyricsX.LyricsWidget`），
而 app 调一次 `reloadAllTimelines()`，`chronod` 会**按小组件的配置拆成几个请求**，挨个过这同一道节流：第一套配置立即
刷新，其余配置每次都排到 5 秒窗口结束。配置按 `record reload: [...:<配置编号>]` 末尾的数字区分。

**配置不看设置的值，而看这个小组件有没有在编辑界面改过。**从没编辑过的小组件共用默认配置；改过一次的自成一套，
改回原值也一样。2026-10-18 的实测：

- 超大号开过翻译，自成一套，每次都是它立即刷新；小、中、大号共用默认配置，20:39 到 20:57 之间每次都排在后面，
  比超大号晚 4.7～5.8 秒。
- 把超大号关掉翻译，配置编号换了一个，仍然自成一套。删掉重新添加之后，新加的这个进了默认配置，但删掉的那个留下的
  配置还在 `NotificationCenter` 里继续刷新、继续抢立即刷新的名额，直到重启 `chronod` 和 `NotificationCenter` 才消失。
- 只剩一套配置之后，同样的操作：暂停从播放器回报到上屏 0.39～0.40 秒，切歌 2.07～2.45 秒。

所以只要还有每个小组件自己的设置项，用户编辑过任意一个，就会让一部分小组件的每次更新都晚 5 秒。现在小组件没有
自己的设置项了，见下一节。

### 小组件没有自己的设置项

原来每个小组件有两个设置项：「显示翻译」和「翻译语言」（`AppIntentConfiguration` 加一个配置 intent）。上一节说了，
编辑过的小组件自成一套配置，会让其余小组件每次更新都晚 5 秒。所以现在小组件是 `StaticConfiguration`，编辑小组件时
没有设置项，桌面上所有小组件同属一套配置。提案见
[0019 小组件统一成一种配置](../Evolutions/0019-widget-single-configuration.md)。

**以后要让小组件能用不同方式显示，也加在 app 里，经快照传过去**，不要再给小组件加配置 intent。

- **显示不显示译文，跟随 app 的「Prefer bilingual lyrics」**（`PreferBilingualLyrics`），和桌面歌词、歌词面板一致。
  app 写快照时把它写进 `LyricsWidgetData.showsTranslation`。改这个设置算一次「显示设置变了」，0.3 秒后刷新。中文
  环境下这个设置默认开着（`AppDelegate` 注册默认值时按系统语言定），原来小组件默认不显示译文，所以这些用户升级后，
  小组件会开始显示译文。
- **显示哪一种译文，跟随 app 的「显示语言」**（实验室页，`PreferredLyricsTranslationLanguage`）：app 写快照时调
  `Lyrics.displayTranslation(for:)`，和桌面歌词、歌词面板用的是同一处。填了显示语言，就只取这种语言的译文，不带语言
  代码的译文不显示；没填，就取覆盖行数最多的那种语言，一样多时取语言代码排在前面的，某一行没有这种译文时再退到不带
  代码的那份。网易云、QQ 音乐、酷狗的译文常常不带代码，这一步退路不能省：原来只取带代码的，小组件从来显示不出它们。
  改显示语言和改「Prefer bilingual lyrics」一样，算一次「显示设置变了」。原来小组件的「翻译语言」设置项其实不起作用：
  小组件没有拿它去挑译文。
- 旧版本写的快照里没有 `showsTranslation`，解码时按「不显示」处理（`LyricsWidgetData.init(from:)`），所以升级后、app
  写出新快照之前，小组件照样能读出旧快照。
- 原来写给翻译语言选单的 `availableTranslationLanguages` 也删了。

**升级时，桌面上已有的小组件不会自己并成一套。** 2026-10-18 实测：新描述 23:32 生效后，原来的小、中、大号仍在旧的
默认配置里（`-367998910074015721`），编辑过的超大号仍自成一套（`7312778174216299536`）。app 每请求一次刷新，照样拆成
两个请求，后一个晚 5 秒。之后新加的小组件进新的静态配置，日志里配置编号是空的，例如 `systemMedium::`。所以只有把
旧的小组件删掉、重新添加，才会同在一套配置里。**发布说明要提示用户：更新后把桌面上的小组件全部删掉，再重新添加一次。**

删掉的小组件留下的配置可能还挂在 `NotificationCenter` 里，见上一节。这次又遇到一次：删掉的是编辑过的超大号，它的
live view 一直在刷新，占着立即刷新的名额，重新添加的四个小组件全被排到 5 秒后。重启 `chronod` 和 `NotificationCenter`
之后才消失。两次残留的都是打开过编辑界面的小组件；现在小组件没有编辑界面了，以后应该不会再产生新的残留。用户那边，
注销或重启一次也能清掉。

### 刷新的渲染开销

一次刷新，WidgetKit 要先把新 timeline 的每一条 entry、按桌面上的每个尺寸都渲染存档，**全部做完才一起换上**。
2026-10-18 测的一次切歌：每个尺寸 34～35 条，共约 140 份视图，从 WidgetKit 第一次向小组件要 timeline 到换上用了 2.0 秒；
暂停只有 1 条，0.2 秒。所以播放、切歌之后的延迟，大头在渲染。

当时每份视图有两处多余的开销：

- 小号、中号、超大号在视图里用 `NSImage(contentsOf:)` 读封面，每条 entry 都重新读一遍文件、解一遍码。现在
  `LyricsTimelineProvider` 每生成一次 timeline 只用 ImageIO 解码一次，把 `CGImage` 放进 entry，各条共用。封面文件由
  `WidgetDataStore.writeCover` 原子写入，读的一方不会读到写了一半的文件。
- 大号、超大号的歌词区每条排 33 行，现在是 17 行，见上一节。

改完后同一种操作：切歌后 15～23 条的 timeline，从 WidgetKit 第一次要 timeline 到换上用 0.7～1.1 秒。

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

### 每行提前 0.8 秒排进 timeline

小组件不跑代码推进歌词，每一行是一条 timeline entry，`entry.date` 一到，桌面上的宿主进程 `NotificationCenter`
换上这一条。实际换上的时刻比 `entry.date` 晚，而且每次晚得不一样，所以 `LyricsTimelineProvider` 把每一行的
`entry.date` 提前一段（`WidgetSchedulingCompensationMs`）。

2026-10-18 在 macOS 27.2 上量了一次：

- 宿主换上每一条的时刻，比 `entry.date` 晚的中位数是 0.78 秒；大号、超大号各 36 次换行，九成落在 0.22～1.24 秒之间。
- 原来提前 0.6 秒，相对歌词平均晚约 0.18 秒。改成 0.8 秒，中位数正好对上歌词。
- 抖动消除不了：212 次换上的时刻里有 69 次落在整秒之后 0.1 秒以内（均匀分布应约 21 次）。宿主的计时器允许较大误差，
  系统把它和别的计时器合并，常常凑到整秒才触发。

量法：录下面这条日志，几分钟就够。小组件每次生成 timeline 都记一条 `preview=`，列出前 8 条 entry 相对这条日志的时刻
（`@+秒数#行号`）；`NotificationCenter` 每换上一条，就给对应尺寸记一条 `Evaluated inner view`。把每条 entry 的时刻
和它之后的第一次换上配对，相减就是延迟。刷新后 0.5 秒内的那次换上是新 timeline 本身，不算。

```bash
/usr/bin/log stream --level info --style compact --predicate '(subsystem == "com.JH.LyricsX.diagnostics" AND eventMessage CONTAINS "preview=")
  OR (process == "NotificationCenter" AND category == "timelineLiveView" AND eventMessage CONTAINS "dev.JH.LyricsX"
  AND eventMessage CONTAINS "Evaluated inner view")'
```

想不重新编译就试别的提前量，见 `LyricsTimelineProvider` 里 `defaultWidgetSchedulingCompensationMs` 的注释：
要写进 App Group 容器里的那份偏好，也就是小组件读快照的同一个文件。

### timeline 只排 60 秒，提前 15 秒要下一份

播放中的 timeline 只排接下来 60 秒的行，用 `.after` 让 WidgetKit 到点再要一份新的，每次都从最新的快照重新对时，
WidgetKit 计时和实际播放之间的误差就攒不起来。

原来 `.after` 的时刻就是窗口的末尾，交接时会断档。`chronod` 在那个时刻之后约 4 秒才来要新的 timeline，再渲染
1～2 秒才换上，这期间旧 timeline 已经没有下一行了。2026-10-18 录到一次：大号从 19:43:10 到 19:43:17 一行没换，
窗口末尾之后才开始的那一行晚了好几秒，而且每分钟一次。现在 `.after` 定在窗口末尾前 15 秒，交接期间旧 timeline 里
还有行可换。每次生成的条数不变，只是后台刷新从约每 64 秒一次变成约每 49 秒一次。

### 更新之后，结束旧版本留下的扩展进程

Sparkle 在 app 退出之后才安装更新，小组件扩展的进程它不管。安装时旧的 app 被挪进 Sparkle 的安装目录然后删掉，
扩展进程照样运行着那个已删除的文件；系统按实例复用进程，之后小组件的每次请求都交给它，直到用户注销或重启。
平时这只意味着新版本对小组件的改动要重启才生效；配置方式一变就成了故障。2026-10-28，一台 macOS 26.7 的 Mac 从
1.9.0-beta.14 更新到 rc.1：rc.1 的小组件是静态配置，没有配置 intent，beta.14 的旧进程却要求 intent，25 分钟里报了
798 次 "Intent configuration is required but was not provided"，桌面小组件全黑。结束那个进程之后，系统一秒内从新
安装包启动扩展，四个小组件都取到了 timeline，此后没有再报错。

所以 app 每次启动都检查一遍（`StaleWidgetExtensionTerminator`，在后台队列上跑），找到旧进程就发 SIGTERM 结束它，
再刷新一次所有小组件，让系统从当前安装包启动扩展。Sparkle 的维护者对这类问题给的也是这个办法
（[Sparkle issue 1096](https://github.com/sparkle-project/Sparkle/issues/1096)）。

哪些进程算旧的，由 `WidgetExtensionProcessPolicy` 决定：

- 运行在安装包里那个路径上、但跑的不是那个文件（设备号和 inode 不同）：更新把文件原地覆盖了。
- 运行在别的路径上、而那里的文件已经不在：Sparkle 挪走又删掉的旧版本。
- 运行在别的路径上、那里是同一个小组件的**更旧**版本：旧版本还没删掉。
- 其余都不动：别的构建的小组件（比如 Debug 版，bundle identifier 不同）、同一版本的另一份副本，以及**更新**的副本，
  后者是系统挑来服务小组件的那一份。最后这条是实测改出来的：一开始只要版本号不同就结束，结果一个 2929 的 Debug
  构建结束了系统刚从 2930 那份启动的进程，系统马上又启动一个，白折腾一次。

进程的路径和文件不从 `proc_pidpath` 取，而是从进程映射可执行文件的那段内存（`PROC_PIDREGIONPATHINFO`）里取，也就是
`lsof` 列为 txt 的那一项：文件删掉之后它仍报文件最后所在的路径，inode 也还是旧文件的。先用 `proc_name` 按进程名
筛一遍，免得对每个进程都去翻内存区域；`proc_name` 的缓冲区至少要有 `proc_bsdinfo.pbi_name` 那么长（32 字节），
短了它对每个进程都直接失败，第一次实测就是因此什么也没找到。

**macOS 27.2 上系统自己会清掉旧进程。** 实测时把正在服务小组件的 Debug 包挪走、换上新构建、删掉旧包，旧进程一直
活着；新包登记进 LaunchServices、app 启动的那一刻，系统用 SIGKILL 结束了它。这台 Mac 当初从 beta.14 更新到 rc.1
时也没出问题。macOS 26.7 没有这么做，所以这一段主要是给 macOS 26 及更早的系统用的，在 27 上它通常找不到要结束的
进程。

**旧描述还会留一阵。** 版本号变化时 `chronod` 立刻重读小组件描述，读的是当时还活着的旧进程，于是 beta.14 的描述
（带配置 intent）记在了新版本号下，要等下一次版本号变化才会重读。结束旧进程之后小组件照常出图，目前没看到这份旧
描述造成别的问题。

### app 退出时清空快照

播放中的 timeline 从快照记下的时刻往后推着排行。app 一退出就没人更新快照了，可小组件每 45 秒左右还会要一份新
timeline，读到的仍是那份「正在播放」的快照，于是接着往后推：歌名停在退出时那首，歌词一直滚到列表末尾，播放按钮
看起来也还在播放。

现在 app 退出时（`applicationWillTerminate`）在 `lyricsDisplay` 队列上清掉快照，立刻刷新一次，不等节流窗口；
小组件回到没有歌曲时的样子。`AppController` 同时记下一个标志，之后再有写快照的请求一律当作没在播放，退出途中
排着的刷新不会把快照写回来。2026-10-28 实测：Debug 版退出后约 50 毫秒，小组件来取 timeline，读到的是空快照。

退出 LyricsX 之后音乐可能还在放，小组件说「没在播放」不一定对；但它已经无从知道播放状态，总比继续滚一份过时的
歌词好。

## 模块结构

| 文件 | 内容 |
|---|---|
| `LyricsXPackage/Sources/LyricsXWidgetShared/LyricsWidgetData.swift` | app 写给小组件的快照，包括显示设置（`showsTranslation`）；旧版本写的快照照样能解码 |
| `LyricsXWidget/LyricsTimelineProvider.swift` | 静态配置的 timeline provider：从快照给每行生成一条 entry |
| `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetLyricsLayoutPolicy.swift` | 纯函数：给定每行高度，决定显示哪些行、每行的上边缘在哪 |
| `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetReloadPolicy.swift` | 纯规则：一串变化之后什么时候刷新，新快照值不值得刷新 |
| `LyricsX/Component/WidgetReloadCoordinator.swift` | 在 `lyricsDisplay` 队列上执行上面的规则：记下变化、到点写快照、该刷新才刷新 |
| `LyricsXWidget/Views/LyricsWindowView.swift` | 大号和超大号共用的歌词区，以及量高度、调用策略、摆放行的 `LyricsWindowLayout` |
| `LyricsX/Intents/WidgetPlaybackIntents.swift` | 三个播放按钮的 intent，同时编进 app 和小组件；在 app 里调 `AppController` 的 `togglePlaybackFromWidget()` 等方法 |
| `LyricsXPackage/Sources/LyricsXWidgetShared/WidgetExtensionProcessPolicy.swift` | 纯规则：一个正在运行的小组件扩展进程是不是更新留下的旧进程 |
| `LyricsX/Component/StaleWidgetExtensionTerminator.swift` | app 启动时枚举进程、读出每个小组件进程运行的文件，按上面的规则结束旧进程 |

## 验证

```bash
# 挑行策略，8 个用例（<1 秒）。第一个用例在原来的固定 9 行行为上是红的：
# 它显示第 6–14 行，360 pt 塞进 200 pt
cd LyricsXPackage && swift test --filter WidgetLyricsLayoutPolicyTests

# 刷新规则，12 个用例（其中三个参数化，<1 秒）。换歌那个用例在原来「有变化就立即刷新」的行为上是红的：
# 刷新 4 次，第一次在 0 秒，那时还是上一首的歌词。「单纯的暂停、恢复几乎立刻刷新」那几个在
# 「播放状态一律等 1 秒」的行为上是红的
cd LyricsXPackage && swift test --filter WidgetReloadPolicyTests

# 快照的编码，3 个用例（<1 秒）。旧版本写的快照（没有 showsTranslation）应读成不显示译文
cd LyricsXPackage && swift test --filter LyricsWidgetDataTests

# 哪些小组件扩展进程算更新留下的旧进程，10 个用例（<1 秒）。三种该结束的情况在原来「从不结束」的行为上是红的；
# 「更新的副本不动」和「读不出版本号的副本不动」在一开始「版本号不同就结束」的规则上是红的
cd LyricsXPackage && swift test --filter WidgetExtensionProcessPolicyTests
```

结束旧进程这一步在 app 里，没有测试宿主，是这样实测的：复制一份 `/bin/sleep`，放到某个
`…/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget` 路径下运行，再删掉它的目录，就得到一个和 Sparkle 更新后
一样、跑着已删除文件的「小组件」进程（系统不会替它收拾，它不是真的扩展）。然后启动 app，几秒内这个进程应当消失，
日志里有 `Ended stale widget extension <pid> at <路径>`：

```bash
/usr/bin/log show --info --last 5m --style compact \
  --predicate 'subsystem == "com.JH.LyricsX.diagnostics" AND category == "StaleWidgetExtension"'
```

同时确认别的小组件进程（正式版的、其他 Debug 构建的）还在，一个都不该被结束。

退出时清空快照：放着歌时退出 app，上面那条 `log stream` 里，`[LXWG][Reload] reloadAllTimelines (hasSnapshot=false…)`
之后应紧跟 `[LXWG][Provider] getTimeline(in:) called (hasData=false…)`。要直接看快照，读 App Group 容器里的那份
偏好文件（`~/Library/Group Containers/<group>/Library/Preferences/<group>.plist`），不要用 `defaults read <group>`：
它读的是 `~/Library/Preferences` 下另一份早已过时的同名文件。刚退出时文件可能还没写回磁盘，以小组件日志为准。

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
metadata="$products/LyricsX-Debug.app/Contents/PlugIns/LyricsXWidget.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"
jq -c '.actions | to_entries[] | select(.key | test("PlayPause|NextTrack|PreviousTrack"))
       | {intent: .key, openAppWhenRun: .value.openAppWhenRun, systemProtocols: .value.systemProtocols}' "$metadata"
# 小组件没有配置 intent：actions 只有这三个，entities 为空
jq -c '{actions: (.actions | keys), entities: (.entities // {} | keys)}' "$metadata"
```

**改了小组件的描述之后，先临时调高两个 Info.plist 的 `CFBundleVersion` 再构建，测完改回、不提交。** 描述指有没有
设置项、支持哪些尺寸、显示名这类内容。`chronod` 按版本号缓存描述，版本号不变就判定 "No updates required -
descriptors are up to date"，一直用旧描述；重启 `chronod` 也只是从缓存里读。Debug 构建的版本号恒为 2929，所以换成
静态配置后，编辑菜单还在。改成 2930 后，日志里出现 "Refetching descriptors due to extension version change, from
2929-2929-… to 2930-2930-…"，菜单才消失。正式发版时 CI 会改版本号，用户不受影响。只改视图或 timeline 的话不用调，
它们每次刷新都会重新问小组件。

下面这些只能在桌面上人工确认：

- 按钮：在桌面放一个大号或超大号小组件，点播放、上一首、下一首，播放器应当响应，且不弹出设置窗口。播放/暂停的
  图标约 1 秒内就变；下一首约 2～3 秒内连同歌词一起换好。日志里，按下之后第一条
  `[LXWG][Provider] getTimeline(in:) called` 读到的就应该是新状态。
- 超大号：在 app 的偏好设置里打开「Prefer bilingual lyrics」，放一首带翻译的歌，封面、标题和播放按钮都应留在小组件
  里，歌词区里没有被切掉半截的行。
- 统一配置：先把桌面上的小组件全部删掉、重新添加（理由见「小组件没有自己的设置项」）。放一首带翻译的歌，在 app 里
  切换「Prefer bilingual lyrics」，桌面上所有小组件应当在约 1 秒内一起显示或收起译文。上面那条日志里，每次刷新的 `record reload` 只应出现一个配置编号，`Throttling additional refresh request`
  不应紧跟在每次刷新后面出现。
- 大号：放一首有长句的歌，折行的句子应当居中，当前行不再变成一行加省略号。

## 已知降级

- **SwiftUI 那一层没有自动化测试。** 小组件的视图在 widget target 里，不在可测试的 package 里，WidgetKit 的渲染
  也只能在桌面上看，所以自动化测试只覆盖挑行策略。自定义 `Layout` 在小组件里能工作，依据是推断：小组件的视图在
  扩展进程里排版，`GeometryReader` 在小组件里同样可用。这一点要在桌面上确认。
- 折行后整句偏左（#142 第 6 条里的第三种情况）的原因没有坐实。推测是溢出时的挤压造成的，现在歌词区不再溢出，
  预计随之消失，同样要在桌面上确认。
- 三个 intent 的最低系统从 macOS 13 提到 14，这是 `AudioPlaybackIntent` 的要求。它们在快捷指令（Shortcuts）里
  也显示为 LyricsX 的动作，macOS 13 上不再有这三个动作。小组件本身最低 macOS 15，不受影响。
- 刷新攒着发的代价：换歌后歌名也要等到那一次刷新才换（约 1.5～2.5 秒，原来立刻换，但配着错的状态）；歌曲开头或
  结尾 1.5 秒内的暂停、播放，以及跳转进度，小组件约 1 秒后才跟上。小组件上的播放按钮不受影响。
- 「单纯的暂停」靠进度判断：要是哪个播放器换歌时先报一次暂停，报的却是上一首、离结尾还远的进度，这次暂停会被当成
  单纯的暂停立刻刷新，用掉 5 秒的窗口，换歌后的正确内容要等窗口过去。目前只见过报新歌开头进度的情况。
- 5 秒的节流是从 `chronod` 日志里量出来的，Apple 没有写进文档，系统版本变了可能跟着变。
- 按钮写好状态再返回这一段没有自动化测试：intent 由系统在 app 进程里调用，只能看日志、在桌面上点按钮来确认。
- 每行换上的时刻前后有约半秒的抖动，来自系统合并计时器，app 这边消除不了；提前量只能让它的中位数对上歌词。
- 小组件不能各自设置：所有小组件显示不显示译文都跟着 app 的「Prefer bilingual lyrics」，显示哪种跟着 app 的显示语言，
  不能一个显示、一个不显示，也不能各显示一种。这是为了统一配置有意做的取舍，见「小组件没有自己的设置项」。
- 小组件不做简繁转换：桌面歌词会按 app 的简繁设置转换中文歌词和译文，歌词面板会转换译文，小组件显示的都是原文。
- 小组件删掉后残留的配置要重启 `chronod` 和 `NotificationCenter` 才清掉，见「节流按小组件种类算，请求按配置拆分」。
- 升级之后要把小组件全部删掉、重新添加一次，才会同在一套配置里；没这样做的用户，一部分小组件仍晚 5 秒。见「小组件
  没有自己的设置项」。
- 结束旧扩展进程没在一次真实的 Sparkle 更新里验证过：macOS 27.2 上系统自己先清掉了，app 这一步是用假进程实测的
  （见「验证」）。macOS 26 上的效果要等下一次发版，在 26 的 Mac 上更新之后看上面那条日志。
- 从 beta.14 或更早直接更新上来的，`chronod` 里那份旧描述要到再下一次版本号变化才更新，见「更新之后，结束旧版本留下的
  扩展进程」。
- app 不是正常退出（崩溃、强制退出）时 `applicationWillTerminate` 不会运行，快照留着，小组件照旧滚下去，直到 app
  再启动写新快照。

## 后续工作

- 发版时，发布说明里写上「更新后把桌面上的小组件全部删掉，再重新添加一次」。
- 也可以考虑由 app 自己发现还留着旧配置的小组件，提示用户重新添加。可以试试 `WidgetCenter.shared.currentConfigurations()`，
  但它返回的 `WidgetInfo` 能不能分出新旧两种配置，还没验证。
- 小组件跟随 app 的简繁设置：照桌面歌词的做法，在 app 写快照时转换，经快照传过去。
- 播放器不给封面时，小组件只显示音符占位图（#147）。歌词面板已经会联网找封面（`HighResolutionArtworkService`），
  但它只在面板窗口开着时运行，结果也不写给小组件。
