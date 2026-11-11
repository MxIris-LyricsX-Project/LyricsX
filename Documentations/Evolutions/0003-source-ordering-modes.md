# 0003 - 歌词源排序模式：分数优先，同分再看源

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-11
- **所属愿景**: 无
- **关联提案**: [0001 切换到下一条歌词候选](0001-next-lyrics-candidate.md)（候选池与手动搜索面板都用本提案要改的这个比较函数排序）
- **实现分支 / PR**: `develop`
- **配套文档**: [歌词候选的排序](../Internal/LyricsSourceOrdering.md)

## 摘要

把现有的「启用歌词源优先级」复选框改成三选一的排序模式：**只按匹配分数** /
**歌词源优先** / **分数优先，同分再按歌词源**。新增的第三种是本提案的目的 —— 跨来源先比匹配
分数，分数接近到分不出高下时才由歌词源顺序决定。「分数接近」需要一个容差（定为 **0.02**），
否则两个浮点分数永远不会相等，源顺序永远轮不到生效。

比容差取值更要紧的是：新规则**必须仍是全序**，否则「自动匹配选中的」和「搜索面板列表第一条」
会开始不一致 —— 那正是促成这份提案的那次排查里最难查的一类症状。

## 动机

现在的「启用歌词源优先级」是**压倒性**的：只要两条结果来自不同的源，就完全按源顺序决定，
匹配分数一概不看（`Global.swift:241-253`）。

后果是，用户把 QQ音乐排在第一之后，一条明显不匹配的 QQ音乐结果（比如标题只沾边、时长差
30 秒）会稳压一条完美匹配的酷狗结果。用户想表达的其实是「**其他条件差不多时**我更喜欢 QQ音乐」，
而不是「QQ音乐永远对」。

现有的两种状态都给不了这个：关掉是完全不看源，打开是完全不看分数。中间没有档位。

## 前期调研

- **现有比较函数** —— `lyricsHasHigherPriority(_:over:)`（`Global.swift:240`）：
  开启源优先级时先比源在列表里的下标，下标不同即定胜负；相同（含两者都不在列表里）才比
  `quality + artworkMatchBonus`。
- **分数怎么来的** —— `Lyrics.quality`（LyricsKit 的 `Lyrics+Quality.swift`）：
  艺人相似度 ×0.45 + 标题相似度 ×0.40 + 时长相似度 ×0.15，钳制到 [0,1]，
  再 +0.05（有翻译）、+0.05（有逐字时间标签）、−0.3（疑似伴奏/卡拉OK版）。
  分数按 `metadata.quality` **缓存**，且依赖当次搜索请求的关键词。
- **容差量级的实测依据** ——
  时长相似度是 `1 − 0.5 × (Δt/10)²`，权重 0.15，所以时长差 5 秒只造成 **0.019** 的分差、
  差 3 秒只有 **0.007**。而「有无翻译」是 0.05。取 0.02 作容差，正好吸收 5 秒以内的时长抖动，
  同时保留翻译/逐字歌词这两档加分的区分度。
- **两个调用方** —— 自动匹配用**增量比较**（新结果 vs 当前冠军，`AppController.swift:512-520`），
  搜索面板与 0001 的候选池用**插入排序**（`SearchLyricsViewController.swift:132`、
  `PriorityOrderedCandidatePool.insert`）。
  **这两种在全序下等价、在非全序下会给出不同的第一名。**
- **现有偏好** —— `LyricsSourcePriorityEnabled: Bool` + `LyricsSourcePriorityOrder: [String]`
  （`Global.swift:198`），UI 在 Source 页（`PreferenceSourceViewController`，复选框 + 可拖拽表格）。
- **已有迁移设施** —— `UserDefaultsMigrator`（`LyricsX/Component/UserDefaultsMigrator.swift`）
  已有一次性迁移的模式（按 key 记录完成标记），布尔到枚举的迁移可以沿用。

## 提议方案

### 一、三种模式

```swift
enum LyricsSourceOrderingMode: Int {
    case qualityOnly = 0          // 只按匹配分数（等价于现在关闭源优先级）
    case sourceFirst = 1          // 歌词源优先（等价于现在开启）
    case qualityFirstSourceTieBreak = 2   // 分数优先，同分再按歌词源（新增）
}
```

存为 `LyricsSourceOrderingMode: Int`。迁移：旧值 `false → 0`、`true → 1`，一次性执行并打标记。
歌词源顺序表在模式 1 和 2 下都可编辑，模式 0 下置灰。

### 二、「同分」用分数分桶来判定，而不是直接比大小

新模式的比较是 `(分数桶 降序, 源下标 升序)` 的字典序：

```
bucket(lyrics) = floor(effectiveQuality(lyrics) / 0.02)
```

**为什么必须是分桶，而不是「若 |q₁ − q₂| < 0.02 则比源、否则比分数」**：后者不满足传递性。
举个真会发生的例子，容差 0.02、源顺序 A < B：

- a（源 A，0.900）与 b（源 B，0.915）：分差 0.015 < 0.02 → 同分 → a 胜（源 A 靠前）
- b（源 B，0.915）与 c（源 B，0.925）：分差 0.010 < 0.02 → 同分 → 同源比分数 → c 胜
- a（源 A，0.900）与 c（源 B，0.925）：分差 0.025 > 0.02 → 比分数 → c 胜

得到 a > b、c > b、c > a —— 看似还行，但把 c 换成 0.918 就会出现 a > b、b ≈ c、c > a 的环。
排序结果随此变得依赖到达顺序，于是**自动匹配的冠军和面板列表第一条会对不上**。
本提案的动机排查里，用户报告的正是这类「两边不一致」的困惑，绝不能新造一个同类来源。

分桶把分数量化到 0.02 的网格上，比较退化成两个整数的字典序，**传递性由构造保证**。
代价是网格边界：0.0199 与 0.0201 落在不同桶，虽然只差 0.0002 也不算同分。
这个抖动是随机的、非系统性的，且换来一条硬性质 —— **分差 ≥ 0.02 时分数一定说了算**
（跨 0.02 必然跨桶）。

### 三、封面加分照旧参与

`effectiveQuality` 仍是 `quality + artworkMatchBonus`（该加分默认关闭）。加分是后到的，
会改变桶号，因此仍需 0001 已有的 `resort()` / 重新比较路径，无需新增机制。

### 非目标

- **不修复「歌词不对」的缓存问题** —— 那是 [0002](0002-always-ignore-cached-lyrics.md)。
  本提案只改排序，不改读哪些候选。
- **不消除自动匹配与搜索面板的候选集合差异**（自动 `limit: 5` + 去括号标题、面板 `limit: 8`
  + 原标题；严格搜索只作用于自动路径）。那是另一件事，值得单独一份提案。
- **不改 `quality` 的算法本身** —— 权重、加分、惩罚项全部保持现状。
- **不做按源的分数加权/信任度** —— 见替代方案。
- **不让容差可配置** —— 多一个数字旋钮，用户无从判断该调多少；先用固定值，
  确有需要再单开提案。

## 详细设计

```swift
// Global.swift
static let lyricsSourceOrderingMode = Key<Int>("LyricsSourceOrderingMode")

/// Scores within this distance count as "the same" for ordering purposes.
/// Sized against the real spread of `Lyrics.quality`: a 5-second duration
/// mismatch moves the score by ~0.019, while having a translation moves it
/// by 0.05 — so this absorbs timing noise without erasing the translation
/// and word-by-word bonuses.
private let sourceOrderingQualityTolerance = 0.02

func lyricsHasHigherPriority(_ new: Lyrics, over existing: Lyrics) -> Bool {
    switch currentSourceOrderingMode() {
    case .qualityOnly:
        return effectiveQuality(new) > effectiveQuality(existing)

    case .sourceFirst:
        let newIndex = sourcePriorityIndex(new)
        let existingIndex = sourcePriorityIndex(existing)
        if newIndex != existingIndex {
            return newIndex < existingIndex
        }
        return effectiveQuality(new) > effectiveQuality(existing)

    case .qualityFirstSourceTieBreak:
        // Quantised comparison, not `abs(a - b) < tolerance`: the latter is
        // not transitive, and a non-transitive relation makes the insertion
        // sort and the running-maximum disagree on the winner.
        let newBucket = qualityBucket(new)
        let existingBucket = qualityBucket(existing)
        if newBucket != existingBucket {
            return newBucket > existingBucket
        }
        return sourcePriorityIndex(new) < sourcePriorityIndex(existing)
    }
}

private func qualityBucket(_ lyrics: Lyrics) -> Int {
    Int((effectiveQuality(lyrics) / sourceOrderingQualityTolerance).rounded(.down))
}

private func effectiveQuality(_ lyrics: Lyrics) -> Double {
    // NaN compares false against everything, which would silently reduce the
    // insertion search to arrival order — the reason this clamp already exists.
    (lyrics.quality.isFinite ? lyrics.quality : 0) + effectiveArtworkBonus(lyrics)
}
```

`sourcePriorityIndex` 是现有源下标查找（不在列表里的取 `Int.max`）原样抽出。

**迁移**（`UserDefaultsMigrator` 新增一步，标记键 `Migration.SourceOrderingMode.v1`）：

```swift
if userDefaults.object(forKey: "LyricsSourceOrderingMode") == nil {
    let legacyEnabled = userDefaults.bool(forKey: "LyricsSourcePriorityEnabled")
    userDefaults.set(legacyEnabled ? LyricsSourceOrderingMode.sourceFirst.rawValue
                                   : LyricsSourceOrderingMode.qualityOnly.rawValue,
                     forKey: "LyricsSourceOrderingMode")
}
```

旧键保留不删，便于回退到旧版本。

## 替代方案考量

- **把源顺序折算成分数惩罚**（`adjusted = quality − sourceIndex × δ`）—— 天然全序、
  没有桶边界抖动，很有吸引力。否掉的原因是 δ 无法两头兼顾：取 δ = 容差，
  第 6 个源就要背 0.10 的惩罚，而 `quality` 的实际动态范围也就 0.3–1.0，
  等于把低优先级源永久压死，退化成「源优先」；取 δ = 容差/源数量，
  相邻两源之间的实际容差只剩 0.0033，用户设的「同分看源」几乎不生效。
  分桶虽然有边界抖动，但**不累积**，第 6 个源和第 2 个源面对同样的门槛。
- **直接改变现有复选框「开」的语义**（开 = 新的同分看源）—— 改动最小，但会在用户毫不知情的
  情况下改掉他们已经调好的行为，且再也回不到旧行为。
- **保留复选框、下面加一个「仅在分数相同时生效」子选项** —— 与三选一等价，
  但两个嵌套复选框有一个组合（关 + 勾选子项）是无意义的，单选组没有这个问题。
- **按源给固定信任度加权**（如 QQ音乐 ×1.05）—— 表达力更强，但要求用户理解乘性权重，
  且与「拖拽排序」这个已有的交互模型冲突。
- **容差做成可配置** —— 见非目标。

## 影响

### 用户可见变化

- Source 页的「启用歌词源优先级」复选框变为三个单选项：
  「只按匹配分数」/「歌词源优先」/「分数优先，同分再按歌词源」。
- 已开启源优先级的用户迁移到「歌词源优先」，**行为与现在完全一致**；未开启的迁移到
  「只按匹配分数」，同样一致。**没有人的行为会在升级后自己改变**，第三种模式需要手动选。
- 选择第三种模式后，歌词源顺序表仍然可拖拽，只是话语权降为「分数接近时的裁决者」。

### 可发现性

- 三个选项直接列在 Source 页原复选框的位置，替换它，不新增页面。
- 每个选项需要一行说明，尤其第三项要点明「分数差在很小范围内才算接近」，
  避免用户以为源顺序完全不起作用。

### 数据与配置兼容

- 新增 `LyricsSourceOrderingMode: Int`；旧的 `LyricsSourcePriorityEnabled: Bool` 保留不删，
  降级回旧版本仍可用。
- 迁移一次性执行并打标记；迁移失败（读不到旧值）时落到 `qualityOnly`，与出厂默认一致。
- `LyricsSourcePriorityOrder: [String]` 不变。

### 平台与最低版本

不变（macOS 12+）。无平台差异。

### 发布

不需要新权限、entitlement 或隐私清单条目。不影响公证与 Sparkle 更新。

### 对已保存歌词的影响

排序只影响「这次搜索选哪条」，不会重写任何已保存的歌词文件。已经存下的结果不受影响 ——
想让新规则作用于它们，需要配合 [0002](0002-always-ignore-cached-lyrics.md) 或手动重搜。

## 落地步骤

1. 引入 `LyricsSourceOrderingMode` 与新偏好键，`lyricsHasHigherPriority` 按模式分派；
   模式 0/1 的行为与现状逐字等价。
2. `UserDefaultsMigrator` 加迁移步骤与标记。
3. 实现 `qualityFirstSourceTieBreak` 分支与分桶。
4. Source 页 UI 换成单选组，改 `PreferenceSourceViewController` 的读写与置灰逻辑，
   补 `Preferences.xcstrings` 文案。
5. 测试：**把排序判定抽成不依赖 `defaults` 的纯函数**（输入：分数、源下标、模式、容差），
   放进 `LyricsXFoundationTests`。必须覆盖的三条：
   - 三种模式各自的胜负判定；
   - **传递性**：随机生成若干 (分数, 源下标) 组合，断言比较关系无环、且插入排序的结果与
     「反复取最大值」的结果一致 —— 这条正是本提案最想守住的性质；
   - 分差恰好 ≥ 容差时分数一定赢。

**收尾时必须判断两件事**（结果写进决策日志）：配套文章、新术语（「分数桶」「同分容差」
大概率要进术语表）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-11 | Created as Draft | 起因：用户希望跨来源先按分数排，分数一致时才按歌词源顺序 —— 现有的源优先级是压倒性的，一条明显不匹配的高优先级源结果会稳压完美匹配的低优先级源结果。 |
| 2026-08-11 | 确定呈现方式 | 用户选择把复选框换成三选一单选组，而非「复选框 + 子选项」。旧设置自动迁移，无人的现有行为被改变。 |
| 2026-08-11 | 确定同分容差 | 用户选择 **0.02**。依据：时长差 5 秒约造成 0.019 分差，而「有无翻译」是 0.05 —— 0.02 恰好吸收时长抖动而保留翻译/逐字加分的区分度。 |
| 2026-08-11 | 确定用分桶而非差值比较 | 差值比较（`abs(a−b) < 容差`）不满足传递性，会让「增量取最大」与「插入排序取第一」给出不同冠军 —— 而这正是本次排查中用户困惑的症状类型。分桶以边界抖动为代价换取构造性的传递性。 |
| 2026-08-11 | Draft → Accepted | 用户批准，实现开始。 |
| 2026-08-11 | 「分差 ≥ 容差时分数一定说了算」被实测推翻 | 提案第二节把这条写成了硬性质，落地时的扫描测试当场证否：`0.12 + 0.02` 在 `Double` 里是 `0.13999999999999999`，实际间隔 0.01999999999999999，两者落进同一个桶。成立的版本是「分差**严格大于**容差」。测试改用 1.001 倍容差断言保证，另加一条把 0.12 / 0.18 这两个反例钉住的用例，防止保证日后被重新说大。提案按规矩保持原貌。 |
| 2026-08-11 | 旧键改为跟随写入 | 提案只说「旧键保留不删」。实现进一步在每次改模式时同步写 `LyricsSourcePriorityEnabled = (mode == .sourceFirst)`，否则「便于回退到旧版本」这个理由只对从未改过模式的用户成立。第三种模式在旧版没有对应物，映射成「关」——那一档里分数说了算，与新模式更接近。 |
| 2026-08-11 | Accepted → Implemented | 配套文章：写了[歌词候选的排序](../Internal/LyricsSourceOrdering.md)（传递性为什么是全部难点、分桶 vs 比差值的反例、迁移的顺序约束）。新术语：「分数桶」「同分容差」按提案预判登记进项目术语表。落地步骤第 5 步的三条测试全部落实，其中传递性与「两种用法冠军一致」写成了属性测试。 |
