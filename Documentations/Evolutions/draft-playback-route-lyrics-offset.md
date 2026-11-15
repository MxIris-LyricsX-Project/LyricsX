# Draft - 按播放器与输出设备设置歌词偏移

- **状态**: Accepted
- **创建日期**: 2026-11-15
- **最后更新**: 2026-11-15
- **实现分支**: LyricsX `feature/playback-route-lyrics-offset`（从 develop 切）；MusicPlayer `feature/system-media-player-bundle-id`（叠在 `feature/system-media-player-name`，即 1.11.0 之上）

## 摘要

歌词时间现在有两层偏移：每首歌自己的偏移（写进歌词文件的 `[offset:]`）和「通用」页的全局偏移。可播放器各自对输出延迟的补偿并不一致：QQ 音乐 11.11.1 在 `-[AudioPlayManager updateProgress:]` 里写死，输出走 AirPlay 时把进度减 2.205 秒、走蓝牙时减 0.1 秒，从不读 CoreAudio 报的真实延迟；网易云音乐不做补偿。HomePod mini 2 当 Mac 扬声器时真实延迟几乎为零（1 代约 2 秒），于是同一台设备在不同播放器下需要不同的修正，一个全局值顾不过来。本提案加第三层偏移，按「播放器 × 输出设备」分别设置，与前两层相加。

## 方案

**识别播放器：用 bundle ID。**

- 指定了脚本播放器（Music、Spotify 等五个）时取 `MusicPlayers.Scriptable.playerBundleID`；自动模式取其中正在播放的那个。
- 系统级正在播放（QQ 音乐、网易云都走这条）目前拿不到来源 App：MusicPlayer 1.11.0 的 `SystemMedia.name` 只认得那五个播放器，其余一律 `nil`。在 MusicPlayer 上给 `SystemMedia` 加 `public var playerBundleID: String?`，命名照 `Scriptable.playerBundleID`，取值与 1.11.0 的 `name` 同源（客户端有宿主 App 时取宿主），和曲目一起写、一起清，发 MusicPlayer 1.12.0。这个改动叠在 1.11.0 之上。

**识别输出设备：CoreAudio 系统默认输出设备的 UID。**

- 读 `kAudioHardwarePropertyDefaultOutputDevice`，以设备的 `kAudioDevicePropertyDeviceUID` 为键（Apple 文档说明它跨重启保持不变），设备名只用于显示；监听默认输出设备的变化，切设备立即生效。
- 实现时先用一个探针确认 AirPlay 接收端（HomePod）在 CoreAudio 里是各自独立的设备、UID 能区分不同的 HomePod；若它们共用一个设备、靠 data source 区分，键里再加上 data source。

**怎么叠加。**

- `Lyrics.adjustedOffset` = 歌词自带偏移 + 全局偏移 + 当前组合的偏移。菜单栏、桌面歌词、HUD、Apple Music 面板、Touch Bar、小组件都经 `adjustedTimeDelay` 取时间，三层相加后它们一起生效。
- 现在监听 `.globalLyricsOffset` 来重排时间的三处（`AppController`、`KaraokeLyricsController`、`MenuBarLyricsController`）改为监听「生效偏移变了」：改全局偏移、改当前组合的值、换播放器、换输出设备，都触发同一个信号。
- 单位与正负号沿用前两层：毫秒，正值让歌词提前。没设过的组合按 0 算，不内置任何预设值。
- 只按「播放器 × 设备」精确匹配，不做「任意播放器」或「任意设备」的通配。
- 状态菜单的偏移行和偏移快捷键仍只调每首歌的偏移。

**设置界面：「通用」页全局偏移旁的一个按钮，打开一张表单。**

- 全局偏移输入框右边加一个按钮，不另起一行：通用页是不滚动的页里最高的（窗口 870 pt），再加一行就超出 13 寸 MacBook Air 能放下的约 876 pt（见 `Documentations/Internal/PreferenceWindowSizing.md`）。
- 表单顶部是当前组合（例如「QQ音乐 → 客厅」）和它的偏移输入框，改了就存给这个组合，填 0 即删掉这条。识别不出播放器或输出设备时输入框禁用，并说明缺的是哪个。
- 下面一张表列出所有存过的组合（播放器、设备、偏移），可以改值、删除。设备不在线时照样列出，用存下的名字显示。

**存储与测试。**

- 一个新的 UserDefaults 键，存组合列表：播放器 bundle ID、设备 UID、偏移，以及存入时两者的显示名。不写进歌词文件。
- 纯逻辑（查表、三层相加、编码与解码）放 `LyricsXFoundation`，配 `LyricsXFoundationTests`；CoreAudio 读取另配一个读当前默认设备的探针。

**已知局限。**

- 播放器绕过系统输出、自己选设备时（Music 自带的 AirPlay 选择器、Spotify Connect、Audirvana 独占设备），读到的仍是系统默认输出，对不上。
- QQ 音乐交给系统「正在播放」的进度有没有带上那 −2.205 秒还没查。这只决定 QQ 音乐 × HomePod 要不要填 +2205，装好后实测即知，不影响方案。

**落地步骤。**

1. MusicPlayer：`SystemMedia.playerBundleID` 与测试。
2. LyricsXFoundation：`PlaybackRoute`、`PlaybackRouteLyricsOffsets`（查表、设值、删条目、编解码）与 `LyricsXFoundationTests`。
3. LyricsXFoundation：CoreAudio 读默认输出设备、监听它的变化，配一个列出本机输出设备的探针，确认 AirPlay 设备的 UID 形态。
4. App：识别当前播放器与输出设备、算出当前组合的偏移；`adjustedOffset` 加上它；三处重排时间的监听改为同一个信号。
5. App：全局偏移旁的按钮与表单，新文案的本地化。
6. 文档：`CLAUDE.md` 的测试覆盖清单、按需的实现说明，提案改成实际做法。

正式收尾时另做：原名恢复先合；MusicPlayer 这条分支合进它的 develop 并打 `v1.12.0`；LyricsX 把 `exact:` 改成 `"1.12.0"`、重新解析并提交 `Package.resolved`。实现期间 LyricsX 分支仍钉着 develop 的 1.10.1，app 对着本地的 MusicPlayer 分支编译。

**落地顺序。** MusicPlayer 改动叠在 1.11.0 上，而 LyricsX develop 还钉着 1.10.1、1.11.0 配套的原名恢复分支（`feature/system-now-playing-name-recovery`）也还没合。所以原名恢复要先收尾合进 develop，这个再合。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-15 | Created as Draft | 用户换用 HomePod mini 2 后，QQ 音乐写死的 AirPlay 补偿让歌词晚了两秒多，而网易云在同一台设备上是准的；需要按播放器和输出设备分别修正 |
| 2026-11-15 | 沿用现有偏移的单位与正负号，三层直接相加 | 同一个应用里出现两种方向相反的设置只会让人填错 |
| 2026-11-15 | 播放器按 bundle ID、设备按 CoreAudio UID 识别 | QQ 音乐、网易云不在 MusicPlayer 认得的五个播放器里；设备名会重名、会被改，UID 不会 |
| 2026-11-15 | 不内置预设值 | 每个播放器交给系统的进度是否已含补偿各不相同，预设值猜错比不设更糟 |
| 2026-11-15 | 用户批准，开始实现 | |
| 2026-11-15 | LyricsX 分支从 develop 切，不叠在原名恢复分支上；提案作为功能分支的第一个提交，不先提交到 develop | 原名恢复分支落后 develop 40 个提交，缺菜单栏卡拉OK进度改过的偏移监听；develop 上还有别的会话没推送的 12 个提交，正在收尾 |
| 2026-11-15 | 实现期间不推 MusicPlayer 的 tag | tag 推出去就不能再动；API 等用户看过再定版，收尾时再打 |
| 2026-11-15 | 设置入口从「通用页加一行」改为全局偏移旁的按钮加表单 | 通用页再高一行就放不进 13 寸 MacBook Air 的屏幕 |
