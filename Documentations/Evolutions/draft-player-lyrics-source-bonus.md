# Draft - 歌词来源和正在播放的 App 是同一家时加分

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-26
- **最后更新**: 2026-11-26
- **所属愿景**: 无
- **关联提案**: [0003 歌词源排序模式](0003-source-ordering-modes.md)（加分进的是同一套排序比较）；
  [0031 歌词源可以单独关掉](0031-lyrics-source-switches.md)（同一个设置页）；
  [0029 按播放器与输出设备设置歌词偏移](0029-playback-route-lyrics-offset.md)（「当前播放器的 bundle ID」那段逻辑从它那里抽出来共用）；
  [Draft 拆分 LyricsXFoundation](draft-split-lyricsx-foundation.md)（若它先落地，本提案的新文件改放进 `LyricsPolicies`）
- **实现分支 / PR**: `feature/player-lyrics-source-bonus`（LyricsX），功能树 `.worktrees/MxIris-LyricsX-Project-PlayerLyricsSourceBonus`（父仓库）
- **配套文档**: 待定 —— 预计在实现说明 [歌词候选的排序](../Internal/LyricsSourceOrdering.md) 补一节
- **网页版**: 同目录同名的 `.html`

## 摘要

歌曲在 QQ 音乐、网易云音乐、酷狗音乐或「音乐」App 里播放时，来自同一家歌词源（QQMusic、NetEase、Kugou、Apple Music）的
搜索结果在匹配分数上加 0.10。加分进入 `effectiveQuality`，所以自动挑选屏幕上的歌词和搜索面板的排序同时生效，搜索面板的
「评分」列照封面加分的写法把加分摊开（`1.09 (+0.10)`）。判断「这条歌词是不是播放器自家的」在歌词到达时做一次，结果记进
歌词的 metadata；从 bundle ID 认出歌词源的规则是 `LyricsXFoundation` 里的纯函数，带单元测试。「设置 → 歌词源」页加一个
默认勾选的开关，「按歌词源顺序优先」模式下这个开关不起作用，显示为不可用。

## 动机

- **用户在播放器里听的那一版，播放器自家的歌词最对得上。** 截图里的例子：在 QQ 音乐里播放薛之谦的《一半》，搜索面板
  排第一的是 Kugou 的 1.05，QQMusic 的同一首歌只有 0.99。两条都是对的歌，差的 0.06 来自 LyricsKit 给翻译和逐字时间
  各加的 0.05（`LyricsKit/Sources/LyricsService/Utilities/Lyrics+Quality.swift:11-12`），而不是匹配程度。QQ 音乐自家的
  歌词是按它曲库里这一版录音做的时间轴，别家的同名歌词可能来自另一个版本，时间轴对不上。
- **现有的排序手段做不到「跟着播放器走」**：0003 的三种排序模式和拖动排序是一张固定的全局列表。用户在 QQ 音乐和网易云
  之间切换播放器时，只能每次去设置里拖一次顺序。
- **评分算法里没有任何关于播放器的信息**：`Lyrics.quality` 只看歌手、歌名、时长和两项特性；App 侧唯一的附加项是封面
  相似度加分（`LyricsX/Utility/Global.swift:380-391`）。

## 前期调研

- **分数怎么算、在哪里比较**
  - LyricsKit 的 `Lyrics.quality`（`Lyrics+Quality.swift:43`）= 歌手 0.45 + 歌名 0.40 + 时长 0.15 的加权，夹到 [0, 1]，
    再加翻译 +0.05、行内时间标签 +0.05，伴奏版 −0.3；首次读取时缓存进 `metadata`。
  - App 侧的 `effectiveQuality(_:)`（`LyricsX/Utility/Global.swift:380`）= `quality`（NaN 归零）+ `effectiveArtworkBonus(_:)`。
    `lyricsHasHigherPriority(_:over:)`（`Global.swift:348`）用它比较，候选池（`AppController.swift:61`）和搜索面板
    （`SearchLyricsViewController.swift:462`、`:501`）都走这一个比较函数。
  - 搜索面板「评分」列（`SearchLyricsViewController.swift:533`）显示 `effectiveQuality`，封面加分不为 0 时后缀 `(+0.15)`。
    实现说明《歌词候选的排序》的「分数在搜索面板是看得见的」一节要求显示与排序读同一份实现。
- **封面加分是现成的先例**：加分值存在歌词的 `metadata.data`（键 `LyricsX.ArtworkMatchBonus`，`Global.swift:306-313`），
  开关 `artworkSimilarityBoostEnabled` 在 `effectiveArtworkBonus` 里判断（`Global.swift:388`）。它是异步算出来的，所以要在
  `lyricsDisplay` 队列上写、写完 `resort()`（`AppController.swift:1636-1675`）。本提案的判断是同步的，在歌词到达、进候选池
  之前就能写完，不需要那套重排。
- **歌词到达的入口**
  - 自动搜索：`AppController.lyricsReceived(lyrics:)`（`AppController.swift:1211`），MainActor 上调用（`:584`、`:1379`）。
    它先按请求 id 和 `selectedPlayer.currentTrack` 过滤，再 `filtrate`、`recognizeLanguage`、`cacheQualityBeforeDisplay()`
    （`:1232`），然后才进候选池、才可能上屏。「下一条候选」的补搜（`:1379-1384`）也走它。
  - 搜索面板：`SearchLyricsViewController.lyricsReceived(lyrics:)`（`SearchLyricsViewController.swift:455`），`@MainActor`。
- **歌词源的名字**：provider 把自己的 `static let service` 写进 `metadata.service`（`LyricsProvider.swift:41`）：
  `"QQMusic"`、`"NetEase"`、`"Kugou"`、`"Apple Music"`、`"LRCLIB"`、`"Musixmatch"`，与 `LyricsProviders.ServiceID.displayName`
  （`LyricsKit/Sources/LyricsService/Provider/Service.swift:20`）逐字相同。设置页已经用 `displayName` 反查 `ServiceID`
  （`PreferenceSourceViewController.swift:98`）。
- **当前播放器的 bundle ID 已经有人在取**：`PlaybackRouteLyricsOffsetController.playerBundleIdentifier(of:)`
  （`LyricsX/Component/PlaybackRouteLyricsOffsetController.swift:131-145`）穿过 `MusicPlayers.Agent` 取到
  `Scriptable.playerBundleID` 或 `SystemMedia.playerBundleID`（MusicPlayer `Players/SystemMedia.swift:275`，系统级正在播放时
  是正在播放的 App 的 bundle ID，宿主 App 优先）。它在主队列上读。
- **几个 App 的 bundle ID**（本机核对）
  - `/Applications/QQMusic.app` → `com.tencent.QQMusicMac`；`/Applications/NeteaseMusic.app` → `com.netease.163music`。
  - 系统级正在播放的允许列表（`SystemWideNowPlayingAppList`）里还有 `com.tencent.QQMusic.D5Q73692VW`，是在 Mac 上运行的
    iPad 版 QQ 音乐。
  - 「音乐」App 是 `com.apple.Music`。
  - **推测，未核对**：酷狗音乐本机没装。它的 iOS 版是 `com.kugou.kugou1002`，Mac 版应同样以 `com.kugou.` 开头；网易云 iOS 版
    `com.netease.cloudmusic`。
- **哪些歌词永远不会加分**：歌词库的 `.lrcx` 不记录来源（实现说明《歌词候选的排序》「关掉的歌词源」一节），音频文件内嵌和
  旁边的 `.lrc` 也没有 `metadata.service`，它们都不加分。
- **翻译出来的副本会带上标记**：AI 翻译的结果是 `Lyrics(lines:idTags:metadata: source.metadata)`
  （`LyricsXFoundation/AILyricsTranslation.swift:409`），metadata 整份复制，标记跟着走。
- **三种排序模式下加分的作用**（`LyricsSourceOrderingPolicy.swift:54-92`）
  - 「只按匹配分数」：分数严格大于才算更优，加分直接生效。
  - 「按匹配分数，同分再看歌词源顺序」：分数先按 0.02 分桶，0.10 是五个桶，加分直接生效。
  - 「按歌词源顺序优先」：先比来源在列表里的位置，位置相同才比分数。同一个来源的结果要么全都加分、要么全都不加，
    所以加分改变不了任何顺序。
- **0.10 这个值**：截图里 QQMusic 0.99 + 0.10 = 1.09，超过 Kugou 的 1.05；能抵消对方多出的一项特性加分再加一点时长差。
  对方两项特性都有、自家一项都没有时正好打平，按「先到的留着」处理。歌名或歌手对不上的结果（截图里同一歌手的另一首歌 0.59、0.62）落后正确结果
  0.3 以上，加分翻不了盘。封面加分是 0.15，两项可以叠加。

## 提议方案

1. **认出播放器自家的歌词源**：`LyricsXFoundation` 加 `LyricsProviders.ServiceID.init?(playerBundleIdentifier:)`，
   按 bundle ID 的点分段、不区分大小写匹配：
   - `com.tencent.qqmusic*`（第三段以 `qqmusic` 开头）→ `.qq`
   - `com.netease.163music`、`com.netease.cloudmusic` → `.netease`
   - `com.kugou.*` → `.kugou`
   - `com.apple.music`（正好三段）→ `.appleMusic`
   - 其余（Spotify、腾讯和网易的别的 App、「播客」「TV」等）→ `nil`
2. **在歌词到达时打标记**：两处 `lyricsReceived` 在歌词进候选池或面板列表之前，用 `PlayerLyricsSourcePolicy` 判断
   `metadata.service` 是不是当前播放器自家的歌词源，结果写进 `metadata.data`（键 `LyricsX.IsFromPlayerLyricsSource`）。
   当前播放器取自 `selectedPlayer.currentPlayerBundleIdentifier`，那是从 `PlaybackRouteLyricsOffsetController` 里抽出来的
   共用逻辑。
3. **加分进 `effectiveQuality`**：新增 `effectivePlayerLyricsSourceBonus(_:)`，开关开着且标记为真时返回
   `PlayerLyricsSourcePolicy.matchBonus`（0.10），否则 0。`effectiveQuality` = `quality`（NaN 归零）+ 封面加分 + 这一项。
4. **面板评分列**：后缀改为两项加分之和，任一项不为 0 时显示（`1.09 (+0.10)`、两项都有时 `1.24 (+0.25)`）。
5. **开关**：新偏好键 `PlayerLyricsSourceBoostEnabled`，`UserDefaults.plist` 注册默认 `true`。「设置 → 歌词源」页在歌词源表
   下方加一个复选框和一行说明，绑定这个键；`updateUI()` 在「按歌词源顺序优先」模式下把复选框设为不可用。

### 非目标

- **Spotify 不对应 Musixmatch**：Spotify 的歌词由 Musixmatch 提供，但不是 LyricsX 搜到的那一份，时间轴也未必一致。
- **不给本地歌词加分**：歌词库、内嵌歌词、旁边的 `.lrc` 都不知道来源。
- **切换开关不重排已有的候选**：与封面加分开关、排序模式一致，下一次搜索或面板下一次重排时生效，屏幕上的歌词不动。
- **加分值不做成设置项**：0.10 是写死的常量，只有开和关。
- **不改 LyricsKit**：LyricsKit 不知道播放器，加分留在 App 侧，与封面加分同层。
- **不改「按歌词源顺序优先」模式的语义**：那个模式下来源列表说了算，本提案不去自动调整列表。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `LyricsXPackage/Sources/LyricsXFoundation/PlayerLyricsSourcePolicy.swift` · `LyricsProviders.ServiceID.init?(playerBundleIdentifier:)`、`PlayerLyricsSourcePolicy` | 新增 | bundle ID → 歌词源的对应规则；`matchBonus = 0.1`；`lyricsService(_:belongsToPlayerWithBundleIdentifier:)` | 判断的唯一出处，脱离 App 便于测试 | 1 |
| `LyricsXPackage/Tests/LyricsXFoundationTests/PlayerLyricsSourcePolicyTests.swift` | 新增 | 各播放器的对应、同公司别的 App、大小写、未知与空值、歌词源名字、截图场景在两种按分数模式下的排序 | 锁定规则与 0.10 的取值理由 | 1 |
| `LyricsX/Component/SelectedPlayer.swift` · `MusicPlayers.Agent.currentPlayerBundleIdentifier` | 新增 | 从 `PlaybackRouteLyricsOffsetController` 搬来的「穿过 Agent 取 bundle ID」 | 两处共用一份 | 2 |
| `LyricsX/Component/PlaybackRouteLyricsOffsetController.swift` · `playerBundleIdentifier(of:)` | 删除 | 两处调用改读 `selectedPlayer.currentPlayerBundleIdentifier`，私有静态函数删掉 | 逻辑已搬走，行为不变 | 2 |
| `LyricsX/Utility/Global.swift` · `UserDefaults.DefaultsKeys` | 修改 | 加 `playerLyricsSourceBoostEnabled = Key<Bool>("PlayerLyricsSourceBoostEnabled")`，放在 `artworkSimilarityBoostEnabled` 旁 | 新偏好键 | 2 |
| `LyricsX/Supporting Files/UserDefaults.plist` | 修改 | `PlayerLyricsSourceBoostEnabled` = `true` | 默认开 | 2 |
| `LyricsX/Utility/Global.swift` · `Lyrics.isFromPlayerLyricsSource`、`markPlayerLyricsSource(playerBundleIdentifier:)`、`effectivePlayerLyricsSourceBonus(_:)`、`effectiveQuality(_:)` | 新增 / 修改 | metadata 标记、到达时打标记的方法、加分读取；`effectiveQuality` 加上这一项 | 加分进入排序 | 2 |
| `LyricsX/Component/AppController.swift` · `lyricsReceived(lyrics:)` | 修改 | `cacheQualityBeforeDisplay()` 之前调 `markPlayerLyricsSource` | 自动挑选生效 | 2 |
| `LyricsX/Search/SearchLyricsViewController.swift` · `lyricsReceived(lyrics:)`、`qualityDisplayText(for:)` | 修改 | 插入列表前打标记；评分后缀显示两项加分之和 | 面板排序与显示 | 2 |
| `LyricsX/Supporting Files/Base.lproj/Preferences.storyboard` · Source 场景 `KTZ-mJ-lpY` | 修改 | 表格下方加复选框和说明标签，约束改为表格 → 复选框 → 说明 → 底边 | 开关的界面 | 3 |
| `LyricsX/Preferences/PreferenceSourceViewController.swift` | 修改 | 新 outlet；`viewDidLoad` 里 `bind(.value, withDefaultName: .playerLyricsSourceBoostEnabled)`；`updateUI()` 在 `.sourceFirst` 时 `isEnabled = false` | 开关接线 | 3 |
| `LyricsX/Supporting Files/mul.lproj/Preferences.xcstrings` | 修改 | 两条新文案（复选框标题、说明），补简体 / 繁体中文 | 新界面文案 | 3 |
| `Documentations/Internal/LyricsSourceOrdering.md` | 修改 | 新增一节「播放器自家的歌词源」；「分数在搜索面板是看得见的」改为两项加分；「已知空白」里 NaN 那条改成两项 | 下次维护会踩的决策 | 4 |
| `Documentations/Internal/PreferenceWindowSizing.md` | 修改 | Source 页的实测尺寸 | 页面变高了 | 4 |
| `CLAUDE.md`（LyricsX） | 修改 | `LyricsXFoundationTests` 覆盖范围加一句「哪个歌词源是播放器自家的」 | 测试清单与代码同步 | 4 |
| `Documentations/Evolutions/draft-player-lyrics-source-bonus.md`（及 `.html`）、两份索引 | 修改 | 落地时取号、状态改 Implemented | 提案收尾 | 4 |

## 架构图

改了什么：

```text
LyricsXFoundation/
+ PlayerLyricsSourcePolicy.swift
+   extension LyricsProviders.ServiceID
+     init?(playerBundleIdentifier:)        com.tencent.qqmusic* -> .qq, ...
+   enum PlayerLyricsSourcePolicy
+     matchBonus = 0.1
+     lyricsService(_:belongsToPlayerWithBundleIdentifier:) -> Bool
  LyricsSourceOrderingPolicy                 (unchanged)

LyricsX app
  SelectedPlayer.swift
+   MusicPlayers.Agent.currentPlayerBundleIdentifier
  PlaybackRouteLyricsOffsetController
-   static playerBundleIdentifier(of:)       (moved to Agent extension)
  Global.swift
+   DefaultsKeys.playerLyricsSourceBoostEnabled
+   Lyrics.isFromPlayerLyricsSource          metadata "LyricsX.IsFromPlayerLyricsSource"
+   Lyrics.markPlayerLyricsSource(playerBundleIdentifier:)
+   effectivePlayerLyricsSourceBonus(_:)
~   effectiveQuality = quality + artwork bonus + player source bonus
  AppController.lyricsReceived
+   lyrics.markPlayerLyricsSource(...)       before cacheQualityBeforeDisplay / pool
  SearchLyricsViewController
+   lyricsReceived: lyrics.markPlayerLyricsSource(...)
~   qualityDisplayText: suffix = artwork bonus + player source bonus
  PreferenceSourceViewController / Preferences.storyboard
+   checkbox "Prefer lyrics from the playing app's own service" + note
~   updateUI: checkbox disabled in .sourceFirst
```

数据流：

```text
search result arrives (main actor)
  -> AppController.lyricsReceived / SearchLyricsViewController.lyricsReceived
       -> lyrics.markPlayerLyricsSource(
              playerBundleIdentifier: selectedPlayer.currentPlayerBundleIdentifier)
            -> PlayerLyricsSourcePolicy.lyricsService(lyrics.metadata.service,
                   belongsToPlayerWithBundleIdentifier:)
                 -> ServiceID(playerBundleIdentifier:)?.displayName == service
            -> metadata.data["LyricsX.IsFromPlayerLyricsSource"] = true / false
       -> candidate pool insert / panel insert
            -> lyricsHasHigherPriority
                 -> effectiveQuality
                      = quality
                      + effectiveArtworkBonus          (Lab switch)
                      + effectivePlayerLyricsSourceBonus (Source pane switch)
                 -> LyricsSourceOrderingPolicy.hasHigherPriority
```

## 详细设计

### `PlayerLyricsSourcePolicy.swift`

```swift
import Foundation

extension LyricsProviders.ServiceID {
    /// The lyrics source run by the company behind the music app with
    /// `bundleIdentifier` — QQ Music's for QQ Music — or `nil` when LyricsX
    /// searches no source of that app's.
    ///
    /// Matched on the identifier's dot-separated components, ignoring case,
    /// so the Mac and the iPad builds of one player map alike and another app
    /// from the same company does not.
    public init?(playerBundleIdentifier bundleIdentifier: String) {
        let components = bundleIdentifier.lowercased().split(separator: ".")
        guard components.count >= 3, components[0] == "com" else { return nil }
        switch (components[1], components[2]) {
        case ("tencent", let product) where product.hasPrefix("qqmusic"):
            self = .qq
        case ("netease", "163music"), ("netease", "cloudmusic"):
            self = .netease
        case ("kugou", _):
            self = .kugou
        case ("apple", "music") where components.count == 3:
            self = .appleMusic
        default:
            return nil
        }
    }
}

/// Lyrics from the source run by the app the track plays in — QQ Music's
/// lyrics while QQ Music plays — score higher, because they are timed against
/// the recording that app is playing.
public enum PlayerLyricsSourcePolicy {
    /// Added to the match score of lyrics from the playing app's own source.
    ///
    /// Enough to outweigh one of LyricsKit's 0.05 feature bonuses (translation,
    /// inline time tags) plus a small duration difference, so the playing app's
    /// copy of the right song comes first; far short of the 0.3 or more a wrong
    /// artist costs, so it never lifts another song above the right one.
    public static let matchBonus = 0.1

    /// Whether lyrics that `service` found — a provider's name as
    /// `Lyrics.Metadata.service` records it — come from the lyrics source of
    /// the app with `playerBundleIdentifier`.
    public static func lyricsService(
        _ service: String?,
        belongsToPlayerWithBundleIdentifier playerBundleIdentifier: String?
    ) -> Bool {
        guard let service, let playerBundleIdentifier,
              let playerSource = LyricsProviders.ServiceID(playerBundleIdentifier: playerBundleIdentifier) else {
            return false
        }
        return playerSource.displayName == service
    }
}
```

- 选「点分段」而不是子串：子串 `kugou` / `qqmusic` 会把名字里碰巧带这几个字母的别家 App 也算进来；按段匹配只认这几家公司
  自己的反向域名。
- `com.apple.music` 要求正好三段，`com.apple.Music.something`（扩展、插件）不算。

### App 侧（`Global.swift`）

```swift
static let playerLyricsSourceBoostEnabled = Key<Bool>("PlayerLyricsSourceBoostEnabled")

private let isFromPlayerLyricsSourceKey = Lyrics.Metadata.Key("LyricsX.IsFromPlayerLyricsSource")

extension Lyrics {
    /// Whether these lyrics came from the lyrics source of the app their
    /// track was playing in when they arrived. Set once, on arrival, by
    /// `markPlayerLyricsSource(playerBundleIdentifier:)`.
    var isFromPlayerLyricsSource: Bool {
        (metadata.data[isFromPlayerLyricsSourceKey] as? Bool) ?? false
    }

    /// Records whether these lyrics come from the playing app's own source.
    /// Call where search results come in, before they go into the candidate
    /// pool or on screen: the mark is read wherever lyrics are ranked.
    func markPlayerLyricsSource(playerBundleIdentifier: String?) {
        metadata.data[isFromPlayerLyricsSourceKey] = PlayerLyricsSourcePolicy.lyricsService(
            metadata.service,
            belongsToPlayerWithBundleIdentifier: playerBundleIdentifier
        )
    }
}

func effectiveQuality(_ lyrics: Lyrics) -> Double {
    let quality = lyrics.quality.isFinite ? lyrics.quality : 0
    return quality + effectiveArtworkBonus(lyrics) + effectivePlayerLyricsSourceBonus(lyrics)
}

func effectivePlayerLyricsSourceBonus(_ lyrics: Lyrics) -> Double {
    guard defaults[.playerLyricsSourceBoostEnabled], lyrics.isFromPlayerLyricsSource else { return 0 }
    return PlayerLyricsSourcePolicy.matchBonus
}
```

- **存的是「是不是」，不是加分值。** 封面加分存的是 0.15 这个值；这里存事实、值由策略给出，以后调整 0.10 不必考虑已经打过
  标记的歌词。
- **为什么在到达时打标记、不在比较时现算**：比较函数在候选池的有序插入里反复调用，播放器若在一首歌中途换了（系统级正在播放
  跟着最近发声的 App 走），现算会让同一个池子前后用两套比较规则，插入位置就不可信了。到达时打一次，同一条歌词的分数从此不变。
  到达时的过滤（请求 id、`currentTrack`）保证读到的是这首歌所在的播放器。
- **写 metadata 不用切到 `lyricsDisplay` 队列**：两处都在歌词进候选池或面板列表之前写，这时还没有任何读者。这与
  `cacheQualityBeforeDisplay()` 是同一个时机和理由（CLAUDE.md「Data Flow」一节）。
- **搜索面板手动搜别的歌时**也按当前播放器打标记：面板绝大多数时候搜的就是正在播放的歌；搜别的歌时，同一来源的结果统一加分，
  不会把错歌顶上来。

### `MusicPlayers.Agent.currentPlayerBundleIdentifier`（`SelectedPlayer.swift`）

```swift
extension MusicPlayers.Agent {
    /// The bundle identifier of the app the designated player plays its
    /// track in, looking through the agents that only pass another player's
    /// events on; `nil` when no player can be told.
    var currentPlayerBundleIdentifier: String? {
        playerBundleIdentifier(of: designatedPlayer)
    }
}

private func playerBundleIdentifier(of player: MusicPlayerProtocol?) -> String? {
    switch player {
    case let agent as MusicPlayers.Agent:
        return playerBundleIdentifier(of: agent.designatedPlayer)
    case let scriptable as MusicPlayers.Scriptable:
        return scriptable.playerBundleID
    case let systemMedia as MusicPlayers.SystemMedia:
        return systemMedia.playerBundleID
    default:
        return nil
    }
}
```

`PlaybackRouteLyricsOffsetController` 原来是 `Self.playerBundleIdentifier(of: selectedPlayer)`，`selectedPlayer` 本身就是一个
Agent，改成 `selectedPlayer.currentPlayerBundleIdentifier`，结果相同。

### 搜索面板评分列

```swift
private func qualityDisplayText(for lyrics: Lyrics) -> String {
    let total = String(format: "%.2f", effectiveQuality(lyrics))
    let bonus = effectiveArtworkBonus(lyrics) + effectivePlayerLyricsSourceBonus(lyrics)
    guard bonus != 0 else { return total }
    return total + String(format: " (%+.2f)", bonus)
}
```

合起来显示：两项来源不同，但对用户来说「这一行为什么高」只需要一个数；要分清是哪一项，看「来源」列就知道它是不是播放器自家的。

### 设置页

- 复选框标题：`Prefer lyrics from the playing app's own service`（简体「优先使用正在播放的 App 自家的歌词」，繁体「優先使用
  正在播放的 App 自家的歌詞」）。
- 说明（与表格上方那行提示同样的小号字）：`While QQ Music, NetEase Cloud Music, Kugou or Music plays, lyrics from its own
  service score 0.1 higher.`（简体「在 QQ 音乐、网易云音乐、酷狗音乐或「音乐」里播放时，来自同一家的歌词加 0.1 分。」，繁体
  「在 QQ 音樂、網易雲音樂、酷狗音樂或「音樂」裡播放時，來自同一家的歌詞加 0.1 分。」）
- 位置：歌词源表下方。约束改为 表格底边 + 16 → 复选框，复选框底边 + 4 → 说明（前缘对齐复选框标题），说明底边 + 24 → 视图
  底边；原来的 `Q5D-XX-2sF`（表格底边 = 视图底边 − 24）改接到说明上。frame 用 `ibtool --update-frames` 算到临时文件，只搬回
  这一页的 rect。
- `updateUI()`：`playerLyricsSourceBoostButton.isEnabled = mode != .sourceFirst`。
- 改 storyboard 之前确认 Xcode 没打开 `Preferences.storyboard`，否则保存会被覆盖。

## 替代方案考量

- **比较时现算（不打标记）**：播放器中途变化会让候选池前后用两套比较规则，有序插入失效；而且每次比较都要查一遍播放器。否。
- **把加分放进 LyricsKit 的 `quality`**：LyricsKit 不知道播放器，要给 `LyricsSearchRequest` 加字段、发新版本、改 `exact:`
  版本号；`quality` 还会被缓存进 metadata，开关切换后清不掉。否。
- **按播放器自动调整歌词源优先级列表**：会改写用户自己排的顺序，而且只在「按歌词源顺序」两种模式下有用，默认模式下无效。否。
- **加分取 0.15（与封面加分一致）**：会压过对方两项特性加分还多出 0.05，自家一项都没有的歌词也能稳赢翻译加逐字的版本；
  0.10 让这种情况打平，留给先到的那条。否。
- **用子串匹配 bundle ID**：见详细设计，会误伤别家 App。否。
- **放进实验室页（与封面加分同一页）**：这是关于歌词源的偏好，放在歌词源页、紧挨着排序模式，用户调来源时一眼能看到；
  实验室页留给实验性功能。否。
- **不做开关**：有的用户更看重翻译或逐字歌词，可能宁可要别家的翻译版。用户选了加开关。否。
- **只在搜索面板加分、自动挑选不变**：面板显示的分数就和实际排序不一致了，违反「显示与排序读同一份实现」。用户选了两处都加。否。

## 影响

### 用户可见变化

- 在 QQ 音乐、网易云音乐、酷狗音乐或「音乐」里播放时，自动挑选更常选到这个 App 自家的歌词；搜索面板里它们排得更靠前，
  评分列带 `(+0.10)`。
- 「设置 → 歌词源」页底部多一个默认勾选的复选框和一行说明；选「按歌词源顺序优先」时它变灰。
- 用 Spotify、Vox、Audirvana、Swinsian 等播放时行为不变。

### 可发现性

- 默认开启：这是一个明确更准的信号，绝大多数用户不需要知道它存在就能受益。
- 开关在歌词源页，和排序模式、歌词源表在一起；评分列的 `(+0.10)` 让用户在面板里能看出某一行为什么高。

### 数据与配置兼容

- 新键 `PlayerLyricsSourceBoostEnabled`，`UserDefaults.plist` 注册默认值 `true`，不需要迁移。
- 新的 metadata 键只存在于内存里的歌词对象上，不写进歌词库文件。
- 降级到旧版本：旧版本不认识这个键，不加分；再升级回来，开关设置仍在。

### 平台与最低版本

无变化。部署目标仍是 macOS 12。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。下一版的发布说明加一条「在 QQ 音乐、网易云音乐、酷狗音乐
或「音乐」里播放时优先使用它自家的歌词」。

## 落地步骤

1. **策略与测试** —— 改动地图第 1、2 行
   - 行为：`qqMusicForMacAndForIPadMapToQQMusic`（`com.tencent.QQMusicMac`、`com.tencent.QQMusic`、`com.tencent.QQMusic.D5Q73692VW`）
   - 行为：`neteaseCloudMusicMapsToNetEase`（`com.netease.163music`、`com.netease.cloudmusic`）
   - 行为：`kugouAppsMapToKugou`
   - 行为：`musicMapsToAppleMusic`
   - 行为：`bundleIdentifiersMatchIgnoringCase`
   - 行为：`otherAppsFromTheSameCompaniesMapToNoSource`（`com.tencent.xinWeChat`、`com.netease.mail`、`com.apple.TV`、`com.apple.podcasts`、`com.apple.Music.extension`）
   - 行为：`unknownPlayersMapToNoSource`（`com.spotify.client`、空字符串、单段）
   - 行为：`lyricsFromThePlayersOwnServiceBelongToIt`（`"QQMusic"` + QQ 音乐、`"Apple Music"` + 「音乐」等，用 provider 实际写入的名字）
   - 行为：`lyricsFromAnotherServiceDoNotBelongToThePlayer`
   - 行为：`lyricsWithoutAServiceOrWithoutAPlayerBelongToNoPlayer`
   - 行为：`playerSourceOutranksAnotherSourceAheadByOneFeatureBonus`（截图场景，在「只按匹配分数」和「同分再看源」两种模式下）
   - 行为：`playerSourceDoesNotLiftAnotherSongAboveTheRightOne`（截图里同一歌手的另一首歌 0.59 + 0.10，仍在 Kugou 那份《一半》的 0.98 之后）
2. **加分进排序** —— 第 3 至 9 行
   - 行为：`PlaybackRouteLyricsOffsetController` 的偏移在换播放器时照旧切换（行为不变，构建 + 现有 `PlaybackRouteLyricsOffsetsTests`）
   - 行为：在 QQ 音乐里播放时，自动挑选选中 QQMusic 的歌词（App 没有测试 target，用 Debug 构建实际播放核对）
   - 行为：搜索面板里 QQMusic 的结果排到前面，评分列带 `(+0.10)`；封面加分同时生效时显示两项之和
   - 行为：开关关掉后，下一次搜索不再加分
3. **设置页开关** —— 第 10、11、12 行
   - 行为：复选框默认勾选，重开设置窗口后保持
   - 行为：「按歌词源顺序优先」模式下复选框不可用，切回另两种模式恢复
   - 行为：简体、繁体中文下文案正确，页面高度按内容算（不继承上一页的尺寸）
4. **文档与收尾** —— 第 13 至 16 行
   - 行为：`swift test --filter LyricsXFoundationTests` 全绿；App 的 Debug 构建通过

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计在 `Internal/LyricsSourceOrdering.md` 补一节即可，不单独成文。
- **有没有引入新术语** —— 「播放器自家的歌词源」是否进术语表，落地时判断。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-26 | Created as Draft | 用户在搜索面板里看到 QQ 音乐播放的歌排第一的是 Kugou 的歌词，要求歌词来源与正在播放的 App 一致时加分 |
| 2026-11-26 | 加分同时用于自动挑选与搜索面板 | 用户选择；面板显示的分数必须就是排序比较的分数 |
| 2026-11-26 | 加开关，默认开启，放在歌词源页 | 用户选择加开关；位置由 agent 定，理由见替代方案 |
| 2026-11-26 | Accepted | 用户批准，开始实现 |
| 2026-11-26 | In Progress | 功能树建好，开始第 1 步 |
