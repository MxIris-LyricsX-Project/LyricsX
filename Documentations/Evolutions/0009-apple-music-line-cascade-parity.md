# 0009 - 行间 cascade 对齐 Apple Music 26.6 并修复全屏掉帧

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-04
- **最后更新**: 2026-09-04
- **关联提案**: [0007 对齐 Apple Music 26.6 歌词动画](0007-apple-music-lyrics-animation-parity.md)
- **配套文档**: [Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md)（已更新行间、光栅化、策略开关与验证记录）

## 摘要

0007 落地后，行间动画在「单 clip spring」和「SwiftUI 式逐行 cascade」之间反复切换：前者被用户否决为
接近线性平移，后者全屏时掉到 30 FPS。2026-09-04 重新逐函数核对 `Music.i64` 后确认，Apple Music 26.6 的正常
自动切行本来就是逐行错峰的 cascade，0007 决策日志里「Apple Music 只在一个 animator 中驱动 clip bounds」
的结论是把翻译开关的 `LinesUpdateResult` 路径误认成了切行路径。掉帧的根因也不是 cascade 本身，而是
本项目的行 layer 从不光栅化，而 Apple Music 的 `SyncedLyricsLineLayer` 从 init 起就 `shouldRasterize = true`。

本提案做三件事：按 Apple Music 的方式光栅化行 layer；把行间 cascade 做成两套可切换的参数与策略，默认
Apple Music 26.6 原值，保留用户认可过的旧 cascade 供并排比较；把结构化歌词的行内 emphasis 门槛也做成
可切换，默认 Apple Music 的语言与时长规则，另一档为满强度。行内公式、layer 层级、viewport mask 与背景
渲染均不改动。

## 方案

### 一、Apple Music 26.6 行间切换的实际机制（本次核对结果）

调用链：display link → `SyncedLyricsManager` 选行 → 代理 `animate(to:)`，即 `sub_1001E6B54` →
`sub_1001DCBD4`。后者对每个可见行创建一个 `AnimationDescriptor`，`SyncedLyricsViewController` 再用
`sub_10015D1B0` 把每个 descriptor 变成一个带 delay 的 `LayerPropertyAnimator`。

- 曲线：`LyricsSpecs.lineChangeSpringTimingParametersValues`，`sub_1001D1C28` 默认初始化为
  mass 1 / stiffness 100 / damping 18，Music 侧配置闭包 `sub_1001D0A1C` 与 `sub_100128D3C` 都不覆盖它。
  阻尼比约 0.9，固有周期约 0.63 秒。
- 逐行 delay：`specs.lineDelay × 行序号`。全屏 pretty 模式 `lineDelay = 0.05` 秒，侧栏模式 0.02 秒。
  向前一行以上回滚时序号反转且 delay 减半，二进制里的调试字符串称之为 "duration hack"。
- 动画对象：每行 `NSView` 自己的 frame，通过 `sub_1001DF214` 在 animator 的 change block 里 `setFrame:`；
  clip 在整个 cascade 期间不动。最后一个 descriptor 的 completion `sub_1001DF460` 再把
  `contentView.bounds` 设到新 offset，并把各行 frame 复位，画面无缝。
- 快速歌词：`displayLinkFired` → `sub_1001D8C08` 在 `currentAnimators` 非空时直接跳过管理器更新，
  即有切行动画在飞时不选新行，动画完成后一次性追上。不存在第二套高阻尼 spring。
- 选中态：`sub_1001E2608` 用 `custom((0.17, 0), (0.83, 1), 0.28 s)` 切换选中/未选中；blur 半径
  仍用 0007 记录的 `(0.33, 0) (0.2, 0.1) 0.12 s`。
- 性能：`SyncedLyricsLineLayer.init`（`sub_1001A5294`）设置 `shouldRasterize = true`、
  `rasterizationScale = specs.displayScale`，并永久安装 gaussian blur `CAFilter`；`sub_1001DC498` 只在
  blur 半径动画期间把 rasterize 关掉，`sub_100158F24` 在 specs 变化时重设 `rasterizationScale`。

`sub_1001E56B0`（"selecting"）是另一条代理方法：目标行完全可见时只更新选中态、不滚动。它由初始选中与
seek 使用，不在正常自动切行的调用链上，因此不影响上面的结论。

顺带核对的 `LyricsSpecs` 默认值：`syllableLift` pretty 模式 3.0、侧栏 2.0；`lineSpacing` pretty 50、
侧栏 36；`paragraphSpacing` 39；`animationHeadstart` 0.1；`glowRadius` 5；`emphasizingScaleRange`
1 … 1.14；`glowRange` 0 … 0.4；`lineFinishProgressAnimationDuration` 0.25。pretty 模式的
`selectedLinePosition` 是 Music 用自己的 `activeBaseline` 锚点构造的 `.center(rect:)`，不是
`.topRelative`；本项目继续沿用 0007 校准出的 40% baseline，不在本提案范围内重算。

### 二、行 layer 光栅化

- `SyncedLyricsLineView` 的 backing layer 设 `shouldRasterize = true`，`rasterizationScale` 跟随
  `window.backingScaleFactor`，backing 属性变化时同步更新。
- `setLineBlurRadius` 的现有逻辑保留「动画期间关闭、结束后恢复」，但恢复目标固定为 true，不再回读
  动画前的值。现在回读到的是 backing layer 的默认 false，等于从未光栅化。
- 假设：与 Apple Music 一致，所有行都光栅化，包括正在做逐字动画的选中行。若实测选中行每帧重光栅化
  的开销可见，再把选中行豁免并记入决策日志。

### 三、两套行间 cascade，运行时可切换

`LineTransitionPlan` 增加 `CascadeVariant`，由隐藏的 `UserDefaults` 键
`AppleMusicLyricsCascadeVariant` 选择，每次切行时读取，因此不用重启即可 A/B。默认 `appleMusic26`。

| | `appleMusic26` | `legacySwiftUI` |
|---|---|---|
| 参与行 | 全部可见行 | 上方 3 行 + 选中行及下方 5 行 |
| 曲线 | 所有行 spring mass 1 / stiffness 100 / damping 18 | 上方 0.5 秒 ease-in-out；其余 period 0.6 / 阻尼比 0.725 |
| delay | 0.05 秒 × 序号；回滚时序号反转并减半 | 0.08 秒 × (序号 + 2) |
| 快速切行 | cascade 在飞时不接受新选行，完成后追上 | 0.4 秒内再次切行改为 period 0.5 / 阻尼比 1 的 clip settle |

两套都沿用现有 `LineTransitionCoordinator` 的执行方式：clip 模型先到位，行 layer 用 presentation
位移补偿再归位。这与 Apple Music「先动行 frame、完成后再动 clip」视觉等价，且不违反 AppKit layout
对 model frame 的所有权。点击歌词的 interactive spring 与大跨度 seek 直接落位两条路径不变。

### 四、两套结构化行内 emphasis，运行时可切换

`WordEmphasisPlan` 增加 `StructuredEmphasisPolicy`，由隐藏键 `AppleMusicLyricsStructuredEmphasisPolicy`
选择，默认 `appleMusic26`。只影响 `.synchronized` 词；`.inferred` 路径保持现状。

- `appleMusic26`：现有规则，即 `ar / he / zh / ja` 只 lift，其他语言 `wordDuration > 1 s` 且
  `wordLength <= 7` 时 `factor = min(duration, 2) - 1`，首字延迟 `stagger × (index + 1)`。
- `fullEmphasis`：`factor = 1`，首字零延迟，与 `.inferred` 路径观感一致。

本地歌词库 2048 首中只有《跳楼机》带 `[synchronized-timing]`，且它在用户 8 月 29 日认可行内动画之后
才缓存。因此「行内又变回 beta」最可能是这首歌命中了 `appleMusic26` 的中文规则，而不是代码回归；
两档可切换后由用户并排定夺。

### 五、诊断、测试与文档

- `LineTransition` 与 `InlineKaraoke` 的现有日志加上当前 variant / policy 字段。
- `LineTransitionProbes` 按 variant 参数化：动画数量、delay、spring 系数、回滚减半、以及
  「cascade 在飞时的新选行被推迟到完成后」；`AnimationPlanTests` 覆盖两档 policy；结构探针断言行
  layer `shouldRasterize` 为 true，且 blur 动画结束后恢复为 true。
- 更新实现说明 [Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md) 的行间一节和
  「与提案的差异」，纠正 0007 中的错误结论；0007 正文按规则不改。术语表不新增。

### 不做的事

- Metal 背景的主线程 drawable 等待属于 0008；先看光栅化后它是否随合成压力下降而消失。
- 不重算选中位置的 `.center(rect:)` 锚点，不实现 `hidePreviousLines`、Background Vocals 与 duet。
- 不新增设置界面，两个开关都是隐藏 defaults 键。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-04 | Created as Draft | 用户要求完整复刻 Apple Music 行内与行间动画，现状要么掉帧要么观感差距大。 |
| 2026-09-04 | 不重开 0007，新建轻量档提案 | 0007 已落地，是决策快照；本次是新的参数、策略与性能改动，关联而不改写。 |
| 2026-09-04 | 行内不改公式，只加可切换门槛 | 用户选择「先做成可切换再比」；对比用的歌曲用户表示不重要，按调查到的数据走。 |
| 2026-09-04 | 行间两套参数都做成可切换，默认 Apple Music 原值 | 用户选择「两套都做成可切换」。 |
| 2026-09-04 | 光栅化优先 | Apple Music 行 layer 常开光栅化，本项目从未开；这是全屏 30 FPS 与旧 cascade 被否决之间的公共根因。 |
| 2026-09-04 | Draft → Accepted | 用户回复「接受提案」。 |
| 2026-09-04 | Accepted → In Progress | 按提案顺序实施：先光栅化，再 cascade 两档，再行内两档，最后同步实现说明。 |
| 2026-09-04 | 光栅化落地 | 回归先在旧实现上以退出码 1 失败（backing layer 不光栅化、scale 1.0），修复后通过；blur 动画期间关闭、结束后固定恢复为 true。选中行同样光栅化，未做豁免。 |
| 2026-09-04 | cascade 两档落地 | `LineCascadeVariant` 由 `AppleMusicLyricsCascadeVariant` 选择，默认 `appleMusic26`；两档都由 `LineTransitionCoordinator` 执行，Apple Music 档新增「在飞时推迟新选行、settle 后追上」；点击、用户滚动、大跨度 seek 不等待。 |
| 2026-09-04 | 行内两档落地 | `StructuredEmphasisPolicy` 由 `AppleMusicLyricsStructuredEmphasisPolicy` 选择，默认 `appleMusic26`；`fullEmphasis` 让结构化词 factor 1、首字零延迟。`.inferred` 路径不变。 |
| 2026-09-04 | 验证 | LyricsXPackage 133 项、17 个 suite `--no-parallel` 全部通过，原始退出码 0；workspace Debug scheme 隔离 DerivedData 冷/增量构建成功，0 warning；SwiftFormat lint 通过。未启动应用做交互式 UI 验证，帧率与观感留给用户按 `defaults write` 并排比较。 |
| 2026-09-04 | 配套文档判断 | **更新既有实现说明**，不另写指南：新增行间真实机制、两档 cascade 表、光栅化一节、开关用法与验证记录，并纠正 0007 阶段的错误结论。 |
| 2026-09-04 | 术语表判断 | **不登记**。cascade、variant、policy、rasterization 都是通用技术词。 |
| 2026-09-04 | In Progress → Implemented | 代码、测试与文档已就绪，尚未提交；落地 `develop` 时再按远端最大编号分配 NNNN。 |
| 2026-09-06 | 补分配编号 0009 | 2026-09-04 以 draft 文件名落地是漏了这一步；随 0011 一起改名并更新链接。 |
