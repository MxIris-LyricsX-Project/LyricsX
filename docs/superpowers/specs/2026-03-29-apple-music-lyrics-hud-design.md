# Apple Music 风格歌词 HUD 设计

## 概述

将 LyricsX 的 HUD 歌词窗口从当前基于 AppKit NSTextView 的简单滚动视图，升级为 Apple Music 风格的全歌词体验。macOS 15+ 使用全新 SwiftUI 窗口，旧版本保留现有 HUD。

## 决策记录

| 决策 | 选择 |
|---|---|
| 功能范围 | 全量复刻：行级高亮 + 逐字卡拉OK + 交互状态机 + 进度圆点 + 背景歌词 |
| 兼容性 | `if #available(macOS 15, *)` 分支，旧版本保留原有 HUD |
| 实现方案 | 纯 SwiftUI，通过 NSHostingController 嵌入 NSWindow |
| 逐字卡拉OK | 词级填充和字符级插值填充两种都实现，对比选择 |
| 窗口 | 全新独立窗口，非替换现有 HUD 内容 |
| 背景 | 可配置：专辑封面模糊 / 纯深色 / 跟随系统 |
| 翻译显示 | MelodicStamp 风格：行内附属，14pt 小字，透明度略低 |

## §1 整体架构

```
LyricsHUDViewController (macOS <15, 保留原有)
    └── ScrollLyricsView (NSTextView)

AppleMusicLyricsWindowController (macOS 15+, 新增)
    └── NSHostingController
        └── AppleMusicLyricsRootView
            ├── BackgroundView (封面模糊/纯色/可配置)
            └── AppleMusicLyricsScrollView (滚动引擎)
                └── ForEach lines → LyricsLineRowView
                    ├── LRCLyricsLineView (行级/逐词高亮)
                    └── TranslationView (小字翻译附属)
```

**入口分支**：在 `AppDelegate` 或菜单触发处用 `if #available(macOS 15, *)` 决定打开哪个窗口。两套窗口互斥，同一时间只显示一个。

**数据源不变**：新视图同样订阅 `AppController.shared.$currentLyrics` 和 `$currentLineIndex`，读取 `selectedPlayer.playbackTime` 获取精确播放位置。

## §2 滚动引擎 — AppleMusicLyricsScrollView

核心组件，负责歌词的布局、滚动和级联动画。

**布局结构**：
```swift
ScrollView {
    LazyVStack(spacing: 0) {
        ForEach(0..<lineCount, id: \.self) { index in
            LyricsLineRowView(...)
        }
    }
    .padding(.vertical, containerHeight / 2)
}
.scrollPosition($scrollPosition, anchor: .center)
```

**核心状态**：
- `scrollPosition: ScrollPosition` — 驱动滚动定位
- `contentOffset: [Int: CGFloat]` — 每行的垂直偏移量，驱动级联推动动画
- `lineHeights: [Int: CGFloat]` — 通过 `onGeometryChange` 测量每行实际高度

**级联推动动画**（scroll to highlighted）：
- 高亮行之前的 10 行：弹簧动画回归 `offset = 0`
- 高亮行及之后 10 行：带递增延迟（`0.08s`）的弹簧动画，向下推动
- 补偿逻辑：相邻行高度差异过大时做平滑补偿，避免跳跃感
- 使用 `.spring(duration: 0.6, bounce: 0.275)`

**曲目切换**：监听 identifier（曲目 ID）变化，清零所有 `contentOffset`，重新执行初始推动动画。

## §3 视觉效果 — 行级淡化

每行歌词根据与高亮行的距离，应用不同的透明度和模糊。

**透明度**：
- 高亮行：`1.0`
- 公式：`max(0.125, 0.55 - distance * 0.05)`
- 距离 1→0.50，距离 2→0.45，...，距离 9+→0.125

**模糊**：
- 高亮行：`0`
- 公式：`clamp(distance * 1.0, 1.0, 6.0)`

**高亮行亮度**：LRC 行在高亮时 `brightness(0.5)`。

**动画过渡**：
- 激活：立即 `0.8s smooth` 过渡
- 取消激活：延迟 `0.25s` 后 `0.8s smooth`（行短暂"停留"再暗下去）

**悬停效果**：鼠标悬停在非高亮行上时，临时取消该行的淡化效果。

## §4 逐字卡拉OK渲染

利用 macOS 15 的 `TextRenderer` 协议实现逐字符填充扫过效果。

**数据源**：`LyricsLine.Attachments[.timetag]` 提供逐词时间戳。

**模式 A — 词级填充**：
- 每个词作为整体，在其时间区间内从暗到亮
- 没有 timetag 数据时回退到行级高亮

**模式 B — 字符级插值填充**：
- 在词内按字符渲染宽度比例分配时间
- 用渐变 `clipToLayer` 做软边缘扫过，`blendRadius` 控制过渡带宽度

**两遍绘制**（两种模式通用）：
1. 第一遍：以 `inactiveOpacity(0.55)` 绘制全部文字（暗底层）
2. 第二遍：用线性渐变 mask 裁剪，以全亮度绘制已填充部分

两种模式都实现，对比效果后选择。

## §5 用户交互状态机

| 状态 | 含义 |
|---|---|
| `.following` | 自动滚动跟随播放，隐藏滚动指示器 |
| `.intermediate` | 用户刚滚动，等待 1s 后进入倒计时 |
| `.countingDown` | 显示进度环动画，3s 后自动恢复跟随 |
| `.isolated` | 用户锁定位置，不自动滚动 |

**状态流转**：
```
.following → 用户滚动 → .intermediate
.intermediate → 1s 后 → .countingDown
.countingDown → 3s 后 → .following
任意状态 → 点击锁定按钮 → .isolated
.isolated → 点击解锁按钮 → .following
```

**UI 表现**：
- `.following`：隐藏滚动条
- `.countingDown`：圆形进度环（0→1，3s），点击切换到 `.isolated`
- `.isolated`：锁定图标，点击恢复 `.following`

**点击跳转**：点击任意歌词行，播放跳转到该行时间 `+0.01s`，状态回到 `.following`。

## §6 间奏进度圆点 + 背景 + 翻译

**间奏进度圆点**：
- 两行歌词间沉默间隔 ≥ 4.5s 时显示三个圆点
- 呼吸动画：scale 1.0→1.25，`smooth(duration: 1.5)` 循环
- 按进度阈值依次激活：dot1 at 0.33，dot2 at 0.66，dot3 at 0.90

**可配置背景**（偏好设置选择）：
- 专辑封面模糊：提取封面 → 放大模糊 + 半透明暗色遮罩
- 纯深色：`Color.black` 或 `NSColor.windowBackgroundColor`
- 跟随系统：`NSVisualEffectView` 的 `.behindWindow` 材质

**翻译显示**：
- 行内附属，紧跟主歌词下方
- 字号 14pt（主歌词约 24pt），透明度略低
- 跟随主行参与高亮/淡化/滚动动画
- 数据源：`LyricsLine.Attachments[.translation(languageCode:)]`
- 中文繁简转换：复用 `ChineseConverter.shared`

## §7 窗口管理与集成

**窗口配置**：
- `styleMask = [.titled, .closable, .resizable, .fullSizeContentView]`
- `titlebarAppearsTransparent = true`，`titleVisibility = .hidden`
- 默认大小约 400×600，支持拖拽调整
- 窗口层级可切换（普通/悬浮）

**入口集成**：
```swift
if #available(macOS 15, *) {
    // 打开 AppleMusicLyricsWindowController
} else {
    // 打开 LyricsHUDWindowController（现有）
}
```

**文件组织**：
```
LyricsX/
  LyricsHUD/                          ← 保留不动
  AppleMusicLyrics/                   ← 新目录
    AppleMusicLyricsWindowController.swift
    AppleMusicLyricsRootView.swift
    AppleMusicLyricsScrollView.swift
    LyricsLineRowView.swift
    LyricsTextRenderer.swift
    InteractionStateModel.swift
    ProgressDotsView.swift
    BackgroundView.swift
```

**偏好设置**：在现有偏好面板中增加背景模式选项，复用 `UserDefaults` 存储。
