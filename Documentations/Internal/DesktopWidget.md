# 桌面小组件：实现说明

> 最初的设计稿是 [`docs/superpowers/specs/2026-03-28-desktop-widget-design.md`](../../docs/superpowers/specs/2026-03-28-desktop-widget-design.md)。
> 本文记录**实际落地的实现**、为什么这样做，以及已知降级。面向维护者。

## 背景与目标

小组件有小、中、大、超大四个尺寸，大号和超大号带播放控制按钮。数据单向流动：主 app 把当前歌曲、
当前行前后各 50 行歌词和播放进度写进 App Group 的 `UserDefaults`（`WidgetDataStore`），封面写成共享容器里的
`cover.jpg`；小组件的 `LyricsTimelineProvider` 按每行的开始时间生成 timeline entry，由 WidgetKit 在对应时刻换上。
小组件自己不跑任何代码去推进歌词。

## 关键设计决策

### 播放按钮走 `AudioPlaybackIntent`，不用 `openAppWhenRun`

小组件扩展是沙盒进程，发不了 Apple Event，也没有 MusicPlayer 的播放器后端，所以三个按钮的 intent
（`PlayPauseIntent`、`NextTrackIntent`、`PreviousTrackIntent`）必须在主 app 里执行。

设计稿用 `openAppWhenRun = true` 做到这一点，理由是 LyricsX 是 `LSUIElement` 应用，打开它用户看不见。
**这个前提不成立**：系统为执行 intent 去打开一个已经在运行的 app，对 app 来说就是一次 reopen，而
`AppDelegate.applicationShouldHandleReopen` 对 reopen 的回应是弹出设置窗口。于是每按一次按钮就弹一次设置窗口
（issue #142）。`applicationShouldHandleReopen` 本身没有错——用户在 Finder 里再次双击 LyricsX 时，就该看到设置——
所以不改它，改的是 intent。

遵循 `AudioPlaybackIntent`（macOS 14 起）后，系统把 intent 放进 app 进程执行，**不打开 app**
（Apple 文档 *Adding interactivity to widgets and Live Activities*：遵循 `AudioPlaybackIntent` 或
`LiveActivityIntent` 的 intent 在 app 进程里执行）。区别在构建产物里看得到，见「验证」一节：改之前三个 intent 是
`openAppWhenRun: true`、`systemProtocols` 为空；改之后是 `false`，并带
`com.apple.link.systemProtocol.AudioStarting`。

这个文件同时编进 app 和小组件两个 target：小组件要用这些类型构造 `Button(intent:)`。小组件里那一份的
`perform()` 被 `#if !WIDGET_EXTENSION` 掏空，系统不会调用它。

## 验证

```bash
# 三个按钮 intent 的元数据：应为 openAppWhenRun false，且 systemProtocols 含 AudioStarting
products=<DerivedData>/Build/Products/Debug
jq -c '.actions | to_entries[] | select(.key | test("PlayPause|NextTrack|PreviousTrack"))
       | {intent: .key, openAppWhenRun: .value.openAppWhenRun, systemProtocols: .value.systemProtocols}' \
   "$products/LyricsX-Debug.app/Contents/PlugIns/LyricsXWidget.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"
```

按下按钮之后系统怎么调度，只能人工确认：在桌面放一个大号或超大号小组件，点播放、上一首、下一首，
播放器应当响应，且不弹出设置窗口。

## 已知降级

- 三个 intent 的最低系统从 macOS 13 提到 14，这是 `AudioPlaybackIntent` 的要求。它们在快捷指令（Shortcuts）里
  也显示为 LyricsX 的动作，macOS 13 上不再有这三个动作。小组件本身最低 macOS 15，不受影响。
