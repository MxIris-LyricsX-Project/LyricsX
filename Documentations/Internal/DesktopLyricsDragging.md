# 桌面歌词的拖动与光标：实现说明

> 没有配套提案：这是对 #226（拖动跨换行与跨屏）的回归修复。本文记录手形光标为什么不能用
> cursor rect，以及在没有自动化测试的情况下怎么复查。面向维护者。

## 背景

开着「允许拖放」（`DesktopLyricsDraggable`）时，整个桌面歌词接受鼠标按下（`KaraokeLyricsView.hitTest`
返回它自己，而不是鼠标下面的那个文字框），所以拖到一半换行也不会中断。#226 同时加了手形光标：
悬停时是张开的手，拖动时是握拳的手。

## 问题：换行时歌词框先横跳再单边收缩

#226 的手形光标用的是 cursor rect（在 `resetCursorRects` 里 `addCursorRect(bounds, …)`）。此后只要开着
允许拖放，每次换行的第一帧，歌词框会瞬间移到新位置，而旧文字和旧宽度都还在；之后宽度才从一侧动画到
新宽度。看起来就是先横跳十几到上百 pt，再单边收缩。正常应该是位置和宽度一起动画，两边对称收缩、中心不动。

关掉允许拖放就不跳，1.9.1 也没有这个问题。字体、注音、罗马音、播放器都无关。

## 原因

开着允许拖放，播同一首歌，各录 20 秒，统计歌词框中心的跳变次数：

| 版本 | 跳变次数 |
|---|---|
| #224 之后、#226 之前 | 0 |
| #226 | 42 |
| develop，去掉 `resetCursorRects` | 0 |
| develop，保留 `resetCursorRects`，去掉 #224 加的 `window?.layoutIfNeeded()` | 15 |

所以 cursor rect 单独就会触发横跳，和 #224 在换行后立即布局窗口无关。

推测的机制（没有逆向确认）：换行时 `displayLrc` 在 `NSAnimationContext` 里改布局，视图的位置和尺寸本该
一起走隐式动画。视图带着 cursor rect 时，AppKit 要重建 cursor rect，这一步在动画上下文之外先把窗口
排了一次版。于是歌词视图的位置不带动画、直接落到终点，而做背景的子视图（autoresizing）仍按动画改宽度。

## 做法

不用 cursor rect，手形光标改由视图已有的 tracking area 负责：

- 允许拖放或「隐藏歌词：鼠标经过时」开着任何一项，就装上 tracking area。
- 允许拖放时，`mouseEntered` / `mouseMoved` 设张开的手（拖动中设握拳的手），`mouseExited` 恢复箭头。
- 不允许拖放时，照旧在鼠标经过时隐藏歌词。

1.9.1 里这个 tracking area 本来就一直装着（「鼠标经过时」默认开），从来不会引起横跳。

**不要再给 `KaraokeLyricsView` 加 `resetCursorRects` / `addCursorRect`。**

## 怎么复查

`KaraokeLyricsView` 在 App target 里，`LyricsXPackage` 的测试够不到它，横跳也只在真实窗口、真实播放时
出现，所以没有自动化测试。改了这个视图、桌面歌词的布局或鼠标处理之后，照下面的步骤手工复查。
测试时屏幕上要一直开着桌面歌词播歌，还要录屏，最好在一台没人在用的 Mac 上做。

1. 运行 Debug 版，在偏好设置里勾上「允许拖放」，取消「隐藏歌词：屏幕截图时」（否则录不到桌面歌词），
   把桌面歌词的背景颜色设成不透明的纯品红（#FF00FF），因为脚本按颜色找框。
2. 播一首相邻两句长短差别大的歌，打开单曲循环，例如 The Script 的《Hall of Fame》，打开「优先使用双语歌词」。
3. 歌词已经显示之后，只录歌词框所在的那一条（Retina 屏）：
   `screencapture -x -V 20 -R <x>,<y>,<宽>,<高> box.mov`
4. `python3 -I Scripts/count-desktop-lyrics-box-jumps.py box.mov`（需要 ffmpeg）。跳变 0 次、退出码 0 才算通过。
   修复前同样的条件 20 秒有二三十次。歌词框刚出现时的淡入和上移会算成跳变，所以要在歌词显示之后再开始录。
