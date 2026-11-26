# 歌词候选的排序

> 对应提案：[0003 歌词源排序模式](../Evolutions/0003-source-ordering-modes.md)
>
> 面向维护者。讲的是「为什么这么实现」，不是「实现了什么」——后者读代码更快。

## 一句话

「两条歌词哪条排前面」这个判断从 `Global.swift` 里的一段 `if` 变成了
`LyricsSourceOrderingPolicy` 这个纯函数，支持三种模式；新增的第三种（分数优先、同分看源）
靠**把分数量化到 0.02 的网格上**来判定「同分」，因为直接比差值会破坏传递性。

## 为什么传递性是这件事的全部难点

有**两个调用方**用同一个比较函数，但用法不同：

- 自动搜索是**擂台赛**：手里攥着当前最好的一条，新结果赢了就换（`AppController.lyricsReceived`）；
- 搜索面板和候选池是**插入排序**：每条新结果插到第一个「打得过」的前面
  （`SearchLyricsViewController`、`PriorityOrderedCandidatePool.insert`）。

「反复取最大值」和「插入排序取第一名」**只有在比较关系是全序时才必然给出同一个冠军**。
关系一旦出现环，两者就会分道扬镳 —— 屏幕上的歌词不再是面板列表的第一条。

这不是假想的风险：促成 0003 的那次排查，用户报的症状正是「歌词不对，但搜索面板第一条是对的」。
当时查下来根因是缓存（见 [0002](../Evolutions/0002-always-ignore-cached-lyrics.md)），
但如果这里引入一个非传递的比较，就会**真的**造出同一个症状，而且再也说不清是哪一个原因。

`LyricsSourceOrderingPolicyTests` 因此有两条属性测试，比逐条判定的用例重要得多：
一条断言三种模式都无环（反对称 + 传递），另一条直接**把两种用法都跑一遍并断言冠军相同**。

## 为什么是分桶，不是比差值

最直觉的写法是「分差小于容差就算同分，去比源」：

```swift
if abs(a - b) < tolerance { return sourceIndex(a) < sourceIndex(b) }
return a > b
```

它不传递。容差 0.02、源顺序 A 在 B 前：

- a（源 A，0.900）vs b（源 B，0.915）：差 0.015 → 同分 → a 胜；
- b（源 B，0.915）vs c（源 B，0.918）：差 0.003 → 同分 → 同源比分数 → c 胜；
- a（源 A，0.900）vs c（源 B，0.918）：差 0.018 → 同分 → a 胜。

于是 a > b、c > b、a > c，看着没事；但把 c 挪到 0.921，第三条就翻成 c > a，环就出现了。
**上面那条属性测试会当场抓住它** —— 这也是那两条测试存在的意义。

分桶把分数量化到 `floor(quality / 0.02)`，比较退化成两个整数的字典序
`(桶号 降序, 源下标 升序)`，传递性由构造保证，不依赖容差取值。

## 分桶的边界抖动，以及它比提案说的更松一点

代价是网格边界：0.0199 和 0.0201 只差 0.0002，却落在不同桶，不算同分。这个抖动是随机的、
不累积的（第 6 个源和第 2 个源面对同样的门槛），提案里已经接受了。

**但提案多说了一句话，落地时发现它不成立。** 提案写的是「分差 ≥ 0.02 时分数一定说了算
（跨 0.02 必然跨桶）」。这在实数上对，在 `Double` 上不对：

```
0.12 + 0.02 == 0.13999999999999999   // 实际间隔 0.01999999999999999
0.12 / 0.02 == 6.000000000000001  → 桶 6
0.13999999999999999 / 0.02 == 6.999999999999999 → 桶 6   // 同桶！
```

也就是说，**名义上差一个容差的两条歌词仍可能被判为同分**，因为浮点加法给出的间隔比 0.02 少了
一个尾数位。真正成立的保证是「分差**严格大于**容差时，分数一定说了算」。

代码注释和测试都按后者写：`aGapWiderThanTheToleranceIsAlwaysDecidedByQuality` 用 1.001 倍容差
扫过整个分数区间，另一条 `aGapOfExactlyTheToleranceCanStillTie` 把上面这两个反例**钉住**，
免得以后有人把保证重新说大。提案按规矩保持原样，不回头改。

## 迁移：为什么必须跑在 `register(defaults:)` 之前

`UserDefaultsMigrator.migrateSourceOrderingModeIfNeeded()` 判断「用户是否已经选过模式」用的是
`object(forKey:) == nil`。而 **`UserDefaults` 的注册域（registration domain）对 `object(forKey:)`
是可见的** —— 一旦 `registerUserDefaults()` 先跑，新键就再也不是 nil，迁移会认为用户已经选过，
老用户在旧复选框里打开的「歌词源优先级」会被**静默丢弃**，退回成「只按分数」。

所以 `AppDelegate` 里的顺序是硬性的：两个迁移都在 `registerUserDefaults()` 之前。
新键**故意不写进 `UserDefaults.plist`**，正是为了不给这个顺序留翻车的余地。

## 旧键为什么保留，还要跟着写

`LyricsSourcePriorityEnabled`（Bool）没删，且用户每次改模式都会被同步写一次
（`mode == .sourceFirst`）。理由是降级：装回旧版本时它是唯一能读到的开关。
第三种模式在旧版没有对应物，映射成「关」而不是「开」—— 那一档里分数说了算，与新模式更接近。

## 分数在搜索面板是看得见的

搜索面板（`SearchLyricsViewController`）的表格有一列 `Score`，显示的就是
`effectiveQuality` —— 排序真正比较的那个数，不是 LyricsKit 的原始 `quality`。
封面相似度加分或播放器自家歌词源的加分生效时，那一格会写成 `0.92 (+0.15)`，把加分单独摊开；
两项都生效时括号里是两项之和。合成一个数是有意的：这一行是不是播放器自家的来源，
看同一行的「来源」列就知道，括号里只需要回答「这一行为什么高」。

这一列存在的理由是排查：排序出问题时，最先要分清「分数算错了」还是「比较写错了」，
而分数不可见的时候这两件事从症状上完全一样。也因此 `effectiveQuality`、
`effectiveArtworkBonus` 与 `effectivePlayerLyricsSourceBonus` 在 `Global.swift` 里是 internal
而非 private —— 面板要读它们，
且必须读**同一份**实现，另写一份显示用的算法就等于让显示的分数和排序用的分数各说各话。

## 关掉的歌词源

> 对应提案：[0031 歌词源可以单独关掉](../Evolutions/0031-lyrics-source-switches.md)

歌词源表的「来源」一列是复选框，取消勾选的源**根本不创建**：`AppController.updateLyricsManager()`
读 `LyricsSourceSwitches`，只为开着的源调用 `create(_:)`。自动搜索、搜索面板、「下一条候选」的补搜
都读同一个 `lyricsManager`，所以这一处过滤三条路径同时生效。没有选择「照常搜、再丢结果」，
因为用户关掉一个源常常就是因为它连不上或很慢，请求照发等于没关。

几处容易改错的地方：

- **存的是关掉的源，不是开着的源**（`DisabledLyricsSources`）。空列表就是全开，LyricsKit 以后新加的源
  默认也开着；反过来存的话，新源会悄悄地对所有老用户关闭。
- **存 `ServiceID.rawValue`，不是显示名。** 优先级列表 `LyricsSourcePriorityOrder` 存的是显示名，
  那是历史做法；显示名是界面文字，一旦改了，按它存的开关就对不上了，源会悄悄重新打开。
  设置页的行仍是显示名，靠 `ServiceID.allCases` 映射回去。
- **读不懂的值原样保留。** 更新的版本写入的未知源标识符，在旧版本里切换别的源时不会被抹掉。
- **表在三种排序模式下都可以点。** 原来「只按匹配分数」模式下整张表 `isEnabled = false`，
  而这正是默认模式，复选框放进去就点不了。现在只是序号淡化、`writeRowsWith` 拒绝拖动。
- **Apple Music 关掉时 token 检查照做**：实验室页的状态行要它的结果；检查通过后还要开着才装进去。
- **管不到已保存的歌词。** 歌词库 `.lrcx` 不记录来源（`[by:]` 是歌词作者），没法判断某个文件来自哪个源，
  所以关掉一个源不会让已经存下来的它的歌词消失；要重新搜，用「忽略已保存的歌词」或手动搜索。
- **生效时机是下一次搜索。** 切换后立即重建 `lyricsManager`，但正在跑的搜索沿用旧的那组源，
  屏幕上的歌词和本首歌的候选也不动。

## 播放器自家的歌词源

> 对应提案：[Draft 歌词来源和正在播放的 App 是同一家时加分](../Evolutions/draft-player-lyrics-source-bonus.md)

歌在 QQ 音乐、网易云音乐、酷狗音乐或「音乐」里播放时，同一家歌词源（QQMusic、NetEase、Kugou、Apple Music）
的结果在 `effectiveQuality` 里加 `PlayerLyricsSourcePolicy.matchBonus`（0.1）。理由是那个 App 的歌词按它正在放的
这一版录音对的时间轴，别家同名的歌词可能来自另一个版本。开关是歌词源页的 `PlayerLyricsSourceBoostEnabled`，
默认开（`UserDefaults.plist`）。

几处容易改错的地方：

- **标记在歌词到达时打一次，不在比较时现算。** 两处 `lyricsReceived`（`AppController`、`SearchLyricsViewController`）
  在歌词进候选池或面板列表之前调 `markPlayerLyricsSource(playerBundleIdentifier:)`，把结果存进
  `metadata.data["LyricsX.IsFromPlayerLyricsSource"]`。系统级正在播放跟着最后发声的 App 走，比较时去读播放器的话，
  同一个候选池会在两次插入之间换一套比较规则，有序插入就不可信了。也因为在进池之前写，这时还没有读者，
  不需要像封面加分那样切到 `lyricsDisplay` 队列。新增一个歌词进来的入口时记得也打这个标记，
  否则那条路进来的歌词永远不加分。
- **存的是「是不是」，不是加分值。** 封面加分存的是 0.15 这个值；这里值由策略给出，调 0.1 不用管已经打过标记的歌词。
- **bundle ID 按点分段匹配，不按子串。** `com.tencent.qqmusic*`、`com.netease.163music` / `cloudmusic`、`com.kugou.*`、
  正好三段的 `com.apple.music`。子串会把名字里碰巧带这几个字母的别家 App 算进来；按段匹配也让 Mac 版和 iPad 版
  （`com.tencent.QQMusicMac`、`com.tencent.QQMusic.D5Q73692VW`）一起命中，腾讯、网易的其他 App 不命中。
  酷狗的 Mac 版本机没装、bundle ID 没核对过，靠 `com.kugou.` 前缀兜住。
- **0.1 的分寸。** 够盖过一项 0.05 的特性加分（翻译、行内时间标签）加一点时长差；对方两项都有、自家一项都没有时
  正好打平，留给先到的那条。歌名或歌手对不上的结果落后 0.3 以上，翻不了盘。测试里的分数取自真实的搜索面板。
- **「按歌词源顺序优先」模式下它不起作用。** 那个模式先比来源位置，只在同一来源内比分数，而同一来源的结果要么
  全都加、要么全都不加，所以设置页在这个模式下把复选框设为不可用。
- **本地歌词永远不加分**：歌词库 `.lrcx`、内嵌歌词、旁边的 `.lrc` 都没有 `metadata.service`。
- **取当前播放器 bundle ID 的逻辑在 `MusicPlayers.Agent.currentPlayerBundleIdentifier`**（`SelectedPlayer.swift`），
  与按播放器设歌词偏移的 `PlaybackRouteLyricsOffsetController` 共用一份。
- **切换开关不重排已有候选**，与封面加分、排序模式一样，下一次搜索或面板下一次重排时生效。

## 已知空白

`lyricsHasHigherPriority` 这一层（读偏好、把 `Lyrics` 摊成分数与源下标）仍然没有自动化测试，
因为它依赖 `defaults`，而 app target 没有测试宿主。可测的部分已经全部外移到
`LyricsSourceOrderingPolicy`；留在 app 侧的只有两件事，改动时请当心：

- 源下标只在 `mode.usesSourcePriorityOrder` 为真时才去算（省掉整张列表的 lowercase），
  否则两边都填 `unlistedSourceIndex`，让所有涉源的判断落空、退到比分数；
- `effectiveQuality` 先把 NaN 归零**再**加封面加分和播放器自家歌词源的加分。顺序反了的话
  `NaN + bonus` 仍是 NaN，policy 的兜底会把加分一起吞掉。
