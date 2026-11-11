# 0008 - 自绘 Metal 歌词渐变背景

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-29
- **最后更新**: 2026-09-05
- **所属愿景**: 无
- **关联提案**: [0007 对齐 Apple Music 26.6 歌词动画](0007-apple-music-lyrics-animation-parity.md)
- **实现分支 / Pull Request**: `develop`（当前工作树，未单独开分支）
- **配套文档**: [Metal 歌词渐变背景实现说明](../Internal/AppleMusicMetalGradient.md)

## 摘要

歌词面板改用项目自有的 `MTKView` artwork 背景。每首歌只在后台把封面最长边缩到 300 pixel，上传为 private
mipmapped texture；每帧在离屏 texture 中交叉合成 source/destination artwork，通过 `MPSImageGaussianBlur` 模糊，
最后以预生成细分网格做轻微形变并叠加 saturation/scrim。drawable 使用完整 backing resolution，显示节奏最高为
60 FPS。窗口拖动、不可见、完全被遮挡、live resize 或开启 Reduce Motion 时停止连续绘制。

不恢复 SwiftUI 宿主，也不重新引入 ColorfulX、ColorVector 或 SpringInterpolation。实现只使用公开 AppKit、MetalKit
与 Metal Performance Shaders API；不会复制 Apple Music 的 shader、metallib 或私有类型。

### 2026-08-31 架构修订

早期 palette shader 与自定义 `CAMetalLayer` timer 在真实全屏歌词中出现过稳定 30 FPS。frame stage 日志确认，固定
timer 按 60 FPS 请求 frame 时，`nextDrawable()` 会持续等待约一个刷新周期；旧 fragment shader 同时在每个像素上计算
五组移动色场和程序化 grain，使低分辨率 drawable 仍可能错过 16.7 ms 帧预算。

Apple Music 26.6 的 Swift interface、Objective-C runtime dump 与 `Music.i64` 交叉核对表明，它并不使用逐像素 palette
shader：`TSLBackdropMetalView` 继承 `MTKView`，artwork 在后台缩到最长边 300 pixel 后上传为 private mipmapped texture；
每帧先合成 source/destination artwork，再由 `MPSImageGaussianBlur` 处理，最后通过预生成的细分网格做轻微形变并叠加
saturation/scrim。输出 texture 使用完整 backing resolution，昂贵的运动计算只发生在少量 vertex 上。

用户批准按这一公开 API 架构重新实现。因此本提案重新进入 `In Progress`；此前“不上传 artwork texture、保留
0.35 drawable scale、使用独立 `DispatchSourceTimer`”的选择只保留为历史决策，不再约束当前实现。

最新单实例日志表明 renderer 大部分时间实测 56.5–60 FPS，但仍会间歇出现 48–128 ms 的 callback gap；同一窗口内的
Metal command encoding 只有约 0.17–0.59 ms。调研时还发现两个 Debug app 同时运行，并且背景与歌词逐帧路径合计产生
大量 signpost，足以污染 Debug cadence 与日志保留。Apple Music 二进制随后确认三项差异：Gaussian blur options 为
`.allowReducedPrecision + .disableInternalTiling`、优先使用 `BGR10A2Unorm` 并回退到 `BGRA8Unorm`，而且先编码离屏 pass，
最后才获取 `currentRenderPassDescriptor`。本轮修订补齐这三项，并把逐帧 signpost 改为显式诊断开关；周期汇总、慢帧
事件和错误日志继续默认保留。

## 动机

一次性 Core Image 封面模糊背景在静止时成本很低，但用户实测复杂封面下拖动歌词窗口仍会掉帧。它还要求
WindowServer 在窗口移动时持续合成一张铺满窗口的 artwork layer，性能会随封面内容和显示尺寸变化。

ColorfulX 的视觉方向更合适，但 5.6.4 的 AppKit 实现仍按 drawable 全分辨率、显示刷新率持续提交 compute
command，而且没有窗口遮挡和拖动期间的暂停策略。直接接回它会重新引入三项依赖，也无法约束本项目最关心的
窗口拖动路径。

自有 `MTKView` 可以保留封面驱动的柔和空间感，同时明确控制 texture 尺寸、显示节奏与生命周期。封面只在切歌时
预处理一次，逐帧路径只采样一张最长边 300 pixel 的 texture；复杂封面不会增加每帧几何或取色成本。

## 目标

1. 保留封面驱动的柔和动态背景，观感接近 Apple Music 的亮度、空间感与缓慢运动。
2. 使用 `MTKView` 自身的显示同步循环，最高 60 FPS，并输出完整 backing resolution。
3. 窗口拖动、不可见、完全被遮挡、live resize 和 Reduce Motion 下不持续提交 Metal command。
4. 每首歌最多执行一次后台缩图与 texture upload；旧曲目的异步结果不能覆盖当前 artwork。
5. 切歌 artwork 平滑过渡；Reduce Motion 下只在状态改变时请求单帧。
6. 保持歌词面板纯 AppKit，不增加第三方依赖。
7. 默认诊断不能通过逐帧 signpost 反过来影响被测 cadence。

## 非目标

- 不复制 Apple Music 或 ColorfulX 的 shader、metallib、内部类型或具体实现。
- 不逐像素复现 Apple Music 私有动态背景。
- 不恢复整套 SwiftUI 歌词面板。
- 不新增背景模式、质量档位或用户设置。
- 不改歌词行内、行间和 viewport blur 动画。

## 提议方案

### 一、异步 artwork 预处理

`ArtworkBackdropImageProcessor` 接收在 main thread 取得的 `CGImage`，在专用 serial queue 上执行：

```text
CGImage → longest edge ≤ 300 pixel → private mipmapped artwork texture
        └→ 32 × 32 sample → average luminosity
```

同一曲目只提交一次。`ArtworkGradientRequestState` 用 track identity 与单调递增 generation 拒绝乱序 completion。
新曲目短暂缺少封面时先保留当前 texture，超过 1.2 秒仍未收到 artwork 才切换到内置 fallback texture。

### 二、离屏 blur 与网格合成

`GradientBackgroundView` 承载一个自有 `MTKView`：

- `preferredFramesPerSecond` 取当前屏幕上限与 60 的较小值，尚未附着屏幕时回退到 60；
- `framebufferOnly = true`；
- `autoResizeDrawable = false`；
- drawable 使用完整 native backing size；
- output 与 offscreen texture 优先使用 `.bgr10a2Unorm`，设备不支持时回退 `.bgra8Unorm`；
- source/destination artwork 先合成到 offscreen texture，再以 `MPSImageGaussianBlur` 写入第二张 texture；
- blur sigma 为 drawable diagonal 的 `0.045394707`，options 固定为 `.allowReducedPrecision` 与
  `.disableInternalTiling`，edge mode 为 `.zero`；
- 最终 pass 使用 5 × 5 base mesh 与三级细分，在 vertex 端做轻微形变，fragment 端只做 texture sample、saturation
  与 luminosity 驱动的 scrim。

每帧先创建 command buffer 并编码 artwork composition/blur；完成离屏编码后才获取 `currentRenderPassDescriptor` 与
`currentDrawable`，再编码最终 pass、present 和 commit。这样 drawable 等待不会提前阻塞本可先提交给 command buffer
的离屏工作，顺序与 Apple Music 26.6 一致。

### 三、transition 与诊断

Swift 端保留 source/destination texture、transition start time 与一个 pending texture。当前 crossfade 未完成时到达的新
artwork 进入 pending slot，避免中途跳色。运动完全由暂停感知的 elapsed time 推导。

默认只记录两秒周期汇总、慢帧、状态/resource 变化与 command buffer error。`GradientFrameEncode`、歌词 display link
内部阶段等逐帧 signpost 仅在进程环境变量 `LYRICSX_DETAILED_FRAME_SIGNPOSTS=1` 时开启；常规 Debug 运行不会创建
每帧 interval 洪流。开启连续绘制时只切换 `MTKView.isPaused`，不再额外同步调用一次 `draw()`。

### 四、生命周期与窗口拖动

`GradientBackgroundView` 同时检查：

- view controller 是否正在显示；
- view 是否仍在 window；
- window 是否可见且 `occlusionState` 包含 `.visible`；
- `DraggablePanelView` 是否正在移动窗口；
- view 是否处于 live resize；
- Reduce Motion 是否开启。

任一条件要求暂停时，`MTKView.isPaused` 立即置为 `true`。动画时钟同时暂停，恢复后不会因为 wall-clock 已前进而
跳到另一个渐变位置。窗口拖动只复用最后一张 drawable；拖动结束后按当前屏幕刷新率继续绘制。窗口移到另一块
屏幕时，通过 `NSWindow.didChangeScreenNotification` 立即更新 `MTKView` 的刷新率。

## 替代方案考量

- **恢复 ColorfulX 5.6.4** —— 否决。它是纯 AppKit + `CAMetalLayer`，但默认按完整 drawable 和 display link
  持续 compute，没有本项目需要的 occlusion / drag gating，并重新引入两项传递依赖。
- **保留一次性 Core Image artwork backdrop** —— 否决。静止成本低，但复杂封面下窗口拖动仍出现用户可见掉帧，
  且视觉是封面空间模糊，不是用户最终选择的多色渐变方向。
- **用 `NSHostingView` 恢复最初 SwiftUI gradient** —— 否决。会重新扩大 SwiftUI invalidation boundary；现有
  AppKit 歌词逐帧更新不应经过 hosting tree。
- **自定义 `CAMetalLayer + DispatchSourceTimer`** —— 否决。真实日志已经复现 drawable backpressure，且其 timing
  与 `MTKView` 的显示节奏不同；Apple Music 也直接使用 `MTKViewDelegate`。
- **完全静态 artwork backdrop** —— 保留为 Reduce Motion 降级，不作为默认；正常模式仍需要轻微环境运动。

## 影响

### 用户可见变化

- 背景由静态封面模糊图改为封面驱动、带轻微网格形变的缓慢动态 backdrop。
- 窗口拖动时背景暂时冻结，松手后从同一位置继续；歌词与控制仍正常更新。
- 切歌时颜色平滑变化，不出现黑帧或旧曲目异步结果回跳。

### 可发现性

这是现有歌词面板的直接视觉替换，没有新入口或设置。

### 数据与配置兼容

不新增或迁移 `UserDefaults`，不改变歌词、封面缓存和播放器数据格式。

### 平台与最低版本

不改变 package 的 macOS 12 最低版本。`MTKView`、Metal 资源 library 与窗口 occlusion API 均满足现有目标。

### 发布

发布说明只需描述歌词面板背景视觉与窗口拖动性能改善，不暴露 shader 或依赖清理细节。

## 测试与验证

### 自动化测试

1. 默认配置固定为 300 pixel artwork、完整 drawable、0.5 second transition 与 5 × 5 / level 3 mesh；刷新率策略没有
   有效屏幕值时回退 60，并把 120 Hz 屏幕限制为 60 FPS。
2. drawable size 使用完整 backing size 并处理零尺寸。
3. 同一曲目只提交一次 artwork，新曲目使旧 generation 失效。
4. 合成分区图片按比例缩到最长边 300 pixel，并产生 0...1 的 average luminosity。
5. output format 顺序固定为 `BGR10A2Unorm → BGRA8Unorm`，blur options/edge mode 与逆向证据一致。
6. 逐帧 signpost 默认关闭，只能通过精确环境变量值 `1` 开启。
7. lifecycle policy 在隐藏、遮挡、窗口拖动和 Reduce Motion 下停止连续渲染。
8. workspace build 验证 `.metal` source 能被编译并从 target resource bundle 链接。

### 构建与人工观察

- 运行 `ArtworkGradient` 专项测试并以 `swift test` 原始退出码为准。
- 使用隔离 DerivedData 构建 umbrella workspace 的 LyricsX Debug scheme。
- 本轮按用户已有授权只启动隔离 DerivedData 中的一个 Debug app；最终视觉与全屏 cadence 仍由用户操作并复检。

## 风险

- `Bundle.module` 取错会导致 runtime 找不到 shader；pipeline 必须明确从 package resource bundle 创建。
- `BGR10A2Unorm` 并非所有 device 都支持 render target 与 shader write；创建 offscreen texture 或 pipeline 失败时必须回退
  到 `BGRA8Unorm`，不能让背景初始化失败。
- Swift / Metal uniform layout 不一致会产生错误颜色；参数继续使用 `float4`，避免自定义结构 padding。
- `autoResizeDrawable` 关闭后必须在 layout / backing scale 变化时显式同步完整 drawable size。
- 只设置 `isPaused` 而不暂停动画时钟会在松手时跳帧；两者必须作为同一个状态转换。
- artwork completion 必须回到 main thread 并通过 generation gate，不能从后台 queue 修改 view 或 renderer 状态。
- 常规诊断不能开启逐帧 signpost；需要阶段级 trace 时只能为单次进程显式设置环境变量，并避免同时启动第二个 app。

## 文档策略

- 更新本提案与 `Documentations/Internal/AppleMusicMetalGradient.md`。
- 不修改用户明确不再维护的旧 `docs/`。
- 无调用者 API 和隐藏使用契约，因此不新增 guide。
- 没有引入项目自造术语，因此不修改 glossary。
- 不改变安装、使用和构建流程，因此不修改公开 README。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-29 | Created as Draft | 用户指出 ColorfulX 背景与 Apple Music 的明暗、空间感仍有差距。 |
| 2026-08-29 | Draft → Accepted | 用户接受以自有 Metal artwork renderer 替换 ColorfulX 的初版方案。 |
| 2026-08-29 | 初版持续 Metal 方案撤回 | 真实亮色封面被 brightness lift 推得过亮，用户要求恢复最初 SwiftUI 视觉。 |
| 2026-08-29 | 批准 Core Image 修订 | 用户确认把旧 SwiftUI artwork blur 移植到一次性预渲染与纯 AppKit layer。 |
| 2026-08-29 | Core Image 实现完成 | 专项测试、package tests 与 workspace Debug build 通过，等待真实视觉与性能复检。 |
| 2026-08-30 | 复杂封面拖动复检失败 | 用户确认复杂封面下拖动窗口仍掉帧，要求评估恢复 ColorfulX 或自绘 `MTKView`。 |
| 2026-08-30 | ColorfulX 5.6.4 只读核对 | 确认其为 AppKit + Metal，但按完整 drawable 持续 compute，且没有 occlusion / drag gating。 |
| 2026-08-30 | 批准自绘 `MTKView` 修订 | 用户接受低分辨率 30 FPS、异步 palette、拖动与不可见时暂停的自有 renderer；提案保持 `In Progress` 直到实现和验证完成。 |
| 2026-08-30 | In Progress → Implemented | 自有 `MTKView`、异步五色提取、generation gate、拖动 / 遮挡 / live resize / Reduce Motion 暂停与 package shader resource 已完成。专项 11 项与完整 package 113 项测试均以原始退出码 0 通过；隔离 DerivedData 的 umbrella workspace Debug build 成功，app resource bundle 内存在 `default.metallib` 且包含两个预期 shader function。 |
| 2026-08-30 | 文档与术语裁决 | 更新本提案、实现说明与两份索引；没有调用者隐藏契约和项目自造术语，因此不新增 guide、不更新 glossary，也不修改公开 README。 |
| 2026-08-30 | 固定 30 FPS 复检失败 | 用户观察到 Xcode 将窗口报告为约 30 FPS，面板操作也呈现 30 Hz 的卡顿感；源码核对确认限制来自全窗口 `MTKView`，不是歌词 `MSDisplayLink`。 |
| 2026-08-30 | 刷新率策略修订 | 用户批准让低分辨率 renderer 跟随当前屏幕 `maximumFramesPerSecond`，并在窗口换屏时更新；继续保留 drawable scale 与全部暂停策略。 |
| 2026-08-30 | 刷新率修订验证完成 | `ArtworkGradient` 专项 12 项与完整 package 114 项测试均以原始退出码 0 通过；umbrella workspace 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。未启动应用，真实屏幕帧率仍由用户复检。 |
| 2026-08-31 | Implemented → In Progress | 最新日志确认自定义 `CAMetalLayer` 的 drawable backpressure 会把背景稳定降到 30 FPS。Apple Music 26.6 的二进制核对进一步确认其使用 `MTKView` 显示节奏、最长边 300 pixel 的 artwork texture、`MPSImageGaussianBlur` 与细分网格形变，而不是逐像素程序化 palette。用户批准按这一公开 API 架构重新实现背景；此前否决 artwork texture 的判断撤回。 |
| 2026-08-31 | Apple Music 形态的 renderer 已落地 | 已替换为 `MTKView` delegate cadence、300 pixel private mipmapped artwork texture、离屏 transition、`MPSImageGaussianBlur` 与 5 × 5 / level 3 mesh final pass；旧 palette extractor、逐像素色场与自建 timer 已删除。串行执行的歌词面板相关 50 项测试原始退出码为 0，隔离 DerivedData 的 umbrella workspace Debug build 原始退出码为 0，产物 `default.metallib` 包含四个预期 function。完整 package 仍有既存 `WidgetDataStore` round-trip 失败，因此不宣称全套测试通过；真实观感和全屏 cadence 等待用户复检，提案继续保持 `In Progress`。 |
| 2026-08-31 | 单实例 cadence 修订 | 最新日志把大部分 frame 定位在 56.5–60 FPS，间歇 callback gap 为 48–128 ms，而同帧 Metal encoding 低于 0.6 ms；调研期间同时运行的两个 Debug app 与默认逐帧 signpost 会污染测量。本轮默认关闭逐帧 signpost，并对齐 Apple Music 的 blur options、非 sRGB output format 与“离屏编码后再取 drawable”顺序。提案保持 `In Progress`，等待单实例真实全屏复检。 |
| 2026-08-31 | cadence 修订构建完成 | 新增回归测试先红后绿；52 项定向测试中 51 项通过，一个真实时间行内弹跳探针受并发负载影响失败，单独重跑通过。隔离 DerivedData 的 umbrella workspace Debug build 原始退出码为 0，四个 Metal function 均存在。已只启动这一份隔离 app，运行时 cadence 等待用户打开全屏歌词后复检。 |
| 2026-09-05 | 用户批准背景视觉修复 | 根据 Music CPU 数据和本机 Metal 中间表示，补齐高亮限制、深色遮罩及通道下限，恢复三组旋转与双曲面插值；纠正 5×5 个单元被当成 5×5 个控制点的误读。具体实现与本轮验证记录见配套实现说明。保持现有 MTKView/MPS 调度架构，未启动应用做交互验证。 |
| 2026-09-05 | 用户要求继续对齐 MiniPlayer 对照图 | 同歌截图仍显示颜色过艳、暗部过黑。确认 MiniPlayer 存在不同背景路径，不再把独立 Metal 渲染器默认值视为窗口最终外观；在现有最终 pass 中添加明确标注为截图校准的色彩与反差处理，并固定 sRGB 输出。保留现有动画和帧调度，新增封面采样的完整渲染回归；真实播放观感尚未验收，状态保持 In Progress。 |
| 2026-09-05 | 对照目标更正，转入新草稿 | 用户的 Xcode 层级捕获证明对照窗口是 Music 26「正在播放」全窗口播放器，背景由 `MediaCoreUI.Backdrop.CompositeRenderer` 绘制，本提案复刻的 `TSLBackdropMetalView` 只用于 MiniPlayer 大封面态。截图校准判定为错误管线上的补丁，将在新草稿 [0010-apple-music-now-playing-backdrop](0010-apple-music-now-playing-backdrop.md) 落地时删除；本提案保持 In Progress，等新草稿接受后一并收尾。 |
| 2026-09-05 | In Progress → Implemented | 新草稿 [0010-apple-music-now-playing-backdrop](0010-apple-music-now-playing-backdrop.md) 已落地：本提案的 `MTKView` 调度、生命周期暂停、过渡队列与诊断成为两条管线共用的驱动层；复刻 `TSLBackdropMetalView` 的管线以 `legacyTSL` 变体保留（去掉截图校准，恢复 `colorspace = nil` 与原始断言），默认变体改为 `MediaCoreUI` 管线。本提案不再承担「对齐 Apple Music 观感」的目标，剩余的真实观感复检记在新草稿下。 |
