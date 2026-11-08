# Draft - 行内扫光改按 Music 26.6 的逐音节线性推进

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **实现分支 / PR**: `feature/apple-music-syllable-sweep`
- **关联提案**: [0011 行内抬高改成 Music 26.6 的逐音节软弹簧](0011-apple-music-syllable-lift.md)、[0012 行内标签歌词也走 Music 26.6 的逐音节抬高](0012-inline-tag-syllable-lift.md)
- **配套文档**: [Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md)（「扫光」一节）

## 摘要

用户反馈行间动画已经对齐，行内动画还有些对不上 Music。0011、0012 对齐了抬高与放大，扫光（已唱与未唱之间
那道 30 pt 渐变边界）从没对照二进制核对过。2026-11-08 在 Music 26.6 里逐函数读完扫光后发现四处不同：我们按
字符数占比乘整句宽度逐帧摆位置，不看字宽，英文和换行的长句里扫光会和正在抬起的音节错开；Music 给每个视觉行
单独一层渐变，进入新音节时按该音节的实际字形坐标发一段线性动画，渐变前沿只比音节末尾多出羽化宽度的一小截；
词尾空格在词的最后一个音节里扫过；扫光、逐音节抬高、放大用的都是「播放时间 + 0.1 秒」，我们只有放大加了这
0.1 秒。本提案按 Music 的结构重写扫光、给扫光和抬高补上提前量，旧扫光留在隐藏开关后面供并排比较。

## 方案

**Music 26.6 的做法**（`Music.i64`；每帧入口 `sub_10016E8FC` / `sub_10016E348`，每个视觉行 `sub_1001689D4`）：

- 传给每帧更新的时间 = 播放时间 + `animationHeadstart`（specs+0x220，0.1 秒；`0x10016E95C` 的 `FADD`）。
  逐音节抬高 `sub_1001897C0`（以 `time < syllable.startTime` 判断未唱）和放大 `sub_10018B2B4` 收到的是同一个时间，
  被调函数自己都不再加。
- 每个视觉行一层 `LineProgressGradientLayer`：左边实色，右端 `lineProgressionGradientFeather`（30 pt）渐变到透明
  （`sub_1001EB740`），原点固定，推进靠改宽度（`sub_10016A8F8` 建层）。
- 时间落进某个音节 [start, end)、且它不是本行上次推进到的音节（`Line.lastProgressedToSyllable`）时，才发一次
  `LayerPropertyAnimator(.linear(end − start))`（`sub_100169874`），把渐变的透明端推到 `X + D × 30`：
  - `X` 是音节末尾字形在本行里的横坐标；音节是词的最后一个音节、本行后面还有词时，`X` 取下一个词的起点，尾随
    空格就在这个音节里扫过去。
  - `D` 四档，按顺序判断：本行最后一个音节 1；所在词 1–2 个字符（`Lyrics.Syllable.wordLength`）0.5；后面还有
    音节且音节文本少于 3 个字符 0.25；其余 0.12。
- 音节之间、词之间的空隙不发新动画，停在上一个目标；时间早于本行第一个音节时渐变全暗；时间到达本行最后一个
  音节的结束时刻后直接设成全亮。

**本项目怎么改**：

1. ✅ 新增纯计划 `SyllableSweepPlan`（`SyllableSweepPlan.swift`）：由 `LineTextLayout` 算出每个视觉行的音节列表（时间
   范围、透明端目标）、行宽与行的起止时间，并给出「从行首连续播放到某一刻时透明端应在哪」与「某一刻正在唱哪个
   音节」两个查询。音节取法与 `makeSyllableGroups` 一致：结构化词按它的音节，`[tt]` 段和没有音节的结构化词整段
   一个。
2. ✅ `LineProgressGradientLayer` 增加 `originX(forClearEdge:)`，以透明端定位。仍然固定宽度、只动 `position.x`
   （原有的有意差异：改宽度会让动画中途的羽化被裁掉）；位置做线性动画与 Music 改宽度的效果相同。
3. ✅ `SyncedLyricsLineContentLayer` 每帧按 `播放时间 + 0.1 秒` 逐行判断：进入新音节就用新的
   `LinearTimingParameters` 发一段从当前画面位置出发的线性动画；空隙里不动；行开始前全暗；行结束后全亮。
   逐音节抬高同样改用这个时间。
4. ✅ 隐藏开关 `AppleMusicLyricsSweepVariant`（`LineProgressSweepVariant`）：`appleMusic26`（默认，上面的做法）/
   `characterFraction`（原来的按字符占比逐帧摆位置，不加提前量）。在行重建和变成当前行时读取。0.1 秒抬高提前量
   不跟开关走：它是移植时漏掉的一处，不是两种观感。
5. ✅ 测试与文档：`SyllableSweepPlanTests` 断言四档 `D`、词尾取下一个词起点、行的起止与连续轨迹；内容层探针断言
   进入音节才发线性动画、时长与目标、空隙不动、第二行等自己的第一个音节、提前 0.1 秒；抬高提前量的探针。实现说明
   新增「扫光」一节并更正「抬高没有提前量」的旧说法，`CLAUDE.md` 登记新探针。

**没有询问就采用的假设**：

- 跳时间（seek、行中途变成当前行）后，Music 会从旧位置以整段音节时长慢慢追，空隙里则一直不动；本项目改成先把
  扫光直接放到「从行首连续播放到此刻」的位置，再把当前音节剩下的部分线性走完。正常播放时两者一样。
- 发动画时的时长用「音节结束 − 当前时间」，而不是 Music 的整段音节时长：正常播放时差不到一帧，跳时间时不会拖到
  音节结束之后。
- 本行最后一个能唱到的音节扫到整行宽度（Music 扫到它自己的末字形）：行尾若有不带时间的标点，Music 会让它一直停在
  渐变里，这里在最后一个音节唱完时一起点亮；时长为零的音节先剔除再判断四档 `D`，整个羽化宽的前沿落在真正最后一个
  音节上。
- 暂停时（面板在暂停那一刻只渲染一帧）扫光停在暂停时刻对应的位置，不让已发出的线性动画按自己的时钟走完；恢复播放时
  按跳时间处理。Music 暂停时怎么做没有核对。
- 退出当前行时扫光停在当时画面上的位置淡出（沿用 0024 的观感），不让正在走的线性动画边淡出边继续走。
- 从右到左的歌词不在范围内：面板从没建过右到左的扫光，计划只按从左到右算。

**后续项**：

- Music 的 `Line.AnimationKind.crossfade`（`sub_10018AEEC`，逐词背景色 easeInOut）何时启用没有查。
- 跳时间后即将唱完的词仍会从头放大一次：`synchronizeEmphasisState` 按不带提前量的时间标记已唱完的词，放大却按带
  提前量的时间判断；`develop` 上就有，见 [已裁决的 code review 发现](../ReviewDecisions.md)。
- 开窗口的探针（`SyllableLiftProbes`、`InlineTagSyllableLiftProbes`、`LineEmphasisProbes`、`TranslatedLineEmphasisProbes`
  等）这次没跑：从终端启动会在 macOS 27.2 的 Dock 上留下图标，要用户同意后再跑。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-08 | Created as Draft | 用户反馈行内动画与 Music 对不齐；逆向确认扫光推进方式与提前量都和 Music 不同。 |
| 2026-11-08 | 用户批准 | 用户选择「两处都改」：按 Music 的结构重写扫光、抬高补 0.1 秒提前量、旧扫光留作隐藏开关；用户调用 `implement-feature` 即批准，提案由 agent 起草、用户事前未审阅。 |
| 2026-11-08 | 开始实现 | 在 `.worktrees/LyricsX-SyllableSweepParity` 的 `feature/apple-music-syllable-sweep` 上做，基线 `develop`。 |
| 2026-11-08 | 计划单独成文件 `SyllableSweepPlan.swift` | 方案原写进 `AnimationPlans.swift`；新计划自带两个嵌套类型和三个查询，单独放更好找，不影响行为。 |
| 2026-11-08 | `LayerPropertyAnimator` 增加 `run(startsFromModel:)` | 跳时间后先直接放好渐变、同一轮再发动画；画面还没跟上刚设的 model 值，从画面出发会从旧位置起跳。 |
| 2026-11-08 | 没有音节的视觉行：前面有音节就在它结束时点亮，否则在后面第一个音节开始时点亮；整句都没有时间则一开始就全亮 | 与逐行歌词整行点亮（2026-10-27 修正）一致；Music 的视觉行总有词，这种行只出现在结构化时间漏掉一整行的数据上。 |
| 2026-11-08 | 时长为零的音节不进计划，但仍参与四档 `D` 的判断 | Music 永远进不了这种音节，也不会朝它推；`D` 的判断照 Music 按完整音节列表。 |
| 2026-11-08 | 首轮验证 | 新增 `SyllableSweepPlanTests`（10 项）、`SyllableSweepEngineTests`（8 项）、`SyllableLiftHeadstartTests`（1 项），连同受影响的不开窗口套件共 77 项、10 个 suite `--no-parallel` 通过，原始退出码 0；扫光临时切回旧做法、抬高临时去掉提前量时，引擎与抬高两组共 9 项里 8 项失败（只有「旧开关保持原样」那项照常通过），原始退出码 1。SwiftFormat lint 无差异。开窗口的探针没跑（见后续项）。 |
| 2026-11-08 | 自审（`code-review` medium） | 十条发现，修四条、六条登记进 [已裁决的 code review 发现](../ReviewDecisions.md)。修：暂停时已发出的线性动画继续走完（新引入，`pausingStopsTheSweepWhereThePausedTimeHasIt` 修前红）；行尾不带时间的文字在行结束时突然点亮、时长为零的末音节抢走整个羽化宽（`theLastSyllableSweepsToTheEndOfTheRow`、`theLastReachableSyllableLeadsByAWholeFeather` 修前红）；扫光与抬高各有一份音节分组，合并为 `LineTextLayout.Word.animatedSyllables`。 |
| 2026-11-08 | 推翻「时长为零的音节仍参与 `D` 的判断」 | 照 Music 会让真正最后一个音节只超出 0.12 到 0.5 个羽化宽，行结束时再突然点亮；先剔除再判断。 |
| 2026-11-08 | 暂停时扫光停住 | 面板暂停时只渲染一帧，`update` 带上 `isPlaying`；旧扫光每帧直接摆位置，本来就会停。 |
