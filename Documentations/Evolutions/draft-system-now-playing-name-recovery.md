# Draft - 系统级「正在播放」检测到 Music 在播放时，也启用 MusicKit 原名恢复

- **状态**: In Progress
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **实现分支**: LyricsX `feature/system-now-playing-name-recovery`，MusicPlayer `feature/system-media-player-name`

## 摘要

实验室页的「通过 MusicKit 恢复原始的歌曲和艺人名称」（下称原名恢复）目前只在播放源选成 Apple Music 时生效。播放源为
「自动」并打开「Use system wide now playing application」（系统级正在播放，即 `MusicPlayers.SystemMedia`）时，就算正在
播放的就是 Music，开关也不起作用：`SystemMedia.name` 恒为 `nil`，而 `AppController` 只在
`selectedPlayer.name == .appleMusic` 时才挂载 `AppleMusicNameRecoveryPlugin`。这次让系统级正在播放认出 Music，并把
「这次搜索要不要做原名恢复」改成按每次搜索判断。

## 方案

**MusicPlayer（发 1.11.0）**

- `SystemMedia.name` 改报当前曲目来源 App 对应的播放器：来源 App 的 bundle ID（有父 App 时取父 App）属于
  `MusicPlayerName` 已知的播放器就返回对应值（`com.apple.Music` → `.appleMusic`），否则仍为 `nil`。
  - macOS 15.4 及以上走 mediaremote-adapter，每条曲目信息里已带 `bundleIdentifier` / `parentApplicationBundleIdentifier`。
  - 15.4 以下走旧 MediaRemote 接口：`updatePlayerState()` 本来就先取了 now-playing client，把它的 bundle ID 并进曲目信息。
  - 名字与 `currentTrack` 一起更新、且先写名字，订阅曲目变化的一方读到的总是这首歌的来源。
  - bundle ID 到播放器的对应复用 `LXMusicPlayerName` 已有的候选表，不另抄一份。
- 新增 Swift 测试 target `MusicPlayerTests`：bundle ID 对应、父 App 优先、缺字段时为 `nil`。
- 从 develop 打 `v1.11.0`；`LyricsXPackage/Package.swift` 的 `exact:` 改为 `"1.11.0"`，按发版流程刷新并核对 `Package.resolved`。

**LyricsX**

- 插件改为开关打开就挂载，是否恢复按每次搜索决定：
  - LyricsXFoundation 给 `LyricsSearchRequest` 加 `isForAppleMusicTrack`，读写 LyricsKit 预留的
    `AppleMusicNameRecoveryPlugin.appleMusicTrackUserInfoKey` 标记。
  - LyricsXFoundation 新增 `AppleMusicTrackNameRecoveryPlugin`，包住 `AppleMusicNameRecoveryPlugin`，只转交带标记的请求。
  - `makeLyricsSearchRequest(for:)`（自动搜索与「下一条候选」共用）和搜索歌词窗口，按 `selectedPlayer.name == .appleMusic` 设标记。
  - `AppController` 里随播放器变化重建歌词源组的订阅收窄到只看开关本身。
- 「写入音乐」菜单项的启用条件补上 `currentTrack?.originalTrack != nil`：系统级正在播放下 `name` 也会是 `.appleMusic`，
  但曲目没有 AppleScript 对象、写不进去，菜单项应和现在一样保持灰色。
- 测试：`LyricsXFoundationTests` 新增一组，覆盖带标记才转交、不带标记不调用、标记读写。
- 文档：CLAUDE.md（测试覆盖清单、MusicPlayer 锁定版本）、术语表「Route B / name recovery」补上何时运行、
  `docs/apple-music-lyrics.md` 6.1 节的挂载条件。

**落地步骤**（每步构建、测试通过后单独提交）

1. [x] MusicPlayer：`SystemMedia.name` 与 `MusicPlayerTests`。
2. [x] LyricsXFoundation：`isForAppleMusicTrack`、`AppleMusicTrackNameRecoveryPlugin` 与测试。
3. [x] LyricsX app：挂载、请求标记、重建订阅、「写入音乐」菜单项；Debug 构建通过。
4. [x] 文案与文档：中文开关文案、CLAUDE.md、术语表、`docs/apple-music-lyrics.md`。
5. [x] 发 MusicPlayer 1.11.0 并改锁定版本（打 tag、推送前先问用户）。

没有询问就采用的假设：

- 不改 LyricsKit：插件本身不看标记，由 LyricsX 包一层，免得多发一个 LyricsKit 版本。
- 只认 Music App；浏览器里的 Apple Music 网页版报的是浏览器的 bundle ID，分不出来，不处理。
- 开关英文文案不动（「Apple Music only」仍成立）；简体、繁体中文去掉「播放源」，改为「（仅限 Apple Music）」
  「（僅限 Apple Music）」，与其余语言一致。
- 搜索歌词窗口预填的艺人名，仍只在当前歌词来自「恢复出的原名」那次搜索时才换成原名，与选 Apple Music 播放源时相同。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-08 | Created as Draft | 用系统级正在播放听 Music 时原名恢复不生效，用户要求只要检测到 Music 在播放就启用 |
| 2026-11-08 | 按每次搜索判断，不再按播放器重建歌词源组 | 重建是异步的（填了 Apple Music 令牌时还要先联网验证），切到 Music 后的第一首歌常赶在重建完成前就用不带插件的旧组搜完；系统级正在播放下来源 App 随时会变，这个时序问题会频繁出现 |
| 2026-11-08 | 用户批准，开始实现；放到 1.9.0 正式版之后发 | 1.9.0 的候选版已观察一周，不在最后关头改系统级正在播放的代码 |
| 2026-11-08 | 提案随功能分支提交，不先落 develop；1.9.0 打 tag 之前不合进 develop；打 tag、推送之前先问用户 | develop 在 1.9.0 正式版之前不加东西；推送与发版由用户决定 |
| 2026-11-08 | 用户批准后，MusicPlayer 的 `v1.11.0` 打在功能分支的最新提交上，MusicPlayer 的 develop 暂不动 | 本地工作区构建用的是 MusicPlayer 主检出，1.9.0 之前不该带上这次改动；功能分支比 develop 只多两个提交，日后快进合并后这个 tag 就在 develop 上 |
| 2026-11-08 | 实现完成，待用户看过后收尾 | 五步都已完成：MusicPlayer 与 `LyricsXFoundationTests` 全部通过，接上 1.11.0 的 Debug 构建通过；实机效果尚未验证。发布说明留到 1.9.0 之后那一版再写 |
