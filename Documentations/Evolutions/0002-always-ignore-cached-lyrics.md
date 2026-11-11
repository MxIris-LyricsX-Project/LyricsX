# 0002 - 总是忽略歌词库缓存

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-11
- **所属愿景**: 无
- **关联提案**: [0001 切换到下一条歌词候选](0001-next-lyrics-candidate.md)（同样起因于「自动匹配的结果不对」，但走的是另一条路：0001 让用户手动换，本提案让自动匹配别再吃陈旧结果）
- **实现分支 / PR**: `develop`
- **配套文档**: [绕过歌词库缓存](../Internal/LyricsLibraryCacheBypass.md)

## 摘要

在偏好设置里新增一个开关「总是忽略已保存的歌词」。开启后，自动匹配**不再读取 LyricsX 自己保存的
歌词库**（`~/Music/LyricsX/` 或用户自定义目录），每次都联网搜索。用户手动选定的歌词、音频文件
内嵌的歌词、音轨旁边用户自己放的 `.lrc` 三者**不受影响**，仍然优先 —— 它们是用户的决定和用户的
文件，不是缓存。搜索一无所获时回退读缓存，避免断网即无歌词。

## 动机

**证据来自一次真实排查**：用户报告「有时候歌词不对，但手动搜索后双击第一条又是对的」。
排查结论是本地缓存里存着错的歌词文件，而**只要缓存命中，自动匹配一次网络请求都不发**
（`AppController.swift:424-429` 读到即 `return`）。

扫描该用户的 113 个缓存文件，查出两个内容与文件名对不上的：

| 文件 | 实际内容 |
|---|---|
| `阵雨天 - 是二智呀.lrcx` | 《倒影》的歌词（`[ti:倒影] [al:倒影] [by:Kugou]`） |
| `陷入情网（翻自 如幻儿） - 谣君.lrcx` | 《50 Feet》（`[ti:50 Feet] [by:Kugou]`） |

这类文件一旦生成就**永远不会自我修复**：文件名由曲目标题生成、内容是当时选中的歌词
（`Extension.swift:153`），两者不一致没有任何机制会发现；而缓存命中又意味着永不重新搜索。
用户唯一的出路是每次都手动去搜索面板重选。

除了「存错了」，缓存陈旧还有两个常见来源：

- 歌词源后来补上了逐字时间标签或翻译，本地那份还是旧的纯文本版；
- 早期版本的匹配逻辑较弱，当年存下的结果按今天的标准根本不会被选中。

## 前期调研

- **缓存命中即短路** —— `AppController.currentTrackChanged()` 依次尝试：内嵌歌词（`:372`）、
  音轨旁边的 `.lrcx`/`.lrc`（`:387`）、保存目录的 `.lrcx`/`.lrc`（`:399`）。
  读到 `.lrcx` 直接 `return`；`.lrc` 则 `break` 后继续搜索（`needsSearching` 标志）。
- **手动选定的歌词走另一条路** —— 0001 引入的 `LyricsSelectionOverrideTable` 在所有自动查找
  之前被查询（`AppController.swift:378-390`），本提案不能动它，否则用户按「下一条」选定的结果
  会在下次播放时被冲掉。
- **保存行为与读取无关** —— `persist()`（`Extension.swift:169`）的目标路径由
  `LyricsStoragePolicy.persistDestination` 解析，与本次读不读缓存无关。所以「忽略缓存」
  只影响读，写照旧。
- **偏好页归属** —— `LoadLyricsBesideTrack`、`WriteBackToLyricsBesideTrack`、歌词保存路径
  都在 General 页（`Preferences.storyboard` 的 `PreferenceGeneralViewController` 场景，
  第 68 行起）。新开关属于同一类，放同一页。
- **默认值机制** —— 布尔默认值写在 `LyricsX/Supporting Files/UserDefaults.plist`，
  由 `registerUserDefaults()`（`AppDelegate.swift:445`）注册。

## 提议方案

### 一、开关只管「库缓存」这一层

新增偏好 `IgnoreCachedLyricsLibrary`（Bool，默认**关闭**）。开启后，`currentTrackChanged`
跳过**保存目录**的 `.lrcx` / `.lrc` 查找，直接进入搜索。

明确**不受影响**的三层，按查找顺序：

1. 用户手动选定的覆盖条目（0001 的覆盖表）—— 是用户的明确决定；
2. 音频文件内嵌的歌词 —— 是用户的文件；
3. 音轨旁边的 `.lrc` / `.lrcx` —— 同样是用户的文件，且本来就默认只读（`3f1c1ab`）。

换句话说，这个开关的语义是「不要相信 LyricsX 自己存过的东西」，而不是「不要相信任何本地文件」。

### 二、搜索一无所获时回退读缓存

搜索流结束后若 `currentLyrics` 仍为 `nil`，再按原顺序读一次库缓存。没有这一步，断网或歌词源
全部失败时用户会从「有一份可能过时的歌词」直接掉到「什么都没有」，这是明显的倒退。

回退前必须校验曲目未变 —— 搜索可能跨越了切歌。

### 三、写回照旧

搜到的结果仍然 `persist()` 到库里。开关管的是读，不是写：保留写入才能让离线时的回退有东西可读，
而且下一次播放又会被新搜索的结果覆盖，陈旧问题不会累积。

### 非目标

- **不自动清理或修复已经存错的缓存文件** —— 删除用户数据必须由用户自己发起。
  真要做，那是另一份提案（比如「校验缓存库、列出可疑条目供用户勾选删除」）。
- **不改变保存路径与保存时机**。
- **不改变匹配与排序规则** —— 那是 [0003](0003-source-ordering-modes.md) 的事。
- **不做按曲目/按专辑的例外开关** —— 全局一个开关就够；需要针对单曲纠正时，
  0001 的「下一条歌词」已经能解决。
- **不缓存搜索结果到内存做二次利用** —— 本提案不引入任何新的缓存层。

## 详细设计

```swift
// Global.swift
static let ignoreCachedLyricsLibrary = Key<Bool>("IgnoreCachedLyricsLibrary")
```

`currentTrackChanged` 中的查找顺序变为：

```swift
// 1. 用户手动选定 —— 不受开关影响
if let overrideURL = userSelectedLyricsURL(forTrackId: track.id), … { return }

var candidateLyricsURL: [(URL, Bool, Bool)] = []

// 2/3. 内嵌与 beside-track —— 不受开关影响
if defaults[.loadLyricsBesideTrack] { … }

// 4. 库缓存 —— 开关在此生效
if !defaults[.ignoreCachedLyricsLibrary] {
    candidateLyricsURL += librarySearchURLs(title: title, artist: artist)
}
```

回退：

```swift
/// Runs after the search stream drains. Only reads the library that the
/// preference told us to skip, and only when the search produced nothing —
/// so "always fetch fresh" never degrades into "no lyrics at all" offline.
private func loadLibraryCacheAsFallback(for track: MusicTrack, title: String, artist: String) {
    guard defaults[.ignoreCachedLyricsLibrary],
          currentLyrics == nil,
          selectedPlayer.currentTrack?.id == track.id else {
        return
    }
    for (url, isSecurityScoped, _) in librarySearchURLs(title: title, artist: artist) {
        if let lyrics = loadLyrics(at: url, securityScopedURL: isSecurityScoped ? url : nil, title: title, artist: artist) {
            currentLyrics = lyrics
            adoptAsSoleLyricsCandidate(lyrics)
            return
        }
    }
}
```

`librarySearchURLs(title:artist:)` 是从现有代码原样抽出的一个函数（`AppController.swift:395-402`
那段），读取路径与开关关闭时**完全一致**，避免两条路径漂移。

## 替代方案考量

- **给缓存加有效期（比如 30 天后重搜）** —— 更「聪明」，但引入一个用户看不见也说不清的时间维度：
  同一首歌今天读缓存、下周联网，行为不可预测。一个明确的开关比一个隐式的过期策略容易理解。
- **启动时校验整个歌词库、自动删除可疑条目** —— 判据（文件名与 `[ti:]`/`[ar:]` 是否相符）
  在多艺人分隔符、括号后缀、翻唱标注上误报率很高：本次排查的 12 个「疑似」里只有 2 个是真的。
  以这种准确率去自动删用户文件不可接受。
- **改成「读缓存但同时后台重搜，发现更好的就替换」** —— 省掉开关，但每首歌都会在播放几秒后
  跳一次歌词，比现在更让人困惑；而且它与 0001 的「钉住」语义直接冲突。
- **把开关做成三态（总是读 / 从不读 / 仅离线时读）** —— 「仅离线时读」正是本提案的回退行为，
  已经是默认的一部分，单独列成一态只会让选项变多而语义重叠。

## 影响

### 用户可见变化

- General 页新增复选框「总是忽略已保存的歌词」（暂定文案），位置在歌词保存路径一组内。
- 开启后每首歌都会联网搜索，歌词出现时间取决于网络（通常几百毫秒到数秒），
  而缓存命中原本是瞬时的。这是开启该选项的必然代价，会在选项的说明文字里写明。
- 已有操作习惯不受影响；关闭状态下行为与现在**完全一致**。

### 可发现性

- 默认**关闭**。理由：它会把「瞬时出歌词」变成「每次等网络」，且绝大多数用户的缓存是正确的。
  这是给遇到问题的用户的一把工具，不是所有人都该付的代价。
- 复选框需要一行说明文字（tooltip 或副标题），点明「不影响你自己放在音乐文件旁边的歌词，
  也不影响你手动选定过的歌词」—— 否则用户会以为它连自己的文件一起忽略。

### 数据与配置兼容

- 只新增一个布尔键，默认 `false`，旧配置无需迁移。
- 不改变任何已存文件的格式与位置；关闭开关即完全回到现有行为。

### 平台与最低版本

不变（macOS 12+）。无平台差异。

### 发布

不需要新权限、entitlement 或隐私清单条目。不影响公证与 Sparkle 更新。
需在发布说明里提示：这是给「歌词总是错且改不掉」的用户的开关。

## 落地步骤

1. 抽出 `librarySearchURLs(title:artist:)`，`currentTrackChanged` 改用它 —— 纯重构，行为不变。
2. 加偏好键与默认值，在 `currentTrackChanged` 中按开关跳过库缓存。
3. 加搜索落空后的回退，含曲目未变校验。
4. General 页加复选框与说明文字，补 `Preferences.xcstrings` / `Localizable.xcstrings` 中英文案。
5. 测试：`librarySearchURLs` 的路径拼装（含标题/艺人里的 `/` 替换）可以进
   `LyricsXFoundationTests`；开关与回退的分支逻辑在 `AppController` 内，没有测试宿主，
   如实记录为手工验证项。

**收尾时必须判断两件事**（结果写进决策日志）：配套文章、新术语。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-11 | Created as Draft | 起因：排查「歌词不对但手动搜索是对的」，确认根因是库缓存命中即短路，且缓存里确实存在内容与文件名不符的文件。 |
| 2026-08-11 | 确定忽略范围 | 用户选择**只忽略 LyricsX 自己保存的库**。手动选定的歌词、内嵌歌词、音轨旁边的文件均不受影响 —— 前者是用户的决定，后两者是用户的文件。 |
| 2026-08-11 | Draft → Accepted | 用户批准，实现开始。 |
| 2026-08-11 | 读文件名改为两种拼法都试 | 落地步骤第 1 步原写「纯重构，行为不变」，实际**没有**保持不变。读路径只把 `/` 换成 `:`，写路径（`LyricsStoragePolicy.libraryFileBaseName`）还会 trim 首尾空白，两边在带空白的元数据上拼出不同文件名。此前只是白丢一次缓存命中；而本提案的回退路径**职责就是读回刚写的文件**，错配会让它直接失效。改用早已存在且有测试、但从未被 app 调用过的 `libraryFileBaseNameCandidates`。详见配套文章的「与提案的差异」。 |
| 2026-08-11 | 回退也写进 catch 分支 | 提案只说「搜索流结束后若 `currentLyrics` 仍为 nil」。实测离线时的常态是所有 provider 一起抛错、直接跳进 catch，只在正常出口调用等于在最需要回退的场景下没有回退。`CancellationError` 一支不调用 —— 那是切歌导致的取消。 |
| 2026-08-11 | Accepted → Implemented | 配套文章：写了[绕过歌词库缓存](../Internal/LyricsLibraryCacheBypass.md)（三处「代码看不出来的决策」：缓存的分层边界、回退为何也在 catch 里、文件名拼法的偏差）。新术语：「歌词库缓存」登记进项目术语表 —— 它与「本地歌词文件」的区别正是本提案的分界线。未按落地步骤第 5 步硬抽 policy 做测试：那三个布尔与的判断抽出来只会把代码翻译一遍，如实记为手工验证项。 |
