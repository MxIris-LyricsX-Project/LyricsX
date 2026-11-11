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
- 🔬 **IDA 验证（2026-07-26，修正上一条的部分判断）**：上一条说「原始数值套用价值低」只对了一半——**具体数值**确实拿不到（`_specs` 是运行时注入），但**动画的数学结构是编译期常量，完全可取**，而且正是逐字弹跳的关键：
  - `sub_1001662D4` 不硬编码 spring 系数，而是从**周期**反推：`mass = 1`、`stiffness = (2π/T)²`、`damping = ζ · 2·√(stiffness · mass)`；逐字动画的调用点（`sub_10018B2B4`）传 `ζ = 1`（临界阻尼，不过冲）、`T = min(lineDuration, 3)`。
  - 同一处按 `min(lineDuration / glyphCount × 0.4, 0.4)` 给每个字**错峰延迟**（第 i 字 × (i+1)）——弹跳观感来自错峰，不来自单字回弹。
  - 每字同时动 scale（`emphasizingScaleRange`，specs +0x100）和上抬（`syllableLift`，specs +0x2D0），载体是 `SyncedLyricsLineLayer.Glyph.GlyphLayer` + `LayerPropertyAnimator`。
  - 动画均设 `preferredFrameRateRange(min: 80, max: 120, preferred: 120)`、`fillMode = .both`、`removedOnCompletion = true`。
  - 仍未取到：`emphasizingScaleRange` / `syllableLift` 的字面值（需 lldb 挂 Music dump `_specs`）。
- 🔬 **lldb 实机 dump（2026-07-26）**：SIP 已关，直接 attach 运行中的 Music（`lldb -p`），在 glyph 动画构造函数 `sub_10018B2B4` 下断点（X0 即 `*LyricsSpecs`），读出完整 880 字节。**运行中的二进制与 `/Volumes/RE/AppleMusic/26.5.1` 的 dump UUID 逐位相同**（`CF9B3665-3252-37B8-B25D-9384D448824F`，arm64e，Music 1.6.5），所以静态偏移表可直接套用。脚本见 scratchpad `dump_specs.py`。取到的真值：

  | 字段 | 偏移 | 真值 |
  |---|---|---|
  | `emphasizingScaleRange` | +0x100 | **1.0 … 1.14** |
  | `syllableLift` | +0x2D0 | **3** |
  | `animationHeadstart` | +0x220 | **0.1** |
  | `lineDelay` | +0x0B8 | 0.05 |
  | `lineChangeSpringTimingParameters` | +0x2F8 | mass 1 / stiffness 100 / damping 18（ζ=0.9, ωₙ=10） |
  | `lineProgressionGradientFeather` | +0x250 | 30 |
  | `lineFinishProgressAnimationDuration` | +0x2E8 | 0.25 |
  | `lineTapProgressFreezeDuration` | +0x2E0 | 0.1 |
  | `maxSelectedLines` | +0x0C8 | 2 |
  | `lineSpacing` / `paragraphSpacing` | +0x078 / +0x050 | 50 / 39 |
  | `deselectedTransform` | +0x1F0 | identity（再次确认非活动行不缩放） |
  | `glowRadius` / `glowRange` | +0x238 / +0x240 | 5 / 0 … 0.4 |
  | `touchDownTransform` | +0x258 | 0.95 等比缩放 |
  | `backgroundVocalsDeselectedTransform` | +0x088 | 0.9 等比缩放 |
  | `lineBlurEnabled` / `hidePreviousLines` | +0x2F1 / +0x2F2 | true / false |
  | `vocalGroupWidthCoefficient` | +0x2D8 | 0.85 |
  | `maxEndTimeOffset` | +0x0C0 | 0.5 |

  `lineChangeSpringTimingParameters` 与此前静态挖出的值完全一致，交叉验证通过。
- ⚠️ **per-line 位置错峰：第二次被证伪（2026-07-26）**。dump 里 `lineDelay = 0.05` 的存在一度让人以为「行位置应该逐行错峰」，据此实现过一版后**已回退**。反证：
  - `sub_10015AF20`（`LayerPropertyAnimator` 的 action）反编译后只有一件事——`scrollView.contentView.setBounds:`。AM 是**整体移动 clip**，文档里的行是静态的。
  - `lineDelay` 的 getter/setter（`sub_1001CF390`/`sub_1001CF398`）**没有任何 xref**（被内联），没有任何证据表明它作用在行的位置上；更可能与 `maxSelectedLines = 2`（同时可有两行选中）配套，用于行级动画的起始错峰。
  - 2026-06-16 那条注释早就记录过同样的结论，且当时的 per-line cascade 实现正是用户报的「直接运动」的来源。
  **结论：行的平滑只能来自 clip spring，不要再往行位置上加错峰。**「行间跳动」若仍存在，应去查 clip spring 为何没生效（`animated` 是否被传 false、`scrollJumpThreshold = 5` 是否被误触发、display link 是否在跑），而不是加 cascade。
- ✅ **逐字弹跳（2026-07-26）**：在上一条的基础上实现。此前高亮行只有线性的「暗→亮」裁剪填充，字本身没有任何几何变化，所以没有 AM 的弹跳感。
  - **不建 layer**：AM 每字一个 `GlyphLayer` 各挂一条 `CASpringAnimation`；我们改为 **CPU 解析求解**同一条 spring，把结果折进已有的单次 `draw(_:)`，图层树保持扁平。临界阻尼（ζ=1）有闭式解 `1 − (1 + ωₙt)·e^(−ωₙt)`，所以每字进度是 elapsed 的纯函数——不逐帧积分、不漂移、任何帧间隔都稳定，seek/卡顿后也不会错位。
  - **触发时刻**：有逐字时间（timetag）就按该字自己的起唱时刻，比固定错峰更贴合人声；无 timetag 时退回 AM 原式的 index 错峰。两种情况用同一条 spring 和同一套级联。
  - **变换**：绕字自身中心缩放（避免放大时侧移）+ 上抬。裁剪在变换**之前**设置，所以填充边缘留在未缩放的视图空间，字可以越过边缘长大而不破坏扫光。
  - **重绘**：原本只在填充边缘移动 ≥0.5pt 时重绘；补上「还有字没弹稳就继续重绘」，否则暂停的行会卡在弹到一半。两个条件都为假时自动停止重绘。
  - **落地文件**：新增 `GlyphEmphasisSchedule.swift`（spring + 错峰调度 + 变换）、`GlyphLayout.swift`（Core Text 逐字布局，从 view 里搬出）；`LyricsLineRowView.swift` 只保留调用。搬出后该 view 的 class body 从 341 行降到 309 行，顺带消掉了既有的 `force_cast` / `function_body_length` 违规。
- ✅ **用实机真值校正 + 羽化边缘（2026-07-26，同日晚）**：上一条初版凭经验值实现，实测「逐字动画不对、字一个个跳」。lldb dump 后定位到三个原因，均已修：
  1. **弹跳幅度差一倍多**：`scaleUpperBound` 从经验值 1.06 改为真值 **1.14**；`syllableLift` 从 2.5 改为 **3**。
  2. **「跳动」源于错峰方式选错**：初版按「每个字自己的起唱时刻」触发，而相邻音节可能相隔数百毫秒，于是字一个个单独蹦。已改回 AM 的做法——**按 glyph 索引固定错峰** `min(lineDuration / glyphCount × 0.4, 0.4) × (i+1)`，整行如连续波浪推过。`GlyphLayoutEntry.characterIndex` 随之成为死代码已删除。
  3. **补上 `animationHeadstart = 0.1`**：动画比歌词时间提前 0.1s 起步，否则整体慢半拍。
  另外把扫光的**硬边裁剪换成 30pt 羽化**（`lineProgressionGradientFeather`）：不再用 `context.clip` 硬切，而是按字心与填充边缘的距离算 alpha（以边缘为中心、前后各 15pt 过渡），亮层叠在暗层上合成，边界由「刀切」变为渐变。
- ❌ **CPU 逐帧方案整体废弃，改为照搬 AM 的图层树（2026-07-26，第五轮）**。前四轮都在调参数，用户反复反馈「差距非常巨大，几乎不可用」，最后指示「别试了，照搬 AM 吧」。继续 RE 后确认：**问题不在参数，在架构**——按 AM 的方式重建后，前四轮那些参数根本不需要调。
  - **AM 的合成关系**（`sub_100169AC8` 建行、`sub_10018C12C` 建词、`sub_10016694C` 建字，`setMask:` 只有这两处）：

    ```
    LineLayer                     mask = 字层容器
    ├─ backgroundColorLayer       未唱底色，铺满整行
    ├─ LineProgressGradientLayer  已唱亮色 + 羽化带
    └─ mask = 容器
         └─ WordColorLayer × 词    mask = WordLayer
              └─ WordLayer        shouldRasterize；shadow 即微光
                   └─ GlyphLayer × 字
    ```

    **颜色和扫光在遮罩外，字的几何在遮罩内。** 这是关键：字缩放时颜色自动跟随，同时扫光边界始终像素连续。单趟 `draw(_:)` 无法把两者分开，所以之前无论怎么调都做不出来。
  - **字层是什么**：`SyncedLyricsLineLayer.Glyph.GlyphLayer` 继承 MusicUtilities 的 `CTRun.PartialRunLayer`，存 `run` + `range` + `textPosition`，`drawInContext:` 只做三件事——填充色设**纯白**、设 text matrix、`CTRunDraw` 画自己那一段。`contentsFormat = .gray8Uint`。纯白+灰度 = 它是**遮罩**，不是文字本身。
  - **动画驱动**：`LayerPropertyAnimator` 收集图层属性改动 → diff 新旧值 → 每个变化的属性发一条 `CASpringAnimation`，`beginTime` 承担错峰、`fillMode = .both`、`preferredFrameRateRange(80,120,120)`。**发完就没有 CPU 参与**，逐字插值全在渲染进程。
  - **弹跳以词为单位**（`sub_10018B2B4`，由 `sub_1001689D4` 每词调一次）。设词内 N 字、词时长 D：逐字延迟 `min(D/N × 0.4, 0.4) × (i+1)`；弹簧 `ζ=1`、`T = min(D, 3)`；目标是 `frame.origin` 挪位 + `affineTransform = scale(s,s)`；再过 `2D/N` 发第二条回到 identity。同时**词图层动 `shadowOpacity`**（`glowRange = 0…0.4`、`shadowRadius = glowRadius = 5`）——唱到的词那圈微光，之前完全没做。
  - **位移公式**：AM **不做逐字宽度累加**。`x = (原x + W(1−s)/2 + s·原x) / 2` 展开正好等于「整个词按 `k = (1+s)/2` 绕词心缩放」。字按 s 缩放、词按 k 铺开，s > k，所以字之间会轻微互相靠拢——那个「挤一下」正是 AM 的观感。第四轮加的累加补偿把它抹平了，方向就是反的。
  - **落地文件**：新增 `AppleMusicLyricsSpecs.swift`（常量集中）、`SpringTimingParameters.swift`（按周期反推 spring）、`LayerPropertyAnimator.swift`、`GlyphRunLayer.swift`、`LineProgressGradientLayer.swift`、`LineTextLayout.swift`（Core Text → 词 → 字）、`SyncedLyricsLineContentLayer.swift`（层树 + 调度）。删除 `GlyphEmphasisSchedule.swift`、`GlyphLayout.swift`、`LineProgressGradient.swift`。`LyricsLineRowView` 不再画正文，只画翻译。
  - **有意偏离 AM 的四处**（都已在代码注释里写明理由）：
    1. **扫光层宽度固定、只动 position**。AM 会同时改它的 `bounds`，但子层是按 model bounds 布局的，动画中 presentation 会把羽化带裁掉；固定宽度后羽化在每一插值帧都在正确位置。
    2. **回弹用真定时器，不是第二条 `beginTime` 动画**。同一 key path 上两条延迟动画，后加的那条会以 backwards fill 覆盖前一条的整个运行区间，字会被钉在原位。
    3. **回弹目标取排版原位**，而非 AM 的「原位 − syllableLift」。照抄会让已唱的词永久停在高 3pt 的位置，整行出现台阶。
    4. **微光挂在字层，不是词层**。AM 挂在词层，但词层自己没有内容、只有子层——这种图层的阴影按**边界矩形**算，塞进遮罩里就是一个亮方块。AM 靠同时开 `shouldRasterize` 把子层压平成位图才拿到字形阴影；我们改挂到有真实绘制内容的字层上，阴影天然贴着字形轮廓，不用光栅化，也没有子层动画反复重栅格化的开销。
  - **`t`（缩放/微光的插值系数）仍未取到**：AM 存在 Word 对象里（`Word+56`），静态查不到来源。已挂钩 `sub_10018B2B4` 采样，但需要 Music **歌词面板可见**才会命中（六个钩子零命中即证明面板未开）。当前按满值 `t = 1` 实现（即 `s = 1.14`、微光 0.4），是 AM 的上限而非中间态。
- ✅ **强调被裁剪 / 弹跳幅度失控（2026-07-26 修复）**。用户实测「非常生硬的弹跳，而且弹跳幅度非常大」，实为两个几何缺陷叠加，均已定位到确切数字：
  - **`emphasizedOrigin` 纵向漏加词框留白偏移**。横向加了、纵向没加，字形静止时在词框里的 y 是 15.52，强调那一刻直接跳到 −6.78——不是抬 3pt，是往上蹿 22pt。
  - **整行图层的 `bounds` 恰好等于排版出的文字块**，而这一层的遮罩就是字层树，遮罩画不出被遮罩图层之外。强调加出来的一切（上抬、放大、微光）全在框外被齐平切掉；即便修好上一条，每个强调字的顶部仍会少约 6.8pt、首字左边少 3.6pt。所谓「生硬」其实是字被裁没了又冒出来。
  - 顺带修掉一处**位置漂移**：原来用 `layer.frame.origin = …` 挪字形，而回弹那趟执行时缩放还挂着——`frame` 是按变换后的外接框算的，一个「放大—回落」循环实测偏 7%，且不会自校正。改为直接设 `position`。
  - **修法**：`textOutset` 让整行图层比文字块四周各外扩一圈（外扩量与单词那圈共用 `emphasisHeadroom` 计算，不会走样），遮罩/底色/各行渐变/词色层统一平移；`LyricsLineRowView` 定位时减掉它，文字落点不变。
  - **验证手段（可复用）**：把这七个文件连同一个 `AppleMusicLyrics` + `WordTimingEntry` 桩单独编成命令行程序，用 `CARenderer` + Metal 纹理离屏渲染整棵层树（遮罩、阴影、在飞动画都真实合成），按 60fps 出帧再编码成视频。比开 App 等歌词行快得多，本轮两个缺陷都是这么定位并复核的。实测第一个字：纵向位移 20px → 7px（设计值 3pt 上抬 + 半个放大量），可见高度从「31px 塌到 15px」变成「31…41px、再不低于静止高度」。
- ⏳ **待运行时视觉验证**（需正在播放且有歌词的 Apple Music；菜单栏 app，面板需手动开启）：当前行高亮、词级扫光、弹簧滚动手感、点按跳转。文字方向/位置与逐字弹跳已由上述离屏渲染验证。
- ✅ **非当前行的模糊（2026-07-26 补齐）**。
  - **AM 的做法**（`SyncedLyricsLineLayer`，`sub_10019EEDC` 建立、`sub_10019EBAC` 改半径）：行图层**常驻**两个 `CAFilter`——`gaussianBlur` 和 `colorBrightness`——切换焦点时只动数值，走 `setValue:forKeyPath:` 的 `filters.gaussianBlur.inputRadius`。**选中行在函数入口就 early return**，永远不模糊。
  - **不是按距离分级，是开关**。二进制里只有两个字面量：取消选中写 3.0（`sub_1001E9420`）、选中写 0.0（`sub_1001E2608`），`sub_1001E3148` 统一 clamp 到 4.0。录屏实测佐证：量每行笔画边缘 20%→80% 的过渡宽度（这个量与亮度无关，不会被「越远越暗」干扰），当前行 1px，其余各行一律 7~8px，距离 1 和距离 4 没有区别。
  - **有意偏离 AM 的两处**：
    1. **用公开的 `CIGaussianBlur`，不用私有 `CAFilter`**，配合 `NSView.layerUsesCoreImageFilters`。两者的 `inputRadius` 不是同一个量：直接照抄 3 会糊约 1.7 倍。用同一套边缘宽度指标标定后，AM 的 3 对应 `CIGaussianBlur` 的 1.75~2.0，故取换算系数 `coreImageBlurRadiusScale = 0.625`，把 AM 的原值保留在 specs 里、换算发生在使用点。*（本条偏离已被后续「换回私有 `CAFilter`」取代，见下方 2026-07-26 深夜条目——但其中「两者语义不同」的归因是错的，换算系数本身仍保留。）*
    2. **没有当前行时不模糊**。AM 的逻辑是「非选中即模糊」，没有「一行都没选中」这个状态；照抄会让前奏期间整面板发糊，看着像坏了。
  - **动画时长 0.33s** 取自 AM 传给动画器的 timing 负载首字段；该负载的 case 标记（tag 5）没解出来，所以曲线是我们自己的 easeInEaseOut。
  - **`colorBrightness` 那一路暂未实现**：AM 同时还动一个亮度滤镜，符号是 `kCAFilterColorBrightness` + `kCAFilterInputAmount`，方向由 specs+0x2F4 的一个 bool 决定正负。我们已经用容器 alpha 做了明暗区分，重复叠加会过暗。
- ✅ **模块抽出为 SPM target + 探针测试落地（2026-07-26）**：整个 `AppleMusicLyrics/` 从 App target 抽为 `LyricsXPackage` 的新 target **`AppleMusicLyricsPanel`**（`git mv` 保留历史），从此 `swift build` / `swift test` 无需 Xcode 工程即可独立构建、探测本引擎。
  - **App 侧只留一个文件**：`AppleMusicLyricsWindowController`（纯胶水——窗口 frame 记忆、pin 按钮、`isShowLyricsHUD` 生命周期），继续以 `extension AppleMusicLyrics` 挂在包内公开的命名空间上。
  - **对 App 的全部耦合收敛为一个注入面 `AppleMusicLyrics.HostEnvironment`**：`player`（`MusicPlayerProtocol`，默认 `MusicPlayers.Virtual`，探针零依赖）、双语开关、翻译变换（原 `ChineseConverter.shared`）、`lyricsTimeDelay`（原 `defaults[.globalLyricsOffset]` 路径）、偏好变更信号（原 `defaults.publisher`）。`LyricsPanelViewController` 公开 init 注入 `$currentLyrics` / `$currentLineIndex` 两个 publisher——喂合成 publisher 即可离屏驱动整个面板。包内保留 `selectedPlayer` / `adjustedTimeDelay` 两个同名 internal 别名路由到 HostEnvironment，移动过来的源码零改动照读。
  - **两个纯扩展下沉 `LyricsXFoundation`** 供 App 与包共用：`PlaybackState.lyricsDisplayTime(trackDuration:)`、`MusicTrack.resolvedArtwork`。`Task.sleep(seconds:)` polyfill 随唯一使用者进包。
  - **探针**：本会话的 CARenderer 离屏 harness 移植为 `AppleMusicLyricsPanelTests/LineEmphasisProbes`——一条真实时间线跑满一行，断言三件事：①ink 高度永不低于静止值（防 mask 裁剪回归）②最高 ink 行的抬升 ≤ `syllableLift×2+6` 行（防 22pt 过冲回归）③线终了后每个 glyph 位置回到起点 0.5px 内（防 frame-setter 漂移回归）。`APPLE_MUSIC_LYRICS_PROBE_FRAME_DIRECTORY=<dir>` 可逐帧导 PNG。命令：`cd LyricsXPackage && swift test --filter LineEmphasisProbes`（约 8s，全绿）。
  - **坑（探针姿势）**：swift-testing 的 `@MainActor` 测试体本身就是 main queue 上在跑的 job，用 `RunLoop.run(until:)` 等待时 main queue 不可重入，`asyncAfter` 的词回程批次永远不执行、全部字形停在发力位——等待必须用 `await Task.sleep`（挂起让 main queue 排空）；另外图层树要 `CATransaction.flush()` 才会进 `CARenderer`，否则首帧全空。
  - 包 target 以 `.swiftLanguageMode(.v5)` 编译（与 App 的 SWIFT_VERSION 5 一致），Swift 6 严格并发迁移留作独立工作。`LyricsXPackage` 平台随之 10.15 → 12（与 App 部署目标一致）。
- ✅ **真实 lrcx 库探针 + 由其抓出的一个真 bug（2026-07-26）**：新增 `LyricsLibraryFixtureProbes`，直接把 `~/Music/LyricsX` 里 App 自己下载的 `.lrcx`（本机 1310 个）喂给面板，三个层次：
  - **扫库**（`everyDisplayedLibraryLineSurvivesKaraokeLayout`）：每个采样文件的每一可显示行都过一遍解析 → `LineTextLayout.build` → `KaraokeFill` 采样。断言的是**引擎的健壮性而非数据的干净**——真实库里有 timetag 索引超行字符数、tag 时间超行时长、词内多连空格在折行点悬挂等形态，引擎必须全部消化。默认采样 40 个文件（约 0.3s）；`APPLE_MUSIC_LYRICS_FIXTURE_SWEEP_LIMIT=2000` 全库（约 8s），当前全绿。`APPLE_MUSIC_LYRICS_FIXTURE_DIRECTORY` 可换素材目录；无库时整套 skip。
  - **容器级**：真文件喂 `SyncedLyricsContainerView`（离窗模式），断言行视图数 = 可显示行数、行高为正且不重叠、高亮中间行时恰好那一行 `isHighlighted`。
  - **面板端到端**：真文件经 `HostEnvironment` 同款 publisher 注入整个 `LyricsPanelViewController`（挂在从不上屏的窗口里），断言行数与跟随行切换——这正是抽包时承诺的契约：不开 App、不放歌就能驱动整个面板。
  - **抓出的真 bug 已修**：`KaraokeFill.fraction` 文档承诺返回 `0...1`，但对「tag 索引超过行字符数」的真实文件返回了 2.18（`1022-比尔的歌 - Bomb比尔.lrcx` 的制作人行）——图层侧恰好有第二道 clamp 所以视觉没炸，但契约已破。修复：`fraction` 出口统一 clamp。
  - **探针标定两则**（不是引擎 bug，是断言过强）：①Core Text 允许折行点空白悬挂在行框外、词自带尾随空格，包含性判定改为按词内最长空白连长给悬挂容差，且只查有墨迹的词；②tag 时间可超过 `<end>` 声明的时长，「结束后必须填满」的时刻取两者较大值。
- ✅ **扫掠白色从未上屏的回归 + 亮度层级压扁（2026-07-26 深夜修复）**。用户反馈「跟 AM 还是差好多，应该一眼就能看出来」——确实一眼可见，且探针全绿拦不住，因为探针只量墨迹几何、对颜色是瞎的。
  - **定位过程（三级证据链，可复用）**：①实机窗口截图逐行量笔画亮度峰值：AM 当前行已唱部分 1.00（纯白），我们**唱完了的**当前行只有 0.595——恰好等于「未唱 50% 白叠背景」，即已唱白从未出现；②探针逐帧导 PNG，fill=0.5 的帧无一白像素——问题在引擎不在 App 胶水；③把 `LineProgressGradientLayer` 源码抄到 scratchpad 单独经 `CARenderer` 渲染，抄写时无意多写了一行 `applyColor()`，立即正常——同一份代码一行之差，真凶锁定。
  - **根因**：`LineProgressGradientLayer.init` 里 `self.color = color` 指望 `didSet` 把颜色传进子层，但 **Swift 在所属类自己的初始化器内赋值不触发属性观察器**——每个新建的扫掠层生来无色（`fillLayer.backgroundColor` / `gradientLayer.colors` 都是 nil）。且行视图的顺序是先设 `sungColor` 再 `rebuild()`（重建渐变层），外部赋值也救不回来。修复：init 内显式调 `applyColor()`。
  - **亮度层级**：AM 实测非当前行**不按距离压暗**——d1~d4 笔画峰值全部平在 ~0.5（层次感来自模糊，不来自透明度阶梯）；我们此前的 `0.55 − 0.05·d`（下限 0.125）是自己发明的，面板下半截沉进背景。改为非选中一律 0.55。
  - **探针补色觉**：`LineEmphasisProbes` 新增第 3 条断言——fill=0.5 帧，已唱半区近白像素 > 500、未唱半区 < 50（避开 30pt 羽化带 ±35pt）。这类「渐变没画出来」的回归从此过不了测试。
  - **顺带排除两个伪差距**：当前行字号与邻行放大裁剪比对完全相同（「看着大」是模糊吃掉笔画边缘的错觉，与 lldb dump 的 `deselectedTransform = identity` 互证）；行 alpha 机制本身正常。
- ✅ **模糊换回私有 `CAFilter`（2026-07-26 深夜，用户明确豁免 App Review 顾虑）**。`NSClassFromString("CAFilter")` + `filterWithType: "gaussianBlur"`，滤镜类、key path（`filters.gaussianBlur.inputRadius`，与反汇编逐字节相同）、渲染路径（render server 原生，不再需要 `NSView.layerUsesCoreImageFilters`，也不再有 Core Image 进程内合成）全部与 Music 同源；类不存在时优雅退化为无模糊。
  - **重要实测更正**：CAFilter 与 `CIGaussianBlur` 的 `inputRadius` **语义完全相同**（同场景阶跃边缘并排量：两者 r=3 都是 10px、r=1.875 都是 6px）。因此 0.625 换算系数补偿的不是「私有 vs 公开」的差异，而是 **Music 存储常数 3 与其实际渲染效果（≈1.875）之间的内部缩放**——Music 在把 3 写进滤镜前显然还除过什么（尚未在反汇编中找到那一步）。系数保留、常量更名 `renderedBlurRadiusScale`，注释以屏幕实测为锚。
  - 本批验证：LineEmphasisProbes（含新色觉断言）+ LyricsLibraryFixtureProbes 全绿；workspace Debug 构建 0 error / 0 代码 warning；实机重启后窗口截图复核（见下）。
- ✅ **逐字弹跳「像机器人」→ 波浪化（2026-07-26 深夜）**。用户描述得很准：「我们的弹跳像机器人摆动，AM 则流畅得像摇摆的旗子」。同时用户还观察到「AM 不是每首歌都有这效果，像是要歌词格式里的数值支撑」——这条观察正是病因所在。
  - **结构性病因，不是参数问题**。AM 的动画单位是**词**（TTML 里一个带起止时间的 `<span>`，横跨多个字母/汉字），波来自**词内部**字形之间的错峰。它那两个常数因此是这样配合的：弹簧周期 = 整个**词**的时长（很长），而每个字形的回落只等 `2 × 词时长 ÷ 字形数`（很短）——于是字形**永远到不了顶就开始往回走**，与邻居的运动大幅重叠，这就是旗子。
  - **我们的 lrcx 是逐字时间戳**，每个"词"只剩一个字形，两个机制同时退化：①`stagger × (序号+1)` 无字可错，退化成纯延迟 0.4×字长（实测一个 0.47s 的字要晚 0.19s 才起跳，0.1s 的提前量补不回来）；②回落按 `2×字长` 触发，而弹簧 1.46×字长就停稳了——**每个字在顶上冻结约 0.6 秒**。升→冻→落、彼此不重叠，就是机器人。
  - **定位方法（可复用）**：动画参数与 `beginTime` 全是已知量，所以不必测像素——直接把调度解析地积分出来画成时间×位移表。用真实歌词 `沉睡中缠绵 清醒又幻灭` 的时间戳跑出的表里，每个字的"冻结平台"一眼可见；同一套公式喂给一个 5 字形的词则是每字全程在动、幅度呈梯度（横向读 6,6,6,4,3）、峰值仅 67%。两张表并排就是病因和药方。
  - **修法**：`LineTextLayout` 新增**短语分组**（`Word.phraseDuration` / `phraseGlyphCount`）——按空白切分，遇折行、无时间戳的词、以及跨度超过 Music 自己的 `maximumEmphasisSpringPeriod`（3s）时断开；弹簧周期与回落延迟改用**短语**跨度，让 Music 的公式回到它被设计的区间。**每个字的起跳仍锚在它自己被唱到的时刻**（`scheduleDueWords` 本来就是这么触发的），不用均匀错峰，否则长句里动画会跑到歌声前面。
  - **有意偏离 AM 一处**：字形延迟由 `stagger × (序号+1)` 改为 `× 序号`。AM 用 +1 是因为它的 stagger 是"词时长÷该词字形数"，很小；我们的 stagger 来自短语，而词只含一个字形，+1 会让每个字都晚一整拍。词内部的错峰逻辑不变，只去掉了这个前置偏移。
  - **分组规则是对我们数据格式的适配，不是从 AM 抄的**——AM 不需要它，因为它的 TTML 天生就是词级。Music 的常数与公式一个未动。
  - **探针**：新增 `emphasisRipplesAcrossNeighboursInsteadOfFreezingEachGlyph`，逐帧采样每个字形 presentation 层的位置，断言两件事：①任一时刻至少 3 个字形同时在动（防"逐字轮流"回归）②没有字形在离开静止位后**真正停住**超过 0.15s（防"顶上冻结"回归）。"停住"用比"在动"严一个数量级的阈值（0.01pt/帧 vs 0.05），因为弹簧换向时速度必然过零、但不会真停——这一点最初写松了导致探针在 0.25s 边界抖动。**已反向验证**：把代码改回旧调度，两条断言都如实失败（同时在动 2 个、冻结 0.35s）。
  - `LineEmphasisProbes` 整体改为 `@Suite(.serialized)`：两条探针都跑真实墙钟时间线、回落批次经主队列 `asyncAfter`，并行时会在彼此的 `await` 点交错，互相污染测量。
- ✅ **行切换滚动：交给 Core Animation 驱动（2026-07-26 深夜）**。用户反馈行间「没有任何动画效果，就是线性的上移，看不到弹跳」。
  - **一次自摆乌龙，值得记下来**。先用用户给的 CleanShot 录屏拟合，得出 ωₙ≈15、峰值 570 pt/s，据此把 `scrollSpringNaturalFrequency` 从 10 改到 13.3。**这是错的**：那份录屏是 30fps，而运动是 60Hz 的，30Hz 采样把相邻两帧合成一帧、**把每帧步长翻了一倍**，拟合自然偏快。教训：**给运动曲线拟合参数之前，先确认采样率不低于显示刷新率。**
  - **改用 60fps 单独录制 Music 后的真值**：连续三次单行推进，各走 80~90pt，**由 27~28 步在 450ms 内送达**（即 Music 每一个显示帧都在动），步长依次 `1 3 4 5 5 6 6` 上升、`5 5 4 4 3 3 2 2 1 1 1` 衰减。6pt/帧 @60Hz = 360 pt/s，而 ζ=0.9 的弹簧峰值速度为 `travel · ωₙ · 0.395`，反解 ωₙ = 10.1。**与 dump 出的 mass 1 / stiffness 100 / damping 18 完全一致**，故已改回 10 并在注释里记下这次教训。
  - **所以差距不在曲线，在送达密度**：Music 的 450ms 里有 28 个中间位置，起步的 `1 3 4 5` 和收尾的 `2 1 1 1` 正是"弹"的观感来源；若同样的曲线只送达三五个位置，缓动两端全部丢失，看起来就只剩匀速平移。
  - **无法用录屏测我们自己**：录屏本身会让本 App 掉帧（用户实测：不录屏时正常，一录就狂掉帧；本 App 有 ColorfulX 的 Metal 背景常驻渲染 + 逐帧卡拉OK主线程工作 + Debug 构建挂着调试器）。两个窗口并排同录时更严重。因此侧录数据只能用于 Music，**不能用于判断本 App 的送达密度**——要测必须在 App 内埋点，或改用离屏探针。
  - **顺带澄清**：AM 的行切换**没有位置过冲**（ζ=0.9 的过冲仅 0.15%，不可见）。"弹跳感"来自起步的缓入与收尾的长衰减，不是回弹，所以不要为了"更弹"去降阻尼比。
  - **积分器本身无误**：把 `stepScrollSpring()` 的闭式解原样重跑，得到的是标准弹簧曲线，与理论一致。
  - **顺手去掉一处每次切换的空转**：`updateDistances` 会给**每一行**调 `animateAlpha`，而距离衰减改平后非当前行目标值全相同，绝大多数是空动画——几十个 `CABasicAnimation` 恰好压在滚动弹簧起步的那一帧上。已加相等判断跳过。
  - **最终改法：不再自己逐帧推进，改挂真正的 `CASpringAnimation`**（`stepScrollSpring()` 及其全部状态已删除，display link 回调不再碰滚动）。这样送达密度天然等于刷新率，与主线程忙不忙无关——正是 AM 的机制（`LayerPropertyAnimator` / `sub_100162B3C` 弹 `contentView.bounds` / `sub_10015AF20`）。
  - **关键约束（来自 `appkit-layer-backing`）**：`bounds` 属于 AppKit **无 guard 强制从视图 ivar 回写图层**的几何属性之一（`_updateLayerGeometryFromView`，`setFrameSize:` 里直接调用），所以**不能把 clip 图层的 bounds 当作独立状态去animate**。正确切分是：**模型值先写到终点**（AppKit 保持权威，hit testing / `documentVisibleRect` / 下一次目标计算全读它），**显式动画只作为视觉叠在上面**。显式 `add(_:forKey:)` 的动画不会被"设置模型值"这个动作移除，因此后续的几何同步只要写的是同一个终点就无害。
  - **两个实现细节**：①新弹簧的 `fromValue` 取 **presentation 层**的当前位置而非模型值，否则连续换行时会先跳回再走；②`anchorClip` 保留"目标未变则不重启"的判断——间奏期间它每帧都被调用，每帧重启弹簧会让它永远走不出起步段。
  - **被这次改动抓出的一个真 bug**：`scrollView.contentView`（`NSClipView`）**默认没有图层**，`springClip` 会静默退化成瞬间跳转。已在 `setupScrollView()` 显式 `wantsLayer = true`。这一条是写探针时发现的——不写探针根本不会暴露。
  - **探针**：新增 `ScrollSpringProbes`（离屏窗口 + 合成歌词，不依赖录屏）。断言的是**机制**而非帧数（帧数不确定，机制是确定的）：①行切换后 clip 图层上确实挂着一个 keyPath 为 `bounds.origin.y` 的 `CASpringAnimation`，且 mass/stiffness/damping 恰为 Music 的 1/100/18；②模型值已经在终点；③对同一目标重复 re-center 不会重启弹簧。**已反向验证**：去掉 `add(_:forKey:)` 后第一条如实失败。
- 📋 **剩余（均为净负价值或越界，故未做）**：
  - **CAGradientLayer mask 零重绘**：会替换已通过三轮评审的 two-pass draw（回归风险），且涉及 flipped-layer 坐标；two-pass 仅重绘单行、性能已足，故不为优化而冒险。
  - **精确 Apple 常量**：specs 从 Music 侧注入，且 Apple 的 spec 模型（selectedLinePosition/contentInsets/lineSpacing/paragraphSpacing/emphasizingScaleRange 分立 + 逐字动态缩放）与本简化架构映射不佳，原始数值套用价值低；当前经验值最适合视觉微调。
  - **BackgroundVocals（和声）样式**：需 LyricsKit 暴露和声数据（越界，不改依赖）。
  - ~~逐字精确扫光（per-glyph）/ 字级缩放强调~~：已于 2026-07-26 完成，见下方「逐字弹跳」。

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

> **实际落地（2026-07-26）与本节不同**：没有建 `GlyphLayer`，改为 CPU 解析求解同一条临界阻尼 spring，把 scale + 上抬折进已有的单次 `draw(_:)`。这样既避开了「字形级层数多」的成本，也不用管层的创建/回收，图层树保持扁平。详见进度列表中的「逐字弹跳」条目与 `GlyphEmphasisSchedule.swift`。

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
