# LyricsX 术语表

收录本项目自造词、内部代号，以及通用术语在本项目里的特定含义。
语言与框架的通用术语（Swift 的 `optional`、AppKit 的 `NSView`）不收 —— 收进来只会稀释。

一个术语只登记一处；跨项目通用的术语登记在全局术语表，这里链过去即可。

## 候选池（candidate pool）

一首歌的全部可用歌词结果，按质量排序后留在内存里的那份名单
（`AppController.lyricsCandidatePool`）。

**要点在于「全部」**：在此之前，自动搜索只保留优先级最高的那一条，落败结果当场丢弃。
候选池是「切换到下一条歌词」这个功能的前提。

- 由 `PriorityOrderedCandidatePool` 实现，排序规则与手动搜索面板的结果列表**完全一致**
  （同一个 `lyricsHasHigherPriority`）。
- 生命周期绑定单曲：切歌即清空。不持久化。
- 详见 [歌词候选池](Internal/LyricsCandidatePool.md)。

## 钉住（pinned）

用户手动选定某条候选之后的状态（`candidateSelectionIsPinned`）：后续到达的搜索结果
**仍然进入候选池**，但**不再自动替换屏幕上的歌词**。

不要读成「锁定歌词不可改」—— 用户按快捷键还能继续往下切，钉住挡的只是**自动**替换。
没有它的话，用户切走两秒后一条高分结果到达就会把屏幕拽回去。

## 补充搜索（replenish search）

候选池里没有别的候选时，由「下一条歌词」快捷键**当场发起**的一次搜索。

存在的理由：歌词命中本地缓存时，`currentTrackChanged` 会直接返回、从不搜索，
所以这类歌曲的候选池天然是空的（重启后播老歌就是这个情况）。
没有补充搜索的话，快捷键对它们永远只能回答「没有其他候选」。

## 覆盖表（selection override table）

`LyricsSelectionOverrideTable`：记录「用户为某首歌手动选定了哪个歌词文件」的一张
`track id → 文件路径` 表，存在偏好设置里。

它解决的是顺序问题而非存储问题：自动加载依次查内嵌歌词、音轨旁边的文件、保存目录，
而用户选定的那条写在保存目录（最末），下次播放会被前两者压过。表里的条目把那一个文件
提到查找顺序最前，**且不改写用户自己的任何文件**。

## Route B / name recovery

Apple Music 曲目本地化名恢复：先拿到曲目的原文（母语）名，再用它重新搜索。
这类结果比直连各歌词源慢，因此在优先级窗口之外**豁免**丢弃规则
（`lyrics.isFromSearchPlugin` 为真的那些）。

## 优先级窗口（priority window）

首条歌词到达后的一段时间（`lyricsPriorityWindow`，默认 5 秒），窗口内允许更高优先级的
结果替换已上屏的那条，窗口外则不再替换。

**只影响上不上屏，不影响进不进候选池** —— 窗口外到达的结果同样是合法候选，
只是不该在用户已经开始读歌词之后突然把屏幕换掉。这类结果带 `arrivedAfterPriorityWindow`
标记，两个判断点（正常上屏、封面加分后的重新比较）都要看它。

「能不能上屏」的完整判定 —— 钉住、迟到、Route B 分层、质量比较 —— 集中在
`LyricsDisplayEligibilityPolicy`。改上屏规则请改那里，不要在 `AppController` 里另开分支。

## 歌词库缓存（lyrics library cache）

LyricsX **自己**保存歌词的那个目录（默认 `~/Music/LyricsX/`，或用户自定义路径）里的文件。

**「缓存」只指这一层，且只指其中没有[手选标记](#手选标记user-pick-mark)的那些。**
内嵌歌词和 beside-track 歌词同样是本地文件，但它们是**用户的**资产，不是缓存；
库里带手选标记的文件也不是缓存，它是用户的**决定**，只是恰好存在同一个目录里。
这条分界正是 `IgnoreCachedLyricsLibrary` 开关的作用范围
（详见 [绕过歌词库缓存](Internal/LyricsLibraryCacheBypass.md)）。

缓存命中会让 `currentTrackChanged` 直接返回、一次网络请求都不发，所以库里存错的文件
**永远不会自我修复**。

## 手选标记（user-pick mark）

写在 `.lrcx` 文件里的一行 `[lxpick:<来源>]`，表示这份歌词是用户**手动应用**的，
而不是自动搜索自己存下的。四个入口会打它：搜索面板「使用歌词」、快捷键切换候选、
拖入/粘贴导入、手动编辑（分别记 `search-panel` / `next-candidate` / `import` / `edit`）。

- **判断只看标签在不在，不看取值** —— 取值只为排查时看一眼来路；未来版本写下的陌生取值
  同样算数，因为它照样出自某个人的动作。
- **标记跟着文件走**，不存偏好设置：换设备、恢复备份、手动整理歌词库都不丢，也没有条数上限。
  这正是它与[覆盖表](#覆盖表selection-override-table)的分工 —— 覆盖表解决查找**顺序**，
  标记解决**归属**。
- 旧文件没有标记，一律按自动缓存处理，不做迁移。
- 定义在 `LyricsXFoundation/LyricsUserPickMark.swift`（`Lyrics.isUserPicked`、
  `markAsUserPicked(origin:)`）。

## 分数桶（quality bucket）

把匹配分数量化到固定网格后的整数：`floor(分数 / 同分容差)`。

「分数优先，同分再按歌词源」这一模式用它判定「同分」——**不是**比较分差。理由是分差比较
（`abs(a − b) < 容差`）不满足传递性，而非传递的比较会让「自动匹配的冠军」和「搜索面板第一条」
对不上。分桶把比较退化成两个整数的字典序，传递性由构造保证。详见
[歌词候选的排序](Internal/LyricsSourceOrdering.md)。

## 同分容差（quality tolerance）

分数桶的宽度，固定 **0.02**，不可配置（`LyricsSourceOrderingPolicy.qualityTolerance`）。

取值依据是分数本身的量级：时长差 5 秒约造成 0.019 的分差、差 3 秒只有 0.007，而「有无翻译」
是 0.05。0.02 恰好吸收时长抖动，又保留翻译与逐字歌词这两档加分的区分度。

**保证是「分差严格大于容差时分数一定说了算」，不是「≥」** —— 浮点加法会让名义上差一个容差的
两个分数实际间隔略小于容差，从而落进同一个桶。

## beside-track 歌词

放在音频文件同目录、同主文件名的 `.lrc` / `.lrcx`。**默认只读**：视为用户自有资产，
除非显式开启 `WriteBackToLyricsBesideTrack`，否则 LyricsX 不写回。

## 截图副本（replicant）

AppKit 为状态栏条目渲染的截图。macOS 26 起，系统菜单栏显示的就是它，而不是 App 自己的状态栏窗口
（那个窗口的窗口号是 2³²，不在屏幕上）。条目每变化一次，AppKit 就会重新截图：先把条目的外观切到截图外观，
`cacheDisplay(in:to:)` 画一张位图，再把外观切回来。

因此在条目里放什么、多久变一次，直接决定 CPU 开销；会对外观切换做出反应的视图（`NSTextField`）甚至能让截图停不下来。
详见[菜单栏歌词的绘制](Internal/MenuBarLyricsRendering.md)。
