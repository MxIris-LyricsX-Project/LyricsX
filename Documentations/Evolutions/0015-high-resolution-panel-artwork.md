# 0015 - 歌词面板封面改用联网取到的高清图

- **状态**: In Progress
- **创建日期**: 2026-09-10
- **最后更新**: 2026-09-10
- **所属愿景**: 无
- **配套文档**: [面板高清封面](../Internal/HighResolutionPanelArtwork.md)

## 摘要

Apple Music 风格歌词面板的封面目前只有一个来源：当前播放器交出来的那张图。走系统 Now Playing 时
是 MediaRemote 的 `kMRMediaRemoteNowPlayingInfoArtworkData`（各家 App 自己压过，常见 300–600 px），
走 ScriptingBridge 时是曲目内嵌封面。而面板的封面视图在全屏时会被拉到 `窗口宽 × 0.285`
（5K 屏约 700 pt ≈ 1400 px），所以放大就糊。

本提案让面板在每次换歌时额外联网找一张更高清的同款封面：并行查 iTunes Search API 和歌词候选自带的
`metadata.artworkURL`，用**已经存在的** `ArtworkSimilarityScorer`（dHash 结构指纹 + 色度校验）确认
它确实是同一张封面，再挑像素最大的那张换上去。校验不过就保持现状——宁可糊，也不能放错封面。

## 方案

### 作用范围只有面板的封面视图

面板的 Metal 背景**不在范围内，也不需要在**：它会把封面下采样到 128 px
（`NowPlayingBackdropConfiguration().artworkDimension`，`legacyTSL` 变体是 300 px）才送进渲染管线，
高清图对它零收益。Widget 的封面写入、TouchBar 封面、菜单栏取色一律保持现状。

### 两路来源，取最大

| 来源 | 取法 | 典型上限 |
|------|------|---------|
| iTunes Search API | `https://itunes.apple.com/search?term=<title artist>&entity=song&limit=5`，`country` 用 `defaults[.appleMusicStorefront]`（未设置则用系统区域）。取 `artworkUrl100`，把末段 `100x100bb.jpg` 改写成 `1200x1200bb.jpg` | 1200×1200 |
| 歌词候选自带的封面 URL | QQ 的 `T002R800x800M000…` 试着提到 `T002R1000x1000M000…`（失败退回原 URL）；网易 `picUrl` 追加 `?param=1024y1024`；Kugou / Musixmatch 原样用 | 800–1024 |

第二路不额外发搜索请求——这些 URL 是歌词搜索顺带返回的，本来就有。

### 什么时候允许替换

- **本地有封面**：必须 dHash 指纹匹配（沿用现有的 `dHashDistanceThreshold` / 强阈值 / 色度带三档判据）
  **且**像素明显更大（长边至少大 1.2 倍），才替换。
- **本地压根没有封面**（有些播放器就是不给）：退到元数据校验——归一化后的标题与艺人都匹配，且
  （若知道时长）时长差 ≤ 3 秒，才采用。

`ArtworkSimilarityScorer` 需要加一个**不下载、只比对**的入口 `matches(image:)`，把现有阈值逻辑
从 `matches(artworkURL:)` 里抽出来共用；现有那条路径的行为不变。

### 注入方式

面板是独立的 package target，与 app 之间只有 `AppleMusicLyrics.HostEnvironment` 一个缝，因此不新开
第二条通道：`HostEnvironment` 增加一个

```swift
public var artworkUpgrades: AnyPublisher<ArtworkUpgrade, Never>   // 默认 Empty
public struct ArtworkUpgrade { public let trackIdentifier: String; public let image: NSImage }
```

面板订阅它，只在 `trackIdentifier` 等于当前曲目时调用已有的 `applyArtwork`。默认值是 `Empty`，
所以 probe 测试套件（`LineEmphasisProbes` 等）一行都不用改。

app 侧新增 `LyricsX/Component/HighResolutionArtworkService.swift`（actor）：曲目变化和 `currentLyrics`
变化时触发，先查缓存，否则并行取两路、校验、择大发布。**只在面板窗口已创建时才发请求**——面板没开
就不该为它联网。

### 缓存

`~/Library/Caches/<bundle id>/HighResolutionArtwork/<sha256(归一化 title|artist|album)>.jpg`。
缓存键不用 `track.id`（它随播放器和来源变化，同一首歌换个播放器就不命中）。找不到高清图也写一条
负结果标记（7 天过期），免得每次重听同一首歌都重查一遍。启动时按 mtime 剪到 300 个文件上限。

### 开关

新增 `.highResolutionPanelArtworkEnabled`（`Global.swift`，默认 **开**），复选框加在 Lab 偏好页，
挨着现有的「封面相似度加权」。改 `Preferences.storyboard` 之前先确认 Xcode 没有打开该文档。

### 测试

纯策略部分（URL 改写规则、择优判定表、缓存键归一化、无本地封面时的元数据校验判据）放进
`LyricsXFoundation` 做成纯函数，在 `LyricsXFoundationTests` 里测；网络与磁盘 IO 留在 app 侧，不进测试。

### 未经询问就定下的假设

1. iTunes 侧只要到 1200×1200，不去拉原图（`100000x100000-999.jpg` 常有 3 MB 以上，对一个 1400 px
   的视图没有意义）。
2. 长边至少大 1.2 倍才替换——差一点点不值得换图带来的闪动。
3. 面板窗口没开时完全不联网。
4. 负结果缓存 7 天。

### 实现时补上的决定

写的时候发现「换歌那一刻」的信息是不全的：系统 Now Playing 的封面常常比标题晚一两秒到，歌词更晚，
而这两样恰恰决定了校验走指纹还是走元数据。于是：

- **一首歌看三次**：换歌时、歌词落定时、换歌后 3 秒（歌词一直不来的兜底）。三次都走同一个
  `resolve`，已经出过图的曲目直接返回。
- **下载结果按曲目留在内存里**，第二次不重新下载，只重新校验——第二次的判定可能和第一次不同，
  因为这时候本地封面到了，弱的元数据校验升级成了真正的指纹比对。iTunes 搜索每首歌只发一次。
- **只有歌词落定之后才允许记负结果**。换歌那一刻记，会把「歌词源」这条路整个封死七天。
- 顺手把 app 里的 `String.strippingBrackets` 移进了 `LyricsXFoundation`——元数据校验要用它，
  两处各留一份同样的正则不合适。调用点只有 `AppController` 一处。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-10 | Created as Draft | JH：面板封面分辨率低，全屏看着糊，希望每次播放联网取一次封面，哪个质量高用哪个 |
| 2026-09-10 | 两路来源都查，取像素最大的一张 | iTunes 清晰度高但华语冷门歌覆盖一般，歌词源覆盖好但上限低，互补 |
| 2026-09-10 | 必须指纹匹配才替换；本地无封面时退到元数据校验后仍可采用 | 翻唱、同名歌、搜索偏差都会让「只比尺寸」放错封面；而完全不给封面的播放器又是最需要这个功能的场景 |
| 2026-09-10 | 作用范围只限面板封面视图，背景不动 | 背景管线把封面下采样到 128 px，高清对它零收益 |
| 2026-09-10 | 加偏好开关（默认开）+ 磁盘缓存 | 这是每首歌都会发起对外请求的功能，得留得关；磁盘缓存让重听不再重复下载 |
| 2026-09-10 | Draft → Accepted | JH 批准，开始实现 |
| 2026-09-10 | 一首歌看三次（换歌 / 歌词落定 / 换歌后 3 秒） | 封面与歌词都比标题晚到，只看换歌那一刻会永远拿不到指纹校验 |
| 2026-09-10 | 下载过的候选按曲目留在内存，后续只重新校验 | 让「重看一次」几乎免费，否则三次触发就是三倍流量 |
| 2026-09-10 | 负结果只在歌词落定后才记 | 换歌那一刻记会把歌词源这条路封死七天 |
| 2026-09-10 | Accepted → In Progress | 代码写完并通过构建与 85 项 package 测试，等实机确认 |
