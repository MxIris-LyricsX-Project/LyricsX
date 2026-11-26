# Draft - 搜索歌词面板：底部改成跟着播放走的歌词预览，搜索框跟着切歌

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-26
- **最后更新**: 2026-11-26
- **所属愿景**: 无
- **关联提案**: [Draft 拆分 LyricsXFoundation](draft-split-lyricsx-foundation.md)（若它先落地，本提案给
  `LyricsSearchPanelResults` 加的两个方法随该类型一起进 `LyricsPolicies`）
- **实现分支 / PR**: `feature/search-panel-synced-preview`（LyricsX），功能树 `.worktrees/MxIris-LyricsX-Project-SearchPanelSyncedPreview`（父仓库）
- **配套文档**: 待定 —— 落地时判断是否在 [候选池实现说明](../Internal/LyricsCandidatePool.md) 之外另写一份
- **网页版**: 同目录同名的 `.html`

## 摘要

「搜索歌词」面板底部不再显示选中结果的 LRC 原文，而是换成浮动歌词窗口用的那种滚动歌词视图（`ScrollLyricsView`）：
选中一条结果，就按它的时间轴显示歌词，正在唱的那一行高亮并保持在中间，跟着播放器的进度往下走。时间按「播放器位置 +
这条歌词应用之后会用的总偏移」计算，所以预览里看到的进度就是点「应用」之后屏幕上会看到的进度；双击某一行跳到那里播放，
方便对一下时间轴。歌词带逐字时间（行内时间标签）时，正在唱的那一行里已唱的部分是强调色、没唱的是白色，
分界按标签的时间在字里平滑扫过——与状态栏歌词的卡拉OK进度同一套计算和画法——可以逐字核对标签与演唱是否一致。结果不属于正在播放的歌时，预览只显示歌词、不标进度。面板开着的时候，播放器换了歌，标题和歌手两个
输入框就换成新歌的名字并重新搜索；面板关着时不做任何事，下次打开时照旧按正在播放的歌刷新。判断「要不要重搜」和
「预览要不要跟进度」是 `LyricsSearchPanelResults` 上的两个纯方法，有单元测试。

## 动机

- **看原文判断不了时间轴对不对**：底部的 `lyricsPreviewTextView` 显示的是 `Lyrics.description`
  （`LyricsX/Search/SearchLyricsViewController.swift:289`），也就是带 `[ti:]`、`[offset:]` 和每行 `[mm:ss.xx]`
  时间标签的 LRC 文本。要知道这条歌词和正在放的歌对不对得上，只能拿时间标签和播放器的时间心算，还得自己加上歌词自带的
  offset、全局偏移和按播放器与输出设备设置的偏移（0029）。实际上没有人这么做。
- **现在只能「先应用再看」，而应用会留下痕迹**：想确认一条结果的时间轴，唯一的办法是点「应用」看屏幕上的歌词。
  `apply(_:to:)`（`:160-187`）会把它标成用户亲选（`markAsUserPicked`）、写进歌词库（`persist()`）、记进手选覆盖表
  （`rememberLyricsSelection`）、把整个结果列表交给候选池，开了「自动写入 Music」时还会写进 Music。试错一次，
  这些都已经发生了；试错几次，覆盖表和歌词库里留下的是最后一次的结果，未必是用户想要的。
- **切歌之后面板还停在上一首**：输入框只在面板出现时（`viewWillAppear` → `reloadKeyword()`，`:45-73`）和从菜单再次打开时
  （`SearchLyricsWindowController.showWindow`，`SearchLyricsWindowController.swift:15-18`）更新。面板开着的时候换了歌，
  输入框和结果都还是上一首的。此时点「应用」，结果会按 `LyricsResultsApplication.originalTrackOnly` 存给上一首
  （`:110-122`，候选池实现说明第五节）——不会出错，但用户多半以为自己在给正在放的这首挑歌词，结果屏幕上什么都没变。
  面板开着一直挑歌词、播放列表自动往下走，是很常见的用法。

## 前期调研

- **面板现在的结构**（`Main.storyboard` 场景 `hFt-BA-jFS`，`LyricsX/Supporting Files/Base.lproj/Main.storyboard:646-987`）
  - 自上而下：Search Bar（标题、歌手两个输入框，绑定 `searchTitle` / `searchArtist`，`NSContinuouslyUpdatesValue` 开）
    → 分隔线 → 结果表 + 200 pt 封面 → 分隔线 → `NSScrollView`（`rkQ-Bz-mQO`，最小高度 200）里的 `NSTextView`
    （`PEz-rD-ja1`，outlet `lyricsPreviewTextView`）→ 分隔线 → 「应用」按钮栏。
  - 面板刚打开时是收起的：`hideLrcPreviewConstraint`（`E0H-1P-tjm`，结果区底边 = 视图底边，优先级 750）压过
    `normalConstraint`（`hYs-Ms-8iP`，按钮栏底边 = 视图底边，749），`viewDidLoad` 里先把后者关掉。第一次选中结果时
    `expandPreview()`（`:329-347`）把窗口往下拉高、关掉前者，动画结束后打开后者。
  - 原文还有另一个用处：把结果行拖到 Finder 或文本编辑器，导出的就是 `description`（`:293-317`）。这条路不变。
- **面板控制器常驻**：`AppDelegate.searchLyricsWC` 是 `lazy var`（`LyricsX/Component/AppDelegate.swift:32`），关窗不释放。
  因此任何订阅都必须跟着窗口的可见性开关，否则窗口关着也会在后台跟着切歌搜索。
- **需要的视图已经有了**：`ScrollLyricsView`（`LyricsX/View/ScrollLyricsView.swift`）是浮动歌词窗口
  （`LyricsHUDViewController`）用的滚动歌词视图：
  - `setupTextContents(lyrics:)`（`:89-133`）只排启用且非空的行，按「双语歌词」偏好附上中文翻译，居中对齐；
  - `highlight(position:)`（`:212-237`）按时间二分查找当前行并换色，`scroll(position:)`（`:239-260`）把它滚到中间；
  - 双击某行回调 `doubleClickLyricsLine(at:)` 并带上该行时间，滚轮开始 / 结束回调 `scrollWheelDidStartScroll` /
    `scrollWheelDidEndScroll`，上下边缘渐隐，首末行可以滚到中间（`updateEdgeInset`）。
  - 在 storyboard 里用 `customClass="ScrollLyricsView"` + 文档视图 `customClass="LyricsTextView"` 装配
    （`Main.storyboard:550`、`:556`）；`textView` 是对 `documentView` 的强制转换，所以文档视图必须是 `LyricsTextView`。
  - `textColor`、`highlightColor` 的默认值是浮动窗口深色背景用的浅灰和浅绿（`:30`、`:42`），放进普通窗口要换成系统颜色。
  - 浮动窗口怎么驱动它：`LyricsHUDViewController.displayLyrics`（`LyricsX/LyricsHUD/LyricsHUDViewController.swift:104`）
    用 `playbackTime + adjustedTimeDelay` 调 `highlight` 和带 0.3 秒动画的 `scroll`；用户手动滚动后 `isTracking = false`
    停止自动滚动，双击某行（`:125`）跳播并恢复跟随。
- **进度从哪来**：`AppController` 只为 `currentLyrics` 算 `currentLineIndex`（`scheduleCurrentLineCheck`，
  `LyricsX/Component/AppController.swift:374-410`）：取 `playbackState.lyricsDisplayTime(trackDuration:)`
  （`LyricsXPackage/Sources/LyricsXFoundation/MusicPlayerExtensions.swift`）加 `lyrics.adjustedTimeDelay`，用 LyricsKit 的
  `lyrics[position]`（`LyricsKit/Sources/LyricsCore/Lyrics.swift:190`，返回当前行与下一行的下标）找当前行，在下一行开始时
  再算一次；最后一行之后仍在播放就每秒复查（为单曲循环回到开头）。预览的歌词不是 `currentLyrics`，所以要自己按同样的办法排。
- **偏移与应用后一致**：`Lyrics.adjustedTimeDelay`（`LyricsX/Utility/Extension.swift:279-285`）= 歌词自带 offset + 全局偏移 +
  当前播放器与输出设备的偏移，只依赖歌词本身和全局状态。对一条还没应用的结果算出来的值，就是它应用之后的值。
  全局偏移变化（`defaults.publisher(for: [.globalLyricsOffset])`）和设备偏移变化
  （`PlaybackRouteLyricsOffsetController.shared.currentRouteOffsetDidChange`）都有现成的发布者（`AppController.swift:154-162`）。
- **切歌的发布者在属性更新之前发出**：`selectedPlayer.currentTrackWillChange` 在 Scriptable 播放器上就是 `$currentTrack`
  （`MusicPlayer/Sources/MusicPlayer/Players/Scriptable.swift:56`），`@Published` 在 `willSet` 里发出，此刻读
  `selectedPlayer.currentTrack` 还是旧歌。`AppController` 先 `removeDuplicates()`（`MusicTrack` 按 id 比较，挡掉 SystemMedia
  只换封面的更新）再切队列（`AppController.swift:141-145`）。面板要用发布出来的值，并异步切到主线程。
  现在的 `searchAction` 从 `selectedPlayer.currentTrack` 读曲目（`:83`），直接在回调里同步调用会搜成上一首。
- **恢复名在切歌瞬间可能是上一首的**：`reloadKeyword()` 优先用 `AppController.shared.currentLyrics?.searchPluginTerm`
  （Apple Music 原名恢复找到的原文名，`:63-68`）。`currentLyrics` 是在 `currentTrackChanged()`（`AppController.swift:522-535`）
  里、在歌词队列上清空的，和主线程上的面板没有先后保证：面板处理切歌时它可能还是上一首的歌词，拿它的恢复名会把上一首的名字
  填进新歌的输入框。所以跟着切歌的那条路不读它；打开面板时那条路照旧读（那时 `currentLyrics` 已是这首歌的）。
- **「存给原来那首歌」这条路仍然需要**：`LyricsResultsApplication` 与 `save(_:forTrackNoLongerPlaying:)`（`:110-147`）是
  b2262cd1 为「面板开着切了歌」加的。跟着切歌之后它很少再走到，但播放器退出（曲目变成 nil）时面板保留结果、
  以及切歌到主线程处理之间的一瞬间，仍然靠它把歌词存对地方。
- **测试能覆盖到哪**：面板控制器在 app target 里，包测试够不着；`LyricsSearchPanelResults`
  （`LyricsXPackage/Sources/LyricsXFoundation/LyricsSearchPanelResults.swift`）是纯值类型，已有
  `LyricsSearchPanelResultsTests`，新判断放这里就能测。
- **文案**：storyboard 的文字在 `mul.lproj/Main.xcstrings`，代码里的在 `Localizable.xcstrings`；往 String Catalog
  加条目要手工按 `localizedStandardCompare` 插入，只补简繁中文（项目惯例）。

## 提议方案

### 一、底部换成跟着播放走的预览

1. storyboard 里把 `rkQ-Bz-mQO` 改成 `ScrollLyricsView`、`PEz-rD-ja1` 改成 `LyricsTextView`（不可编辑、不可选、
   不画背景、内容清空），outlet 改名 `lyricsPreviewView`。约束、最小高度和「收起 → 首次选中时展开」的行为都不变。
2. `viewDidLoad` 里设外观：字体系统字体 13 pt（经新加的 `ScrollLyricsView.fixedFont`），普通行 `secondaryLabelColor`，
   深浅外观都跟着系统走。竖向滚动条关掉（同浮动窗口）：视图的上下渐隐遮罩会把滚动条一起遮掉，只剩中间一截。
3. **逐字进度**：当前行没有行内时间标签时整行 `controlAccentColor`；有标签时整行先是 `labelColor`，已唱的部分画成
   `controlAccentColor`，分界在字里平滑移动。已唱多少由 `KaraokeLineTiming`（状态栏的卡拉OK进度用的同一个类型）给出：
   两个标签之间线性插值，得到带小数的已唱字数，再换算成分界所在的字和这个字唱过的比例。颜色由 `ScrollLyricsView` 的
   新属性 `karaokeUnsungTextColor` 打开，浮动窗口不设它，行为不变。
4. 选中一条结果：`lyricsPreviewView.setupTextContents(lyrics:)` 装入它，恢复自动滚动，立即刷新一次进度（不带动画）。
   没有选中时清空预览、显示一行居中的占位文字「选中一条结果，在这里跟着播放预览」。
5. **刷新进度**（`refreshPreviewProgress(animated:)`）：
   - 只有 `panelResults.previewFollowsPlayback(whilePlaying: 正在播放的曲目 id)` 为真时才标进度——结果是为正在放的这首
     搜到的。否则只显示歌词、不高亮（从「跟随」变成「不跟随」时重新 `setupTextContents` 清掉残留的高亮）。
   - 位置 = `playbackState.lyricsDisplayTime(trackDuration:) + lyrics.adjustedTimeDelay`，调 `highlight(position:)`
     （它返回当前行是否换了）；自动滚动开着时，换了行或非定时的刷新才调 `scroll(position:)`——同一行里进度推进不滚动。
     带动画时用浮动窗口同样的 0.3 秒 `swiftOut`。
   - 正在播放、当前行的已唱部分正在移动（`karaokeProgressMoves(at:)`）、窗口没被完全挡住时，用 display link
     （MSDisplayLink，app 已依赖，兼容 macOS 12）每帧刷新，60 fps，与状态栏相同。否则停掉 display link，在
     `ScrollLyricsView.nextHighlightChange(after:)` 给出的时刻再刷新：下一行开始，或当前行的进度开始移动，取早的那个；
     过了最后一行仍在播放则每秒复查。暂停时两者都不排。
   - 触发：选中变化、`selectedPlayer.playbackStateWillChange`（暂停、继续、拖动进度）、全局偏移变化、设备偏移变化、
     窗口改大小、窗口遮挡状态变化、上面排的定时器与 display link。
6. **交互**：手动滚动预览时停止自动滚动（同浮动窗口）；双击某一行，在跟随状态下把播放器跳到该行
   （`行时间 - adjustedTimeDelay`）并恢复自动滚动，不跟随时什么都不做；预览没有右键菜单。

### 二、搜索框跟着正在播放的歌切换

1. 窗口出现时（`viewWillAppear`）开始订阅，消失时（`viewDidDisappear`）取消订阅、停掉预览定时器：
   `selectedPlayer.currentTrackWillChange.removeDuplicates().receive(on: DispatchQueue.main)`。
2. 收到新曲目：`panelResults.needsNewSearch(whilePlaying: track?.id)` 为真（换了一首歌）时，先结束输入框的编辑
   （`view.window?.endEditing(for: nil)`，免得正在输入的文字盖回去），把两个输入框换成新歌的标题和歌手（不读恢复名，
   理由见调研），然后为这首歌搜索。曲目变成 nil（播放器退出、停止）时保留现有结果，「应用」照旧存给原来那首。
3. 搜索改为显式带曲目：`searchAction(_:)` 只转调新的 `search(for track: MusicTrack?)`，切歌那条路把发布出来的曲目传进去，
   不再读可能还没更新的 `selectedPlayer.currentTrack`。
4. 打开面板（`reloadKeyword()`）照旧：按正在播放的歌填输入框（优先恢复名），名字和上次不同就重搜；另外补上
   「曲目 id 变了也重搜」——同名的另一首歌（另一个版本）之前会沿用上一首的结果。

### 非目标

- 不在预览里调偏移。偏移照旧在状态栏菜单里调，调了预览会跟着动。
- 不嵌 Apple Music 风格的歌词引擎（见替代方案）；逐字进度照状态栏的样子画，不做抬起、发光这类效果。
- 不自动选中第一条结果；选中仍由用户决定。
- 面板关着时不跟着切歌，也不在后台搜索。
- 恢复名在搜索开始后才出现时，不改输入框、不重搜（会把用户正在看的列表整个换掉）。
- 不改「应用」的语义：上屏、标记亲选、写库、交给候选池、自动写入 Music，全部照旧。
- 不再在面板里显示 LRC 原文；要原文的用户把结果行拖出去即可（已有功能）。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `LyricsXPackage/Sources/LyricsXFoundation/LyricsSearchPanelResults.swift` · `LyricsSearchPanelResults` | 修改 | 加 `needsNewSearch(whilePlaying:)` 与 `previewFollowsPlayback(whilePlaying:)` | 两条判断做成纯函数，包测试能测 | 1 |
| `LyricsXPackage/Tests/LyricsXFoundationTests/LyricsSearchPanelResultsTests.swift` | 修改 | 补七个用例（见步骤 1 的行为清单） | 钉住「何时重搜」「何时跟进度」 | 1 |
| `LyricsX/Supporting Files/Base.lproj/Main.storyboard` · 场景 `hFt-BA-jFS` | 修改 | `rkQ-Bz-mQO` → `ScrollLyricsView`（关掉竖向滚动条），`PEz-rD-ja1` → `LyricsTextView`（不可编辑、不可选、不画背景、清空内容）；outlet `lyricsPreviewTextView` → `lyricsPreviewView` | 复用浮动窗口的滚动歌词视图 | 2、5 |
| `LyricsX/Search/SearchLyricsViewController.swift` · `SearchLyricsViewController` | 修改 | 预览装配与外观、占位文字、`refreshPreviewProgress(animated:)` 与定时器、遵循 `ScrollLyricsViewDelegate` | 底部预览跟着播放走 | 2 |
| `LyricsX/View/ScrollLyricsView.swift` · `ScrollLyricsView` | 修改 | 加 `fixedFont: NSFont?`，设了就代替 `fontName` + `fontSize` | 系统字体没有能按名字取的名字（按名字取 `.AppleSystemUIFont` 得到 Times），预览要用系统字体 | 2 |
| `LyricsX/View/ScrollLyricsView.swift` · `ScrollLyricsView`、`KaraokeLineLayout`（文件内私有） | 修改 | 加 `karaokeUnsungTextColor`；`highlight(position:)` 标当前行、按 `KaraokeLineTiming` 算出已唱部分并返回是否换行；新增 `karaokeProgressMoves(at:)` 与 `nextHighlightChange(after:)`；行查找抽成 `indexOfLine(at:)`，涂色抽成 `paintHighlightedLine()`；右到左的行不显示进度 | 逐字进度 | 5、6 |
| `LyricsX/View/ScrollLyricsView.swift` · `LyricsTextView` | 修改 | 加 `sungPart`；`draw(_:)` 先画已唱区域之外的文字，再把这一行的字形在已唱区域里单独画一层、涂成强调色 | 分界要停在字的中间，颜色属性做不到；移动分界不重新排版 | 6 |
| `LyricsX/Search/SearchLyricsViewController.swift` · `SearchLyricsViewController` | 修改 | 进度移动时开 display link（60 fps），否则用一次性定时器；订阅窗口遮挡变化 | 平滑扫过，不动时不耗电 | 6 |
| `LyricsX/Search/SearchLyricsViewController.swift` · `SearchLyricsViewController` | 修改 | 可见期间订阅切歌；`search(for:)`；`reloadKeyword()` 补曲目 id 判断 | 输入框跟着切歌 | 3 |
| `LyricsX/Supporting Files/Localizable.xcstrings` | 修改 | 占位文字一条，补简繁中文 | 新文案 | 2 |
| `Documentations/Internal/LyricsCandidatePool.md` · 第五节 | 修改 | 写明面板开着时跟着切歌、旧结果被换掉；「存给原来那首」只剩曲目变 nil 与切歌瞬间两种情形 | 实现说明与代码一致 | 4 |
| `LyricsX/CLAUDE.md` · Build Commands | 修改 | `LyricsXFoundationTests` 的覆盖清单补上「搜索面板何时为新歌重搜、预览何时跟进度」，并写明 `KaraokeLineTiming` 也给搜索面板的预览用 | 项目指令里列着每个策略测试 | 4、6 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案；落地时取号 | 索引 | 4 |

`ScrollLyricsView` 加了 `fixedFont` 与逐字进度（见决策日志），两者默认关闭，浮动窗口不受影响；第 5 步曾新增的
`KaraokeCharacterOnsets` 与它的测试在第 6 步删掉了，没有发布过；「不跟随时清掉高亮」用重新
`setupTextContents` 做到。

## 架构图

改了什么：

```text
SearchLyricsViewController (app target)
├── Search Bar: title / artist fields         ~ refilled when the playing track changes (window visible only)
├── results table + artwork                     (unchanged)
├── - NSScrollView + NSTextView                 - raw LRC text (Lyrics.description)
├── + ScrollLyricsView + LyricsTextView         + selected result, current line follows playback
│   └── + placeholder label                     + shown while nothing is selected
└── Apply bar                                   (unchanged)

LyricsSearchPanelResults (LyricsXFoundation)
├── application(whilePlaying:)                  (unchanged)
├── + needsNewSearch(whilePlaying:)             + another track started → search for it
└── + previewFollowsPlayback(whilePlaying:)     + results belong to the playing track → mark progress

ScrollLyricsView (app target, shared with the lyrics HUD)
├── + fixedFont: NSFont?                        + the system font, which has no name for fontName
├── + karaokeUnsungTextColor: NSColor?          + turns on karaoke progress (off in the HUD)
├── ~ highlight(position:) -> Bool              ~ marks the line, puts its sung part, reports a line change
├── + karaokeProgressMoves(at:) -> Bool         + the sung part moves now → refresh every frame
├── + nextHighlightChange(after:)               + next line start, or when the sung part starts moving
└── LyricsTextView
    ├── + sungPart: SungPart?                   + glyph range, rects up to the sung edge, colour
    └── + draw(_:)                              + text outside the rects, then the line's glyphs inside, recoloured

KaraokeLineTiming (LyricsXFoundation)             (unchanged; the menu bar's karaoke progress uses it too)
└── sungCharacterCount(atLyricsTime:) -> Double   fractional: the edge sits inside a character
```

数据流：

```text
selectedPlayer.currentTrackWillChange            (subscribed between viewWillAppear and viewDidDisappear)
  └── removeDuplicates → receive(on: main)
        └── panelResults.needsNewSearch(whilePlaying: track?.id)
              ├── true  → window.endEditing(for: nil)
              │           (searchTitle, searchArtist) = (track.title, track.artist)
              │           search(for: track) → panelResults reset → preview cleared, placeholder shown
              └── false → nothing (same track, or nothing playing)

table selection ─────────────┐
playbackStateWillChange ─────┤
globalLyricsOffset ──────────┼──→ refreshPreviewProgress(animated:)
currentRouteOffsetDidChange ─┤      guard panelResults.previewFollowsPlayback(whilePlaying: currentTrack?.id)
window resize / occlusion ───┤
one-off timer ───────────────┤
DisplayLink (60 fps) ────────┘      position = playbackState.lyricsDisplayTime(trackDuration:) + lyrics.adjustedTimeDelay
                                    lyricsPreviewView.highlight(position:)
                                    isPreviewTracking ? lyricsPreviewView.scroll(position:) : ()
                                    isPlaying, karaokeProgressMoves(at:), window visible
                                      ? keep the display link running
                                      : stop it; one-off timer at nextHighlightChange(after:) (1 s past the last line)

double-click line (following only) → selectedPlayer.playbackTime = linePosition − adjustedTimeDelay
```

## 详细设计

### `LyricsSearchPanelResults` 的两个新方法

与已有的 `application(whilePlaying:)` 同形：名词或断言短语 + `whilePlaying:` 标签，参数是正在播放的曲目 id。

```swift
extension LyricsSearchPanelResults {
    /// Whether a new search should replace these results now that
    /// `currentTrackIdentifier` plays: another track has started. With
    /// nothing playing the results stay — they still belong to the track they
    /// were found for, and applying one saves it for that track.
    public func needsNewSearch(whilePlaying currentTrackIdentifier: String?) -> Bool {
        guard let currentTrackIdentifier else {
            return false
        }
        return currentTrackIdentifier != trackIdentifier
    }

    /// Whether the preview of the selected result marks the line at the
    /// playback position: only while the track the results were found for
    /// plays. A search typed in with nothing playing was not for any track, so
    /// no playback position applies to it.
    public func previewFollowsPlayback(whilePlaying currentTrackIdentifier: String?) -> Bool {
        guard let trackIdentifier else {
            return false
        }
        return trackIdentifier == currentTrackIdentifier
    }
}
```

两者故意不对称：`trackIdentifier == nil`（没在播放时手动搜的）遇到新歌开始播放要重搜，但它的预览永远不跟进度。

### 面板控制器的新状态

```swift
@IBOutlet var lyricsPreviewView: ScrollLyricsView!
private let previewPlaceholderLabel = NSTextField(labelWithString: NSLocalizedString(
    "Select a result to preview it with the song.",
    comment: "Search Lyrics panel placeholder shown while no result is selected"
))
/// False once the user scrolls the preview by hand; selecting a result or
/// double-clicking a line turns it back on.
private var isPreviewTracking = true
private var previewLineCheck: Cancellable?
/// Subscriptions held while the window is on screen.
private var visibleWindowObservations: Set<AnyCancellable> = []
```

### 进度刷新

```swift
private func refreshPreviewProgress(animated: Bool) {
    previewLineCheck?.cancel()
    previewLineCheck = nil
    guard let lyrics = panelResults.selectedResult,
          panelResults.previewFollowsPlayback(whilePlaying: selectedPlayer.currentTrack?.id) else {
        return
    }
    let playbackState = selectedPlayer.playbackState
    let playbackTime = playbackState.lyricsDisplayTime(trackDuration: selectedPlayer.currentTrack?.duration)
    let position = playbackTime + lyrics.adjustedTimeDelay
    let marksAnotherLine = lyricsPreviewView.highlight(position: position)
    if isPreviewTracking, marksAnotherLine || !animated {
        scrollPreview(to: position, animated: animated)
    }
    guard playbackState.isPlaying else {
        return
    }
    let delay = lyricsPreviewView.nextHighlightChange(after: position).map { max(0, $0 - position) } ?? 1
    let queue = DispatchQueue.main
    previewLineCheck = queue.schedule(
        after: queue.now.advanced(by: .seconds(delay)),
        interval: .seconds(42),
        tolerance: .milliseconds(20)
    ) { [weak self] in
        self?.refreshPreviewProgress(animated: true)
    }
}
```

- 定时器写法照 `AppController.scheduleCurrentLineCheck`：用可取消的重复调度当一次性定时器，每次刷新先取消上一个。
- 「跟随 → 不跟随」的转换点只有两个（曲目变成 nil、切到别的歌），后者会立即重搜、清空预览；前者在切歌回调里
  重新 `setupTextContents` 清掉高亮。

### 逐字进度

照状态栏歌词的卡拉OK进度（`MenuBarMarqueeLabel`）做：同一个时间计算，同样的「已唱部分整块换色、分界对齐设备像素」，
同样按需开 display link。

- **已唱多少**：`KaraokeLineTiming(line:)` 给出排好序、只增不减的关键帧；`sungCharacterCount(atLyricsTime:)` 在两个
  关键帧之间线性插值，返回带小数的已唱字数。整数部分是分界所在的字，小数部分是这个字唱过的比例。字的单位是 Swift
  `Character`，`KaraokeLineLayout` 记下每个字在文本里的 UTF-16 起点，用来查字形。
- **分界在哪**：`NSLayoutManager.boundingRect(forGlyphRange:in:)` 取分界那个字的矩形，`minX + width × 比例` 就是分界；
  逐个枚举这一行（只是原文，不含双语的翻译那半行）的行片段：分界之前的行片段整块算已唱，分界所在的行片段从左边到分界，
  后面的不算。分界取整到设备像素，没跨过一个像素就不重画。
- **怎么画**（`LyricsTextView.draw(_:)`）：`NSTextStorage` 里当前行整行是 `labelColor`；画的时候先用 even-odd 裁剪把
  已唱区域挖掉、照常画文字，再只在已唱区域里开一个透明图层，`drawGlyphs(forGlyphRange:at:)` 把这一行的字形画进去，
  用 `sourceIn` 混合铺一层强调色——字形的覆盖度不变、颜色换掉。每个像素只来自一种颜色，分界可以停在字的中间；
  移动分界不改文本属性、不重新排版，只重画这一行的矩形。
- **何时刷新**：`karaokeProgressMoves(at:)` 在当前行的第一个与最后一个关键帧之间为真，这段时间里 display link 每帧
  调一次 `refreshPreviewProgress(animated: true)`；其余时间是一次性定时器，醒在下一行开始或进度开始移动时。
  帧率 60：状态栏歌词的默认值，MarqueeLabel 在 60 Hz 屏幕上的动画也是这个频率。窗口被完全挡住时不开 display link，
  遮挡状态一变就重新判断。
- **右到左的行**（希伯来文、阿拉伯文）不显示进度、整行强调色，同状态栏：从左往右填会让这种行一开始就是满的。

### 切歌订阅

```swift
override func viewWillAppear() {
    super.viewWillAppear()
    reloadKeyword()
    selectedPlayer.currentTrackWillChange
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] track in self?.playingTrackChanged(to: track) }
        .store(in: &visibleWindowObservations)
    selectedPlayer.playbackStateWillChange
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshPreviewProgress(animated: false) }
        .store(in: &visibleWindowObservations)
    defaults.publisher(for: [.globalLyricsOffset]).signal()
        .merge(with: PlaybackRouteLyricsOffsetController.shared.currentRouteOffsetDidChange)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshPreviewProgress(animated: false) }
        .store(in: &visibleWindowObservations)
}

override func viewDidDisappear() {
    super.viewDidDisappear()
    visibleWindowObservations.removeAll()
    previewLineCheck?.cancel()
    previewLineCheck = nil
}
```

`playbackStateWillChange` 同样在 `willSet` 里发出，但刷新读的是 `selectedPlayer.playbackState`；`receive(on: main)` 是异步投递，
读到时属性已经更新。实现时以构建后的实际行为为准，若读到旧值就改成用发布出来的 `PlaybackState`。

### 文案

| key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `Select a result to preview it with the song.` | 同 key | 选中一条结果，在这里跟着播放预览。 | 選取一條結果，在這裡跟著播放預覽。 |

## 替代方案考量

- **嵌入 Apple Music 风格的歌词引擎，显示逐字扫光**：`LyricsPanelViewController` 接受注入的歌词与当前行发布者，技术上能放进来，
  逐字时间对不对也能看出来。否：它为深色、带封面背景的大窗口设计，字号按窗口宽度分档，有 display link 和 Metal 背景，
  放进一个普通窗口的底部既不协调又贵；它的 `HostEnvironment` 是全局单例，时间偏移和播放器都按「屏幕上的那条歌词」接好了。
  逐字时间改在 `ScrollLyricsView` 里照状态栏的样子画（见决策日志）。
- **按字点亮、不插值**（第 5 步先做的版本）：字在它的标签开始那一刻整字变色，看到的就是标签本身的时刻。否：用户看过，
  一个字一个字地跳显得卡。平滑扫过在一字一标签的中文上，每个字仍在自己的标签时刻被扫到，核对照样可行；只标词首的英文
  看到的是词内的插值，与状态栏、桌面歌词显示的一致。
- **用文本属性逐帧换色**：`NSTextStorage` 只能整字换色，分界停不到字的中间，而且每次改属性都要让排版失效。否。
- **在文本视图上叠一层 `CALayer` 遮罩、用 Core Animation 关键帧动画推进**（桌面歌词的做法）：不占主线程，但一行折成
  几行时遮罩要按行片段拼，窗口改宽、暂停、跳播都得重建动画。预览一次只动一行，逐帧重画这一行的矩形足够便宜。否。
- **只显示一行卡拉OK（桌面歌词那种）**：能看逐字进度，但只看得到一行，看不出前后是否整体偏了一段。否。
- **保留原文，加一个「预览 / 原文」切换**：需求是不再显示原文；原文本来就能把结果行拖出去拿到。否。
- **固定频率刷新（例如每 0.1 秒）**：写起来简单，但面板开着时一直唤醒主线程，扫过也不够平滑。只在进度移动时每帧刷新、
  其余时间按下一行的开始时间排定时器（`AppController` 的现成做法），开销只在有东西要变时发生。否。
- **面板关着也跟着切歌**：关着的窗口没人看，后台搜索只浪费请求。否。
- **用户改过输入框就不跟着切歌**：需求是输入框跟着播放的歌走；为上一首改的搜索词对新歌也没有意义。否。
- **恢复名晚到时更新输入框并重搜**：会把用户正在看、可能已经选中的列表整个换掉；面板自己的搜索也走恢复名插件，
  恢复出来的结果照样会出现在列表里。否。

## 影响

### 用户可见变化

- 搜索面板底部：原来的 LRC 原文换成按时间轴滚动的歌词，正在唱的那一行用系统强调色标出、跟着播放往下走；
  没选中结果时显示一行占位文字。
- 带逐字时间的歌词，当前行的已唱部分随演唱平滑扫成强调色，与状态栏歌词的卡拉OK进度一样。
- 双击预览里的某一行，播放器跳到那一行（仅当结果属于正在播放的歌）。
- 面板开着时换了歌，输入框自动换成新歌的名字，结果列表换成新歌的搜索结果。正在为上一首挑、还没应用的结果会被换掉，
  这是跟着切歌的代价；要给上一首挑歌词，等它下次播放时再挑。
- 原来看 LRC 原文的用法：把结果行拖到 Finder 或文本编辑器，得到的就是原文（已有功能，不变）。

### 可发现性

没有新设置项。预览在第一次选中结果时随窗口展开出现，与现在一样；占位文字告诉用户这里是做什么的。默认即生效。

### 数据与配置兼容

不新增、不改动任何偏好设置、歌词文件或缓存。

### 平台与最低版本

不变（macOS 12+）。用到的 `ScrollLyricsView`、`controlAccentColor`（10.14+）、Combine、MSDisplayLink 都已在用。

### 发布

不涉及权限、entitlement、隐私清单、公证或 Sparkle。下次发版的发布说明要写这两处变化。

## 落地步骤

1. **两条判断与测试**（已完成）—— 改动地图第 1、2 行
   - 行为：`aNewTrackStartingNeedsANewSearch`
   - 行为：`theSameTrackPlayingOnNeedsNoNewSearch`（只换了封面的更新）
   - 行为：`nothingPlayingKeepsTheResults`
   - 行为：`aTrackStartingAfterASearchTypedWithNothingPlayingNeedsANewSearch`
   - 行为：`thePreviewFollowsPlaybackWhileTheSearchedTrackPlays`
   - 行为：`thePreviewStopsFollowingOnceAnotherTrackPlays`（含曲目变成 nil）
   - 行为：`thePreviewOfASearchTypedWithNothingPlayingNeverFollowsPlayback`
2. **底部换成跟着播放走的预览**（已实现，界面待手工检查）—— 改动地图第 3、4、5、10 行
   - 行为：选中一条结果，预览显示它的歌词，当前行高亮并居中
   - 行为：播放中到了下一行的时间，高亮与滚动跟着移到下一行
   - 行为：暂停时高亮停住；在播放器里拖动进度，高亮跳到对应行
   - 行为：调全局偏移或设备偏移，高亮随之前后移动
   - 行为：手动滚动预览后不再自动滚动；双击某行跳播并恢复自动滚动
   - 行为：结果不属于正在播放的歌时只显示歌词、不高亮，双击无效
   - 行为：没选中结果时显示占位文字；深浅外观下文字都清楚
   - 行为：拖出结果行导出的仍是 LRC 原文
3. **输入框跟着切歌**（已实现，界面待手工检查）—— 改动地图第 9 行
   - 行为：面板开着时换了歌，输入框换成新歌的名字并重新搜索
   - 行为：只换了封面的曲目更新不触发重搜
   - 行为：播放器退出时结果保留，「应用」存给原来那首歌
   - 行为：正在输入时换了歌，输入框显示新歌的名字
   - 行为：面板关着时换歌不搜索；再打开时按正在播放的歌刷新
   - 行为：打开面板时遇到同名的另一首歌也会重搜
4. **文档与收尾**（已完成）—— 改动地图第 11、12、13 行
   - 行为：候选池实现说明第五节、项目 `CLAUDE.md` 的测试清单与代码一致
5. **关掉预览的滚动条，逐字进度先按字点亮**（用户看过第一版后提出；按字点亮已被第 6 步取代）—— 改动地图第 3、6 行
   - 行为（界面）：预览右侧不再出现被渐隐遮掉的半截滚动条；滚轮与触控板照样能滚
   - 行为（界面）：浮动歌词窗口不变
6. **逐字进度改为平滑扫过**（用户看过按字点亮后提出；已实现，界面待手工检查）—— 改动地图第 6、7、8、12 行
   - 行为：已唱多少沿用 `KaraokeLineTimingTests`（状态栏的卡拉OK进度用的同一组测试），不新增纯逻辑
   - 行为（界面）：带逐字时间的行，已唱部分是强调色，分界在字里平滑移动，不再一个字一个字地跳
   - 行为（界面）：没有逐字时间的行整行强调色；同一行里进度推进时不滚动，换行时才滚
   - 行为（界面）：暂停时分界停住，继续后接着走；拖动进度后分界跳到对应位置
   - 行为（界面）：改窗口宽度、一行折成两行时，分界仍对在字上，第一行唱完才进第二行
   - 行为（界面）：双语歌词的翻译那半行不扫，保持白色
   - 行为（界面）：浮动歌词窗口不变

验证：步骤 1 跑 `swift test --filter LyricsSearchPanelResultsTests`（`LyricsXPackage`，加 `LYRICSX_USE_LOCAL_DEPENDENCY=1`
与隔离的 `--scratch-path`）；步骤 2、3 构建整个 app（按 `xcode-build-and-test` skill 选机器），界面行为由用户在真机手工检查，
agent 不自行操作界面。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要单独的实现说明：「为什么切歌那条路不读恢复名」「为什么用发布出来的曲目」写进代码注释和
  候选池实现说明第五节即可。落地时再确认。
- **有没有引入新术语** —— 预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-26 | Created as Draft | 用户要求重构搜索歌词面板：底部改为可检查进度的选中歌词预览，输入框跟着正在播放的歌切换。预览样式（复用浮动窗口的逐行滚动视图，而非 Apple Music 引擎的逐字扫光）由 agent 按调研选定，写进替代方案供用户推翻 |
| 2026-11-26 | Accepted | 用户批准，开始实现 |
| 2026-11-26 | 第 1 步完成 | `LyricsSearchPanelResultsTests` 12 个用例在 Ultra 上通过。包测试要用 workspace 的 `Package.resolved`：`swift package update` 会把 UIFoundation 升到要求 macOS 14 的版本，`from: "0.42.0"` 不挡它 |
| 2026-11-26 | 偏离：`ScrollLyricsView` 加 `fixedFont` | 提案原写「不改 `ScrollLyricsView`」。它的字体只能由 `fontName` + `fontSize` 按名字取，而系统字体没有可按名字取的名字（`.AppleSystemUIFont` 取到的是 Times），预览要系统字体，就加了一个可选的固定字体，浮动窗口不受影响 |
| 2026-11-26 | 第 2、3 步合成一个提交 | 两步改的都是面板控制器里交织在一起的几处（`search(for:)` 同时服务两步），分开提交得把同一个文件拆成两半 |
| 2026-11-26 | 预览在主线程读歌词，沿用既有做法 | 预览在主线程读选中结果的 `lines` 与偏移；结果应用之后它就是屏幕上的歌词，翻译和偏移会在别的线程写它。浮动窗口一直这样读屏幕上的歌词，`ReviewDecisions.md`「`currentLyrics` 与候选池在两个线程上都被改」已裁决为既有设计、不在局部改，这里不另起一套同步 |
| 2026-11-26 | 实现完成，待用户看过后收尾 | app 在 Ultra 上用 workspace 构建通过（Debug，`CODE_SIGNING_ALLOWED=NO`），`LyricsXFoundationTests` 262 个测试通过（1 个已知问题是系统翻译探针，与本次无关）。界面行为（第 2、3 步的行为清单）待用户手工检查。文档：候选池实现说明第五节、项目 `CLAUDE.md` 的测试清单已同步；不另写实现说明——两处不显然的决定（切歌用播放器报的名字、用发布出来的曲目）写在代码注释和候选池实现说明里；没有新术语 |
| 2026-11-26 | 用户看过第一版：滚动条有问题，要支持逐字歌词 | 预览右侧的竖向滚动条被 `ScrollLyricsView` 的上下渐隐遮罩遮得只剩一截，照浮动窗口关掉。用户用这个面板主要是逐字核对时间标签，原方案「逐行高亮就够」不成立，改为在 `ScrollLyricsView` 里按字点亮：字在标签开始时亮、不插值（理由见替代方案），新增纯类型 `KaraokeCharacterOnsets` 与测试；仍不嵌 Apple Music 引擎 |
| 2026-11-26 | 第 5 步完成，待用户再看 | app 在 Ultra 上构建通过，`LyricsXFoundationTests` 272 个测试通过（新增 `KaraokeCharacterOnsetsTests` 十个，1 个已知问题同前）。界面上的逐字点亮与滚动条待用户实机检查 |
| 2026-11-26 | 用户看过按字点亮：一个字一个字地跳显得卡，要照状态栏歌词做 | 改为平滑扫过（第 6 步）：已唱多少用 `KaraokeLineTiming` 的插值，`LyricsTextView` 把已唱区域单独画一层强调色，只在进度移动时开 60 fps 的 display link。替代方案里「插值会误导核对」的理由不再成立：一字一标签的中文每个字仍在自己的标签时刻被扫到。`KaraokeCharacterOnsets` 与它的十个测试只为按字点亮而加、没发布过，删掉 |
