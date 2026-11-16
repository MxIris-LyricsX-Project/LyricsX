# 按播放器与输出设备的歌词偏移

> 面向维护者。讲的是「为什么这么实现」，不是「实现了什么」——后者读代码更快。
> 提案：[按播放器与输出设备设置歌词偏移](../Evolutions/draft-playback-route-lyrics-offset.md)。

## 一句话

歌词时间 = 播放进度 + 三层偏移之和：歌词文件自带的 `[offset:]`、「通用」页的全局偏移、当前
**播放路由**（正在播放的 App × 系统默认输出设备）的偏移。第三层存在 `PlaybackRouteLyricsOffsets`
这张表里，由 `PlaybackRouteLyricsOffsetController` 跟着播放器和输出设备切换，`Lyrics.adjustedOffset`
每次读都把它加进去，所以菜单栏、桌面歌词、HUD、Apple Music 面板、Touch Bar、小组件都不用各自改。

## 为什么要按「播放器 × 设备」，而不是按设备

播放器各自补偿输出延迟，而且补得不一样：

- QQ 音乐 11.11.1 在 `-[AudioPlayManager updateProgress:]` 里写死，输出的 transport 是 AirPlay（且设备
  UID 含 `-audio`）时把进度减 2.205 秒，蓝牙减 0.1 秒，从不读 CoreAudio 的 `kAudioDevicePropertyLatency`。
- 网易云音乐不补偿。

HomePod mini 2 当 Mac 扬声器时真实延迟几乎为零（1 代约 2 秒），于是同一台设备，QQ 音乐要修、网易云不用修。
按设备存一个值顾不过来，只能按组合存。

## 播放器怎么认

用 bundle ID，不用 `MusicPlayerName`：后者只有 Music、Spotify 等五个可脚本控制的播放器，QQ 音乐、网易云都不在里面。

- `MusicPlayers.Agent`（`Selected`、自动模式的 `NowPlaying`）只是转发，顺着 `designatedPlayer` 往下找。
- 脚本播放器取 `Scriptable.playerBundleID`。
- 系统级正在播放取 `SystemMedia.playerBundleID`（MusicPlayer 1.12.0 起）：来源 App 有宿主时取宿主，和
  `SystemMedia.name`、adapter 的白名单用的是同一个标识。它在 `currentTrack` 之前写入，所以订阅
  `currentTrackWillChange` 的一方拿到的已经是新曲目所在的 App。

QQ 音乐的 iOS 内嵌进程报的是 `com.tencent.QQMusic.D5Q73692VW` 这种带 Team ID 后缀的标识，不是外壳 App 的
`com.tencent.QQMusicMac`。存的就是 MediaRemote 报的那个；显示名和图标经 `NowPlayingApplication` 去掉后缀后解析。

## 设备怎么认：UID，AirPlay 例外

一般设备用 `kAudioDevicePropertyDeviceUID`。它跨重启不变，用户改了设备名也不变。

**AirPlay 不行。** 2026-11-15 在 macOS 27.2 上，HomePod 立体声对当输出时查到的情况：

- CoreAudio 里是一台名字只叫「AirPlay」的设备，UID 形如 `7534dad1-c133-456f-8c49-2139a77aa23e-1050365501503375-Audio`。
- `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist` 按 UID 记着每台出现过的设备。同一个前缀
  `7534dad1-…` 带着 7 个不同的数字后缀，前缀本身历史上出现过 16 种。也就是说，**每次连接都换一个 UID**。
- 没有 data source；`kAudioDevicePropertyModelUID` 就是 UID 本身；自定义属性（`appt`、`flus`、`voic`、`apsl`、
  `btpt`）都是原始数据，没有接收端的名字。
- HomePod 在 Bonjour（`_airplay._tcp`）里广播的 `gid`、`pi`、`psi` 都和 UID 的前缀对不上。

所以 `AudioOutputDevice.persistentIdentifier` 对 AirPlay 返回固定的 `transport.airplay`，所有 AirPlay 输出共用一个偏移。
按 UID 存的话，下次连上 HomePod 就找不回来了。QQ 音乐的补偿本来也不分是哪台 AirPlay 接收端，
「播放器 × AirPlay」正好对得上它。

要分清是哪台接收端（HomePod mini 1 与 mini 2、HomePod 与 Apple TV），得经私有框架取接收端的稳定身份，
例如 AVFoundation 的 `AVOutputContext` 或 MediaRemote 的输出设备。这次没有做。

**复查**：新系统上跑 `swift test --filter AudioOutputDeviceProbes`，它会打印默认输出设备和全部输出设备的 UID、名字、
transport 与 data source。要看 AirPlay，就在 HomePod 当输出时跑；要看 UID 换没换，就对比上面那份 plist 里同一前缀有几条。

## 已知局限

- 播放器绕过系统输出、自己选设备时（Music 自带的 AirPlay 菜单、Spotify Connect、Audirvana 独占设备），读到的仍是系统默认输出。
- QQ 音乐交给系统「正在播放」的进度有没有带上那 −2.205 秒还没查。这只决定 QQ 音乐 × AirPlay 要填多少，实测即知。
- 小组件只在它本来就会刷新的时候拿到新偏移。全局偏移也是这样，切设备时不额外刷新。

## 线程

`Lyrics.adjustedOffset` 在歌词显示队列、主线程和 Apple Music 面板的每一帧上都会被读，所以当前组合的偏移放在锁里，
任何线程都能读。其余状态（当前播放器、当前设备、整张表）只在主队列上改，设置表单在主队列上订阅它们。

偏移变了要让显示立刻跟上，不能等下一行：`AppController`、桌面歌词、菜单栏原来只在全局偏移或本曲偏移变化时
重排当前行，现在把 `currentRouteOffsetDidChange` 并进同一个信号。切歌、换播放器、换输出设备、改表，
只要当前组合的偏移变了，它就发一次。

## 设置入口为什么是按钮而不是一行

「通用」页是不滚动的页里最高的（窗口 870 pt），13 寸 MacBook Air 最多放得下约 876 pt（见
[设置窗口的尺寸](PreferenceWindowSizing.md)），再加一行就会超出屏幕。所以按钮和全局偏移输入框放在同一个 grid
单元格里：`PreferenceGeneralViewController` 在 `viewDidLoad` 里把那个单元格的内容换成一个横向 stack。
storyboard 只多了一个指向输入框的 outlet。
