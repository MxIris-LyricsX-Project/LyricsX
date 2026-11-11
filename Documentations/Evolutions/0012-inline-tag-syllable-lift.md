# 0012 - 行内标签歌词也走 Music 26.6 的逐音节抬高

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **关联提案**: [0011 行内抬高改成 Music 26.6 的逐音节软弹簧](0011-apple-music-syllable-lift.md)（结构化路径的同一机制；该提案明确把 `.inferred` 留待另议）
- **配套文档**: [Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md)（factor 与语言能力、逐音节抬高、2026-09-06 修正）

## 摘要

用户对比后发现「英文歌行内动画一上一下，中文歌像掀起一块布」。查证后不是语言差异：当时播的是 Kugou 版
STAY，只有 `[tt]` 行内标签，走的是 0011 有意保留的 `.inferred` 老路——每个 phrase 满强度放大 14%、发光、逐字
抬起再收回；对比的中文歌全是 Apple Music 结构化歌词，走的是 0011 移植的逐音节软弹簧抬高，抬起后不落回。
酷狗、QQ 音乐的 `[tt]` 是真实的逐字（英文逐词）时间轴，网易云部分歌也有，只有 LIBLRC 完全按行；一个 `[tt]`
段就是 Music 里一个音节的可靠替身。本提案让 `[tt]` 歌词在默认档下也走 Music 的机制：每段抬 3 pt 且不落回，
只有 Music 会判为 `.factor` 的段（语言有 `emphasis` 能力、超过 1 秒、不超过 7 字）才放大发光；老观感原样留在
`fullEmphasis` 档，供并排比较。

## 方案

- `WordEmphasisPlan.make`：判定只看策略档，不再看 timing 来源。`appleMusic26` 下 `.inferred` 与 `.synchronized`
  同一条门槛（语言能力、时长大于 1 秒、不超过 7 字、factor 大于 0，首字等待一个 stagger），不满足即 `nil`；
  `fullEmphasis` 下两种来源都保持 factor 1、首字零延迟的老公式。
- `SyncedLyricsLineContentLayer`：
  - `makeSyllableGroups` 对带时间的 `.inferred` 词也建一组（整词一组，`[tt]` 没有更细的音节），`.none` 的判定
    落到 `updateSyllableLifts` 的软弹簧抬高上；`fullEmphasis` 下 `decideEmphasis` 仍返回 swell 计划，音节组不用。
  - `decideEmphasis` 在 `appleMusic26` 下对 `.inferred` 词用词自己的时长和 glyph 数做判定，不再用
    `assignEmphasisTiming` 拼出的 phrase 时长——否则一句英文会整句超过 1 秒而全部放大。词长按去掉首尾空白后的
    字符数算，`[tt]` 的英文词带着尾随空格。
  - `LineTextLayout` 的 phrase envelope 与 rapid fallback 不动，只有 `fullEmphasis` 档还在用它们。
- 假设：`StructuredEmphasisPolicy` 与它的隐藏键 `AppleMusicLyricsStructuredEmphasisPolicy` 不改名，直接扩大适用范围
  到行内标签歌词，用户已经在用这个键做 A/B；LIBLRC 等纯按行歌词没有词级时间，仍只有整行高亮，不在本提案范围。
- 测试：新增 `InlineTagSyllableLiftProbes`（Kugou 版 STAY 一句的真实逐词时间：默认档下软弹簧抬高、不放大不发光、
  未唱的词不动、抬起后不再下落；1.46 秒的 `stay` 按 factor 0.46 放大发光；`fullEmphasis` 档保留老观感），修复前红。
  `AnimationPlanTests` 的 `.inferred` 用例改成按档断言。`LineEmphasisProbes`（逐字中文 `[tt]`）在默认档下重跑，
  其断言（不裁切、抬高有界、sweep 上色、不漂移、不在弧顶停住）对新机制同样成立。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-06 | Created as Draft | 用户报告英文歌行内动画「一上一下」；查证是 Kugou `[tt]` 歌词走了 `.inferred` 老路，不是语言差异。 |
| 2026-09-06 | 纠正「Kugou 时间轴是均分的」判断 | 均分的只有文件开头署名行；正式歌词行逐词时长与 Apple Music 同曲相差不到 0.1 秒。用户指出酷狗、QQ 音乐都是逐字歌词。 |
| 2026-09-06 | Draft → Accepted → In Progress | 用户回复「改」。走轻量档：一处机制扩展，不改公开接口。 |
| 2026-09-06 | 老观感留在 `fullEmphasis` 档而不是删掉 | 用户习惯并排比较两档再定；隐藏键已存在，不新增开关。 |
| 2026-09-06 | `[tt]` 段整词一组，不再拆更细 | `[tt]` 没有音节层级；酷狗英文逐词、中文逐字，本身就是 Music 音节的粒度。 |
| 2026-09-06 | `WordEmphasisPlan.make` 去掉 `timingSource` 参数 | 判定只看策略档；保留一个不参与判定的参数会误导调用方。`TimingSource` 枚举仍由 `LineTextLayout.Word` 使用。 |
| 2026-09-06 | 验证 | `InlineTagSyllableLiftProbes` 三条默认档探针与 `AnimationPlanTests.inferredTimingFollowsMusicsGateByDefault` 修复前红（stiffness 537 而非 14、scale 1.14、glow 0.4、factor 恒 1）、修复后绿；`LineEmphasisProbes` 逐字中文 `[tt]` 探针在默认档下不改即通过；LyricsXPackage 全量 183 项、27 个 suite `--no-parallel` 退出码 0；workspace Debug 隔离构建成功；SwiftFormat lint 本次改动文件无差异（既有的 `LyricsLibraryFixtureProbes.swift:298` 一处 wrapIfStatementBodies 未动）。未启动应用做交互式 UI 验证。 |
| 2026-09-06 | 配套文档判断 | **更新既有实现说明**：「factor 与语言能力」两档策略段、「逐音节抬高」段改为覆盖行内标签歌词，已知边界条目改为指向修正记录，新增 2026-09-06 修正记录；`CLAUDE.md` 登记 `InlineTagSyllableLiftProbes`。不另写指南。 |
| 2026-09-06 | 术语表判断 | **不登记**。inline tag、segment 都是既有用语。 |
| 2026-09-06 | In Progress → Implemented | 代码、测试与文档就绪。 |
| 2026-09-06 | 落地为 0012 | 与代码同一 commit 进入 `develop`。 |
