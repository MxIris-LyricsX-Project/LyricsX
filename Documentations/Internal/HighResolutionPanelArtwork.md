# 面板高清封面

Apple Music 风格歌词面板的封面，什么时候会被一张联网找来的高清图顶掉，以及为什么这条链路
长成现在这样。设计与取舍见提案
[歌词面板封面改用联网取到的高清图](../Evolutions/0015-high-resolution-panel-artwork.md)。

## 一句话

播放器给的封面（系统 Now Playing 常见 300–600 px）在全屏时会被拉到约 1400 px，所以
`HighResolutionArtworkService` 去 iTunes Search API 和歌词候选自带的封面 URL 各找一张，
确认是**同一张封面**且明显更大之后，换掉面板封面视图里的那一张。

## 三个参与者

| 谁 | 在哪 | 管什么 |
|---|---|---|
| `HighResolutionArtworkPolicy` | `LyricsXPackage/Sources/LyricsXFoundation/` | 纯判断：URL 怎么改写、多大才算值得换、缓存键怎么算、没有指纹时怎么用元数据兜底。没有网络和磁盘，所以能在 `LyricsXFoundationTests` 里全测。 |
| `HighResolutionArtworkService` | `LyricsX/Component/` | actor。发请求、读写磁盘缓存、跟 `ArtworkSimilarityScorer` 握手，最后从 `artworkPublisher` 发出结果。 |
| `AppleMusicLyrics.WindowController` | `LyricsX/AppleMusicLyrics/` | 触发与注入。订阅活在面板窗口的生命周期里——**面板没开，这套东西一次网络请求都不发**。 |

面板本身只认 `AppleMusicLyrics.HostEnvironment.artworkUpgrades` 这一个口子，默认值是
`Empty`，所以离屏 probe 测试套件完全不受影响。

## 为什么一首歌要看三次

换歌那一刻拿到的信息是残缺的：系统 Now Playing 的封面常常比标题晚一两秒，歌词更晚。而这两样
恰恰决定校验强度——有本地封面才能走 dHash 指纹比对，没有就只能退到标题/艺人/时长的元数据校验。

所以 `WindowController` 在三个时刻各调一次 `resolve`：

1. `currentTrackWillChange` —— 换歌。
2. `AppController.$currentLyrics` —— 歌词落定（含落定为 `nil`）。
3. 换歌后 3 秒的一次性兜底 —— 给「歌词一直不来但封面晚到了」的曲目留的。

`resolve` 自己是幂等的：这首歌已经出过图就直接返回。**下载过的候选按曲目留在内存**，第二次不重
新下载、只重新校验——第二次的判定可能和第一次不同，因为这时本地封面到了，弱的元数据校验升级成了
真正的指纹比对。iTunes 搜索每首歌只发一次，结果缓存在同一份 per-track 状态里。

## 校验：宁可糊，也不能放错

`ArtworkSimilarityScorer` 原本只用来给歌词候选加分，现在多了一个**不下载、只比对**的入口
`evaluate(image:)`，复用同一套阈值（结构 dHash + 模糊带里的色度校验）。它返回三态，而不是
`Bool`：

- `.match` —— 换。
- `.mismatch` —— 不换。这是真正的拒绝。
- `.noReference` —— 播放器压根没给封面，**没有东西可比**。这时才退到
  `HighResolutionArtworkPolicy.metadataMatches`：标题（允许去掉括号后相等）、艺人（允许一方多带
  featuring，但必须落在词边界上）、时长差 ≤ 3 秒。

还有一个容易漏的点：ScriptingBridge 会把 `artwork` 缓存成 `NSNull`，`AppController` 因此可能给
这首歌记了个空指纹，而 `MusicTrack.resolvedArtwork` 明明能从原始 AppleEvent 字节里读出图来。
`supplyNowPlayingIfMissing(image:trackIdentifier:)` 就是来补这一刀的——不补的话，Apple Music
用户（最大的一群）会全部掉到弱的元数据校验上。

Spotify 是另一种缺封面：它的脚本字典把 `artwork` 标成已废弃、永远不会有值，正确来源是
`artwork url`。在 MusicPlayer 接上这个 URL 之前（issue #195），Spotify 曲目从播放器那里一张图都拿不到，
永远走 `.noReference`；而同一份适配器又把 Spotify 以毫秒计的 `duration` 当秒透传，时长差 1000 倍，
3 秒的元数据容差把所有候选都拒了——面板上于是一张封面都没有。现在 MusicPlayer 的 Spotify 适配器换歌后
异步下载 `artwork url` 指向的图，下载完把同一首曲目再发布一次，面板的 `refreshArtwork()` 和这里的
指纹比对都能拿到播放器自己的封面，Spotify 用户不再依赖元数据校验。

## 两个具体的坑

**像素不是点。** `NSImage.size` 是点，跟着图片声明的 DPI 走：一张 1200×1200、标了 144 dpi 的
JPEG 报出来的 `size` 是 600×600。所有尺寸比较都走 `longestPixelEdge`（读
`representations` 的 `pixelsWide` / `pixelsHigh`），拿 `size` 比会把大图判成小图。

**背景不吃高清图。** 面板背景把封面下采样到 128 px（`NowPlayingBackdropConfiguration()`
的 `artworkDimension`，`legacyTSL` 变体是 300 px）才进渲染管线，所以换上高清图对它零收益、
只会白白触发一次交叉淡入。面板因此只在**背景还没拿到这首歌的封面时**才把高清图也喂给它。

## 缓存

`~/Library/Caches/<bundle id>/HighResolutionArtwork/`，文件名是
`sha256(归一化的 标题|艺人|专辑)`。**不用 `MusicTrack.id`** —— 它由当前播放器分配，同一首歌换个
播放器就认不出自己刚写的缓存。

- `.artwork` = 下载到的原始字节，直接存不重新编码。命中时顺手 touch 一下 mtime，剪枝时先扔没人听的。
- `.miss` = 空文件，表示这首歌哪儿都没找到高清封面，7 天内不再重查。**只有歌词落定之后才允许写**
  —— 换歌那一刻就写，会把「歌词源」这条路整个封死七天。
- 超过 300 个文件时按 mtime 从旧到新剪，每次运行只剪一次。

## 开关

`HighResolutionPanelArtworkEnabled`，默认开，在 Lab 偏好页。关掉之后 `resolve` 第一行就返回，
面板退回只用播放器给的那张图。
