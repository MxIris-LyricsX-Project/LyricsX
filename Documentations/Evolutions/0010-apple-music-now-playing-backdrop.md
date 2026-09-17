# 0010 - 歌词面板背景改按 Music 26「正在播放」的 MediaCoreUI 管线重做

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-05
- **最后更新**: 2026-09-05
- **关联提案**: [0008 自绘 Metal 歌词渐变背景](0008-apple-music-metal-gradient.md)
- **配套文档**: [Metal 歌词渐变背景实现说明](../Internal/AppleMusicMetalGradient.md)

## 摘要

0008 及其两轮「颜色对齐」把 Apple Music 的背景当成 `TSLBackdropMetalView` 来复刻，最后一轮甚至按截图拟合了一段
降饱和、降反差、抬亮的「校准」。2026-09-05 用 Xcode 视图层级捕获（`/Volumes/RE/AppleMusic/26.6/Music.viewhierarchy`）
确认：用户一直用来对照的窗口是 Music 26 主窗口的「正在播放」全窗口播放器，背景视图是 `MediaCoreUI.BackdropHostView`，
渲染器是 `MediaCoreUI` 框架里的 `Backdrop.CompositeRenderer`。`TSLBackdropMetalView` 只服务于 MiniPlayer 的大封面态和
旧沉浸模式，两套管线的数学、参数和色彩空间处理都不同，所以之前无论怎么调常数都对不上。

本提案把背景按 `MediaCoreUI` 的实际管线重做：128 像素封面、gamma 空间、三实例旋转、四分之一分辨率画布、以 pt 计的
大半径高斯模糊、CAMeshTransform 细分网格、反预乘加白混加 3D LUT 的最终合成、BGRA10_XR 输出。保留 0008 已有的
`MTKView` 调度、窗口生命周期暂停、generation gate 与隔离构建。做成可切换：`mediaCoreUI26` 默认，`legacyTSL` 保留去掉
截图校准后的现状供并排比较。截图校准整段删除。

## 方案

### 一、对照目标的更正（层级捕获证据）

- 捕获里只有主窗口可见（`NSWindow` 0x8ba3a2300，1176 × 811 pt，标题 "Music"）；MiniPlayer 窗口存在但 `visible = 0`。
- 主窗口内容为 `MediaCoreUI` 的 `RootView`，view controller 是 `NowPlayingViewController<Music.MusicPlayerController>`；
  子视图依次为 `MediaCoreUI.BackdropHostView`（全窗口）和承载 `NowPlayingFullWindowPlayer` 的 `NSHostingView`。
- `BackdropHostView` 下只有一个 `CAMetalLayer`：`pixelFormatName = BGRA10_XR`、`colorSpaceName = kCGColorSpaceExtendedSRGB`、
  `framebufferOnly = 1`、`displaySyncEnabled = 1`、`maximumDrawableCount = 3`、drawable 2352 × 1622，
  `effectiveAppearance = DarkAqua`。
- 歌词由 `Music.MusicPlayerController.LyricsViewController` 经 SwiftUI 桥接承载，里面就是 Apple 自己的
  `LyricsX.SyncedLyricsViewController`（同名是巧合，那是 Music 内部歌词模块的 Swift module 名）。
- 背景上方没有材质层。全窗口的 `CABackdropLayer`（groupName `com.apple.MediaCoreUI.backdrop`）是 `captureOnly = YES`，
  只给玻璃按钮取样。之前怀疑的 `AMPVibrantContainerView` 经运行时反射确认是普通 `NSView`，只重写了
  `_vibrantBlendingStyleForSubtree`。

### 二、`Backdrop.CompositeRenderer` 的实际管线

证据来源三方核对：`/Volumes/DyldSharedCaches/macOS/26.6/MediaCoreUI.i64`（idax 从 26.6 dyld cache 建库，image base
0x25953e000，`dyld_info -exports` 的偏移加 base 即地址）、本机
`/System/Library/PrivateFrameworks/MediaCoreUI.framework/Versions/A/Resources/default.metallib` 的 IR
（`metal-objdump --metallib -d`）、上述层级捕获。本机系统是 26.6.2，与数据库的 26.6 不是同一 build，运行时地址对不上，
静态表要从数据库读。

渲染器由三个子渲染器串联：`TextureBlender` → `RotatingArtworkRenderer` → `PinchRenderer`（init 0x259679E64，
`draw(in:)` 0x25967C5CC，每帧推进 0x25967B980，尺寸变化 0x25967BC9C，环境参数 0x25967A234）。

#### 1. 封面贴图与切歌

- 封面先用 `CGBitmapContext` 重绘到最多 128 × 128（0x2596796EC），再用 `MTKTextureLoader` 加载，选项只有
  `SRGB: false`（0x25967FCB0）。**整条管线在 gamma 空间工作**，中间纹理全部 rgba16Float（pixel format 115）。
- `TextureBlender` 输出 128 × 128 纹理；切歌用 `blended_fragment` 在新旧纹理间 `mix(旧, 新, u[3])`，`u[3]` 经
  `crossfadeTimingFunction (0, 0, 0.3, 1)` 缓动，`crossfadeDuration` 0.8 秒（wall-clock）。
- 无封面时用占位色（Music 传 `systemGray`）。

#### 2. 三实例旋转合成（`rotation_vertex` / `rotation_fragment`）

- 画布为 drawable 的四分之一尺寸（宽高各 `>> 2`），storage shared，每帧 clear 为透明 (0, 0, 0, 0)（0x25967F708）。
- 三个模型矩阵（0x25967A4F8、0x259680AAC）：实例 0 `scale(1.4)`，timeScale 120；实例 1 `T(−0.25, 0.15) · scale(0.7)`，
  timeScale 70；实例 2 `T(0.7, 0.7) · scale(0.7)`，timeScale 90，且 `rotationReference = 0`，即它的视图基还按实例 0 的
  角速度绕画面中心公转。
- 顶点：`θ = time · 2π / timeScale`；`pos = View × Sk × (View 基按参考实例旋转) × Model × R(θ) × v`。View 横屏为
  `scale(1, w/h)`，竖屏 `scale(h/w, 1)`。`Sk = 1 + 0.33 × mix(spectrum.x, spectrum.y, 0.1)²`，无音频分析时为 1。
- 片元：`c = 封面采样（贴图为空则灰 0.3）`；`c = mix(c, 黑, darken + 0.0075 × 实例序号)`，深色外观 `darken = 0.5`，
  浅色 0.35（0x2595B4038 判断 `effectiveAppearance`）；对比度 `(c − 0.5) × (1 + spectrum.x × 0.076) + 0.5`；
  饱和度矩阵（SVG saturate 系数 0.213 / 0.715 / 0.072）`s = saturation + spectrum.z × 0.166`。输出 alpha 1。

#### 3. 高斯模糊

`MPSImageGaussianBlur`，作用在四分之一画布上，`sigma = blurBase × backingScale / 4`（0x25967FA34）。`blurBase` 以 pt 计，
初值 80，每帧向目标值 ±1 逼近；目标值和饱和度一起由「横竖屏 × 强度档」决定（0x25967A234）：

| 场景 | 饱和度 `u[9]` | 模糊目标 pt |
|---|---|---|
| 横屏，exciting（歌词态） | 2.4 | 120 |
| 横屏，subdued | 2.9 | 200 |
| 竖屏，exciting | 2.0 | 85 |
| 竖屏，subdued | 2.4 | 160 |

2x 屏横屏歌词态等效全分辨率 sigma 240 像素，约为 0008 现状（对角线 × 0.0454，同尺寸约 128 像素）的两倍。

#### 4. 网格形变（`pinch_vertex`）

- 横屏用 8 × 8 格（9 × 9 个控制点），竖屏 5 × 5 格（`sub_2596541E8`，flag 由 0x25967A234 写入 `renderers[2] + 112`）。
  五套预设随机选一套（`sub_25965415C(5)`），每套含源与目标两张控制点表，转成 `CAMeshTransform` 后 `subdividedMesh: 2`。
  控制点位置为 `2 × p − 1`，纹理坐标为格点坐标。
- 静态表在数据库：`0x29CF37568`（5 × 5，头 32 字节后 10 个数组指针，每个数组 32 字节头 + 36 个 CGPoint）、
  `0x29CF3A9B8`（8 × 8，81 个 CGPoint）。落地时用 `get_bytes` 提取，本机运行时读不到（build 不同）。
- 顶点：`warped = mix(源位置, 目标位置, u[4])`，`u[4] = (sin(time / 3.5) + 1) / 2`（`warpTimingSpeed` 3.5）；
  `plain = (格点 − 0.5) × (2 + 0.5 × (1 − u[5]))`；`pos = mix(plain, warped, u[5])`。`u[5]` 是 `pinchMix` 经
  `modeTimingFunction (0.42, 0, 0.58, 1)` 缓动，exciting 档 0.8 秒内升到 1（形变全开），subdued 档降到 0（无形变、1.25 倍放大）。

#### 5. 最终合成（`pinch_fragment`）

`c = 采样(模糊画布).rgb / alpha`（反预乘，抵消零边模糊的暗角）→ `c = mix(c, 白, 0.1)` → `out = LUT3D(c)`，alpha 1。
`mask_pinch_fragment` 只在 `ViewConfiguration.masked` 下使用，Music 的「正在播放」用 `.standard`。

LUT 来自资源 `BackdropLUT`（Assets.car，32 × 1024 RGBA8），按每 32 行一片切成 32 片上传为 32³ 的 rgba8Unorm 3D 纹理
（0x259680594、0x25967CF78），采样坐标 (x, y, z) = (R, G, B)。实测：灰阶恒等（误差 ≤ 0.003）；纯红 (1, 0, 0) →
(0.694, 0.055, 0.059)；纯蓝 → (0.035, 0.035, 0.710)；纯绿不变；全立方体平均亮度 0.500 → 0.489，平均饱和度 0.682 → 0.648。
它是一张温和的「压纯红纯蓝」查表，不是主要观感来源。

#### 6. 输出与节奏

- `BackdropHostView` 创建 `MTKView`：GPU family apple5 及以上 `preferredFramesPerSecond = min(30, 屏幕上限)`，否则 30 或 15；
  `colorPixelFormat` 取渲染器 `framebufferPixelFormat`，本机为 BGRA10_XR，layer 色彩空间 extended sRGB；
  `layer.allowsDisplayCompositing` 跟随宿主属性；`enableSetNeedsDisplay = false`。
- 每次 `draw(in:)` 让 `time += 1/60`（Reduce Motion 时 1/600），所以 30 FPS 下运动速度是名义值的一半：旋转周期实际
  240 / 140 / 180 秒，网格往返约 44 秒；切歌与模式切换用 2 倍步长补偿，仍是 0.8 秒。
- `Uniforms` 368 字节布局：0 `time`；16 `viewMatrix`；80 起三个模型各 80 字节（矩阵 64、`rotationReference` i16、
  `timeScale` float @68）；320 切歌混合；324 网格进度；328 `pinchMix`；332 常量 4.0（着色器未用）；336 / 338 int16 宽高；
  340 饱和度；344 白混 0.1；348 压暗；352 频谱 float4。

#### 7. 谁在切换强度档

`SpectrumAnalysis.intensity`：`subdued = 0.2`，`exciting = 1.0`。`CompositeRenderer.isBehindLyrics` 就是 `intensity == 1.0`
（getter 0x259678E80，setter 0x259678ED4）。`BackdropHostView` 初始化即设 1.0；Music 的 `FullWindowPlayer.selectedContent`
变化时调用 `NowPlayingViewController.setBackdropIntensity(exciting: 选中内容是否为歌词)`（Music.i64 `sub_100032078`）。
因此用户截图对应的档位是**横屏 + exciting**：饱和度 2.4、模糊 120 pt、形变全开、压暗 0.5。

### 三、为什么之前的量化差异现在能解释

2026-09-05 上午的《晴天》对照图（加校准之前的版本）统计：

| 区域统计 | 0008 现状 | Apple Music |
|---|---|---|
| 亮度 p10 / p50 / p90 | 0.070 / 0.134 / 0.304 | 0.134 / 0.175 / 0.336 |
| 饱和度 p50 / p90 | 0.59 / 1.00 | 0.32 / 0.46 |

- 暗部从不低于 0.1：来自 `mix(c, 白, 0.1)`，0008 现状则精确卡在 TSL 的下限 0.07。
- 饱和度只有一半：先压暗 50% 再饱和 2.4，远比 TSL 的 1.3 × 2 叠加温和，且全程 gamma 空间。
- 极平滑：模糊大一倍以上，封面只有 128 像素。

Codex 那段「presentation 校准」是拿这张图的一条竖条拟合出来的全局色调曲线，用在错误的管线上，才出现「不艳了但也没层次」。

### 四、移植方案

1. **管线**：新增 `MediaCoreUI` 形态的 renderer，复用 0008 的 `MTKView` 生命周期、暂停策略、generation gate 与 package 内
   `.metal` 资源。四个 pass：blender（128 × 128，切歌 crossfade）→ 三实例旋转到四分之一画布 → MPS 模糊 → 细分网格 +
   反预乘 + 白混 + LUT 到 drawable。全部在 gamma 空间，贴图 `SRGB: false`。
2. **参数**：按第二节表格取值，横竖屏由窗口宽高比决定，深浅色由 `effectiveAppearance` 决定，默认 exciting 档。
   频谱项固定为 0，不接音频分析。
3. **LUT**：Apple 资源不能照搬。默认用参数化近似只压纯红纯蓝（按实测的 0.69 / 0.71 增益拟合），并允许关闭；差别很小。
4. **节奏**：待定（见下）。倾向保持 60 FPS 渲染但把时间步长对齐到 Apple Music 的实际速度。
5. **可切换**：隐藏 defaults 键 `AppleMusicLyricsBackdropVariant`，`mediaCoreUI26`（默认）与 `legacyTSL`（现状去掉校准）。
6. **删除**：`presentationSaturation / Contrast / Brightness` 与对应 shader 段、`greenArtworkRetainsTheMutedMiniPlayerTone`
   那条按竖条拟合的测试、`ArtworkBackdropReferenceFixture` 的校准用途。
7. **测试**：离屏渲染真实封面采样，对照本节表格与用户截图的区间断言；网格细分与旋转矩阵的数值测试；LUT 近似的单调性测试。
8. **文档**：落地时更新 0008 的实现说明（纠正「目标是 TSLBackdropMetalView」的前提）、两份索引；本提案落地时分配编号。

### 五、待定

- 帧率：照 Apple Music 原样 30 FPS + 半速时间，还是 60 FPS + 对齐速度。
- LUT：近似还是跳过。
- 用户需要再截一张对照图（之前的《半岛铁盒》已丢失）作为第二组参照数值。

### 六、顺带核对并排除的 MiniPlayer 路径（Music.i64）

- MiniPlayer 背景由 `miniplayer_backdrop` defaults 决定：1 用 `TSLBackdropMetalView`（VibrantDark，`setBlur: 1000`），
  否则 `NSVisualEffectView(.popover, .behindWindow, .active)`；`sub_100093DE0` 在大封面态（状态 6–8）强制 Metal。
- MiniPlayer 的 Metal 参数：黑色遮罩 `0.7 − 0.4 × clamp((宽 − 400) / 400, 0, 1)`，动画速度 `10.5 − 9 × 同系数`；
  `setBlur: 1000` 会在首次尺寸变化时被 `buildTextures:` 的对角线公式覆盖。
- 这些与用户对照的窗口无关，记录在此仅为避免再走弯路。

### 产出物

- `/Volumes/DyldSharedCaches/macOS/26.6/MediaCoreUI.i64`、`AMPDesktopUI.i64`（idax，`--load-got`，正常关闭）。
- 着色器 IR 与 LUT 提取脚本在 `/tmp/claude/MediaCoreUIMetal/`（临时目录，可按本文命令重生成）。
- 层级捕获解析脚本在 `/tmp/claude/Backdrop/viewhierarchy/`（`Response_*` 为 gzip JSON，`Response_0` 是对象树，
  `Response_3` 是属性表）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-05 | Created as Draft | 用户提供层级捕获，确认对照窗口是「正在播放」全窗口播放器，背景实现在 `MediaCoreUI`，0008 复刻的 `TSLBackdropMetalView` 不是目标。 |
| 2026-09-05 | 先落盘调查结果 | 上下文即将耗尽；参数、地址与方案全部记入本文，方案细节（帧率、LUT）待用户决定后再接受。 |
| 2026-09-05 | Draft → Accepted | 用户批准（「接受提案，开工」）。两项待定按方案倾向执行：保持 60 FPS 渲染、把时间步长按 0.5 对齐到 Apple Music 的实际运动速度；LUT 用参数化近似（可关闭）。 |
| 2026-09-05 | Accepted → Implemented | 新增 `NowPlayingBackdropPipeline`（blend → 三实例旋转 → 四分之一画布 MPS 模糊 → 细分网格 + 反预乘 + 白混 + LUT 近似），`ArtworkBackdropRenderer` 改为驱动 `ArtworkBackdropFramePipeline` 协议，隐藏键 `AppleMusicLyricsBackdropVariant` 在 `mediaCoreUI26`（默认）与 `legacyTSL` 之间切换；两张网格表从 `MediaCoreUI.i64` 提取为完整数组（5 × 5 表与 Music 的 TSL 表逐字节相同）；presentation 校准、竖条拟合测试与对应 shader 段已删除。背景相关 39 项测试与跳过既存 `WidgetDataStoreTests` 的完整 package 160 项测试原始退出码 0；隔离 DerivedData 的 workspace Debug 构建原始退出码 0，`default.metallib` 含十个 function。离屏预览帧在与截图同位置的竖条上亮度 p10 / p50 / p90 为 0.151 / 0.194 / 0.280、饱和度 p50 / p90 为 0.29 / 0.34，落在 Apple Music 截图（0.134 / 0.175 / 0.336；0.32 / 0.46）的区间内。未启动应用做交互验证，真实观感待用户并排复检；第二张对照截图暂不需要。 |
| 2026-09-05 | 文档与术语裁决 | 配套实现说明整体重写为「一个驱动器、两条管线」；0008 提案随之收尾为 Implemented。没有引入项目自造术语，不改 glossary；不改公开 README。 |
| 2026-09-05 | 三组并排截图复核 | 用户提供《等你下课》《三拜红尘凉》《半岛铁盒》三组「我们 / Apple Music」截图。整窗亮度中位数分别为 0.179 / 0.176、0.220 / 0.217、0.295 / 0.278，前两组的饱和度与分布也在同一区间；只有高反差的《半岛铁盒》我们的亮斑更亮、暗角更暗（p10 / p90 为 0.167 / 0.386 对 0.203 / 0.325）、饱和度中位数高约一成。用重建的 `MediaCoreUI.i64` 复核了尺寸回调（`drawableSizeWillChange` 传像素尺寸与 `backingScaleFactor`）、画布（像素右移两位）、sigma（120 × scale / 4）、环境表和视图矩阵，均与实现一致；`CAMetalLayer` 已确认带 extended sRGB。单帧对照无法区分网格预设、旋转相位与 Music 音频频谱项（`Sk` 缩放、对比与饱和增量）的影响，未据此改常数。两个尚未验证的假设：Music 对已兼容色彩空间的封面不重绘（P3 封面按 sRGB 数值使用，会略欠饱和），以及播放中的频谱项。 |
| 2026-09-06 | 落地为 0010 | 与代码同一 commit 进入 `develop`。 |
| 2026-09-17 | 帧率 60 FPS → 30 FPS | 推翻 2026-09-05 那条「保持 60 FPS 渲染」的决定。用户报告面板开着时整个系统掉帧、活动监视器 12 小时能耗 202。对 1.9.0-beta.11（build 10900111，当时还是 ColorfulX 背景）采样：空闲时持续占 12% CPU（10 s 消耗 1.2 s），主线程 3049 个样本中 371 个在主队列绘制，其中 251 个阻塞在 `nextDrawable()` 的信号量上——提交速度已被刷新率限流，即满速渲染并与合成器抢 GPU。当前实现虽已换掉 ColorfulX，但 `drawFrame` 每帧仍无条件重跑整条 MPS 模糊链，面板可见时的单帧代价与 beta 同构。原决策取 60 FPS 是想「画面更细、速度靠 `animationTimeScale = 0.5` 对齐」，但动画时间读的是 wall-clock（`ArtworkGradientAnimationClock` 累加时间戳差值）而非每帧累加固定步长，帧率只改变采样密度、不改变运动速度；且本文第三节记录的 Music 自身就是 `preferredFramesPerSecond = min(30, 屏幕上限)`。故改为 `min(30, 屏幕上限)`，`animationTimeScale` 保持 0.5 不动——它与帧率无关，一并改成 1.0 反而会让运动快一倍。策略测试同步断言 30，并补一条原本缺失的情形：屏幕上限低于 30 时跟随屏幕（24 Hz → 24）。隔离 DerivedData 的 workspace Debug 构建与 `ArtworkGradientRenderingPolicyTests` 原始退出码均为 0。真实观感与能耗降幅待用户复检。 |
