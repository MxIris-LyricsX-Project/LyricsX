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
封面相似度加分生效时，那一格会写成 `0.92 (+0.15)`，把加分单独摊开。

这一列存在的理由是排查：排序出问题时，最先要分清「分数算错了」还是「比较写错了」，
而分数不可见的时候这两件事从症状上完全一样。也因此 `effectiveQuality` 与
`effectiveArtworkBonus` 在 `Global.swift` 里是 internal 而非 private —— 面板要读它们，
且必须读**同一份**实现，另写一份显示用的算法就等于让显示的分数和排序用的分数各说各话。

## 已知空白

`lyricsHasHigherPriority` 这一层（读偏好、把 `Lyrics` 摊成分数与源下标）仍然没有自动化测试，
因为它依赖 `defaults`，而 app target 没有测试宿主。可测的部分已经全部外移到
`LyricsSourceOrderingPolicy`；留在 app 侧的只有两件事，改动时请当心：

- 源下标只在 `mode.usesSourcePriorityOrder` 为真时才去算（省掉整张列表的 lowercase），
  否则两边都填 `unlistedSourceIndex`，让所有涉源的判断落空、退到比分数；
- `effectiveQuality` 先把 NaN 归零**再**加封面加分。顺序反了的话
  `NaN + bonus` 仍是 NaN，policy 的兜底会把加分一起吞掉。
