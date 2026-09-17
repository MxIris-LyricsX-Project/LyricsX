# Apple Music 歌词面板 Metal 渐变背景

> 对应提案：[0008 自绘 Metal 歌词渐变背景](../Evolutions/0008-apple-music-metal-gradient.md)（`MTKView` 架构、生命周期暂停、
> MiniPlayer 管线）与 [0010 歌词面板背景改按 MediaCoreUI 管线重做](../Evolutions/0010-apple-music-now-playing-backdrop.md)
> （对照目标更正、`MediaCoreUI` 管线的逆向结果与移植决策）。
>
> 面向维护者。这里记录两条背景管线各自的边界、共用的调度层，以及为什么看起来更简单的做法行不通。

## 一句话

`GradientBackgroundView` 创建时按隐藏 defaults 键 `AppleMusicLyricsBackdropVariant` 选一条管线：默认 `mediaCoreUI26`
复刻 Music 26「正在播放」全窗口播放器的 `MediaCoreUI.Backdrop.CompositeRenderer`；`legacyTSL` 保留 0008 复刻的 MiniPlayer
`TSLBackdropMetalView`（已去掉截图校准）供并排比较。两条管线共用 `ArtworkBackdropRenderer` 的 `MTKView` 显示节奏、
切歌过渡队列、可暂停的动画时钟、窗口生命周期暂停与性能诊断。

切换方法（Debug 构建的 bundle id 前缀是 `dev.JH`）：

```bash
defaults write dev.JH.LyricsX AppleMusicLyricsBackdropVariant legacyTSL   # 或 mediaCoreUI26
```

键只在背景视图创建时读一次，重新打开歌词面板窗口才生效。

## 对照目标：为什么以前怎么调都不像

2026-09-05 之前的两轮「颜色对齐」都把 Apple Music 的背景当成 `TSLBackdropMetalView`，最后一轮甚至按截图拟合出一段
降饱和、降反差、抬亮的「presentation 校准」。用户提供的 Xcode 视图层级捕获证明，对照窗口是 Music 主窗口的「正在播放」
全窗口播放器，背景视图是 `MediaCoreUI.BackdropHostView`，渲染器在 `MediaCoreUI` 框架里；`TSLBackdropMetalView` 只服务于
MiniPlayer 的大封面态和旧沉浸模式。两套管线的色彩空间（gamma 与 linear）、封面尺寸（128 与 300 pixel）、模糊尺度
（120 pt 与对角线 × 0.045）、压暗方式（先压暗再饱和，与先饱和再遮罩）都不同，所以在错误管线上拟合任何常数都只能得到
「不艳了但也没层次」。校准段落已整体删除，证据与地址见新草稿第二节。

## 架构：一个驱动器，两条管线

```text
GradientBackgroundView            ArtworkGradientMetalView (MTKView)        ArtworkBackdropRenderer
──────────────────────            ───────────────────────────────────       ───────────────────────
变体解析、封面预处理、贴图上传 ──→ drawable size、外观、backing scale ──→ 命令队列、过渡队列、动画时钟、诊断
                                                                                  │ ArtworkBackdropFrameContext
                                                                                  ▼
                                                              any ArtworkBackdropFramePipeline
                                                        ┌───────────────────────┴────────────────────────┐
                                              NowPlayingBackdropPipeline                     ArtworkBackdropPipeline
                                              (mediaCoreUI26，默认)                          (legacyTSL)
```

- `ArtworkBackdropFramePipeline` 把一帧拆成「取 drawable 之前的离屏工作」和「落到 drawable 的最终 pass」，驱动器先编码前者、
  再取 `currentRenderPassDescriptor`，保持 0008 量出来的「离屏编码后再取 drawable」顺序。`prepareResources(for:)` 返回
  `.ready / .rebuilt / .failed`，驱动器只在 `.rebuilt` 时记日志。
- 帧上下文里除了两张封面贴图、线性过渡进度和已扣除暂停的 wall-clock 动画时间，还带 `backingScaleFactor` 与
  `isDarkAppearance`：`MediaCoreUI` 的模糊半径以 pt 计、压暗系数随 `effectiveAppearance` 变，两者都由 `MTKView` 在
  `viewDidChangeBackingProperties` / `viewDidChangeEffectiveAppearance` 时推给驱动器。
- 变体决定三件与管线配套的事：封面最长边（128 / 300）、`MTKTextureLoader` 选项（`SRGB: false` 无 mipmap / `SRGB: true`
  带 mipmap）、无封面回退延迟。`ArtworkBackdropVariant` 把这些和 `makePipeline(device:)` 放在一起，`GradientBackgroundView`
  不再持有具体配置。
- drawable 像素格式、`CAMetalLayer` 色彩空间和 clear color 都由管线声明：`mediaCoreUI26` 用 extended sRGB（与 Music 的
  `BGRA10_XR + kCGColorSpaceExtendedSRGB` 等价，值域 0–1 时与 sRGB 相同），`legacyTSL` 沿用 `nil`。

## `mediaCoreUI26`：`MediaCoreUI.Backdrop.CompositeRenderer`

### 数据流

```text
封面 NSImage → CGImage → 最长边 ≤ 128（sRGB context）→ MTKTextureLoader(SRGB: false)  …… 全程 gamma 空间
    ↓ generation gate
blend pass   128 × 128 rgba16Float      mix(上一张, 当前, bezier(0, 0, 0.3, 1)(进度))，0.8 s wall-clock
rotation pass  drawable >> 2 rgba16Float  clear 透明；三个实例：压暗 → 对比 → 饱和
MPSImageGaussianBlur                     sigma = 模糊半径 pt × backingScale / 4，edge mode zero
pinch pass   drawable                    细分网格形变 → rgb / alpha → mix(白, 0.1) → clamp → LUT 近似
```

### 封面与混合

`ArtworkBackdropImageProcessor` 仍按原 aspect ratio 缩到最长边 128 pixel；blend pass 用 [0, 1] 纹理坐标把它拉进 128 × 128
的方形纹理，非方形封面会被拉伸，这与 Music 直接把纹理映射到 quad 一致，封面几乎总是方形。贴图用 `SRGB: false`：
后续所有运算都在 gamma 编码值上进行，这是 Music 的做法，也是它「亮部不刺眼、暗部不发黑」的一半原因。

切歌过渡沿用驱动器的过渡队列（0008 的单项 pending 机制），只是时长改成 0.8 s，并在管线里套 `CubicBezierTimingFunction`
(0, 0, 0.3, 1)。求解用牛顿迭代加二分兜底，`NowPlayingBackdropConfigurationTests` 用手算的 `value(at: 0.5) ≈ 0.806` 钉住。

### 旋转 pass

顶点变换按 `rotation_vertex` 的 IR 逐项还原：

```text
θ = time × 2π / timeScale
view' = view × R(θ_reference)            仅 rotationReference ≥ 0 的实例
position = Sk × view' × model × R(θ) × vertex
R(a) 的第一列是 (cos a, −sin a)，即 y 向上的裁剪空间里顺时针转
```

- `view` 横屏 `scale(1, w/h)`、竖屏 `scale(h/w, 1)`，让每份封面在像素上保持正方形；横竖屏按 drawable 宽高比判定。
- 三个实例：`scale(1.4)`、timeScale 120；`T(−0.25, 0.15)·S(0.7)`、70；`T(0.7, 0.7)·S(0.7)`、90 且 reference 0，
  即第三份封面还随第一份的角速度绕画面中心公转。矩阵、周期与引用在 `NowPlayingBackdropConfiguration.musicRotationInstances`。
- `Sk = 1 + 0.33 × mix(spectrum.x, spectrum.y, 0.1)²`；面板不接音频分析，频谱固定为 0，`Sk = 1`。
- 片元顺序固定：`mix(c, 黑, darken + 0.0075 × 实例序号)`（深色外观 0.5，浅色 0.35）→ `(c − 0.5)(1 + spectrum.x × 0.076) + 0.5`
  → SVG saturate 矩阵，`s = 饱和度 + spectrum.z × 0.166`。横屏歌词态饱和度 2.4，竖屏 2.0。输出可以越出 0–1，
  半精度画布原样保留，直到最终 pass 前才 clamp；这也是中间纹理必须是 `rgba16Float` 的原因。

`NowPlayingBackdropRenderingTests.rotationPassDarkensAndSaturatesEachCopyInGammaSpace` 用 (0.8, 0.4, 0.2) 的纯色封面，
在只被第一份封面覆盖的像素和被第三份覆盖的像素上各核对一组手算值（含负的蓝通道）。

### 模糊

画布是 drawable 的四分之一（宽高各右移两位），`MPSImageGaussianBlur` 的 sigma 是「模糊半径 pt × backingScale / 4」：横屏
歌词态 120 pt，2x 屏上等于画布 60 像素、全分辨率 240 像素，约为 `legacyTSL` 的两倍。Music 还有 subdued 档（横屏 200 pt、
竖屏 160 pt）和每帧 ±1 pt 逼近目标的渐变；面板固定在歌词态，直接取目标值。

### 网格与最终 pass

- 横屏 8 × 8 格（9 × 9 控制点），竖屏 5 × 5 格；五套预设随机选一套，`ArtworkBackdropMeshPresets` 现在完整保存两张表，
  来自 `MediaCoreUI.i64` 的静态数据（`0x29CF37568`、`0x29CF3A9B8`）。5 × 5 表与 Music 自己 `TSLBackdropMetalView` 的表
  逐字节相同，因此 `legacyTSL` 继续用同一份数据，0008 时期从 Music.i64 记录的稀疏差分表已被完整表取代。
- `ArtworkBackdropMeshTopology.makeVertices(sourceControlPoints:destinationControlPoints:)` 接受任意 `n² ` 控制点；Music 对
  两张 `CAMeshTransform` 各调 `subdividedMesh: 2`，这里用 0008 已验证的规则网格 Catmull-Clark 实现细分两级：横屏每边
  33 个顶点、1,089 个顶点、6,144 个 index。
- 顶点：`warped = mix(源, 目标, (sin(time / 3.5) + 1) / 2)`，`plain = (格点 − 0.5) × (2 + 0.5 × (1 − pinchMix))`，
  `position = mix(plain, warped, pinchMix)`。歌词态 `pinchMix = 1`（形变全开）；Music 在切到 subdued 档时用
  (0.42, 0, 0.58, 1) 把它降到 0 并放大 1.25 倍，面板不切档，值保持常量但仍走 uniform。
- 纹理坐标是格点坐标，位置是 `2 × 控制点 − 1`：这会把模糊画布上下翻转，而旋转 pass 的 quad 是正向贴图，两次相抵；
  两个坐标约定都从 Music 的顶点构造函数（`sub_2595F2DAC`、常量 `0x259776610`）确认，不要「顺手」改成一致的。
- 片元：`rgb / max(alpha, 1e-4)` 抵消透明画布边缘被模糊拉进来的暗角；`mix(c, 白, 0.1)` 是暗部永远不低于 0.1 的来源；
  然后 clamp 到 0–1（Music 的 LUT 采样器会这样截断）；最后做 LUT 近似。

### LUT 近似

Music 最后采样资源 `BackdropLUT`（32³ 色立方，不能随包分发）。实测它对灰阶、绿、黄、青、品红恒等，只压纯红
(1, 0, 0) → (0.694, 0.055, 0.059) 与纯蓝 (0, 0, 1) → (0.035, 0.035, 0.710)，且效果随输入线性缩放。着色器里的
`nowPlayingGradeColor` 用七个参数复现：主通道按 `strength × chroma × hueWeight` 减少（红 0.306、蓝 0.29），
其中 `chroma = 主通道 − 最小通道`，`hueWeight` 在色相离纯红/纯蓝 0.26 以内为 1、到 0.77 线性降到 0；减少量的一部分
溢到另外两个通道（红 0.18、蓝 0.12）；次通道在色相中段按 `0.3 × chroma × 4h(1 − h)` 额外压暗。对整个 32³ 立方体的
最大误差 0.040、平均 0.0036（恒等映射的最大误差是 0.306）。`ColorGrading.mix = 0` 可整体关掉。测试用八个直接取自
LUT 的样本值做断言，不是回放实现公式。

### 节奏与时间

Music 以 30 FPS 绘制，但每帧只给 `time` 加 1/60，所以旋转周期实际是 240 / 140 / 180 s，网格往返约 44 s。面板同样
取 30 FPS（`ArtworkGradientRenderingPolicy.backdropFramesPerSecond`，屏幕上限更低时跟随屏幕），把 wall-clock 动画
时间乘以 `animationTimeScale = 0.5` 得到 `time`，运动速度与 Music 一致。

动画时间读的是 wall-clock（`ArtworkGradientAnimationClock` 累加时间戳差值），不是每帧累加固定步长，所以帧率只影响
采样密度、不影响运动速度——`animationTimeScale` 不随帧率改变。曾经跟随屏幕取到 60 FPS，但每帧都要重跑整条模糊链，
实测下来主线程会长时间卡在 `nextDrawable()` 上与合成器抢 GPU；见 0010 的决策日志。切歌过渡与 Reduce Motion 不受这个
比例影响：前者按 wall-clock 0.8 s，后者沿用 0008 的「停止连续绘制、只在状态改变时画单帧」而不是 Music 的 1/600 慢放。

### 与 Music 实现的已知差异

| 项目 | Music | 面板 | 原因 |
|---|---|---|---|
| LUT | 资源 `BackdropLUT` | 参数化近似 | 不能分发 Apple 资源 |
| 频谱驱动的形变、对比、饱和 | 来自音频分析 | 固定 0 | 面板没有音频分析 |
| 强度档 | exciting / subdued 随内容切换 | 固定 exciting | 面板只有歌词态 |
| 模糊目标 | 每帧 ±1 pt 逼近 | 直接取值 | 不切档就没有过渡 |
| 帧率与时间 | 30 FPS，`time += 1/60` | ≤ 30 FPS，`time = 0.5 × wall-clock` | 帧率对齐 Music，时间用 wall-clock 所以速度不随帧率变 |
| Reduce Motion | `time += 1/600` | 停止连续绘制 | 沿用 0008 |
| 无封面 | `systemGray` 占位 | 同色 2 × 2 贴图 | — |

### 参数来源

`MediaCoreUI.i64`（从 26.6 dyld cache 用 idax 建库，image base `0x25953e000`）：初始化 `0x259679E64`、`draw(in:)`
`0x25967C5CC`、每帧推进 `0x25967B980`、环境表 `0x25967A234`、模型矩阵 `0x25967A4F8` / `0x259680AAC`、模糊 `0x25967FA34`、
贴图加载 `0x25967FCB0`、网格预设 `0x2596541E8`、网格顶点构造 `0x2595F2DAC`、LUT `0x259680594`。着色器 IR 来自本机
`/System/Library/PrivateFrameworks/MediaCoreUI.framework/Versions/A/Resources/default.metallib`。2026-09-05 晚间数据库重建（原库因 worker 未正常关闭而损坏）后，又复核了尺寸回调、画布、sigma、环境表与封面重绘
（`0x2596796EC`：色彩空间与 alpha 布局已兼容时不重绘，否则重绘到最多 128 像素），结论不变。本机是 26.6.2，与数据库的
26.6 不是同一 build；静态表要从 cache 文件按数据库地址读（`/tmp/claude/Backdrop/mesh/extract-mesh-tables.py` 的做法），
从运行中的进程读会读到错误的内存。

## `legacyTSL`：MiniPlayer 的 `TSLBackdropMetalView`（保留供比较）

0008 落地的实现，行为回到 2026-09-05 上午的状态：封面最长边 300 pixel、`SRGB: true` 加 mipmap、全分辨率合成三份封面
（平移 `(0, 0)`、`(−0.5, 0.7)`、`(−0.95, −0.7)`，周期 60 / 45 / 35 s，`view × rotation × translation × rotation`）、
sigma 为对角线 × 0.045394707 的模糊、6 × 6 控制点三级细分的网格、最终 pass 先饱和 2 再限高 0.995、减遮罩 0.25 与
偏移 0.02、通道夹到 0.07–0.97，`MTKView.colorspace = nil`。它只在用户想并排看「旧的样子」时有用；MiniPlayer 的
其它路径（`NSVisualEffectView` 分支、随宽度变化的遮罩）不在复刻范围内，见新草稿第六节。

## 生命周期、节奏与诊断（两条管线共用）

- 连续绘制完全交给 `MTKView`：`preferredFramesPerSecond` 取 Music 的 30，屏幕上限更低时跟随屏幕；`autoResizeDrawable`
  关闭，拖动与 live resize 时冻结 drawable size；不创建自定义 timer，不直接调用 `nextDrawable()`。
- `ArtworkGradientRenderingPolicy` 要求 view controller 已显示、view 附着在可见且未被遮挡的窗口、view 未隐藏、窗口不在
  自定义拖动、view 不在 live resize、Reduce Motion 未开启，才连续渲染；暂停时 `ArtworkGradientAnimationClock` 同时停止。
- `#log` / `#signpost` 宏挂在面板诊断开关的 `backdrop` 组（`AppleMusicLyrics.PanelDiagnostics.isBackdropEnabled`）
  上，默认关闭，subsystem 是 `com.JH.LyricsX.AppleMusicLyricsPanel.Backdrop`，与歌词动画的 `.Lyrics` 分开；
  `defaults write dev.JH.LyricsX AppleMusicLyricsDiagnosticsEnabled -string backdrop` 或环境变量
  `LYRICSX_PANEL_DIAGNOSTICS=backdrop`（`1` / `all` 为全开）打开后，驱动器记录变体、渲染状态、资源重建、周期汇总、
  慢帧与 command buffer 错误，逐帧 signpost 只在 `LYRICSX_DETAILED_FRAME_SIGNPOSTS=1` 时生成。

## 失败降级

没有 Metal device、MPS 不支持、命令队列 / pipeline / buffer / 占位贴图创建失败，或资源 bundle 缺少预期 Metal function
时，只显示 `LayerBackedView` 的静态 fallback color。两条管线各自声明自己的 function 名：`mediaCoreUI26` 需要
`nowPlayingQuadVertex`、`nowPlayingBlendFragment`、`nowPlayingRotationVertex`、`nowPlayingRotationFragment`、
`nowPlayingPinchVertex`、`nowPlayingPinchFragment`；`legacyTSL` 需要 `artworkBackdropCompositionVertex/Fragment` 与
`artworkBackdropMeshVertex`、`artworkBackdropFinalFragment`。缺封面时保留上一张 1.2 s，再过渡到占位贴图。

## 验证边界

命令行 Swift Package Manager 不生成 `default.metallib`，测试从 `.metal` 源文件现编译注入；应用仍加载 package 编译的资源。
包内 `AppleMusicLyricsPanel` 依赖本地 LyricsKit 的 `SynchronizedTextTiming`，独立构建与测试必须带
`LYRICSX_USE_LOCAL_DEPENDENCY=1`。

自动化测试覆盖（`swift test --filter "NowPlayingBackdrop|ArtworkBackdrop|ArtworkGradient|ArtworkRendering"`，39 项）：
`Uniforms` 与 Metal 结构逐字段偏移、配置默认值与横竖屏环境表、三实例矩阵、bezier 过渡、半速时间、8 × 8 与 5 × 5 预设的
字面值与拓扑、变体解析与贴图选项；离屏真实渲染核对旋转 pass 的两组手算颜色、最终 pass 的反预乘 / 白混 / 近似 LUT、
八个 LUT 样本、横竖屏资源重建、`MTKView` 采用管线的色彩空间；以及用 `ArtworkBackdropReferenceFixture`（《晴天》对照图
中 叶惠美 封面的 16 × 16 区域平均）在 1176 × 811 上完整渲染两帧的色调区间。`legacyTSL` 的既有测试恢复到校准前的断言。

`LYRICSX_BACKDROP_PHASE_SWEEP_COVER=/path/to/cover.png` 会让 `phaseSweepReportsTheToneRangeOfACover` 用五套网格预设、
0–240 秒的相位把该封面完整渲染一遍，并在旁边写出 `.sweep.tsv`；用《半岛铁盒》截图抠出的封面跑过一次，Apple Music
单帧的亮度 / 饱和度落在本管线相位范围之内（亮度 p10 0.152–0.268、p50 0.269–0.331、p90 0.317–0.393），说明单帧差异来自
相位与预设而非公式。

### 2026-09-05 落地验证

- 背景相关 39 项测试原始退出码 0；跳过既存的 `WidgetDataStoreTests` 后完整 package 160 项、20 个 suite 通过，原始退出码 0。
- umbrella workspace 的 LyricsX Debug scheme 用 `/tmp/claude/DerivedData/LyricsX` 构建，原始退出码 0；四条 warning 均来自
  未改动的 AppDelegate、SearchLyricsViewController 与 Observation 的过时 API。产物 resource bundle 的 `default.metallib`
  含全部十个 function。
- 十六个改动的 Swift 文件通过仓库 `.swiftformat` 的 lint，`git diff --check` 通过。
- 离屏预览帧（`LYRICSX_BACKDROP_PREVIEW_DIRECTORY`，1176 × 811、1x、横屏歌词态、深色外观）在与截图同一位置的空白竖条上：

| 竖条统计 | 0008 校准前 | 本次 `mediaCoreUI26` | Apple Music 截图 |
|---|---|---|---|
| 亮度 p10 / p50 / p90 | 0.070 / 0.134 / 0.304 | 0.151 / 0.194 / 0.280 | 0.134 / 0.175 / 0.336 |
| 饱和度 p50 / p90 | 0.59 / 1.00 | 0.29 / 0.34 | 0.32 / 0.46 |

  输入是 16 × 16 的区域平均而不是原封面，动画相位也不同，所以只能说明落在同一区间，不是逐像素一致。
- 未启动应用、未做交互截图；真实播放时与 Apple Music 并排的观感、帧率与切歌过渡仍需用户复检。
