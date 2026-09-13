# Apple Music 26.6 歌词动画

> 对应提案：[对齐 Apple Music 26.6 歌词动画](../Evolutions/0007-apple-music-lyrics-animation-parity.md)、
> [行间 cascade 对齐 Apple Music 26.6 并修复全屏掉帧](../Evolutions/0009-apple-music-line-cascade-parity.md)
>
> 面向维护者。这里记录最终数据链、动画状态所有权和降级边界；旧的探索文档保留为历史记录，
> 不再作为 26.6 行为的实现依据。

## 一句话

主歌词现在走两条明确的数据路径：Apple Music TTML 保留真实的 word/syllable range 与结束时间，
按 Apple Music 26.6 的 factor、stagger 和 contextual blur 执行动画；行间切换默认走 Apple Music 26.6
的逐行错峰 cascade，并按唱句间隙选择逐字歌词的动态弹簧；旧的 SwiftUI cascade 保留为可切换的第二档。
没有结构化数据的其他歌词在行内继续走原来的
phrase 推断，不伪造不存在的层级。行 layer 像 Apple Music 一样常开光栅化，这是全屏切行不再掉到 30 FPS
的前提。

## 最终数据链

```text
Apple Music TTML
  → LyricsKit Lyrics+TTML
  → LyricsLine.Attachments.SynchronizedTextTiming
  → LRCX [synchronized-timing] + 既有 [tt]
  → AppleMusicLyricsPanel LineTextLayout
  → WordEmphasisPlan / LineTransitionPlan / LineBlurPlan / viewport mask
  → CALayer 显式动画
```

### 结构化 timing 为什么必须在 LyricsKit 保存

TTML 的 `<span>` 同时给出了文本范围、`begin`、`end` 和嵌套关系。旧 parser 只把每个 span 的
开始位置写进 `[tt]`，因此进入面板之前就已经丢掉了结束时间以及 word/syllable 层级；面板再复杂也
无法可靠还原。

`LyricsLine.Attachments.SynchronizedTextTiming` 现在保存：

- word 的 Swift `Character` range 与相对行首的 time range；
- word 下每个 syllable 的 character range 与 time range；
- 可选的整行 duration。

只有一层 timed span 时，它成为一个 word，并生成一个同 range、同 time range 的 syllable；外层
word 包含内层 timed span 时，内层 span 原样成为 syllable。解析仍同时生成既有 `[tt]`，旧消费者
因此还能得到逐字开始时间。

### LRCX 的附加格式

新 attachment 的 tag 是 `[synchronized-timing]`，payload 为：

```text
1:<Base64(JSON)>
```

版本号在 Base64 之外，JSON 内的时间全部是整数毫秒，range 使用半开区间的起止 character index。
这是 additive 格式：没有修改 `[tt]` 的任何字节或语义。

载入时会整体校验：

- word range 有序、非空且不越过歌词文本；
- syllable 位于所属 word 内；
- character range 与 time range 都不会反向；
- 时间有限、非负；
- payload version、Base64 或 JSON 损坏时直接拒绝。

任何一项失败都只丢弃 `SynchronizedTextTiming`，继续使用同一行的 `[tt]`；不会保留半份结构，也不会
让整首歌词解析失败。反向 range 在构造 Swift `Range` 之前就会被拒绝，损坏文件不能借此触发崩溃。

## 行内动画

### 精确路径与 fallback

`LineTextLayout` 先把 Swift `Character` index 转成 Core Text 使用的 UTF-16 code-unit index，
再把 glyph 放回对应 word 与 syllable。结构化 range 之间允许空白；空白形成不带 timing 的边界，
不会被算进相邻 word 的 duration 或 glyph count。

存在有效 `SynchronizedTextTiming` 时，emphasis 使用真实 word duration、word length 和 glyph count。
缺少它时，默认档把每个 `[tt]` 段当成一个音节：酷狗、QQ 音乐的 `[tt]` 是真实的逐字（英文逐词）时间轴，
一段就是 Music 音节的粒度，判定用段自己的时长与去掉首尾空白的字数。既有 `InlineTimeTag` 把相邻字符归回
phrase 的 fallback 只剩 `fullEmphasis` 档在用（见「factor 与语言能力」）。

`InlineTimeTag` 也可能把一段快速演唱拆成连续的空格分隔单元，却没有 Apple Music 用来区分 word 与
syllable 的层级。若同一视觉行里连续至少三个 fallback 单元各自现有的 `emphasisDuration` 不超过
`0.25` 秒，`LineTextLayout` 会让这一段共享 phrase 的 `emphasisDuration` 与
`emphasisGlyphCount`，直到遇到普通速度单元、换行或累计时长超过 `3` 秒。各单元自身的
`timeRange` 不变，因此起跳时刻和 karaoke progression 仍服从来源数据；改变的只是 spring period，
避免每个单元都在一两百毫秒内各自起跳、收回。少于三个的孤立快词不会被合并。

这条 `0.25` 秒规则是缺少结构化层级时的项目 fallback，不是从 Apple Music 26.6 恢复出的常量。
结构化 `SynchronizedTextTiming` 即使 word 很短也始终保留原始 envelope。

### factor 与语言能力

Music 建模时给每个词一个 `Lyrics.Word.emphasis`（`enum { case factor(Double), case none }`，`sub_1001C2DD4`）。
结构化路径按歌词的 `lang` id tag 取基础语言代码：`ar`、`he`、`zh`、`ja`（含地区后缀）的能力表只有
`[gradient, lift]`，其它或未知语言是 `[gradient, lift, emphasis]`（`sub_1001C28A4`）。四项同时满足才是 `.factor`：

```text
language has the emphasis capability
wordDuration > 1 second
wordLength <= 7 characters
factor = min(wordDuration, 2) - 1 > 0
```

其余一律 `.none`。`.none` 的词**没有任何逐字动画**（`sub_10018B2B4` 开头即返回），它的抬高来自下一节的逐音节
弹簧。本项目里 `WordEmphasisPlan.make` 对 `.none` 返回 `nil`，`SyncedLyricsLineContentLayer` 据此决定一个词走
swell 还是走音节抬高。

这条门槛对结构化词和 `[tt]` 行内标签段一视同仁，且可以整档切换。`StructuredEmphasisPolicy` 由隐藏的
defaults 键 `AppleMusicLyricsStructuredEmphasisPolicy` 选择，`SyncedLyricsLineContentLayer` 在每个词起跳时读取，
`WordEmphasisPlan.make` 只看这一档、不看 timing 来源：

- `appleMusic26`（默认）：上面的语言门槛与时长规则，首字额外等待一个 stagger。`[tt]` 段用自己的时长和
  去掉首尾空白的字数判定，不用 `LineTextLayout` 拼出的 phrase 时长——否则一句英文会整句超过 1 秒而全部放大。
- `fullEmphasis`：所有带时间的词一律 `factor = 1`，首字零延迟，`[tt]` 段仍按 phrase envelope 分组——这就是
  2026-09-06 之前所有非 Apple Music 来源的观感，留作并排比较。

加这档的原因见提案 0009：本地歌词库两千多首里只有一首带 `[synchronized-timing]`，用户认可行内动画时看到的是
`[tt]` 的满强度观感，之后拿中文结构化歌词对比时才命中了「只 lift」规则。2026-09-06 用户看过结构化歌词的
逐音节抬高后，把 `[tt]` 的满强度观感描述为「一上一下」，默认档随即改成对两种来源同一机制（见下文修正记录）。

### 调度公式与 layer 层级

`WordEmphasisPlan` 固定 26.6 恢复出的公式：

```text
scale        = 1 + factor × 0.14
glowOpacity  = factor × 0.4
springPeriod = min(wordDuration, 3)
glyphStagger = min(wordDuration / glyphCount × 0.4, 0.4)
riseDelay    = glyphStagger × (glyphIndex + 1)      # fullEmphasis 为 glyphStagger × glyphIndex
returnDelay  = riseDelay + 2 × wordDuration / glyphCount
```

return 只收回放大与横向挤压，**不收回抬高**：`sub_10018B2B4` 交给 `sub_1001678FC` 的目标是
`(frame.origin.x, frame.origin.y − syllableLift)` 加恒等变换，所以唱过的字停在高 3 pt 处，直到倒带
或切行才回到 `frame`。本项目对应 `WordNode.sungOrigin(ofGlyphAt:)`，`resetEmphasis()` 则回到
`restingOrigin`。

### 逐音节抬高

`.none` 的词按音节建 `SyllableLayer`（`sub_10018DA78`；单音节词直接以它充当词 layer），每帧 `sub_1001689D4`
对每个音节调 `sub_1001897C0`：音节从未唱变为已唱时给 `Syllable.layer` 加 `translation(0, −syllableLift)`
（change closure `sub_100189C0C`），动画是 `CASpringAnimation(mass 1, stiffness 14, damping 7)`，时长取它的
`settlingDuration`，约一秒才收敛；时间退回音节之前用同一弹簧回恒等。没有 headstart，不分语言，transliteration
行除外。它不改颜色，sweep 颜色始终是 `gradientLayer` 的事。

本项目对应 `SyllableLiftPlan`（同一组弹簧常量）与 `SyncedLyricsLineContentLayer.updateSyllableLifts`：结构化词按
`LineTextLayout.Word.Syllable.glyphIndices` 分组，整组 glyph 用一个 `LayerPropertyAnimator` 移到 `sungOrigin` /
`restingOrigin`；`.factor` 的词不参与，它的 swell 自带落点。`[tt]` 段没有更细的音节层级，整段一组，默认档下
同样走这条软弹簧；`fullEmphasis` 档下 `decideEmphasis` 仍给它 swell 计划，音节组不用。

glow 在 rasterized `WordLayer` 上，`shadowRadius = 5`、`shadowOffset = 0`；glyph layer 只负责 position
与 affine transform，不再各自投影。word duration 到达后，glow 由独立的
`mass 1 / stiffness 14 / damping 7` spring 回到 0，和 glyph 的几何收回不是同一批动画。

seek、换行、歌词替换或 view reuse 都会取消尚未执行的 glyph return 与 deglow work item，删除显式
动画，并一次性恢复模型状态。新的动画永远从 presentation layer 的可见状态接续。

## 行间动画

选中主歌词使用 `.topRelative(40)`。Apple Music 对 text-only line frame 的计算是：

```text
topInset = visibleHeight × 0.40 - CTFontGetAscent(font)
targetY  = max(lineFrame.minY - topInset, 0)
```

本项目的 row frame 在文字前还有 28 点内边距，因此 `LineTransitionPlan` 从 40% 中减去完整的
`mainTextFirstBaselineOffset`。这样定位的是第一条文字 baseline，而不是 row 外框顶部；窗口高度变化时
会重新计算，不能退回固定点数。

### Apple Music 26.6 实际怎么切行

2026-09-04 逐函数核对 `Music.i64` 后，此前「普通切行只动一个 clip bounds spring」的结论被推翻：那是
翻译 / 音译开关走的 `LinesUpdateResult` 路径（`sub_10015AA20`），不是切行路径。真正的切行链路是
display link → `SyncedLyricsManager` 选行 → 代理 `animate(to:)`（`sub_1001E6B54`）→ `sub_1001DCBD4`：

- 对每个可见行创建一个 `AnimationDescriptor`，`SyncedLyricsViewController.sub_10015D1B0` 再把每个
  descriptor 变成一个带 delay 的 `LayerPropertyAnimator`。
- 普通逐行歌词、或者缺少换行时间间隔时，曲线取 `LyricsSpecs.lineChangeSpringTimingParametersValues`：
  `sub_1001D1C28` 默认填 mass 1 / stiffness 100 / damping 18，阻尼比 0.9，固有周期约 0.63 秒。
  **2026-09-05 补充核对**：`sub_1001E0994` 在 `lyrics.type == timedWords` 时还会调用
  `sub_1001D1A10`，根据唱句间隙选择动态弹簧。此前从 specs 默认值推导「所有行都固定用 1/100/18」
  遗漏了这个分支；仅检查配置是否被覆盖，不能证明消费端不另选曲线。
- delay 是 `specs.lineDelay × max(行序号 - 1, 0)`，序号从 0 开始。全屏 pretty 模式
  `lineDelay = 0.05` 秒，侧栏模式 0.02 秒。往回滚时先反转序号，再减一并截到 0，delay 减半。
  向前的延迟序列为 `0, 0, 50, 100, ... ms`，向后从底部开始为 `0, 0, 25, 50, ... ms`。
  减一与非负截断分别在 `0x1001DE760`、`0x1001DE8C4` 的汇编中确认；此前把回滚逻辑称为
  "duration hack" 的注释不准确，该日志不在回滚延迟分支。
- 动画对象是每行 `NSView` 自己的 frame（`sub_1001DF214` 在 change block 里 `setFrame:`），clip 在整个
  cascade 期间不动；最后一个 descriptor 的 completion（`sub_1001DF460`）才把 `contentView.bounds` 设到
  新 offset 并复位各行 frame。
- 有切行动画在飞时，`displayLinkFired` → `sub_1001D8C08` 直接跳过管理器更新，不选新行；动画结束后
  一次性追上。逐字高亮的进度更新仍继续执行。
- 选中态切换用 `custom((0.17, 0), (0.83, 1), 0.28 s)`；blur 半径仍是下文的 0.12 秒曲线。

pretty 模式的 `selectedLinePosition` 是 Music 用自己的 `activeBaseline` 锚点构造的 `.center(rect:)`，
本项目仍沿用上面校准出的 40% baseline，没有重算。

### 逐字歌词的换行弹簧为什么不能只读 specs

`SyncedLyricsManager` 的 `sub_1001D4DE8` 在 `0x1001D54C4` 读取目标行的开始时间，在
`0x1001D54F8` 读取此前选中行的结束时间，`0x1001D573C` 相减后经 `sub_1001D5CA0` 传给代理。
这不是整行持续时间，也不是两次显示回调之间经过的墙钟时间：

```text
sungGap = nextLine.startTime - previousSelectedLine.endTime
fraction = clamp((sungGap - 0.2) / 0.55, 0, 1)
dampingRatio = (1 - fraction) * 0.12 + 0.78
period = fraction * 0.27 + 0.48
```

`sub_1001662D4` 再把阻尼比与周期转为 mass、stiffness、damping；`sub_100162B3C` 原样交给
`CASpringAnimation`，动画长度取它自己的 `settlingDuration`。上述分支与公式均已对照汇编。

| 唱句间隙 | 阻尼比 | 固有周期 | 越过目标位置的理论幅度 |
|---|---|---|---|
| ≤ 0.2 秒，含重叠唱句 | 0.9 | 0.48 秒 | 位移的约 0.15% |
| 0.5 秒 | 约 0.83455 | 约 0.62727 秒 | 约 0.86% |
| ≥ 0.75 秒 | 0.78 | 0.75 秒 | 约 1.99% |
| 固定回退 1/100/18 | 0.9 | 约 0.62832 秒 | 约 0.15% |
| 旧 Codex 参数 | 0.725 | 0.6 秒 | 约 3.66% |

这些是零初速度弹簧的理论曲线，不是录屏或帧率测量。旧 Codex 参数确实更弹，但不能把恢复它等同于
恢复 Apple Music 的精确分支。

本项目在重建歌词行时判断是否有结构化 word timing 或非空 inline time tags，并在实际换行时使用上一条
**真正显示过的选中行**计算间隙。结束时间优先取有效 `SynchronizedTextTiming.duration`，再取 inline
duration；缺少结束时间、无逐字数据或非有限时间量时，回退到固定弹簧。不能用下一行开始时间推算上一行
结束时间，否则所有间隙都会被人为抹成 0。延后追赶跳过几行时，也不能拿目标行在数组中的前一行代替
真正的上一选中行。

### 本项目的两档 cascade

`LineCascadeVariant` 由隐藏的 defaults 键 `AppleMusicLyricsCascadeVariant` 选择，
`SyncedLyricsContainerView` 每次切行时读取，因此 `defaults write` 后下一次切行就生效，不用重启：

| | `appleMusic26`（默认） | `legacySwiftUI` |
|---|---|---|
| 参与行 | 与旧视口或新视口相交的全部行，从上到下 | 上方 3 行 + 选中行及下方 5 行 |
| 曲线 | 逐字歌词按唱句间隙选动态 spring；信息不足时用 1/100/18 | 上方 0.5 秒 ease-in-out；其余 period 0.6 / 阻尼比 0.725 |
| delay | 0.05 秒 × max(序号 - 1, 0)；回滚时先反转序号、再减一截断并减半 | 0.08 秒 × (序号 + 2) |
| 快速切行 | cascade 未 settle 前不接受新选行，settle 后追上 | 0.4 秒内再次切行改为 period 0.5 / 阻尼比 1 的 clip settle |

两档都由 `LineTransitionCoordinator` 执行，顺序与 Apple Music 相反但视觉等价，而且不违反 AppKit
layout 对 model frame 的所有权：

1. 从 clip 与参与行的 presentation layer 读取当前可见位置。
2. 在关闭 implicit actions 的同一个 transaction 中把 `NSClipView.bounds` 提交到新 anchor；row 的
   AppKit model frame 始终不变。
3. 用完整 clip displacement 反向补偿参与行的 presentation 起点，因此提交 scroll model 时画面
   不会瞬移。
4. 各行按各自的 delay 归位；新 cascade 从旧动画的 row presentation position 接续，并以稳定
   animation key 替换旧动画。整个过程由 render server 插值，不在 DisplayLink callback 里逐帧改
   frame 或触发 layout。

首行补偿已对照 `sub_1001DCBD4` 的 `0x1001DE430` 和排版助手 `sub_1001E0C34`：原版把第一条
参与行的目标 frame 减去滚动位移，然后让后续行接在前一目标 frame 下方。这里对每行的起点统一加回
clip 位移，已经表达同一个坐标转换；首行不再额外加减一次。回归会比较每行在视口中的起点，并确认
包括首行在内的 model position 与动画终点都保持不变。

`appleMusic26` 的「不接受新选行」由 coordinator 的 `isCascadeInFlight` 表达：最慢一行的 delay 加
spring 的 `settlingDuration` 到期前，容器把新的 highlight index 存进
`deferredHighlightedOriginalIndex`，旧行继续 karaoke 直到填满；settle 回调只应用最新一次请求。
完成时刻从实际挂上的动画逐条取最晚结束时间，避免延迟公式修正后仍多等一档。
点击歌词、用户滚动和大跨度 seek 都不等待：点击走 `mass 2 / stiffness 260 / damping 50` 的 interactive
clip spring，用户滚动会取消 cascade 并只更新被推迟的行的 highlight 状态，非交互大跨度 seek 直接
落到模型终点。初始化和离屏也直接落位。

instrumental dots 仍然居中，并复用 coordinator 的 clip spring，不维护第二套逐帧动画状态。

### 行 layer 光栅化

Apple Music 的 `SyncedLyricsLineLayer.init`（`sub_1001A5294`）设置 `shouldRasterize = true`、
`rasterizationScale = specs.displayScale`，并永久安装 gaussian blur `CAFilter`；只有 blur 半径动画期间
（`sub_1001DC498`）临时关掉光栅化。本项目此前从未打开它：blur 动画结束时「恢复」的是 backing layer 默认
的 false，于是 cascade 每帧都要重新合成每一行的嵌套 mask、词级 shadow 和高斯模糊，全屏时正是 30 FPS
的来源。现在 `SyncedLyricsLineView` 在 init、进入 window 和 backing 属性变化时把 backing layer 设为
`shouldRasterize = true`、`rasterizationScale = window.backingScaleFactor`；`isBlurRadiusAnimating`
为真时关掉，动画结束后固定恢复为 true。`rasterizationScale` 不能省：默认值 1 会把 Retina 文字按半分辨率
缓存。正在做逐字动画的选中行也光栅化，和 Apple Music 一致；如果实测它每帧重光栅化的开销可见，再单独
豁免并记入提案决策日志。

## 多行文本坐标

`LineTextLayout` 已把 Core Text 的 y-up baseline 转换成 y-down frame，所以 `SyncedLyricsLineContentLayer`
的**有效**朝向必须是 y-down。Core Animation 的 `isGeometryFlipped` 只是相对父层再翻一次，一个 layer 的有效朝向是
从根到它所有标志的异或（`contentsAreFlipped()`）。AppKit 只在 view 与父 view 的 flipped 状态不同的地方给 backing
layer 打这个标志（面板里打在 `NSScrollView` 的 layer 上，行 view 单独挂进窗口时打在行 layer 上），并且是在
CATransaction 提交时才打，比 `layout()` 晚一拍。所以由我们自己摆放的 sublayer 只能猜奇偶，而且第一次 layout 时
猜不到。

因此 content layer 不再由行 view 手工加到 backing layer 上，而是交给一个 flipped 的 layer-hosting 子视图
`ContentHostView`（`view.layer = contentLayer`）承载：AppKit 会在每次提交时把宿主 layer 的朝向维持成与 view 一致的
y-down，行 view 只在 `layout()` 里设置宿主的 frame（y-down 坐标）。`SyncedLyricsLineContentLayer.init` 仍默认
`isGeometryFlipped = true`，供离屏探针直接挂在 y-up 的 CARenderer 根下使用；被宿主时这个值由 AppKit 接管，行 view
永远不写它。

这条曾两次修错：最早按行 layer 自己的 `isGeometryFlipped` 取反，8445f2e 改成硬编码 `true`，两版都只看了行 layer
自己、没看祖先链的奇偶；2026-09-06 在 Darwin 25.6 上换行歌词再次整行颠倒（08-29 以来没有代码改过这条链，应是
AppKit 打标志的策略变了）。回归测试 `WrappedRowOrderProbes` 把真实容器和单独的行 view 各挂进一个窗口，把两个视觉行
投影到窗口根 layer 上比较高低，并核对文字块顶边落在 padding 上；`LineEmphasisStructureProbes` 里的版权句探针改为
断言 content layer 的有效朝向（`contentsAreFlipped()`）而非它自己的标志。

每个 visual row 还必须保留 Core Text 给出的精确 typographic frame，不能用整段 `contentSize.height`
除以行数来推算平均行高。后者没有表达各行的 ascent、descent 与 leading，会让渐变在不同字体或混排
文本中偏离真实 glyph。

`SyncedLyricsLineContentLayer` 不再用一个覆盖整句的 glyph mask 同时裁切所有行。每个 visual row 都有
独立的 colour container，内部放该行的未唱背景、progress gradient，以及只包含该行 word 的 glyph
mask。progress gradient 为弹跳和 glow 保留的上下 padding 可以在几何上跨过相邻行，但它只能通过本行
mask，因此不会提前点亮下一行左侧的短文本。多行 progression 仍按各行宽度累计，只有前一行完整唱完
后才开始移动下一行 gradient。

## Contextual blur

blur 不再等同于“所有非选中行”。scroll view 先根据当前渲染上下文生成 `LineBlurPlan`，只把上下文内
可见的非选中主歌词放进目标集合；离开上下文的 row 回到 0，避免复用时残留 filter 状态。没有选中行
时集合为空。

半径仍使用屏幕实测校准后的值。`filters.gaussianBlur.inputRadius` 的 transition 为：

- duration `0.12` 秒；
- cubic control points `(0.33, 0)` 与 `(0.2, 0.1)`；
- model radius 先写最终值，显式动画从 presentation radius 开始；
- 动画期间关闭 rasterization，且只有最新 animation generation 的 completion 可以恢复原状态。

### 外层 viewport edge fade

行级 blur 本身不是距离渐变。`SyncedLyricsLineLayer` 对进入 `blurredLineViews` 的 row 使用固定半径；
远处歌词逐渐消失来自更外层的 `Music.LyricsXViewController.maskLayer`。26.6 的类型信息确认该字段是
`CAGradientLayer`，`sub_1001284F8` 把它安装到完整歌词 container 的 backing layer，并设置：

```text
colors    = [clear, white, white, clear]
locations = [0, firstFadeDistance / height,
             1 - secondFadeDistance / height, 1]
```

汇编中的分支不能只看“是否自动跟随”：pretty mode 自动跟随时两个 distance 都是 128 point，手动
scroll 时都是 30 point；non-pretty 自动跟随路径的 first distance 是 70 point，second distance 是
视口高度的一半，因此得到 `[0, 70 / height, 0.5, 1]`。

Music 把 mask 安装在 flipped 的 `AMPFlippedDocumentView` 上，上述 locations 因而是在 flipped geometry
中解释的。本项目把 mask 安装在外层、未 flipped 的 `SyncedLyricsContainerView` 上；内部 document view
是否 flipped 不会改变外层 mask 的坐标。locations 必须保留二进制恢复值，同时反转 gradient vector：

```text
colors     = [clear, white, white, clear]
locations  = [0, 70 / height, 0.5, 1]
startPoint = (0.5, 1)
endPoint   = (0.5, 0)
```

映射后的视觉结果是：顶部约 70 point 从透明过渡到完全不透明，中段保持完全不透明，底部从半屏处开始
渐隐到透明。选中歌词 baseline 位于距视觉顶部 40% 的位置，因此不会再被 mask 降到约 78% opacity。

mask 只创建一次，每次 layout 在关闭 implicit animation 的 transaction 中更新 frame 和 locations，
不参与 display-link tick。

`NSScrollView` viewport 与 Apple Music 一样继续使用 container 的完整 bounds，不增加物理 top / bottom
inset；边缘空间完全由 mask 的 alpha transition 形成。曾尝试上下各缩进 32 point，但用户并排截图
确认这种硬留白与 Apple Music 不符，随后撤销。

因此不能把视觉上的渐隐误实现为“离选中行越远，Gaussian blur radius 越大”。那既不符合二进制结构，
也会让更多大半径 filter 参与行间 spring 合成。非选中行仍保持统一的基础 alpha 和固定 blur，连续的
上下衰减只由 viewport mask 负责。用户反馈的边缘观感不是 row 的真实文字间距不足，因此没有扩大
row spacing，也没有保留额外 viewport inset。

## AppKit 与 Core Animation 的所有权

`NSView.frame` 和 `NSClipView.bounds` 是模型真值，backing layer 的 `position`、`frame`、`bounds`
不能成为另一套持久状态。Core Animation 只承载 presentation：

- model target 总是在动画安装前提交；
- 中断时只从 `presentation()` 读取可见起点；
- animation key 稳定，新动画替换同属性旧动画；
- layout pass 可以随时重投影 backing layer，而不会改变最终状态。
- 面板内任何声明了自己指定初始化器的 `CALayer` 子类都必须覆盖 `init(layer:)`：Core Animation 造 presentation 副本
  就是给原层的类 alloc 新实例再发 `initWithLayer:`，Swift 子类一旦有了自己的指定初始化器就不再继承它，漏掉的那个类
  在任何人取副本时直接崩溃（见 2026-09-13 修正）。

后续若直接长期修改 row backing layer 的 geometry，AppKit 下一次 layout 会把它重写，表现通常是
换行中途突然跳回。不要用 completion 再补 model value，那会同时破坏 hit testing 和连续换行。

## 性能诊断

歌词动画使用 `com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics` subsystem，并把不同边界分到四个 category；背景
渲染单独用 `com.JH.LyricsX.AppleMusicLyricsPanel.Backdrop`（见 `AppleMusicMetalGradient.md`），这样在 Console
里按 subsystem 过滤就能把歌词动画和背景的记录分开看。实现依赖 FrameworkToolbox 0.10.0 的 `OSToolbox`，由
`AppleMusicLyricsPanel` target 直接导入，避免依赖其它模块的 transitive import。

- `LyricsFrame` 每两秒汇总一次 display-link source cadence 与 main queue arrival cadence，同时记录
  nominal frames per second、两侧漏帧数、最大 frame gap、最大 delivery lateness，以及当前歌词长度与
  timing entry 数。汇总还包含 `handleDisplayLink()` 的平均与最大执行时间、超过一帧预算的次数；
  `LyricsPlaybackStateRead`、`LyricsInstrumentalProgressUpdate`、`LyricsKaraokeLineUpdate` 三个嵌套
  signpost 分别覆盖播放器状态读取、间奏状态更新和当前歌词行更新。source 保持 60、main arrival 出现
  30 FPS 式空档，但歌词工作耗时仍很低，表示 main thread 在两个歌词 callback 之间被其它工作阻塞；
  两侧 cadence 一起下降才应继续检查 display scheduling 本身。
- `LyricsLine` 记录 layout 重建的 visual row、word、glyph 数量（`Line layout built` 带整行 `text=`），以及
  blur radius 的每次目标变化。
- `InlineKaraoke` 是行内动画的逐事件追踪，归 `karaoke` 组，每个事件一行，都带 `line=`（该行前 24 个字）：
  - `Line layer rebuilt`：`language=` 与 `words=` 词表，每个词写成 `文本[起-止s]` 或 `文本[起-止i]`，`s`
    是结构化时间轴、`i` 是行内 `[tt]` 回退，多音节词再带 `/N syl`。看这一行就知道这首歌每个词走哪条路。
  - `Word emphasis scheduled`：走 swell 的词，带 `text=`、`timingSource=`、`policy=`、`scale=`、
    `glowOpacity=`，以及逐字的 `riseDelays=` / `returnDelays=`。
  - `Word emphasis withheld`：Music 判为 `.none` 的词，带 `text=` 与 `syllableCount=`。
  - `Syllable lifted` / `Syllable lowered`：逐音节抬高与倒带回落，带音节 `text=`、`glyphs=` 区间、
    `start=` 与触发时的 `elapsedTime=`。
  - `Glyph return started`：swell 词每个字开始收回的时刻。
  - `Emphasis state synchronized`（seek 或时间跳变后的重同步）与 `Emphasis reset`。
  另有 signpost 包围每次 sweep update，可用它确认快速歌词是否在同一 frame 批量安排了过多 glyph animation。
- `LineTransition` 记录 clip spring、row cascade 的 displacement、参与行数、delay 与 settle 时长，并用
  signpost 测量 animation scheduling 本身；render server 后续插值不在这个区间内。`Line advance` 带
  `variant=`，被推迟与追上的切行分别记为 `Line change deferred` 与 `Deferred line change applied`。

这些日志和 signpost 默认全部关闭，按三组开启。面板里每个 `@Loggable` / `@Signpostable` 类型的 `isEnabled:`
都传 `AppleMusicLyrics.PanelDiagnostics` 里自己那组的开关（表达式形式，宏在每个调用点求值并与
`LoggingControl` / `SignpostingControl` 的运行时开关合并），开关值在首次使用时读取一次，环境变量优先于
defaults 键：

- `lyrics`：`LyricsFrame`、`LyricsLine`、`LineTransition`；
- `karaoke`：`InlineKaraoke` 逐事件追踪，量大，只在查行内动画时开；
- `backdrop`：背景渲染（`GradientRenderer`、`GradientFrame`）。

值写 `1` / `true` / `all` 是全开，写 `0` / `off` 是全关，其余按逗号或空格分隔的组名解析，不认识的名字忽略：

```bash
# 运行中的 Debug 构建：写入后重启应用
defaults write dev.JH.LyricsX AppleMusicLyricsDiagnosticsEnabled -string lyrics,karaoke
defaults write dev.JH.LyricsX AppleMusicLyricsDiagnosticsEnabled -bool YES   # 全开
defaults delete dev.JH.LyricsX AppleMusicLyricsDiagnosticsEnabled            # 关闭
# 或在 Xcode scheme / 命令行环境里
LYRICSX_PANEL_DIAGNOSTICS=lyrics,karaoke
```

逐帧阶段 signpost 另有更细的 `LYRICSX_DETAILED_FRAME_SIGNPOSTS=1`，只在 `lyrics` 组打开时有意义。

可在问题出现后直接读取最近记录，不需要把 profiler 附加到 App；按 subsystem 过滤就不会被背景日志淹没：

```bash
/usr/bin/log show --last 2m --info --debug --signpost --style compact \
  --predicate 'subsystem == "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics"'
# 只看行内动画的逐事件追踪
/usr/bin/log show --last 2m --info --debug --style compact \
  --predicate 'subsystem == "com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics" AND category == "InlineKaraoke"'
```

并排比较两档 cascade 或两档行内策略时，播放中直接改隐藏键即可，下一次切行或下一个词生效：

```bash
defaults write dev.JH.LyricsX AppleMusicLyricsCascadeVariant legacySwiftUI     # 或 appleMusic26
defaults write dev.JH.LyricsX AppleMusicLyricsStructuredEmphasisPolicy fullEmphasis   # 或 appleMusic26
defaults delete dev.JH.LyricsX AppleMusicLyricsCascadeVariant                # 回到默认
```

Release 构建的 bundle identifier 是 `com.JH.LyricsX`。无法解析的值按默认档处理。

逐帧路径只写低开销 signpost；可读 `#log` 均为低频汇总、状态转换或逐事件记录（一个音节抬高一行，而不是
一帧一行），不能改成每帧字符串日志，否则诊断本身会改变 frame pacing。

## 与提案的差异和已知边界

- 范围仍只有 main vocals；Background Vocals、duet alignment 和 agent transform 未实现。
- 0007 没有新增开关；后续提案加了两个隐藏 defaults 键（cascade 两档、结构化行内策略两档），没有
  设置界面。非 Apple Music 来源只保留数据 fallback。
- 提案要求精确路径不受 phrase 字段污染。最终代码把统一执行字段命名为
  `emphasisDuration` / `emphasisGlyphCount`：结构化路径填真实 word 值，只有 fallback 才从 phrase 推断。
- Apple Music 26.6 的精确公式没有最小 spring period；非结构化来源的连续快词因为缺失 word/syllable
  层级，额外使用上述 fallback phrase envelope。它只修正运动曲线，不修改来源 timing，也不进入
  `SynchronizedTextTiming` 路径。
- 提案最初把选中位置写成 `.top(12)`，二进制消费端复核随后把精确定位修正为 `.topRelative(40)`。
  同一轮复核还得出「Apple Music 的 normal update 由单 clip bounds spring 承担」，项目据此先后尝试
  `mass 1 / stiffness 100 / damping 18` 与 `period 0.6 / dampingRatio 0.725` 的单 clip spring，实机都被
  用户确认为接近线性平移。2026-09-04 重新核对证明那条结论错了：Apple Music 本来就是逐行错峰
  cascade。2026-09-05 又补齐了此前遗漏的 timedWords 动态弹簧与 delay 减一逻辑，参数与机制见上文。
  旧 SwiftUI cascade 保留为第二档；40% baseline
  anchor 仍是项目的视觉校准，Apple Music pretty 模式实际用 `.center(rect:)` 锚在 `activeBaseline`。
- 0007 阶段的全屏掉帧被归因于 cascade 本身，后来证明根因是行 layer 从未光栅化；见上文「行 layer
  光栅化」。
- 第一版只移植了 LyricsX 内部的 contextual blur，漏掉 Music 外层
  `LyricsXViewController.maskLayer`，导致所有非选中行在 viewport 内同样可见。第一次修正又选中了
  pretty mode 的 128 / 128 point 对称分支；第二张并排截图和汇编复核把 locations 改为 non-pretty
  自动跟随路径的 `[0, 70 / height, 0.5, 1]`。之后先后尝试 128 point 底边校准与
  `[0, 0.5, 0.5, 1]` 对称渐隐，但仍直接沿用了 Music 的 gradient direction，忽略了两边 mask target
  的 flipped 状态不同；对称版本还让位于视觉顶部 40% 的选中行进入 fade。最终保留恢复出的
  `[0, 70 / height, 0.5, 1]`，并在未 flipped 的外层 container 上反转 gradient vector。曾加入的
  scroll viewport 上下各 32 point 留白也被并排截图证明与 Apple Music 不符，最终恢复完整 container
  height。仍然没有恢复距离型 blur、距离型 alpha 或扩大 row spacing。
- 本次没有获得交互式 UI 验证授权，因此没有启动应用；位置与流畅度判断使用用户提供的 Apple Music
  对比录屏，自动化 probe 验证 layer 层级、模型终点、presentation continuity、spring 参数、
  relative baseline、换行顺序与 rasterization 生命周期。
- 非结构化来源（Kugou、QQ 音乐、部分网易云的 `[tt]` 行内标签）从 0011 起一度仍走满强度 swell，2026-09-06
  用户把它描述为「一上一下」（当时播的是 Kugou 版 STAY，不是语言差异），同日改为默认档下与结构化词同一机制，
  老观感留在 `fullEmphasis` 档；见下文「2026-09-06 修正：行内标签歌词也走逐音节抬高」。LIBLRC 等纯按行歌词
  没有词级时间，仍只有整行高亮。

### 2026-09-05 修正：唱过的字保持抬高，而不是落回原位

- **现象**：用户报告带翻译的歌词行内动画「弹跳得很怪异」。库里带翻译的歌恰好都是 Apple Music 来源（带
  `[synchronized-timing]`），复现回路 `TranslatedLineEmphasisProbes` 证明翻译本身不改变逐字轨迹，变的是结构化时间路径：
  中文只抬高不放大，每个字抬 3 pt 后又落回，起落就是全部动作。
- **Music 的实际行为**（`Music.i64` 重新反编译）：`sub_10018B2B4` 在 `riseDelay + 2 × wordDuration / glyphCount` 后调用
  `sub_1001678FC(x: frame.origin.x, y: frame.origin.y − syllableLift, delay)`，change closure `sub_100167C8C` 只做
  `setFrame` 与恒等变换。也就是 return 只收回放大和横向挤压，**抬高保留**；唱过的前缀一直高 3 pt，直到倒带
  （`sub_100166DBC` 以 1.5 秒临界阻尼弹簧回到 `frame`）或切行。`frame`（+0x40）是未抬高的原位，倒带时回的就是它。
- **本项目此前的偏差**：`SyncedLyricsLineContentLayer.scheduleReturns` 把 return 目标写成 `restingOrigin`（未抬高原位），
  自 8445f2e 起如此，不是回归。行内标签路径共用这段代码，只是放大与发光把起落盖住了。
- **修法**：return 目标改为 `WordNode.sungOrigin(ofGlyphAt:)`（原位上移 `syllableLift`），放大与横向位移照旧收回；
  `resetEmphasis()` 不变，仍一次性回到 `restingOrigin`，对应 Music 的倒带与切行。
- **复现测试**：`TranslatedLineEmphasisProbes.sungGlyphsStayLiftedUntilTheLineResets` 用《等你下课》「高中三年 我為什麼」
  走真实 `SyncedLyricsLineView`，断言每个有时间的字结束时高于原位 `syllableLift` 且抬起后不再落回；修复前红，修复后绿，
  作为回归测试保留。
- **连带的探针调整**：`LineEmphasisProbes` 里两条以「唱完回原位」为前提的断言随之改写。
  `emphasisTimelineKeepsGlyphsIntactAndInPlace` 的落位断言改为每个字一致高 3 pt、横向不漂；
  `emphasisRipplesAcrossNeighboursInsteadOfFreezingEachGlyph` 原来把「静止且离开原位」判为卡住、把「至少三个字同时在动」
  当涟漪证据——抬高保留后 return 只剩零点几点的位移，第三个「在动」的字就是它，于是改为「下一个字起跳时前一个字仍在动」，
  卡住则定义为静止时既不在原位也不在抬高位。`APPLE_MUSIC_LYRICS_TRACE_DIRECTORY` 现在也会让它导出 `ripple.tsv`。
- **验证**：五项探针串行通过（`--no-parallel`；两个真实时间轴 suite 并行跑会争抢主线程，翻译对照的 0.5 pt 容差会被
  抖动打穿，这就是为什么 `CLAUDE.md` 的命令一次只跑一个 suite），原始退出码 0；`LyricsXPackage` 全量 167 项、22 个 suite
  通过，退出码 0；`MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 在隔离 DerivedData 构建成功，退出码 0。
  没有交互式 UI 验证授权，未启动应用。

### 2026-09-06 修正：抬高改成逐音节软弹簧，短词和只抬高语言不再逐词弹起

- **现象**：用户报告 Apple Music 来源（结构化 timing、带翻译）的英文歌词行内动画「一顿一顿」，并澄清不是掉帧，是动作本身。
  《Slowly》「Slowly slowly we fall in love」六个词时长 0.2 到 0.75 秒，全部 factor 0，此前仍按 `WordEmphasisPlan`
  给每个词做「逐字 stagger、周期等于词长的临界阻尼抬高」，于是每个词在自己的起点快速弹起、词与词之间静止。
- **Music 26.6 的实际机制**：见上文「factor 与语言能力」与「逐音节抬高」两节；关键地址 `sub_1001C2DD4`（建模决定
  `.factor` / `.none`）、`sub_1001C28A4`（语言能力表）、`sub_10018DA78`（按 emphasis 分叉建 `GlyphLayer` 或
  `SyllableLayer`）、`sub_1001689D4` → `sub_1001897C0` → `sub_100189C0C`（逐音节软弹簧抬高）。此前文档把
  `sub_1001897C0` 标成「音节颜色弹簧」、把 ar/he/zh/ja 描述成「保留 lift 的逐词动画」，都已更正。
- **修法**：`WordEmphasisPlan.make` 对 `.none` 返回 `nil`；新增 `SyllableLiftPlan`；`SyncedLyricsLineContentLayer`
  为结构化词建音节组，词首次到期时决定走 swell 还是音节抬高，每帧按音节起点用软弹簧抬起或放回；`.inferred` 不动。
  提案见 [行内抬高改成 Music 26.6 的逐音节软弹簧](../Evolutions/0011-apple-music-syllable-lift.md)。
- **复现测试**：`SyllableLiftProbes.shortStructuredWordsLiftPerSyllableOnMusicsSoftSpring` 用《Slowly》那行的真实词时间
  走 Core Animation 时间轴，断言起点前不动、同音节整组同动、90% 抬高耗时不少于 0.5 秒、短词不放大、落点 3 pt；
  `aLongStructuredWordStillSwellsWithoutAnExtraSyllableLift` 断言 1.4 秒的词仍放大且抬高不叠加。修复前在 HEAD 上以
  原始退出码 1 失败（逐字错开 0.7 pt、提前 0.05 秒起跳、达不到 90%），修复后通过。
- **连带调整**：`AnimationPlanTests` 改为断言 ar/he/zh/ja 与不满足门槛的词返回 `nil`，并固定软弹簧常量；
  `LineEmphasisStructureProbes` 断言中文词的位置动画就是 stiffness 14 的弹簧、`fullEmphasis` 下才是词长弹簧；
  `TranslatedLineEmphasisProbes.sungGlyphsStayLiftedUntilTheLineResets` 的前提改为「抬高来自音节弹簧」，断言不变。
- **验证**：受影响的六个 suite（28 项）串行通过；`LyricsXPackage` 全量 174 项、25 个 suite `--no-parallel` 通过，原始
  退出码 0；`MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 在隔离 DerivedData 构建成功，退出码 0；
  SwiftFormat lint 通过。`LineEmphasisProbes.emphasisTimelineKeepsGlyphsIntactAndInPlace` 在其中一次串行组合运行里
  以 3 行之差超出抬高上限，单独重跑两次与全量运行都通过，属既有的时序敏感，未改阈值。没有交互式 UI 验证授权，
  未启动应用。

### 2026-09-06 修正：换行歌词的第二视觉行画到第一行上面

- **现象**：用户截图里每条换行的英文歌词都上下颠倒（「knew I never could」在「I told you I changed, even when I」之上），
  单行歌词看不出来。
- **原因**：见上文「多行文本坐标」——content layer 的 `isGeometryFlipped = true` 只是相对父层再翻一次，而 AppKit 在
  CATransaction 提交时把翻转标志打在了 `NSScrollView` 的 layer 上，行 layer 因此已经是有效 y-down，content layer 再翻
  一次就变回 y-up。08-29 硬编码 `true` 时能工作，08-29 以来没有代码改过这条链，应是 AppKit 打标志的策略变了。
- **四问**：`WrappedRowOrderProbes` 在修复前复现（第一行投影在第二行下方）；不是本轮改动引入，行 view 这段自 8445f2e
  未动；所有换行歌词都受影响，必须修；8445f2e 就是为同一现象改成硬编码，再之前按行 layer 自己的标志取反，两次都
  只看了行 layer 自己。
- **修法**：content layer 交给 flipped 的 layer-hosting 子视图 `ContentHostView` 承载，行 view 只设宿主 frame，不再写
  `isGeometryFlipped` / `position`；朝向由 AppKit 在每次提交时维持。
- **回归**：`WrappedRowOrderProbes` 两条（真实容器、单独挂窗）投影比较高低并核对顶边落在 padding 上；
  `LineEmphasisStructureProbes` 版权句探针挂进窗口后断言有效朝向；`TranslatedLineEmphasisProbes` 改为比较文字块
  距行顶的距离而不是 layer position。
- **验证**：`LyricsXPackage` 全量 176 项、26 个 suite `--no-parallel` 通过，原始退出码 0；workspace LyricsX Debug scheme
  隔离 DerivedData 构建成功，退出码 0；SwiftFormat lint 通过。`LineEmphasisProbes.emphasisTimelineKeepsGlyphsIntactAndInPlace`
  的静止帧偶尔渲染为空（flush 后只等 50 ms），本轮单跑失败两次、带帧转储和全量运行均通过，属既有抖动，未改。
  没有交互式 UI 验证授权，未启动应用。

### 2026-09-06 修正：行内标签歌词也走逐音节抬高

- **现象**：用户对比后说「英文歌行内动画一上一下，中文歌像掀起一块布」。查当时加载的文件：英文歌是 Kugou 版
  STAY（`[by:Kugou]`，只有 `[tt]`），走的是 0011 有意保留的 `.inferred` 满强度路径——每个 phrase 放大 14%、发光、
  逐字抬起再收回；对比的中文歌全是 Apple Music 结构化歌词，走逐音节软弹簧抬高。Apple Music 版 STAY 的 366 个词
  里 357 个同样会走抬高路径，所以差别在来源不在语言。
- **数据核对**：起初误判 Kugou 时间轴是均分的（每词 239 ms）；用户指出酷狗、QQ 音乐都是逐字歌词。重新解码正式
  歌词行，逐词时长 155–574 ms，与 Apple Music 同曲相差不到 0.1 秒，均分的只有文件开头的署名行。所以一个 `[tt]`
  段就是 Music 音节的可靠替身。网易云部分歌也有逐字，只有 LIBLRC 完全按行。
- **四问**：能复现——`InlineTagSyllableLiftProbes` 用该行真实逐词时间在默认档下断言软弹簧抬高、不放大不发光、
  抬起后不落回，修复前红。基线也有——自 0011（954459f）起如此，是 0011 明确留下的边界，不是回归。值得修——
  本地库几乎全是 `[tt]` 来源，这是绝大多数歌的观感。以前修过吗——0011 的决策日志写明「`.inferred` 不动」是为了
  保留用户当时认可的观感；用户看过 Music 的真实机制后这个理由不再成立。
- **修法**：`WordEmphasisPlan.make` 去掉 `timingSource` 参数，判定只看策略档；默认档下 `decideEmphasis` 对 `[tt]` 段
  用段自己的时长和去掉首尾空白的字数（不用 phrase envelope），`makeSyllableGroups` 给所有带时间的词建组，
  `[tt]` 段整段一组走 `updateSyllableLifts`；`fullEmphasis` 档保留老公式与 phrase 分组。`LineTextLayout` 不改。
- **回归**：`InlineTagSyllableLiftProbes` 四条（默认档三条修复前红：stiffness 537 而非 14、scale 1.14、glow 0.4；
  `fullEmphasis` 档一条前后都绿）；`AnimationPlanTests` 的 `.inferred` 用例拆成按档断言，默认档按 Music 门槛
  （英文 1.461 秒 factor 0.461、中文为 `nil`、短段为 `nil`）；`LineEmphasisProbes` 的逐字中文 `[tt]` 探针在默认档下
  不改即通过——不裁切、抬高有界、不在弧顶停住对新机制同样成立。
- **验证**：LyricsXPackage 全量 183 项 / 27 suite `--no-parallel` 退出码 0；workspace LyricsX Debug 隔离构建成功；
  SwiftFormat lint 本次改动文件无差异。未启动应用做交互式 UI 验证，观感待用户放 Kugou 歌确认。
- **提案**：`Documentations/Evolutions/0012-inline-tag-syllable-lift.md`。

### 2026-09-13 修正：sweep 层缺 `init(layer:)`，取 presentation 副本时崩溃

- **现象**：`AppleMusicLyricsPanel/LineProgressGradientLayer.swift:30: Fatal error: Use of unimplemented initializer
  'init(layer:)' for class 'AppleMusicLyricsPanel.LineProgressGradientLayer'`，行号指向类声明行。
- **原因**：`CALayer.h` 对 `initWithLayer:` 的注释原话是它专供 Core Animation 造 shadow copy（presentation layer），
  `presentationLayer` 返回 `instancetype`——副本是原层的类 alloc 出来再喂 `initWithLayer:` 的同类实例。Swift 子类一旦声明了
  自己的指定初始化器就不再继承 `init(layer:)`，编译器留下的桩在运行时 trap。源码里没有任何一处直接对这个层调
  `presentation()`，但副本的 `sublayers` / `mask` 返回的都是 presentation 版本，从祖先的副本往下走就会到它；Xcode 的
  Debug View Hierarchy 对整棵树都这么做。
- **四问**：能复现——`LayerPresentationCopyTests` 通过 `CALayer.Type` 元类型动态调 `init(layer:)`（与 Core Animation 同一条
  路径），修复前以同一条 Fatal error 结束进程；静态调用甚至编不过，因为那个初始化器在类型上根本不存在。基线也有——
  537c4c1 把面板提取成 package 时给 `GlyphRunLayer` 与 `SyncedLyricsLineContentLayer` 补了 `init(layer:)`，唯独漏了这个类，
  之后没人动过。值得修——任何取层树 presentation 副本的操作都让应用直接崩溃。以前修过吗——同一条规则在 537c4c1 对两个
  兄弟类做过，本类是当时漏掉的，不是回归。
- **修法**：`LineProgressGradientLayer` 覆盖 `init(layer:)`，拷贝 `lineWidth`、`featherWidth`、`direction`、`verticalPadding`、
  `color` 后调 `super.init(layer:)`；子层由渲染树提供，不复制。面板内 5 个 `CALayer` 子类至此全部合规：`NoAnimationLayer`
  与 `NoAnimationGradientLayer` 没有自定义初始化器，自动继承；其余三个都有覆盖。规则写进上文「AppKit 与 Core Animation
  的所有权」。
- **回归**：`LayerPresentationCopyTests` 三条，逐一覆盖三个带自定义初始化器的层类。只断言 Swift 存储的状态：事务之外直接调
  基类 `init(layer:)`，`bounds`、`contentsScale`、`isGeometryFlipped` 这些 Core Animation 自己管的属性不会拷贝，真实副本从
  渲染树取。`GlyphRunLayer` 的 run 是私有的，靠画进 alpha-only 位图数覆盖像素来证明它带过来了——`CTRunDraw` 用属性字符串
  自己的前景色（默认黑）而不是画布填充色，灰度画布上等于什么都没画，第一版就栽在这里。
- **验证**：`LayerPresentationCopyTests` 修复前红（signal 5，退出码 1）、修复后绿（退出码 0）；LyricsXPackage 全量 208 项 /
  28 个 suite `--no-parallel` 退出码 0；workspace LyricsX Debug
  scheme 隔离 DerivedData 构建成功，退出码 0，3 条警告均为既有弃用告警；SwiftFormat lint 两个改动文件无差异。
  XcodeBuildMCP CLI 在沙箱里建不了自己的日志目录，构建降级到裸 `xcodebuild`。未启动应用做交互式 UI 验证。

## 验证记录

2026-08-29 的本地验证：

- LyricsXPackage：99 项、10 个 suite 全部通过，原始退出码 0；其中集成测试实际执行本地 LyricsKit 的
  flat/nested TTML、LRCX 往返、extended grapheme range 和损坏 payload fallback。
- 新增回归先在旧实现上以原始退出码 1 失败：找不到 clip bounds spring，且 wrapped content layer
  为 unflipped；修复后定向 5 项与完整 99 项均通过。行内两项真实时间轴 Metal probe 保持通过。
- LyricsKit `LyricsService` target：隔离 SwiftPM 目录构建成功，原始退出码 0。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme：使用隔离 DerivedData 构建成功，
  并从 workspace 链接本地 LyricsKit；本次修正后再次构建成功。
- viewport edge fade 回归在缺少 mask 时以原始退出码 1 失败；补上 mask 后定向测试通过，完整
  LyricsXPackage 106 项全部通过、原始退出码 0，随后 workspace Debug scheme 使用隔离 DerivedData
  再次构建成功。
- 非对称 viewport edge fade 回归在 128 / 128 point 实现上以原始退出码 1 失败，并分别报告 top stop
  偏差 0.0725、bottom stop 偏差 0.34；改为 `[0, 70 / height, 0.5, 1]` 后定向测试通过。加入 HUD
  visibility 回归后，LyricsXPackage 107 项在 `--no-parallel` 下全部通过、原始退出码 0，随后
  workspace Debug scheme 使用隔离 DerivedData 构建成功。
- LyricsKit 全量 test target 目前在进入新测试前被既有
  `GroupProviderTests.StaticProvider` / `FailingProvider` 未遵循当前 `LyricsProvider` protocol 阻断；
  这两个文件不在本次改动中。不要把这次编译失败写成“新测试失败”。

2026-08-30 的底部渐隐视觉校准：

- 回归在 70 point 实现上以原始退出码 1 失败，bottom stop 与 128 point 目标相差 0.0725；顶部 0.5
  stop 没有变化。修改后定向测试通过。
- 第一次完整测试聚合运行返回一次没有失败明细的瞬时退出码 1；随后裸输出复跑与再次聚合复跑连续
  两次通过，均为 107 项、13 个 suite，原始退出码 0。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功；本次
  没有启动应用做交互式 UI 验证。

2026-08-30 的对称渐隐与 viewport 留白：

- 两项回归在 128 point 实现上先失败：800 point 测试视口的 bottom stop 与 0.5 对称目标相差 0.34；
  scroll view 仍占满 `(0, 0, 640, 800)`，与上下各 32 point 的目标 frame 相差 32 point。
- 改为 `[0, 0.5, 0.5, 1]` 并应用 32 point vertical inset 后，两项定向回归通过；选中 baseline 与单
  clip bounds spring 的既有回归也继续通过。
- LyricsXPackage 108 项、13 个 suite 全部通过，原始退出码 0；`MxIris-LyricsX-Project.xcworkspace`
  的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。未启动应用做交互式 UI 验证。

2026-08-30 撤销 viewport 硬留白：

- 用户并排截图确认 Apple Music 的 lyrics viewport 仍覆盖完整高度，边缘空间来自渐隐而不是 frame
  inset。完整高度回归在 32 point 实现上先失败，实际 frame 为 `(0, 32, 640, 736)`，目标为
  `(0, 0, 640, 800)`。
- 移除 inset 后，完整高度与对称渐隐两项定向回归通过；LyricsXPackage 108 项、13 个 suite 全部
  通过，原始退出码 0。真实 row spacing、line blur、行内动画与 display-link 路径均未改变。

2026-08-30 修正 flipped coordinate mapping：

- 同一首歌的并排截图显示，对称 mask 把本项目选中行压到约 78% normalized opacity，而 Apple Music
  的选中行保持完全不透明；这证明选中行本身错误地落进了 fade。
- 重新核对 26.6 Swift interface、`sub_1001284F8` 的反编译与汇编后，确认 Music 的 mask target 是
  flipped 的 `AMPFlippedDocumentView`，non-pretty 自动跟随 locations 仍是
  `[0, 70 / height, 0.5, 1]`。本项目外层 container 未 flipped，因此最终反转 `startPoint` 与
  `endPoint`，而不是继续修改 distance。
- 新回归在对称实现上先以原始退出码 1 失败：800 point 视口的第二个 stop 与 `70 / height` 相差
  0.4125，gradient vector 的起点和终点也与目标相反。修复后渐隐与完整高度两项定向回归通过；
  LyricsXPackage 108 项、13 个 suite 全部通过，原始退出码 0；隔离 DerivedData 的 LyricsX workspace
  Debug build 成功。未启动应用做交互式 UI 验证。

2026-08-30 快速 fallback word 的运动 envelope：

- 使用真实歌词 `You say you say what I should do` 的 0.14–0.22 秒 inline timing 增加回归；旧实现下
  每个空格分隔单元仍使用自己的短 spring，测试以原始退出码 1 失败。
- 修复后连续快词、孤立快词和结构化快词共 4 项 layout 回归全部通过；LyricsXPackage 117 项、
  15 个 suite 在 `--no-parallel` 下全部通过，原始退出码 0。
- 默认并行全量运行仍会触发既有 `WidgetDataStoreTests.writeAndRead` 与 `clearData` 共用同一静态 suite
  名称的竞态；单独运行失败项通过。本次没有修改该测试或 widget data store。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。未启动
  应用做交互式 UI 验证。

2026-08-30 恢复旧 SwiftUI 行间 cascade：

- 回归先在单 clip spring 实现上以原始退出码 1 失败：普通换行仍存在 1 个 clip bounds spring，附近
  row 的 `position.y` animation 为 0，无法产生逐行弹跳。
- 修复后 6 项 `LineTransitionProbes` 全部通过：普通换行有 3 行上方 smooth settle 与当前行加下方
  5 行 spring cascade，spring 间隔为 80 ms；快速连续换行会取消 row cascade，并从当前可见 clip
  origin 开始 critically damped settle；点击歌词仍使用原有 interactive clip spring。
- LyricsXPackage 117 项、15 个 suite 在 `--no-parallel` 下全部通过，原始退出码 0；
  `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。
- 本次没有启动应用做交互式 UI 验证；最终视觉效果仍需在真实歌词播放中与 Apple Music 并排确认。

2026-08-31 隔离自动换行后的行内高亮：

- 使用 4 组新造的中文、英文和中英混排长歌词生成 3–4 个 visual row。旧实现中每行 gradient 直接位于
  共享的整句 glyph mask 下，测试找不到任何逐行 colour container，以原始退出码 1 失败；这对应了
  第一行 gradient 的 8 point 上下 padding 提前照亮第二行左侧 glyph 的截图现象。
- 修复后每个 visual row 都有独立 colour container 与 glyph mask；测试同时校验 mask 只包含本行 word，
  gradient 的 `position.y` 和 `bounds.height` 来自该行精确 typographic frame。同一组定向回归通过，
  行内结构与真实时间轴动画探针共 6 项通过。
- 第一次完整复跑中，既有 wall-clock 探针 `emphasisRipplesAcrossNeighboursInsteadOfFreezingEachGlyph`
  瞬时报告 glyph 停在顶点 0.75 秒；该探针单独串行复跑通过，随后显式 `--no-parallel` 的完整
  LyricsXPackage 124 项、17 个 suite 全部通过，原始退出码 0。
- 逐行 colour container 只覆盖本行 typographic frame 加 emphasis outset，不为三行歌词重复分配三份
  整句高度的 mask surface。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。
- 本次没有启动应用做交互式 UI 验证；需要在真实播放中确认截图里的版权行不再由第二视觉行提前高亮。

2026-08-31 尝试用单 clip spring 降低全屏行间动画的合成开销：

- 重建后的 Music 26.6 IDA database 显示，两个普通自动播放调用路径都会选择固定 line-change timing，
  timed-word 歌词也不例外；动态 damping ratio / period 公式属于另一条 descriptor / interaction 路径。
- 新回归在 9 个 row animation 的 cascade 实现上先以原始退出码 1 失败：期望的 clip bounds spring
  数量为 1，实际为 0。修复后普通切行只有 1 个欠阻尼 clip spring，所有 row 的 `position.y` animation
  数量为 0；快速连续切行会从前一个 spring 的 presentation origin 开始高阻尼收敛。
- 6 项 `LineTransitionProbes` 全部通过；LyricsXPackage 125 项、17 个 suite 在 `--no-parallel` 下全部
  通过，原始退出码 0。`MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离
  DerivedData 构建成功，原始退出码 0、0 warning。
- 本次没有启动应用做交互式 UI 验证；自动化验证固定了动画数量、spring 参数、40% baseline anchor 和
  中断连续性，真实全屏 frame pacing 仍需播放时确认。该方案随后在 2026-09-01 的实机播放中被用户否决：
  行间观感接近线性平移，行内动画也被父级整体运动压过。

2026-09-01 恢复 SwiftUI 式行间 cascade：

- 回归在单 clip spring 实现上先以原始退出码 1 失败：普通切行实际有 1 个 clip bounds spring、0 个
  row `position.y` animation，目标为 0 个 clip spring、9 个 row animation。
- 恢复后普通切行重新得到 3 个上方 smooth settle 与当前行加下方 5 行 spring，6 个 spring 保持
  `period 0.6 / dampingRatio 0.725` 和 80 ms stagger；快速切行仍会取消 cascade 并从当前可见 clip
  origin 高阻尼收敛。
- 6 项 `LineTransitionProbes` 与 6 项 `LineEmphasisProbes` / `LineEmphasisStructureProbes` 全部通过，
  原始退出码均为 0。行内 word/glyph timing、glow 与多行分层源码没有改动。
- LyricsXPackage 125 项、17 个 suite 在 `--no-parallel` 下全部通过，原始退出码 0；
  `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功，原始
  退出码 0、0 warning。本次没有启动应用做交互式 UI 验证。

2026-09-04 行 layer 光栅化、两档 cascade 与两档结构化行内策略：

- 光栅化回归 `rowLayersRasterizeLikeAppleMusicWithoutBeingAsked` 先在旧实现上以原始退出码 1 失败：进入
  window 后 `shouldRasterize` 为 false、`rasterizationScale` 为 1.0 而 backing scale 为 2.0。修复后
  `LineBlurProbes` 2 项通过，blur 动画期间仍会关掉光栅化并在 0.12 秒后恢复。
- `LineTransitionProbes` 改为按 `LineCascadeVariant` 注入：3 项 Apple Music 变体（与新旧视口相交的全部行
  都拿到 mass 1 / stiffness 100 / damping 18 的 spring，自上而下每行晚 50 ms；回滚时自下而上每行晚
  25 ms；cascade 在飞时新选行被推迟，等待「spring settlingDuration + 最慢行 delay」后追上并再次 cascade），
  3 项 legacy 变体保持原契约（9 个行动画、6 个 spring、80 ms、0.4 秒内改高阻尼 clip settle），点击歌词与
  viewport mask 两项按两档参数化，共 10 个用例通过。
- `AnimationPlanTests` 新增 `fullEmphasis` 在 `zh-Hans` / `ja-JP` / `en-US` 下 factor 1 与首字零延迟、两个隐藏
  defaults 键的默认值与非法值回退；`LineEmphasisStructureProbes` 新增中文结构化词在两档策略下 glow 分别为
  0 与 0.4、lift 两档都安排的探针。
- LyricsXPackage 133 项、17 个 suite 在 `--no-parallel` 下全部通过，原始退出码 0；SwiftFormat 修正后复跑
  同样 133 项通过、退出码 0。`MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离
  DerivedData 冷构建与增量构建都成功，原始退出码 0、0 warning。
- 本次没有启动应用做交互式 UI 验证。全屏帧率是否恢复 60 FPS，以及两档 cascade、两档行内策略哪一档更接近
  Apple Music，需要用户播放时按上文的 `defaults write` 切换并排比较；`LineTransition` 与 `InlineKaraoke`
  日志会写明当时生效的 variant 与 policy。

2026-09-05 补齐逐字歌词动态换行弹簧与启动时序：

- 回归 `appleMusicWordTimedCascadeUsesTheGapAfterThePreviousSungLine` 在旧实现上以原始退出码 1
  失败：0.2、0.5、0.75 秒三种间隙都得到固定 stiffness 100 / damping 18，而非二进制公式的对应值。
  接入动态分支后通过，并扩展覆盖重叠唱句和超过上限的间隙。
- 向前、向后延迟回归也先以原始退出码 1 失败：应当一起启动的两行实际分别相隔 50 ms、25 ms。
  修正减一截断后通过；同一探针同时验证每行在视口中的起点连续，首行和其他行的 model position
  与动画终点均不变。
- 结构化结束时间优先于 inline fallback；只有逐字起点而没有结束时间时保留固定弹簧；没有逐字数据时
  也保留固定弹簧；延后追赶从最后真正显示过的行计算间隙，跳过的行不会污染参数。这些边界均进入
  `LineTransitionProbes`，该 suite 共 13 项通过。
- 修改只在重建歌词与换行时选择参数和安排动画，沿用现有行 layer 光栅化及 Core Animation 插值。
  全库横向检查后，余下固定 spring 调用属于重新居中和间奏 dots；它们没有这条自动换行的 gap 输入，
  因此继续使用原有固定曲线。旧 `legacySwiftUI` 策略与点击跳转测试保持通过。
- `LYRICSX_USE_LOCAL_DEPENDENCY=1 swift test --package-path LyricsXPackage
  --scratch-path /tmp/codex/SwiftPM/LyricsX --no-parallel`：137 项测试、17 个 suite 通过，原始退出码 0。
  SwiftFormat lint 与 `git diff --check` 通过。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 在
  `/tmp/codex/DerivedData/LyricsX` 冷构建成功，原始退出码 0。先前尝试因 agent 旧缓存缺失 checkout
  和预编译模块失败，移开损坏缓存后完成验证；最终警告来自未修改的依赖、Storyboard 和旧 API 使用，
  本次修改的歌词动画代码没有编译警告。构建沿用 workspace 的依赖锁定版本。
- 文档判断：更新本篇的原版调用链、参数公式、两档策略表、首行坐标补偿与验证记录；既有提案保留为
  当时的决策快照，不把旧结论当成当前实现。没有新增需要登记的项目术语。
- 未启动应用做交互式 UI 验证，也未运行 `xctrace`；本次验证不构成实际观感或全屏帧率测量。

### 2026-09-06 诊断分组与行内动画逐事件追踪

- 现象：用户看日志时被背景渲染（`GradientFrame`）的记录淹没；同时要查的行内动画在日志里一条记录都没有，
  因为 `SyncedLyricsLineContentLayer` 的 `InlineKaraoke` 自 9eb7f37 起 `isEnabled:` 是编译期 `false`，
  b9eb1dc 的总开关没有覆盖它。
- 改法：subsystem 拆成 `com.JH.LyricsX.AppleMusicLyricsPanel.Lyrics` 与 `.Backdrop`；`PanelDiagnostics` 由单个
  布尔改为 `lyrics` / `karaoke` / `backdrop` 三组，环境变量与 defaults 键都接受 `1` / `all` / 组名列表，
  旧的布尔写法仍是全开；`InlineKaraoke` 改挂 `karaoke` 组，并补齐逐事件记录：每行的词表（文本、起止、
  `s` / `i` 来源、音节数）、每个词的 swell 判定与逐字 rise / return 延迟、每个音节的抬高与回落（带
  `elapsedTime`）、每个字的收回时刻、重同步与 reset，都带 `line=` 前缀；`LyricsLine` 的
  `Line layout built` 带整行文本。
- 验证：`PanelDiagnosticsTests` 5 项覆盖默认关闭、全开、组列表、defaults 字符串与布尔、环境变量优先级；
  `LyricsXPackage` 全量 178 项 / 26 suite `--no-parallel` 退出码 0；工作区 LyricsX Debug 隔离构建成功；
  SwiftFormat lint 无差异。
- 文档判断：更新本节上方「性能诊断」与 `AppleMusicMetalGradient.md` 的诊断段；没有新增需要登记的项目术语。
- 未启动应用做交互式验证；新增追踪的实际输出待下次播放后用 `log show` 读取。

## 以后重做版本核对时

Apple Music 私有实现会随版本变化。升级验证时应分别核对：word factor 的语言门槛、rise/return delay、
deglow spring、`lineChangeSpringTimingParametersValues` 的消费端（包括 timedWords 动态分支与 gap 来源）、
`lineDelay`（pretty 与侧栏两个值）、延迟序号的减一截断与回滚处理、首行位移如何传到后续行、
「动画中不选新行」的 tick 门槛、tap line spring、selected baseline fraction、行 layer 的
rasterize 生命周期、blur membership、viewport mask 分支、mask target 的 flipped 状态与 cubic curve。
这些值集中在纯 plan、`LyricsSpecs` 与 `AnimationVariants`，不要先在 layer 执行代码里散改常数。
