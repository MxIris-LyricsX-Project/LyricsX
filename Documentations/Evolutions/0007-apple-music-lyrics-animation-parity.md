# 0007 - 对齐 Apple Music 26.6 歌词动画

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-29
- **最后更新**: 2026-08-29
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / Pull Request**: `develop`（当前工作树，未单独开分支）
- **配套文档**: [Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md)；旧的
  `docs/superpowers/plans/2026-06-13-applemusic-lyrics-calayer-engine.md` 保持原样，作为历史记录

## 摘要

把 `AppleMusicLyricsPanel` 当前的歌词动画从“参数近似”改成与 Apple Music 26.6 相同的动画结构：

- 主歌词使用 Apple Music 的 `.topRelative(40)`：第一行文字 baseline 位于歌词可视高度的 40%。
- 用真实 word/syllable 层级驱动逐字 lift、scale 与 glow，而不是把每个 timed chunk 都当成满强度词。
- 用同一个 transition coordinator 驱动 `NSClipView.bounds` spring；只有模型 frame 真实改变的行
  才增加自己的 `AnimationDescriptor`，不能用所有可见行重复模拟同一段滚动位移。
- 按 Apple Music 的 `blurredLineViews` 集合和 0.12 秒自定义曲线更新模糊，而不是统一模糊所有非选中行。
- 在 LyricsKit 中保留并持久化结构化 timing；Apple Music 的 Timed Text Markup Language（TTML）
  歌词走精确路径，其他歌词源继续使用现有 phrase 推断作为 fallback。

本提案直接替换现有动画，不增加设置或隐藏开关。Background Vocals 与 duet 不在本次范围。

## 动机

当前实现已经具备逐字扫光、glyph lift 和 clip spring，但视觉上仍与 Apple Music 有明显差距。
继续调 scale、spring 或位移常数不能消除这些差距，因为剩余问题来自模型和调度结构：

1. **word 强度被固定为最大值。** `SyncedLyricsLineContentLayer.emphasisFactor` 固定为 `1`，
   短词、长词和 Apple Music 明确排除的语言都会获得完整的 14% scale 与 0.4 glow。
2. **glow 挂错层级。** 当前每个 `GlyphRunLayer` 自己投影，并与 glyph 回落共用一条 spring；
   Apple Music 把 shadow 放在 rasterized `WordLayer` 上，并在词结束时用另一条 spring 单独 deglow。
3. **精确 word/syllable 层级在解析时丢失。** LyricsKit 的 `InlineTimeTag.Tag` 只有开始时间和字符索引；
   TTML 的 `end`、嵌套关系和 word 与 syllable 的边界无法经过 LyricsX 扩展歌词格式（LRCX）往返。
   面板只能用 `phraseDuration` 与 `phraseGlyphCount` 猜测原始词组。
4. **行切换缺少明确的状态所有权。** 选中位置原本居中，后续尝试又把一次 clip 位移复制成所有
   可见行各自的 spring；前者位置不符，后者会让带 blur、mask 和 glyph 子树的多行同时合成，造成掉帧。
5. **模糊范围和曲线均为近似。** 当前所有非选中行使用同一半径和 0.33 秒
   `easeInEaseOut`；Apple Music 按上下文维护需要模糊的行集合，并使用另一条短曲线。

旧设计记录只确认了 clip action，后续第一次实现又把 `LinesUpdateResult` 中的 row descriptor 误解成
“每个可见行都要补偿完整 clip 位移”。复核消费端后可以确定：clip bounds 与真实 row frame update
属于同一个 animator，但 row descriptor 只对应模型 geometry 确实改变的行。旧记录保持不动；本提案
和配套实现说明记录修正后的结论。

## 前期调研

### Apple Music 的数据模型

`/Volumes/RE/AppleMusic/26.6/SwiftInterfaces/LyricsX.Lyrics.swiftinterface` 显示：

- `Lyrics.Word` 保存 `originalStartTime`、`originalEndTime`、`text`、`syllables` 和
  `Emphasis`。
- `Emphasis` 是 `factor(Double)` 或 `none`，不是所有词都默认满强度。
- `Lyrics.Syllable` 保存精确的开始、结束、文本、range 和 `wordLength`。
- `Lyrics.Capability` 分为 `gradient`、`lift`、`emphasis`；lift 与额外的 scale/glow
  是两项独立能力。

Apple Music 把 MediaServices 的歌词对象转换成上述模型时，按语言和词本身计算 emphasis：

- 基础语言代码为 `ar`、`he`、`zh`、`ja` 时只启用 gradient 与 lift，不启用 emphasis。
- 其他语言只有在 word duration 严格大于 1 秒、`wordLength <= 7` 时才生成
  `factor(min(duration, 2) - 1)`。
- 其余情况是 `none`。因此 factor 的范围自然为 `0 ... 1`。

这意味着“不 emphasis”不等于“不动”：glyph 仍可 lift，但 scale 保持 1、glow 保持 0。

### word 动画

26.6 的逐帧链路最终进入 word 动画函数 `sub_10018B2B4`。反编译与 64-bit Arm（ARM64）
指令共同确认：

- scale 为 `lowerBound + factor * (upperBound - lowerBound)`，实测规格为 `1 ... 1.14`。
- glow opacity 使用同一 factor 在 `0 ... 0.4` 内插值。
- glyph spring 的 damping ratio 为 1，period 为 `min(wordDuration, 3)`。
- stagger 为 `min(wordDuration / glyphCount * 0.4, 0.4)`。
- glyph 的起跳延迟使用 `stagger * (glyphIndex + 1)`。
- glyph 回落在自己的起跳延迟之外，再等待 `2 * wordDuration / glyphCount`。
- `WordLayer` 设置 `shouldRasterize = true`，`rasterizationScale` 等于显示 scale，
  shadow radius 为 5、offset 为 0。shadow opacity 在整个 word 层上变化。
- word duration 到达后，glow 由独立的 `mass 1 / stiffness 14 / damping 7` spring 回到 0；
  它不与 glyph 的几何回落绑在一起。

### 正常行切换

选中行变化的正常路径由 `sub_1001E6B54` 调用 `sub_1001DCBD4`，消费端是 `sub_10015AA20`：

- `LinesUpdateResult` 同时保存 animated updates、non-animated updates 和
  `newContentOffsetY`。
- `sub_10015AA20` 只创建一个 `LayerPropertyAnimator`：先登记 update result 中真实存在的 row update，
  再把 `NSClipView` backing layer 与设置 clip bounds 的 closure 登记进同一个 animator。
- `sub_10015AF20` 最终调用 `contentView.setBounds(_:)`；clip 本身不是先跳变、再由所有可见 row
  反向补位的假动画。
- row descriptor 仍保存目标 `lineView`、`deltaY` 与 delay，但它只服务于 row 模型 frame 确实变化的
  update，例如重新布局或内容集合变化；不能把 clip displacement 当成每一行的 `deltaY`。
- 常规 line-change spring 为 `mass 1 / stiffness 100 / damping 18`。
- 行的目标 `NSView.frame` 先成为模型真值；显式 Core Animation 从当前 presentation
  值移动到目标，因此中途再次换行不会跳回旧模型位置。
- clip offset 与真实逐行更新属于同一次 transition，而不是互相独立的两次动画。

选中位置由 `sub_10015A090` 与 `sub_10015CD84` 共同计算。`.topRelative` 的公式是：

```text
topInset = visibleHeight × cardHeightPercentage / 100 - CTFontGetAscent(font)
targetY  = max(lineFrame.minY - topInset, 0)
```

用户提供的 Apple Music 录屏中，选中 baseline 位于歌词可视高度约 40%，与 `.topRelative(40)` 一致。
本项目的 row frame 还包含 28 点文字上内边距，因此实现需要从 40% 中减去“内边距 + font ascent”，
不能直接照搬 text-only line frame 的公式。

### line blur

`SyncedLyricsVisualExperienceManager` 持有 `blurredLineViews: Set<SyncedLyricsLineView>`。
更新函数 `sub_1001DAD9C` 根据当前可见行、选中行和上下文生成目标集合与半径，而不是把
`selected == false` 直接等同于 blurred。

对 `filters.gaussianBlur.inputRadius` 的动画由 `sub_10019EBAC` 建立：

- duration 为 0.12 秒。
- timing curve 为 `custom(point1: (0.33, 0), point2: (0.2, 0.1))`。
- 动画期间临时关闭 rasterization，结束后恢复，避免缓存住中间模糊结果。

### 当前 LyricsKit 的信息损失

`Lyrics+TTML.swift` 当前在每个 `<span>` 开始时只追加
`InlineTimeTag.Tag(index:time:)`，没有读取 `end`，也没有保存 element nesting。
真实样本会出现一个 span 包含多个字符，例如：

`<span begin="29.605" end="30.449">故事的</span>`。

因此“一个 timing tag 等于一个字符”与“相邻 timing tag 必须拼成 phrase”都不是稳定契约。
面板需要读取源数据实际提供的 word/syllable 结构，而不是从渲染后的 tag 列表反向猜测。

## 目标

1. Apple Music TTML 主歌词的逐字动画采用 26.6 的 word/syllable 层级、能力门槛和调度公式。
2. 正常前进、反向移动和可中断的连续换行使用一条 render-server 驱动的 clip bounds spring；
   只有模型 frame 真实变化的行才增加 row animation。
3. 选中行第一条文字 baseline 位于歌词可视高度的 40%。
4. line blur 的目标集合、半径计划、曲线与 rasterization 生命周期对齐 Apple Music。
5. 结构化 timing 可以经过 LRCX 保存和重载，不因缓存而退化。
6. 旧歌词文件、非 Apple Music 来源和损坏的新 attachment 都能安全回退到现有路径。
7. 一条歌词换成两行或更多视觉行时，文字仍按逻辑顺序从上到下显示。

## 非目标

- 不实现 Background Vocals、duet agent alignment 或对应的 0.9 deselected transform。
- 不为网易云音乐、QQ音乐、酷狗等来源发明通用 word/syllable 推断；它们继续使用现有 phrase fallback。
- 不增加用户设置、隐藏默认值或两套长期并存的渲染器。
- 不逐字移植 Apple Music 私有类型；实现使用公开 AppKit/Core Animation 能力和项目现有的
  `LayerPropertyAnimator`。
- 不修改旧的 `docs/superpowers/plans/2026-06-13-applemusic-lyrics-calayer-engine.md`。
- 不在本提案中解决 Apple Music 未来版本可能改变动画规格的问题。

## 提议方案

### 一、LyricsKit 增加结构化 synchronized timing

在 `LyricsLine.Attachments` 下新增公开、纯数据的 `SynchronizedTextTiming`：

- `Word` 保存行内 character range、相对行首的 time range 和 syllables。
- `Syllable` 保存行内 character range 与相对行首的 time range。
- 整体保存可选 line duration。
- range 继续使用 Swift `Character` 计数，与现有 `InlineTimeTag.Tag.index` 契约一致，
  不暴露 Core Text 的 UTF-16 index。
- 文本不重复存储；word 与 syllable 都通过 range 引用 `LyricsLine.content`。

TTML parser 改为维护 element stack：

1. 读取 `<p begin end>` 作为 line 时间范围。
2. 同时读取 `<span begin end>` 的开始、结束、文本 range 与嵌套关系。
3. 明确存在外层 word、内层 syllable 时原样保留。
4. 只有一层 timed span 时，将该 span 表示为一个 word 和一个同范围 syllable，不额外猜测。
5. 继续生成现有 `InlineTimeTag`，供旧消费者和非精确 fallback 使用。

只有 Apple Music TTML parser 生成该结构；其他 parser 不变。

### 二、用附加 attachment 扩展 LRCX，而不是破坏 `tt`

现有 `[tt]` attachment 的格式与语义保持不变。新增
`[synchronized-timing]` attachment，使用带版本号的单行 payload 保存：

- word 的开始/结束毫秒与 character range；
- 每个 syllable 的开始/结束毫秒与 character range；
- line duration；
- payload version。

兼容契约：

- 新版读到旧文件：没有新 attachment，使用现有 phrase fallback。
- 旧版读到新文件：仍可读取 `[tt]` 并完成逐字扫光；未知 attachment 不得影响歌词行。
- 新版读到未知 version、越界 range 或损坏 payload：只丢弃结构化 attachment，继续使用 `[tt]`。
- 新版保存并重新读取：word/syllable 层级、结束时间和 character range 必须完全往返。
- 序列化只使用整数毫秒，避免文本往返产生不必要的浮点差异。

具体分隔符属于实现细节，但 version、字段顺序、range 校验和 fallback 行为必须由测试固定。

### 三、面板优先消费结构化 timing

`LineTextLayout` 增加两条明确的数据路径：

- **精确路径**：存在 `SynchronizedTextTiming` 时，按真实 word range 建 `WordNode`，
  再按 syllable range 把 glyph 分配到相应调度单元。所有公式使用真实 word duration 与 glyph count。
- **fallback 路径**：没有结构化数据时保留当前 `InlineTimeTag` 与 phrase grouping，
  不改变其他歌词源的现有表现。

`phraseDuration` 与 `phraseGlyphCount` 只属于 fallback，不再污染精确路径。

语言能力从 `Lyrics.idTags["lang"]` 解析：转为小写基础语言代码，去掉 `-` 或 `_` 后的地区部分。
`ar`、`he`、`zh`、`ja` 禁用额外 emphasis；未知或缺失语言按 Apple Music 的默认能力集合处理。

### 四、按 word factor 重建 emphasis

为精确路径生成纯数据 `WordEmphasisPlan`：

- `duration > 1` 且 `wordLength <= 7` 且语言允许 emphasis：
  `factor = min(duration, 2) - 1`。
- 其他情况 factor 为 0，但 lift 计划仍可存在。
- scale、glow、spring period、stagger、rise delay、return delay 全部预先计算，
  layer 代码只执行计划，不重复判断业务条件。

`WordNode` 的层级改为与 Apple Music 一致：

1. glyph layer 只负责 position/frame 与 affine transform，不再持有 glow shadow。
2. `WordLayer` 设置正确的 `shouldRasterize`、`rasterizationScale`、shadow color、
   radius、opacity 和 offset。
3. rise 使用 factor 插值得到 scale 与 glow，并恢复 `glyphIndex + 1` 的首个 stagger。
4. glyph 几何回落沿用 word emphasis spring。
5. word duration 到达时另起 `mass 1 / stiffness 14 / damping 7` 的 deglow spring。
6. seek、行复用、选中行变化和歌词替换都取消 pending work，并把模型状态一次性恢复到 rest。

所有可中断动画从 presentation layer 取可见起点，模型值始终先写到最终目标。

### 五、用一个 transition coordinator 驱动 clip bounds

在 `AppleMusicLyricsScrollView` 内引入专用的 line transition coordinator，而不是继续扩张
`springClip(to:)`：

1. 根据新选中行的第一条文字 baseline 和 `.topRelative(40)` 计算最终 clip offset。
2. 提交前记录 clip 的 presentation origin；在关闭 implicit actions 的 transaction 中先提交最终
   `NSClipView.bounds` 模型值，再安装一条 `bounds.origin.y` spring。
3. 正常 selection 不改变本项目中任何 row 的模型 frame，因此不创建 row position animation，也不在
   切行瞬间对所有可见 row 调用 `layoutSubtreeIfNeeded()`。
4. 若其他上下文以后真的改变 row frame，只对那些 frame 有 delta 的 row 使用 update result 中的
   descriptor；不得把 clip displacement 复制到全部可见 row。
5. 连续换行从当前 clip presentation origin 接续；同一目标的重复请求不重启动画。
6. 初始化、数据整体替换和无法获得 presentation layer 的离屏状态直接落到模型终点。

AppKit 的 view geometry 仍是模型权威。实现不得把 backing layer 的 `frame`、`position` 或
`bounds` 当作独立持久状态；显式动画只承载 presentation。这一约束同时适用于 row view 与 clip view。

普通播放使用 `mass 1 / stiffness 100 / damping 18`。用户点击歌词触发跳转时，采用 Apple Music
对应路径的 `mass 2 / stiffness 260 / damping 50`；非交互的大跨度数据跳转保持无动画，避免跨整首歌飞行。

### 六、按上下文生成 blur plan

把 `updateDistances(animated:)` 中的 “非选中即 blurred” 改成两阶段：

1. 纯函数根据可见行、选中行、相对位置和特殊行类型生成 `LineBlurPlan`。
2. view 层只对 membership 或 radius 真正变化的行执行更新。

动画使用：

- 0.12 秒；
- cubic control points `(0.33, 0)` 与 `(0.2, 0.1)`；
- key path `filters.gaussianBlur.inputRadius`；
- 动画期间关闭 rasterization，completion 后恢复原值；
- 中断时从 presentation radius 继续，模型 radius 保持目标值。

Background Vocals 已排除，因此相关分支只在 plan 类型中保留未来可扩展性，不在本次伪造数据。

### 七、固定多行文本的坐标系

`LineTextLayout` 已把 Core Text 的 y-up baseline 转成 y-down 坐标。`SyncedLyricsLineContentLayer`
必须始终保持 `isGeometryFlipped = true`；不能根据 AppKit backing layer 的当前 `isGeometryFlipped`
动态取反，否则同一条歌词换行后会把第二个视觉行画到第一个视觉行上方。

## 详细设计约束

### 动画状态所有权

- `NSView.frame`、`NSClipView.bounds` 与可查询的 selection 是模型真值。
- `CALayer.presentation()` 只用于确定下一条动画的可见起点。
- 每个动画使用稳定 key；同属性的新动画替换旧动画，completion 必须核对 identity，旧 completion
  不能清理新动画。
- `layout()` 和 frame size 更新必须在模型事务内完成，不能等 animation completion 才补。

### 数据校验

结构化 timing 进入渲染前必须满足：

- word ranges 有序、非空、不越过 line content；
- syllable range 位于所属 word 内；
- time ranges 有限、非负、结束不早于开始；
- word 与 syllable 可以有间隙，但不能以错误数据制造负 duration；
- 不合法的整个 attachment 退回现有 `InlineTimeTag`，不能只保留一半结构造成 glyph 遗失。

### 性能边界

- 不增加逐帧文本重排；Core Text layout 仍在行配置时完成。
- word rasterization 只作用于 word 自身，不把整行合成成一张持续失效的大 bitmap。
- 非活跃行不运行 glyph animator。
- 相同 blur、alpha、frame 和 clip 目标不重复创建动画。
- layer 数量与现有 glyph-layer 架构同阶；新增的是每个 word 的 rasterization 与少量 coordinator 状态，
  不是每帧新建 layer。

## 替代方案考量

- **给所有可见 row 保留完整位移 spring** —— 否决。它重复了 clip 的工作，且让多个带 blur、mask、
  rasterized word 的 layer tree 同时合成；用户录屏已经复现明显卡顿。
- **只移植 line cascade，不改 timing 数据** —— 否决。行间会改善，但 word 仍对所有语言和词长使用
  满强度，用户指出的行内差距仍在。
- **只在 AppleMusicLyricsPanel 中推断 word** —— 否决。TTML 的 explicit end 与 element nesting
  已在 LyricsKit parser 丢失，面板无法可靠恢复；缓存后还会再次退化。
- **直接修改现有 `[tt]` 格式** —— 否决。它会让旧版 LyricsX 与其他 LyricsKit consumer 无法读取
  逐字时间。附加 attachment 可以保持原格式不变。
- **结构化 timing 只驻留内存** —— 否决。Apple Music 歌词保存进库后，下一次播放会退化，
  用户会看到同一首歌第一次和第二次动画不同。
- **同时保留新旧两套动画并加开关** —— 否决。用户已选择直接替换；长期双路径会扩大测试矩阵，
  也会让错误路径继续存在。
- **本次一并实现 Background Vocals 与 duet** —— 暂缓。它们还需要 agent、role、对齐方向和
  独立 transform 数据，超出当前“主歌词动画对齐”的边界。
- **改写旧计划文档** —— 否决。旧文件保留当时的探索过程；本提案和新的实现说明成为 26.6
  行为的权威记录。

## 影响

### 用户可见变化

- 当前唱到的主歌词 baseline 位于歌词可视高度约 40%，处在中间偏上的位置。
- word lift、scale 与 glow 的强度会随词持续时间和长度变化；中文、日文、阿拉伯文和希伯来文
  不再出现 Apple Music 没有的额外 scale/glow。
- 行切换由一条 Core Animation clip bounds spring 驱动，不再因每行重复动画而卡顿。
- 换行歌词按正确的逻辑顺序从上到下显示。
- 非选中行的 blur 范围与过渡速度会变化。
- 没有新增菜单、设置或首次启动提示。

### 可发现性

这是现有歌词面板的直接视觉修正，不需要用户学习新操作。发布说明只需说明歌词动画和布局已更接近
Apple Music；不暴露内部 spring、descriptor 或 timing attachment 名称。

### 数据与配置兼容

- 不新增或迁移 `UserDefaults`。
- 旧 LRCX 文件继续可读，缺少结构化 attachment 时走现有 fallback。
- 新文件继续写现有 `[tt]`，旧版本仍能完成逐字扫光。
- 新的 `[synchronized-timing]` 必须对未知 reader 无害，并在新版之间无损往返。
- 损坏的新 attachment 不得让整首歌词加载失败。

### 平台与最低版本

不改变最低 macOS 版本，不引入新的系统权限、entitlement 或隐私清单条目。

### 发布

不需要数据迁移或偏好迁移。发布说明应提到选中行位置和歌词动画变化，但不需要单独的升级指南。
由于视觉变化直接替换旧行为，发布前需要在正常前进、反向点击、seek、暂停恢复和连续快速换行中检查。

## 测试与验证

### LyricsKit

先添加会在旧实现上失败的测试，再实现数据模型：

1. flat timed span 的 explicit end 被保存，不再由下一 tag 猜测。
2. nested word/syllable TTML 保留层级、character range 与 time range。
3. 包含多字符 span、组合字符和混合语言的 index 使用 Swift `Character` 语义。
4. `SynchronizedTextTiming` 序列化后重新解析，所有字段相等。
5. 旧 `[tt]` 文件不受影响；新 attachment 缺失时返回 nil 而不是伪造结构。
6. 未知 version、截断 payload、越界 range 会安全回退。
7. 新文件仍包含可由旧逻辑读取的 `[tt]`。

### AppleMusicLyricsPanel

纯计划测试固定：

- 四种排除语言和带地区后缀的语言代码；
- duration 的 1 秒严格边界、2 秒封顶与 word length 7/8 边界；
- scale、glow、period、stagger、rise delay、return delay 与 deglow spring；
- `.topRelative(40)` 的 baseline 位置换算；
- blur membership、radius 和 cubic curve。

离屏真实窗口 probe 固定机制而非主观帧数：

- glow 位于 rasterized word layer，glyph layer 不持有 shadow；
- model target 在动画开始前已经是终点，presentation 从可见起点运行；
- 连续 emphasis 与连续换行从 presentation 值接续，不出现跳回；
- 普通切行只有一条 clip bounds spring，所有模型 frame 未变化的 row 都没有 position spring；
- 选中行第一条文字 baseline 最终位于可视高度的 40%；
- 截图中的长版权句换行后仍按逻辑顺序从上到下显示；
- blur 动画结束后 rasterization 状态恢复；
- reset、seek 和 view reuse 不留下 pending work 或 animation。

验证构建时使用项目规定的 agent 专属 DerivedData 与 Swift Package Manager scratch path。
默认不启动模拟器，也不进行交互式界面操作；若需要实际点击或录屏比较，另向用户取得授权。

## 落地步骤

1. 在 LyricsKit 添加 TTML fixture、失败测试、`SynchronizedTextTiming` 模型与 LRCX 往返。
2. TTML parser 同时生成结构化 timing 和现有 `InlineTimeTag`，跑 LyricsKit 全部离线测试。
3. AppleMusicLyricsPanel 增加精确/fallback 两条 layout 数据路径和 `WordEmphasisPlan` 测试。
4. 把 glow 移到 rasterized `WordLayer`，拆分 glyph return 与 deglow，并补真实 layer probe。
5. 引入 line transition coordinator，切换到 `.topRelative(40)`，补普通、点击、中断、单 clip spring
   与模型终点 probe。
6. 引入 `LineBlurPlan` 和 0.12 秒自定义曲线，补 rasterization lifecycle probe。
7. 跑 LyricsKit 测试、LyricsXPackage 测试与 LyricsX workspace Debug build；以原始退出码判定成败。
8. 新建 `Documentations/Internal/AppleMusicLyricsAnimation.md`，记录最终调用链、数据格式、
   AppKit geometry 所有权、实际实现与提案的差异；更新文档索引。
9. 收尾时更新本提案状态、决策日志、配套文档链接，并判断是否产生需要登记的新术语。

## 风险

- **Apple Music 私有实现会漂移。** 本提案绑定 26.6；将行为集中在纯 plan 与 specs 中，
  以后版本变化时可以逐项重新验证。
- **LRCX additive attachment 的旧版行为需要实测。** 不能只凭“未知 tag 应该被忽略”假设兼容，
  必须用旧解析路径测试读取与重新序列化。
- **AppKit 会回写 backing-layer geometry。** 如果把 layer model 当独立状态，layout pass 会造成跳变。
  view geometry 必须始终是模型权威。
- **重复 row animation 会压垮合成。** 正常 selection 没有 row frame delta，只允许 clip layer 动画；
  不能为了制造 cascade 再给所有可见 row 添加一次完整 displacement。
- **多层 flipped geometry 容易反转换行顺序。** Core Text 到 y-down 的转换只做一次，content layer
  的坐标契约必须固定，不能跟随 backing layer 状态动态取反。
- **word rasterization 可能增加显存和重建成本。** 需要检查长歌词、长行和 scale 变化时的 layer 数量与
  rasterization churn。
- **源 TTML 可能只有 flat span。** 数据模型允许一个 word 只有一个 syllable；不得为了造出层级而
  猜测不存在的边界。

## 文档策略

- 旧的 `docs/apple-music-lyrics.md` 与
  `docs/superpowers/plans/2026-06-13-applemusic-lyrics-calayer-engine.md` 均不在本次修改范围。
- 本提案是“为什么这样改、放弃了什么”的权威决策记录。
- 完成实现时新建 `Documentations/Internal/AppleMusicLyricsAnimation.md`，专门记录最终代码结构、
  26.6 逆向证据、已知降级和维护陷阱。
- 不需要新增使用指南：此变更没有调用者必须遵守、但从接口签名看不出的使用契约。
- 不需要修改公开 README：安装、使用方式和公开功能列表没有变化。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-29 | Created as Draft | 用户要求继续逆向并对齐 Apple Music 26.6 的歌词动画；当前行内弹跳仍有差距，行间只有平移。 |
| 2026-08-29 | 确定选中位置与跨仓库范围 | 用户选择与 Apple Music 相同的 `.top(12)`，并允许同步修改 LyricsKit 以保留精确 word/syllable 数据。 |
| 2026-08-29 | 确定主歌词范围 | 用户选择只处理主歌词；Background Vocals 与 duet 不进入本次实现。 |
| 2026-08-29 | 确定 fallback | Apple Music TTML 使用精确结构，其他来源继续使用当前 phrase 推断。 |
| 2026-08-29 | 确定持久化 | 用户选择向 LRCX 增加向后兼容的结构化 timing attachment，保存和重启后不得退化。 |
| 2026-08-29 | 确定替换方式 | 新动画直接替换旧路径，不新增用户设置或隐藏开关。 |
| 2026-08-29 | 确定文档策略 | 用户要求旧文档保持不动，为本次工作写新的提案与实现说明。 |
| 2026-08-29 | 完成澄清 | 用户确认以上边界已达成共同理解，允许创建 Draft 提案；实现仍需提案状态变为 `Accepted`。 |
| 2026-08-29 | Draft → Accepted | 用户明确回复“接受提案”，批准按本文范围开始实现。 |
| 2026-08-29 | Accepted → In Progress | 开始按提案实施；先完成 LyricsKit 的结构化 timing 与持久化，再接入动画层。 |
| 2026-08-29 | 配套文档判断 | **写**。[Apple Music 26.6 歌词动画](../Internal/AppleMusicLyricsAnimation.md) 记录最终数据链、AppKit geometry 所有权、降级边界和验证结果；没有新增面向用户的操作，因此不写使用指南。旧探索文档保持原样。 |
| 2026-08-29 | 术语表判断 | **不登记**。TTML、word、syllable、LRCX、Core Animation 和 presentation layer 都是通用技术术语或既有格式名，没有引入项目自造概念。 |
| 2026-08-29 | In Progress → Implemented | AppleMusicLyricsPanelTests 98 项通过；LyricsKit `LyricsService` target 与 LyricsX workspace Debug scheme 均构建成功。LyricsKit 全量 test target 被既有 `GroupProviderTests` test double 的 protocol conformance 编译错误阻断，新结构化 timing 由面板集成测试实际执行。未启动应用做交互式 UI 验证。 |
| 2026-08-29 | 根据视觉反馈收窄修正范围 | 用户确认行内动画已经符合预期，后续不再改动；只处理选中位置、行间掉帧和多行文字顺序。 |
| 2026-08-29 | 修正选中位置结论 | 用户录屏显示 Apple Music 选中 baseline 位于歌词可视高度约 40%；结合 `.topRelative` 的二进制公式，原 `.top(12)` 决策被 `.topRelative(40)` 取代。 |
| 2026-08-29 | 修正行间 transition 结论 | 复核 `sub_10015AA20` 与 `sub_10015AF20` 后确认：Apple Music 在一个 animator 中驱动 clip bounds 与真实 row frame update，不会把完整 clip displacement 复制给所有可见 row。用户批准按此修正。 |
| 2026-08-29 | 增加换行回归 | 原歌词文本顺序正确，错误来自 y-down layout frame 被动态翻回 unflipped content layer；以用户截图中的版权句固定 visual row 顺序与 content layer 坐标契约。 |
| 2026-08-29 | 完成视觉反馈修正 | 定向 5 项先红后绿；LyricsXPackage 99 项、10 个 suite 全部通过，原始退出码 0；隔离 DerivedData 的 LyricsX workspace Debug build 成功。行内动画实现保持不变，旧探索文档未修改。 |
| 2026-08-29 | 落地编号 | 在 `develop` 共享分支提交时按远端最大编号分配为 0007。 |
| 2026-08-29 | 补齐外层 viewport edge fade | 用户并排截图显示远处歌词没有像 Apple Music 一样渐隐。复核 26.6 后确认行 blur 仍是固定半径，连续衰减来自 `Music.LyricsXViewController` 的四段 `CAGradientLayer maskLayer`；自动跟随模式上下各 128 point。实现按该层级补 mask，不按距离放大 blur，也不额外增加已经不小于 Apple Music 的文字间距。 |
| 2026-08-29 | 验证 viewport edge fade | 回归在缺少 mask 时先以原始退出码 1 失败，修复后定向测试通过；LyricsXPackage 106 项全部通过、原始退出码 0，隔离 DerivedData 的 LyricsX workspace Debug build 成功。未启动应用做交互式 UI 验证。 |
| 2026-08-29 | 修正 viewport edge fade 分支 | 后续并排截图证明 128 / 128 point 的 pretty mode 分支与播放器窗口不符。重新核对 `sub_1001284F8` 汇编：non-pretty 且非 scroll 时，`D13` 从常量读取 70 point，`D12` 为 `height * 0.5`，最终 locations 是 `[0, 70 / height, 0.5, 1]`。回归在旧参数上报告 top stop 偏差 0.0725、bottom stop 偏差 0.34，修正后通过；未改 line blur 或真实 row spacing。 |
| 2026-08-29 | 验证非对称 viewport edge fade | 包含 HUD visibility 回归在内的 LyricsXPackage 107 项以 `--no-parallel` 全部通过、原始退出码 0；隔离 DerivedData 的 LyricsX workspace Debug build 成功。SwiftFormat 检查显示本次涉及的 package 文件均通过，AppDelegate 仅报告该文件既有的 property-body 与 doc-comment 格式问题。未启动应用做交互式 UI 验证。 |
| 2026-08-30 | 扩大视觉底边渐隐 | 用户确认顶部渐隐已经合适，但底部歌词仍保持可见太久。结合 mask layer 的 bottom-origin coordinates，保留控制视觉顶部的 0.5 stop，只把控制视觉底部的 first distance 从 70 point 扩到 128 point，最终 locations 为 `[0, 128 / height, 0.5, 1]`。这是当前面板的视觉校准，不再声称逐常量复刻 Music；line blur、row spacing 和 display-link 路径均未改变。回归先红后绿；完整 107 项、13 个 suite 连续两次通过，workspace Debug build 成功。 |
| 2026-08-30 | 对称上下渐隐并增加 viewport 留白 | 用户复核后确认 128 point 的视觉底边仍比顶部亮，并要求歌词不要铺满完整窗口高度。最终把 locations 校准为 `[0, 0.5, 0.5, 1]`，使上下使用同一条渐隐曲线；`NSScrollView` viewport 上下各缩进 32 point，document padding、instrumental indicator 与 `.topRelative(40)` 使用缩进后的可视高度。真实 row spacing、line blur、行内动画与 display-link 路径均未改变。两项回归在旧实现上分别以 bottom stop 偏差 0.34 和 frame 偏差 32 point 先失败，修复后通过；LyricsXPackage 108 项、13 个 suite 全部通过，workspace Debug build 成功。 |
| 2026-08-30 | 撤销 viewport 硬留白 | 用户并排截图澄清目标：Apple Music 的歌词仍使用完整窗口高度，边缘空间只由渐隐形成。撤销上下各 32 point 的 `NSScrollView` frame inset，保留 `[0, 0.5, 0.5, 1]` 对称 mask。完整高度回归在旧实现上以 frame 偏差 32 point 先失败，修复后与渐隐回归一起通过；LyricsXPackage 108 项、13 个 suite 全部通过。 |
| 2026-08-30 | 修正 viewport mask 坐标方向 | 用户再次并排确认右侧 Apple Music：选中行保持完全不透明，顶部快速渐入，底部则从半屏开始逐渐消失。重新核对 26.6 类型与 `sub_1001284F8` 后确认 Music 把 mask 安装在 flipped 的 `AMPFlippedDocumentView`，而本项目的外层 mask target 未 flipped；此前直接照搬 gradient direction 才是上下观感始终不对的根因。最终恢复 recovered locations `[0, 70 / height, 0.5, 1]`，并反转本项目的 gradient vector，使视觉顶部使用 70 point fade、视觉底部使用 half-height fade，viewport 继续占满完整高度。回归在对称实现上以 stop 偏差 0.4125 和 vector 方向相反先失败；修复后定向测试与 LyricsXPackage 108 项、13 个 suite 全部通过，workspace Debug build 成功。未启动应用做交互式 UI 验证。 |
