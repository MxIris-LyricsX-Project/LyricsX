# 0011 - 行内抬高改成 Music 26.6 的逐音节软弹簧

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **关联提案**: [0009 行间 cascade 对齐 Apple Music 26.6](0009-apple-music-line-cascade-parity.md)（结构化行内两档策略的来源）
- **配套文档**: [Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md)（行内动画、factor 与语言能力、2026-09-06 修正）

## 摘要

用户报告 Apple Music 来源（结构化 timing、带翻译）的歌词行内动画「一顿一顿」，明确不是掉帧。重新反编译
`Music.i64` 后确认是机制搬错了地方：Music 的 3 pt 抬高是**逐音节**的，音节一唱到就在 `mass 1 / stiffness 14 /
damping 7` 的软弹簧上浮起并停住，与语言和词长无关；逐字放大加发光的 swell 只给 `Lyrics.Word.emphasis == .factor`
的词（语言有 `emphasis` 能力、词长大于 1 秒、不超过 7 字符），其余词是 `.none`，没有任何逐字动画。本项目此前把抬高
塞进了逐词 `WordEmphasisPlan`：factor 0 的词只剩抬高，却用「周期等于词长、临界阻尼、逐字 stagger」的快弹簧，
短词因此一个接一个弹起。

本提案把结构化路径改成 Music 的形状：`.none` 的词不再安排任何逐字动画，改由逐音节软弹簧抬高；`.factor` 的词保留
现有 swell（它自带 `− syllableLift` 的落点）。`.inferred`（只有 `[tt]`）路径不动。

## 方案

### 一、Music 26.6 的实际机制（本次核对结果，地址均为 `Music.i64`）

- `Lyrics.Word.emphasis` 是 `enum Emphasis { case factor(Double), case none }`，在 `sub_1001C2DD4` 建模时决定。
  语言能力表 `sub_1001C28A4`：`Lyrics.Capability` 三个 case 为 `gradient` / `lift` / `emphasis`，ar/he/zh/ja 只有前两个，
  其余语言三个都有。四项同时满足才是 `.factor(min(d, 2) − 1)`：能力含 `emphasis`、词长大于 1 秒、不超过 7 字符、
  factor 大于 0；背景和声一律 `.none`。
- Layer 树按 emphasis 分叉（`sub_10018DA78`）：`.factor` 的词按字建 `GlyphLayer`；`.none` 的词按音节建 `SyllableLayer`，
  单音节词直接以 `SyllableLayer` 充当词 layer。两种 layer 不会同时存在。
- 每帧 `sub_1001689D4`：先对每个词的每个音节调 `sub_1001897C0(未唱)`，音节状态翻转时给 `Syllable.layer` 加
  `translation(0, −syllableLift)`（`sub_100189C0C`），动画是 `CASpringAnimation(mass 1, stiffness 14, damping 7)`，
  时长取 `settlingDuration`；倒带同一弹簧回恒等。再对词调 `sub_10018B2B4`，`.none` 直接返回。
  transliteration 行跳过音节循环。颜色由 `gradientLayer` 的 sweep 负责，`sub_1001897C0` 不改颜色。

### 二、本项目的改动

1. `WordEmphasisPlan.make` 返回 `WordEmphasisPlan?`：结构化路径在 `appleMusic26` 策略下 factor 不大于 0 即返回 `nil`
   （Music 的 `.none`）。`fullEmphasis` 与 `.inferred` 仍总是返回计划。
2. 新增 `SyllableLiftPlan`：mass 1 / stiffness 14 / damping 7 的 `SpringTimingParameters`。
3. `SyncedLyricsLineContentLayer`：
   - `WordNode` 记录音节组（结构化词按 `LineTextLayout.Word.Syllable.glyphIndices`，没有音节的词整词一组）和一次性的
     `EmphasisDecision`（词首次到期时按当前策略决定，策略改动仍在下一个词生效）。
   - 每帧在 `scheduleDueWords` 之后跑 `updateSyllableLifts`：`.syllableLift` 的词，`elapsed` 越过音节起点则整组 glyph
     用软弹簧移到 `sungOrigin`，退回起点之前则同一弹簧回 `restingOrigin`；`resetEmphasis()` 归位并清状态。
   - `.wordEmphasis` 的词走原有 `emphasize(_:plan:)`，逻辑不变。
4. 测试：新增 `SyllableLiftProbes`（真实 Core Animation 时间轴：起点前不动、同音节整组同动、90% 抬高耗时不少于
   0.5 秒、短词不放大、落点 3 pt；长词仍放大且抬高不叠加），修复前在 HEAD 上红。`AnimationPlanTests` 改为断言
   `.none` 返回 `nil` 并固定软弹簧常量；`LineEmphasisStructureProbes` 断言中文词的位置动画就是 stiffness 14 的弹簧。

### 不做的事

- `.inferred` 路径不改：本地库两千多首里几乎全是 `[tt]`，用户认可的满强度观感保留；是否也换成逐音节抬高另议。
- 不引入独立的音节 layer 层级：本项目 glyph layer 由 `LayerPropertyAnimator` 按 position 驱动，整组同一弹簧同一目标
  与 Music 的 layer transform 观感一致。
- 不改 `WordEmphasisPlan` 的 swell 公式与 `sungOrigin` 落点。

## 决策日志

| 日期 | 决策 | 理由 |
|---|---|---|
| 2026-09-06 | Created as Draft | 用户报告结构化歌词行内动画「一顿一顿」，并澄清不是流畅度问题。 |
| 2026-09-06 | 定性为机制错误而非常量错误 | `Music.i64` 反编译：抬高在 `sub_1001897C0` 逐音节软弹簧，swell 只给 `.factor`；本项目把抬高并进了逐词快弹簧。 |
| 2026-09-06 | Draft → Accepted | 用户回复「修」。 |
| 2026-09-06 | 走轻量档，不重开行间 cascade 提案 | 那份提案已落地；本次只改行内结构化路径的机制，关联而不改写。 |
| 2026-09-06 | `.inferred` 不动 | 保留用户已认可的观感；只对齐有结构化数据的路径。 |
| 2026-09-06 | 验证 | `SyllableLiftProbes` 在 HEAD 上退出码 1、修复后通过；LyricsXPackage 174 项、25 个 suite `--no-parallel` 通过，退出码 0；workspace Debug scheme 隔离 DerivedData 构建成功，退出码 0；SwiftFormat lint 通过。未启动应用做交互式 UI 验证。 |
| 2026-09-06 | 配套文档判断 | **更新既有实现说明**：改写「factor 与语言能力」、新增「逐音节抬高」、把 2026-09-06 待修段改为修正记录；`CLAUDE.md` 登记新探针命令。不另写指南。 |
| 2026-09-06 | 术语表判断 | **不登记**。syllable、capability、spring 都是通用技术词。 |
| 2026-09-06 | Accepted → Implemented | 代码、测试与文档就绪。 |
| 2026-09-06 | 落地为 0011 | 与代码同一 commit 进入 `develop`。 |
