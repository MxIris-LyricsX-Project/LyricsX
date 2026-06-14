# Apple Music 歌词面板 —— CALayer 渲染引擎复刻方案

> 分支：`feature/apple-music-lyrics`　日期：2026-06-13
>
> 目标：用 **AppKit + Core Animation(CALayer) + TextKit 2 + Core Text + CASpringAnimation + CADisplayLink** 复刻 Apple Music 全屏歌词的渲染与动画，做到「帧级一致的手感」，并彻底解决现有 SwiftUI 面板的性能问题。
>
> 配套调查结论见项目记忆 `applemusic-lyrics-rendering-stack.md`（Apple 实现的逆向结论）与 `docs/apple-music-lyrics.md`（逐字 TTML 数据获取，Route A，已 PoC 验证）。

---

## 重大转向（2026-06-14 晚）：彻底纯 AppKit + ColorfulX 背景

应用户要求，整个面板**移除 SwiftUI、改纯 AppKit**，背景换成 **ColorfulX**（Lakr233，Metal 多色渐变），并修复**拖窗时背景冻结**的 bug。

- **依赖**：ColorfulX 6.1.0（+ ColorVector/SpringInterpolation/MSDisplayLink）经 Ruby `xcodeproj` gem 加到 LyricsX app target（生成合法 pbxproj，未手改）。**App 最低系统 macOS 11→12**（ColorfulX 需 12；LyricsX+Helper 已 bump，Widget 保持 15）。
- **架构**：`AppleMusicLyricsRootView.swift`→`LyricsPanelViewController.swift`（纯 AppKit VC，替换 `NSHostingController`）；`BackgroundView.swift`→`GradientBackgroundView.swift`（包 ColorfulX `AnimatedMulticolorGradientView`，颜色取自封面 k-means 主色）；`ProgressDotsView.swift`→`LyricsPanelControls.swift`（AppKit 进度条 + 控制按钮）；`InteractionStateModel` 改纯类（onChange 回调）；`SyncedLyricsContainerView` 直接内嵌进 VC（去掉 `NSViewRepresentable` 桥）。Combine 订阅 + 0.1s 定时器驱动 chrome。`AppleMusicLyrics/` 现**零 SwiftUI**。
- **拖窗冻结修复**：根因 = ColorfulX 的 macOS CVDisplayLink 回调走 `DispatchQueue.main.async`，窗口拖拽进 `NSEventTrackingRunLoopMode` 时主队列不排空。改 `isMovableByWindowBackground=false` + `DraggablePanelView`（`mouseDragged` 屏幕坐标移窗，run loop 留 default 模式 → 渐变照常动画）+ `hitTest` 细化（非交互区可拖、按钮/进度/歌词照常响应）。live-resize 仍可能冻结（彻底修需 fork MSDisplayLink，可选）。
- **评审**：对抗式评审（18 智能体）确认并修复 4 个 LOW 问题（封面/进度条圆角的 layer 同步重置、首曲调色板 nil-latch、交互按钮每 tick 重建图标）+ 自查的拖窗可拖区域。全部编译通过，**待运行时视觉验证**。

## 实现进度（2026-06-14）

- ✅ **Phase 0+1**：`AppleMusicLyricsScrollView.swift` 的 SwiftUI `LyricsScrollView` 改为 `SyncedLyricsRepresentable`（`NSViewRepresentable`）承载 `SyncedLyricsContainerView`（`NSScrollView` + flipped 文档视图 + 行视图 + `CADisplayLink`）。`LyricsLineRowView.swift` 改为 `SyncedLyricsLineView`（layer-backed，文本缓存进 backing store）。距离淡出、跟随居中滚动、点按跳转。编译通过。
- ✅ **Phase 2**：词级卡拉OK填充。**坐标决策**：经 `appkit-layer-backing` 技能确认 flipped backing layer 的 `geometryFlipped = isFlipped XOR ancestorIsFlipped` 会使手动子层坐标错位，遂避开子层，改用翻转安全的 `draw(_:)` 两遍绘制（暗底 + 亮色按比例裁剪），并用 CoreText 计算逐视觉行宽度实现折行级联。`LyricsTextRenderer.swift` 保留 `WordTimingEntry`/`wordTimingEntries` 提取，新增纯函数 `KaraokeFill.fraction`。编译通过。
- ✅ **对抗式评审**（27 个子智能体）确认并修复 4 个真实问题：
  - **A（高）**：空内容的 enabled 行（间奏占位）令 `highlightedLineIndex` 映射不到视图 → 加 `resolveRenderedIndex` 回退到最近已渲染行。
  - **B（中）**：`LayoutSignature` 过弱导致同曲换源碰撞 → 改为全行 content/position/timetag/translation 哈希。
  - **C（中）**：折行歌词填充用单一全高裁剪 → CoreText 逐视觉行级联。
  - **D（低）**：播放中切换双语/简繁偏好不刷新 → `defaults.publisher(for: [.preferBilingualLyrics, .chineseConversionIndex])` 观察并重建。
- ✅ **Phase 4 (lite)**：用户滚动离开→倒计时回到"跟随"时立即重新居中（利用 `interactionState` 变化触发 `updateNSView`，无需额外观察）。
- ✅ **Phase 3 (spring scroll)**：自动居中滚动从 ease-in-out 升级为**弹簧**，由 `CADisplayLink` 逐帧积分（`duration 0.6 / bounce 0.275`，复用旧 SwiftUI 手感值），rapid 行切换保留速度连续性，用户接管时放弃弹簧。纯改 clipView bounds origin，无 layer 坐标陷阱。
- ✅ **Phase 5 (scale emphasis)**：当前行 1.05 倍**中心缩放强调**（Apple "当前行 pop"），用 anchorPoint 无关的 `layer.transform`（不在 AppKit 同步的 13 属性内，安全；倍数克制避免与行距重叠）。
- ✅ **第二轮聚焦评审**（新增代码）修复 3 个真实问题：⑤CT 行高截断丢末行（path 高度改充裕值）⑥弹簧 stale dt 一帧过冲（非动画 centerLine 重置时间戳）⑦缩放命中测试错配（注释说明，影响极小）。
- ✅ **Phase 4 (间奏 dots — intro)**：`SyncedLyricsInstrumentalView`（3 圆点，draw 绘制，翻转无关）。**纯增量**：仅当首行 position > 4s 且当前仍在前奏时创建；否则引擎行为与之前完全一致。前奏中居中于 dots、进度填充；前奏结束淡出+折叠+回弹到首行。经第三轮（聚焦单智能体）复审确认无回归。
- ✅ **Phase 4 (间奏 dots — 曲中)**：词时歌词中按 `timetagDuration` 检测「行尾→下一行」间隙 > 5s，插入**持久行间 dots 槽位**（`interludeSegments`，与行视图交织布局）；间奏期间居中并按进度填充。纯增量：无间隙时与之前完全一致。
- ✅ **Phase 5 (背景氛围漂移)**：`BackgroundView` 给已模糊封面叠加 18s 缓慢 `scaleEffect`/`offset` 漂移（GPU transform 小位图，不触发重新模糊/CoreImage，符合原性能约束），逼近 Apple "活的"背景。
- 🔬 **IDA 验证（2026-06-14）**：反编译 `SyncedLyricsViewController.viewDidLoad`（`sub_100157B08`）确认 Apple 架构与本实现高度一致——layer-backed `NSScrollView`+flipped documentView、`drawsBackground=false`、`hasVerticalScroller`、`automaticallyAdjustsContentInsets=false`、观察 `WillStartLiveScroll`/`DidEndLiveScroll`、每行 `setRasterizationScale(backingScaleFactor)`、每个 line layer 持 `specs`。**规格常量**（含 `emphasizingScaleRange` 等）是从 Music 侧 `LyricsXViewController` 作为 `_specs`/`_unresolvedSpecs` ivar 注入的，字面值需再上溯一层（深 + ROI 低，且架构有别）；当前用经验值（1.05/28/24/0.4/spring0.6·0.275），最适合配合视觉对比微调。
- ⏳ **待运行时视觉验证**（需正在播放且有歌词的 Apple Music；菜单栏 app，面板需手动开启）：文字方向/位置、当前行高亮+缩放+居中、词级扫光、弹簧滚动手感、点按跳转。
- 📋 **剩余（均为净负价值或越界，故未做）**：
  - **CAGradientLayer mask 零重绘**：会替换已通过三轮评审的 two-pass draw（回归风险），且涉及 flipped-layer 坐标；two-pass 仅重绘单行、性能已足，故不为优化而冒险。
  - **精确 Apple 常量**：specs 从 Music 侧注入，且 Apple 的 spec 模型（selectedLinePosition/contentInsets/lineSpacing/paragraphSpacing/emphasizingScaleRange 分立 + 逐字动态缩放）与本简化架构映射不佳，原始数值套用价值低；当前经验值最适合视觉微调。
  - **BackgroundVocals（和声）样式**：需 LyricsKit 暴露和声数据（越界，不改依赖）。
  - 逐字精确扫光（per-glyph）/ 字级缩放强调：可选增强，宜视觉验证后做。

## 0. 背景与结论先行

### 现状
- 当前面板：`LyricsX/AppleMusicLyrics/`，整组 `@available(macOS 15, *)` 的 SwiftUI，经 `NSHostingController` 托管（`AppleMusicLyricsWindowController`）。
- 性能元凶有二：
  1. **SwiftUI `TextRenderer` 每帧重排重绘**（`LyricsTextRenderer`，macOS 15 API）——逐字填充靠每帧重新计算 progress 并触发 body 重算。
  2. **30fps 定时器驱动**（`AppleMusicLyricsRootView` 里 `Timer.publish(every: 1.0/30.0)`）——非显示同步，既不顺滑又持续唤醒整棵视图树。

### 为什么这次复刻可行（且比一般复刻者有利）
1. **渲染零技术壁垒**：Apple 用的全是公开 API，无私有 API、无 Metal 必需（Metal 只在专辑封面氛围背景，与文字无关）。
2. **数据已就位**：`feature/apple-music-lyrics` 分支已能拿到 **Apple 官方逐字 TTML**（`itunes:timing="Word"`），覆盖率等同 Apple；落到 LyricsKit 的 `LyricsLine.attachments.timetag`（`InlineTimeTag`：字符索引 + 行内时间偏移）。
3. **手感可对齐**：Apple 的精确常量（spring 的 mass/stiffness/damping、羽化宽度、错峰延迟、强调缩放区间等）全在 `Music.i64` 里，可反编译提取后照搬。
4. **系统门槛已是 macOS 15**：现有面板已 `@available(macOS 15, *)`，故新引擎可放心用 TextKit 2（12+）、CADisplayLink（14+）、现代 CASpringAnimation —— 与 Apple 选型完全一致，无需为低版本降级。

### 目标与非目标
- **目标**：1:1 复刻歌词文字区的渲染与动画（行级滚动+spring、词级填充、强调缩放、间奏 dots、翻译/音译/和声、点按跳转、手动滚动）。
- **本期非目标**（可后置/近似）：专辑封面派生的动态网格渐变背景（`ArtworkCentricPresentationController` + Metal 那套）—— 与文字独立，单列阶段，先沿用现有 `BackgroundView` 或 macOS 15 `MeshGradient` 近似。

---

## 1. 关键事实：Apple 实现 → 公开 API 映射

| Apple 内部（`LyricsX` / `Music` 模块） | 作用 | 我方公开 API 对应 |
|---|---|---|
| `SyncedLyricsLineView : NSControl`（layer-backed） | 每行一个承载视图 | `NSView`（`wantsLayer`）/ `NSControl` |
| `SyncedLyricsLineLayer : CALayer`，内含 `Line/Word/Syllable/Glyph` 各级子层 | 每行一棵 CALayer 树 | 自建 `CALayer` 子类树 |
| `NoAnimationLayer : CALayer` | 关闭隐式动画 | `CALayer` 子类，`action(forKey:)` 返回 `NSNull` |
| `TextKitLabel`（持 `MusicUtilities.TextKitManager`） | TextKit 2 排版 → layer contents | `NSTextLayoutManager`+`NSTextContentStorage`+`NSTextContainer`；或直接 Core Text |
| `Glyph { CTRun; textPosition; frame }` + `GlyphLayer : PartialRunLayer` | 逐字形布局/动画 | Core Text `CTLine`/`CTRun`/`CTRunGetGlyphs` + 每字形 `CALayer` |
| `LineProgressGradientLayer`（`featherWidth`/`direction`/`color` + `CAGradientLayer`+fillLayer） | 卡拉OK扫光填充 | `CAGradientLayer` 作 mask 沿 X 推进 + 羽化 |
| `LayerPropertyAnimator`（spring/ease/custom bezier） | 自研 CALayer 属性动画器 | `CASpringAnimation` / `CABasicAnimation`（多数场景无需自研） |
| `SpringAnimationParameters`（mass/stiffness/damping/…） | 弹簧物理参数 | `CASpringAnimation.mass/stiffness/damping` |
| `SyncedLyricsViewController`（持 `displayLink: CADisplayLink`） | 逐帧驱动 + 滚动 | `NSViewController` + `CADisplayLink` |
| `SyncedLyricsVisualExperienceManager`（`LinePositionAnimationDescriptor`：curve+views+delay+completion） | 每帧算哪些行动、错峰编排 | 自建编排器（纯 Swift） |
| 数据：TTML → `Lyrics→LyricsLine→Word→Syllable` | 分层时间模型 | LyricsKit `Lyrics`/`LyricsLine` + `InlineTimeTag` |

> 符号说明（见记忆）：第一方 Swift 方法在 `Music.i64` 中被 strip，只剩 ObjC thunk 与编译器元数据/见证符号；真正实现是无名 `sub_`。提取 Apple 参数须走「vtable 还原」而非符号名检索（详见 §6）。

---

## 2. 复用 vs 替换（落到现有文件）

### 复用（数据与外壳，基本不动）
- **数据管线**：Route A 逐字 TTML → LyricsKit → `LyricsLine.attachments.timetag`。
- `LyricsTextRenderer.swift` 末尾的 **`LyricsLine.wordTimingEntries` 提取逻辑**（`InlineTimeTag.tags → WordTimingEntry{characterIndex,timeOffset}`）——搬进新引擎复用。
- `WordTimingEntry`、词级/字符级 progress 的**算法思路**（`wordLevelProgress` / 字符插值）——逻辑保留，执行载体从 SwiftUI 改成 layer mask 推进。
- `InteractionStateModel` / `PlaybackTimeModel`：交互态（自动跟随 / 用户滚动 / 拖拽）与播放时间源——基本复用，仅把「时间→渲染」的消费端换掉。
- `AppleMusicLyricsWindowController`：窗口/层级外壳保留，**把 `NSHostingController(rootView:)` 换成新的 `LyricsPanelViewController`**。
- `lyrics.adjustedTimeDelay`、`line.position` 等既有时间偏移约定。

### 替换（渲染层，全部重写为 CALayer）
| 现有 SwiftUI 文件 | 替换为 |
|---|---|
| `AppleMusicLyricsRootView.swift` | `LyricsPanelViewController`（`NSViewController`） |
| `AppleMusicLyricsScrollView.swift` | `SyncedLyricsView`（`NSScrollView` + flipped documentView，或自管滚动的 `NSView`） |
| `LyricsLineRowView.swift` | `LyricsLineView : NSView`（layer-backed）+ `LyricsLineLayer` |
| `LyricsTextRenderer.swift`（TextRenderer 部分） | `TextLayoutCache` + `ProgressGradientLayer`（mask 推进） |
| `ProgressDotsView.swift` | `InstrumentalDotsLayer`（CALayer 动画） |
| 30fps `Timer.publish` 驱动 | `DisplayLinkDriver`（`CADisplayLink`） |
| `BackgroundView.swift` | 本期保留；背景视觉单列阶段（§7 Phase 5） |

---

## 3. 目标架构（新引擎分层）

```
LyricsPanelViewController : NSViewController            // 替换 NSHostingController 的入口
  ├─ DisplayLinkDriver (CADisplayLink)                  // 逐帧 tick → 推进时间
  ├─ PlaybackTimeModel / InteractionStateModel          // 复用：时间源 + 交互态
  ├─ LyricsLayoutEngine                                 // 编排：算可见行、目标位置、错峰
  └─ SyncedLyricsView (NSScrollView + FlippedDocumentView)
        └─ [LyricsLineView : NSView] (layer-backed, 每行一个，复用/回收)
              └─ LyricsLineLayer : NoAnimationLayer
                   ├─ backgroundLayer        (选中行底色，可选)
                   ├─ contentLayer           ← 按 line 能力择一：
                   │    ├─ TextContentLayer            (普通整行文字)
                   │    ├─ WordFillContentLayer        (词级填充：底色文字 + 高亮文字 + mask)
                   │    │     └─ ProgressGradientLayer (CAGradientLayer mask，沿 X 推进 + 羽化)
                   │    └─ InstrumentalDotsLayer        (间奏 ●●● 呼吸)
                   ├─ translationLayer       (翻译/音译，TextContentLayer 复用)
                   └─ backgroundVocalsLayer  (和声，缩小/右对齐，后期)
```

### 文本与渲染支撑
- `TextLayoutCache`：用 **TextKit 2**（`NSTextLayoutManager`/`NSTextContentStorage`/`NSTextContainer`）或 **Core Text**（`CTFramesetter`/`CTLine`）把一行 `NSAttributedString` 排版一次，产出：
  - 行的 `contents`（`CGImage`，或直接让 layer 用 `display()` 绘一次缓存）；
  - 词级填充所需的 **字符索引 → x 偏移** 映射（`CTLineGetOffsetForStringIndex`）；
  - 字形级强调所需的 per-glyph 几何（`CTRun` 的 positions/advances）。
- 排版结果按 `(文本, 字体, 宽度, 缩放)` 缓存，**仅在文本/尺寸变化时重排**；逐帧只改 layer 属性。

### 动画与驱动
- `LineSpringAnimator`：对行的 `position`/`transform`/`opacity` 套 `CASpringAnimation`（参数取自 Apple，见 §6）；多行错峰用 `beginTime` + `CACurrentMediaTime()` 叠加 `delay`。
- `DisplayLinkDriver`：`CADisplayLink`（绑定窗口 `NSView.displayLink(target:selector:)`，macOS 14+）。每帧只做：①读时间 → ②算当前行/词进度 → ③更新需要变化的 layer 属性（mask 位置、缩放、透明度），**不重排文本**。

---

## 4. 关键技术方案（逐组件）

### 4.1 文本排版与缓存
- 每行 `NSAttributedString`（字体取 SF Pro 对应字重 + Apple 的 leading/spacing，见 §6）。
- TextKit 2 排版进 `NSTextContainer`（宽度=面板可用宽，允许折行）。
- 把排版结果绘进 `LyricsLineLayer` 的 contents（layer `contentsScale = window.backingScaleFactor`，HiDPI 清晰）。
- 折行处理：Apple 的 `Glyph.frame/originalFrame` 表明它把多行也展开成字形坐标；我方词级填充需把 per-line progress 分摊到各视觉行（现有 `LyricsTextRenderer` 注释「Distribute the per-line progress across visual lines」已有同思路，可移植）。

### 4.2 词级填充（卡拉OK扫光）
- 机制：**两层文字 + 渐变 mask**。
  - 底层：未唱颜色的整行文字 layer。
  - 顶层：已唱（高亮）颜色的整行文字 layer，其 `mask = ProgressGradientLayer`。
  - `ProgressGradientLayer`（仿 `LineProgressGradientLayer`）：一个沿 X 方向的渐变，`[不透明, 不透明, 透明]`，过渡区宽度 = `featherWidth`（羽化软边）；通过改其 `frame`/`locations` 或父 mask 的位置把「已亮」区域推进到当前进度 x。
- 进度→x：`elapsedTime` 落在哪个 `WordTimingEntry` 区间 → 取该词起止字符索引 → `CTLineGetOffsetForStringIndex` 得 x → 词内按 `(elapsedTime-start)/(end-start)` 线性插值。算法直接移植现有 `wordLevelProgress` / 字符插值（仅把「返回 progress 值」改成「设置 mask 位置」）。
- RTL：`direction = rightToLeft`（阿拉伯/希伯来），mask 从右往左推。
- 仅行级数据（无 timetag）退化：mask 按 `elapsedTime/lineDuration` 线性推进整行。

### 4.3 行布局 / 滚动 / 选中行定位
- documentView 为 flipped（y 向下），各 `LyricsLineView` 垂直堆叠。
- 「选中行」定位：仿 `LyricsSpecs.SelectedLinePosition`（top / topRelative(cardHeightPercentage) / center）。把当前唱到的行 spring 动到目标基线位置，其余行随动错峰。
- 上下边缘渐隐：documentView 套 `CAGradientLayer` mask（仿 `LyricsXViewController.maskLayer`）。
- 行视图**复用池**：只为可见区 + 预留行实例化 `LyricsLineView`，滚出回收，避免一次性建几百行。

### 4.4 spring 动画 + 错峰（cascade）
- 行切换/上浮：`CASpringAnimation`（key path `position`/`transform.scale`）。参数取 Apple 实测值（§6）。
- 错峰：当前行先动，后续行依次 `+delay`（仿 `LinePositionAnimationDescriptor.delay`）。
- 完成回调：`CAAnimationDelegate` 或 `CATransaction.completionBlock`（仿 `CAAnimationCompletionHandler`）。

### 4.5 字形级强调（Phase 后期，可选）
- Apple 的 `emphasizingScaleRange`：唱到某字时该字 `transform.scale` 在区间内放大并回弹（配 spring）。
- 实现：在 `WordFillContentLayer` 下为活跃词/字建 `GlyphLayer`（仅活跃区，不是整行所有字都建），逐字 spring 缩放 + 透明度。
- 成本权衡：字形级层数多；先做到词级填充，强调作为增强项，按数据/性能开关。

### 4.6 逐帧驱动与时间源
- `CADisplayLink` 取代 30fps `Timer`：跟随刷新率（ProMotion 120Hz）。
- 时间：`PlaybackTimeModel.playbackTime + lyrics.adjustedTimeDelay`（复用现有）。
- 暂停/拖拽：仿 `StaticTimingProvider.isPaused/elapsedTime`，暂停冻结、seek 跳转并重算可见行。

### 4.7 间奏 dots / 翻译 / 音译 / 和声
- 间奏：`InstrumentalDotsLayer`，3 个圆点随间奏时长做容量/呼吸动画（替换 `ProgressDotsView`）。
- 翻译/音译：`LyricsLine.attachments.translation(...)` / `furigana` / `romaji`（LyricsKit 已支持）→ 主文字下方 `translationLayer`。
- 和声（BackgroundVocals）：缩小、对齐侧边的次级 `LyricsLineView`，后期。

---

## 5. 数据层映射与退化策略

| 数据情况 | 来源 | 渲染表现 |
|---|---|---|
| 逐字 TTML（最佳） | Route A（Apple 官方）/ NetEase yrc / QQ qrc / Kugou krc | 词级填充 + 强调缩放（全套效果） |
| 仅行级（LRC） | 多数第三方源 | 行级高亮 + spring 滚动；mask 线性推进整行 |
| 纯静态文本 | 无时间 | `NSScrollView` 静态列表（沿用现状） |

- `RenderingMode`（仿 Apple `LyricsSpecs.RenderingMode`）：`synced` / `static`，由是否有逐行时间决定。
- 词级映射：`InlineTimeTag.Tag{index, time}` 的 `index` 是**行内字符索引**，正好喂 `CTLineGetOffsetForStringIndex`；`time` 是行内偏移，配合 `line.position` 还原绝对时间。

---

## 6. 从 `Music.i64` 提取 Apple 参数（喂给 §4 调参）

> 目的：把「一模一样的手感」从「肉眼试参」变成「照搬 Apple 原值」。

步骤（每个目标类）：
1. 取类元数据：`list_funcs` 找 `…CMa`（type metadata accessor）/ `…CMn`（nominal type descriptor）。
2. 由 nominal descriptor / class metadata 解出 **vtable**，方法指针按 `.swiftinterface` 声明顺序排列 → 给无名 `sub_` 标上方法名。
3. 反编译目标 `sub_`，读出常量。

要提取的参数清单：
- `SpringAnimationParameters`：行位移/缩放用的 mass / stiffness / damping / settlingDuration（可能有多套：选中、取消选中、和声）。
- `LineProgressGradientLayer`：`featherWidth`、渐变 `locations`、扫光 `direction` 默认。
- `LyricsSpecs`：`selectedLinePosition`、`lineSpacing`/`paragraphSpacing`、`emphasizingScaleRange`、各字体（`font`/`backgroundVocalsFont`/`translation*Font`/`transliterationFont`）与 `fontLeading`、`backgroundVocalsDeselectedTransform`、`lineDelay`/`maxEndTimeOffset`/`maxSelectedLines`。
- `SyncedLyricsManager.Configuration`：`animationDuration(_:)` 闭包（按行长算时长的曲线）、`finishLineAnimationDuration`、`maxEndTimeOffset`、`isPlayingSpatial` 的不同处理。

> 提取是「锦上添花」：先用经验值跑通效果，再用 Apple 原值替换对齐，不阻塞主线。

#### 已确认机制（2026-06-14，反编译 `LineProgressGradientLayer.layoutSublayers` = `sub_1001EB740`）

Apple 的扫光层结构（用于把 Phase 2 升级到零重绘 mask）：
- `LineProgressGradientLayer` 内含 **实色 `fillLayer`** + **`gradientLayer`（CAGradientLayer）** + 可选 `horizontalPaddingLayer`。
- 整个 `LineProgressGradientLayer` 的宽度被设为「已唱进度宽度」；在**推进边缘**放一条宽度恰为 `featherWidth` 的渐变软边，其余是实色填充：
  - `direction == leftToRight`：`fillLayer` 在 `x=0..(W-featherWidth)`，`gradientLayer` 在 `x=(W-featherWidth)..W`（软边在右/前缘）。
  - `direction == rightToLeft`：`fillLayer` 在 `x=featherWidth..W`，`gradientLayer` 在 `x=0..featherWidth`（软边在左/前缘）。
- `outerPadding` 用于把 gradient/padding 层在垂直方向外扩（`y=-pad`, `height=2*pad+boundsHeight`）。
- 这层既可作**亮色文字的 mask**（软边即羽化揭示），也可作彩色高亮本体（有 `color: CGColor`）。
- `featherWidth` 数值默认由指定初始化器（无名 `sub_`）/ `LyricsSpecs` 注入，未取到字面值；Phase 3 实做 mask 时再深挖 vtable 取常量。

---

## 7. 分阶段路线图

> 原则：每阶段都能编译、能在真窗口里看到效果、可独立验收。先把「性能 + 行级」立住，再逐步贴近 Apple。

### Phase 0 — 脚手架与接管（不改观感）
- 新增 `LyricsPanelViewController : NSViewController`，`AppleMusicLyricsWindowController` 用它替换 `NSHostingController`（保留 SwiftUI 版本由编译开关切换，便于对比回退）。
- 接入 `PlaybackTimeModel` + `CADisplayLink`（`DisplayLinkDriver`），打印 tick 验证时间源/刷新率。
- **验收**：窗口能开，display link 按刷新率回调，拿到正确 `playbackTime`。

### Phase 1 — 行级渲染 MVP（核心，性能立住）
- `SyncedLyricsView` + `LyricsLineView`/`LyricsLineLayer` + `TextLayoutCache`（TextKit 2 排版进 layer contents）。
- 行布局、选中行 spring 定位、上下边缘渐隐、行视图复用池。
- 选中行整行高亮（先不做词级）。
- **验收**：长歌词流畅滚动（无每帧重排），选中行 spring 切换；Instruments 看 CPU/帧明显优于 SwiftUI 版。

### Phase 2 — 词级填充
- `WordFillContentLayer` + `ProgressGradientLayer`（mask 沿 X 推进 + 羽化）。
- 移植 `wordTimingEntries` 提取 + 进度→x 映射 + 折行分摊。
- **验收**：有逐字 TTML 的歌曲出现 Apple 式词级扫光；无 timetag 退化为整行线性，均不掉帧。

### Phase 3 — 对齐 Apple 手感
- 执行 §6 参数提取，替换 spring/羽化/spacing/缩放区间为 Apple 原值。
- 多行错峰（cascade delay）、`animationDuration` 曲线、选中行定位策略对齐。
- **验收**：与 Apple Music 并排录屏逐帧比对，滚动/切换/扫光节奏基本一致。

### Phase 4 — 交互与文本增强
- 点按行跳转（`onTap` → seek）、手动滚动 + 一段时间后自动归位（复用 `InteractionStateModel`）。
- 间奏 `InstrumentalDotsLayer`、翻译/音译 `translationLayer`。
- **验收**：交互行为与现状对齐；间奏/翻译显示正确。

### Phase 5 — 高保真增强（可选/独立）
- 字形级强调缩放（`GlyphLayer`，活跃区）、和声样式。
- 背景视觉：先 `MeshGradient`/现有 `BackgroundView` 近似，必要时再研究 `ArtworkCentricPresentationController`。
- **验收**：强调缩放出现且不掉帧；背景观感接近。

---

## 8. 性能预算与验证
- 目标：稳定跟随刷新率（60/120Hz），逐帧主线程工作仅「属性更新」，**零文本重排**（仅文本/尺寸变化时排版）。
- 验证：
  - Instruments（Time Profiler / Core Animation）对比 SwiftUI 版与新版的每帧 CPU 与掉帧。
  - 压力样例：长行折行、超多行、快速连续 seek、ProMotion 屏。
  - 断言：滚动/扫光期间无 `layout`/`framesetter` 调用进入热点。

## 9. 风险与对策
| 风险 | 对策 |
|---|---|
| 字形级强调复杂度高 | 降级到词级填充即达 90% 观感；强调列为 Phase 5 可关 |
| Apple 参数提取耗时（vtable 还原） | 先用经验值跑通，参数替换异步进行，不阻塞主线 |
| 折行时词级 x 映射边界 | 复用现有「按视觉行分摊 progress」思路 + 充分用真实歌词测试 |
| 背景视觉难全等 | 本期非目标，独立阶段，先近似 |
| 与 SwiftUI 版并存期的维护 | 用编译/运行开关切换，新版稳定后删除旧 `AppleMusicLyrics/*.swift` |
| TextKit 2 折行/CJK 细节 | 必要时局部退回 Core Text `CTFramesetter` |

---

## 10. 下一步
1. 确认本方案 / 调整 fidelity 目标与阶段优先级。
2. 进入 Phase 0：建 `LyricsPanelViewController` 脚手架并接管 `AppleMusicLyricsWindowController`。
3. （并行）按 §6 在 IDA 里对 `LineProgressGradientLayer` / `LayerPropertyAnimator` 跑一次 vtable 还原，产出首批 Apple 参数。
