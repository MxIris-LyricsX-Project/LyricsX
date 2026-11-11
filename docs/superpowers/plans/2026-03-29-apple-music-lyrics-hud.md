# Apple Music 风格歌词 HUD 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 macOS 15+ 用户实现全新的 Apple Music 风格全歌词 HUD 窗口，包含弹簧级联滚动、逐字卡拉OK渲染、行级淡化、交互状态机等完整功能。

**Architecture:** 纯 SwiftUI 实现，通过 `NSHostingController` 嵌入 `NSWindow`。macOS 15+ 用户看到新窗口，旧版本保留现有 `ScrollLyricsView` HUD。新视图订阅现有 `AppController.shared` 的 `$currentLyrics` 和 `$currentLineIndex`，读取 `selectedPlayer.playbackTime` 获取精确时间。

**Tech Stack:** SwiftUI (macOS 15+), `TextRenderer` protocol, `ScrollPosition`, Spring animations, Combine, AppKit window management

**Note:** Spec 决策表中提到"背景歌词(backing vocals)"，但 LyricsKit 的数据模型不包含 backing vocals 概念（这是 TTML 特有的）。当 LyricsKit 未来添加此支持时再实现。

**Spec:** `docs/superpowers/specs/2026-03-29-apple-music-lyrics-hud-design.md`

---

## File Structure

```
LyricsX/AppleMusicLyrics/                         ← 新目录，所有新文件
  AppleMusicLyricsWindowController.swift           — NSWindowController, 窗口配置与生命周期
  AppleMusicLyricsRootView.swift                   — 根 SwiftUI 视图：背景 + 歌词滚动 + 交互按钮
  AppleMusicLyricsScrollView.swift                 — 滚动引擎：ScrollView + LazyVStack + 级联动画
  LyricsLineRowView.swift                          — 单行歌词：主文字 + 翻译 + 淡化效果 + 点击跳转
  LyricsTextRenderer.swift                         — TextRenderer 逐字卡拉OK（词级 + 字符级两种模式）
  InteractionStateModel.swift                      — 滚动交互状态机（following/intermediate/countingDown/isolated）
  ProgressDotsView.swift                           — 间奏进度圆点（3 dot breathing animation）
  BackgroundView.swift                             — 可配置背景（封面模糊 / 纯深色 / 跟随系统）

LyricsX/Utility/Global.swift                       — 修改：新增 UserDefaults 键
LyricsX/Component/AppDelegate.swift                — 修改：#available 分支打开新窗口
```

---

### Task 1: UserDefaults 键与背景模式枚举

**Files:**
- Modify: `LyricsX/Utility/Global.swift:162` (在 `isShowLyricsHUD` 附近)

- [ ] **Step 1: 在 Global.swift 中新增 UserDefaults 键**

在 `UserDefaults.DefaultsKeys` 扩展中，`isShowLyricsHUD` 行之后添加：

```swift
    static let appleMusicLyricsBackgroundMode = Key<Int>("AppleMusicLyricsBackgroundMode")
```

背景模式值约定：`0` = 专辑封面模糊，`1` = 纯深色，`2` = 跟随系统。默认 `0`。

- [ ] **Step 2: 验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/Utility/Global.swift
git commit -m "feat(apple-music-lyrics): add UserDefaults key for background mode"
```

---

### Task 2: 交互状态机 — InteractionStateModel

**Files:**
- Create: `LyricsX/AppleMusicLyrics/InteractionStateModel.swift`

- [ ] **Step 1: 创建 InteractionStateModel.swift**

```swift
import SwiftUI
import Combine

@available(macOS 15, *)
@Observable
final class InteractionStateModel {

    enum State: Equatable {
        case following
        case intermediate
        case countingDown
        case isolated
    }

    private(set) var state: State = .following

    var isFollowing: Bool { state == .following }

    var isDelegated: Bool { state != .following }

    var delegationProgress: Double = 0

    private var intermediateTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    private let countDownDelay: TimeInterval = 1.0
    private let countDownDuration: TimeInterval = 3.0

    func userDidScroll() {
        guard state != .isolated else { return }
        cancelTimers()
        state = .intermediate
        delegationProgress = 0
        intermediateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.countDownDelay ?? 1.0))
            guard !Task.isCancelled else { return }
            self?.startCountdown()
        }
    }

    func toggleIsolation() {
        cancelTimers()
        if state == .isolated {
            state = .following
            delegationProgress = 0
        } else {
            state = .isolated
            delegationProgress = 0
        }
    }

    func returnToFollowing() {
        cancelTimers()
        state = .following
        delegationProgress = 0
    }

    private func startCountdown() {
        state = .countingDown
        delegationProgress = 0
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 60
            let stepDuration = self.countDownDuration / Double(steps)
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(stepDuration))
                guard !Task.isCancelled else { return }
                self.delegationProgress = Double(step) / Double(steps)
            }
            self.state = .following
            self.delegationProgress = 0
        }
    }

    private func cancelTimers() {
        intermediateTask?.cancel()
        intermediateTask = nil
        countdownTask?.cancel()
        countdownTask = nil
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目**

使用 Xcode MCP 或手动将文件添加到 `LyricsX` target。

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add LyricsX/AppleMusicLyrics/InteractionStateModel.swift
git commit -m "feat(apple-music-lyrics): add interaction state machine model"
```

---

### Task 3: 间奏进度圆点 — ProgressDotsView

**Files:**
- Create: `LyricsX/AppleMusicLyrics/ProgressDotsView.swift`

- [ ] **Step 1: 创建 ProgressDotsView.swift**

```swift
import SwiftUI

@available(macOS 15, *)
struct ProgressDotsView: View {

    var progress: Double  // 0.0 ... 1.0

    @State private var isBreathing = false

    private let dotSize: CGFloat = 6
    private let dotSpacing: CGFloat = 8

    var body: some View {
        HStack(spacing: dotSpacing) {
            dot(activationThreshold: 0.33)
            dot(activationThreshold: 0.66)
            dot(activationThreshold: 0.90)
        }
        .onAppear {
            isBreathing = true
        }
    }

    @ViewBuilder
    private func dot(activationThreshold: Double) -> some View {
        let isActive = progress >= activationThreshold
        Circle()
            .fill(Color.white.opacity(isActive ? 0.8 : 0.3))
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(isActive && isBreathing ? 1.25 : 1.0)
            .animation(
                isActive
                    ? .smooth(duration: 1.5).repeatForever(autoreverses: true)
                    : .smooth(duration: 0.3),
                value: isBreathing
            )
            .animation(.smooth(duration: 0.3), value: isActive)
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/ProgressDotsView.swift
git commit -m "feat(apple-music-lyrics): add interlude progress dots view"
```

---

### Task 4: 可配置背景 — BackgroundView

**Files:**
- Create: `LyricsX/AppleMusicLyrics/BackgroundView.swift`

- [ ] **Step 1: 创建 BackgroundView.swift**

```swift
import SwiftUI

@available(macOS 15, *)
struct BackgroundView: View {

    var artwork: NSImage?
    var backgroundMode: Int  // 0 = artwork blur, 1 = dark, 2 = system

    var body: some View {
        switch backgroundMode {
        case 0:
            artworkBlurBackground
        case 2:
            systemMaterialBackground
        default:
            darkBackground
        }
    }

    @ViewBuilder
    private var artworkBlurBackground: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 80)
                .saturation(1.5)
                .overlay(Color.black.opacity(0.4))
                .clipped()
        } else {
            darkBackground
        }
    }

    private var darkBackground: some View {
        Color.black
    }

    private var systemMaterialBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/BackgroundView.swift
git commit -m "feat(apple-music-lyrics): add configurable background view"
```

---

### Task 5: 逐字卡拉OK渲染 — LyricsTextRenderer

**Files:**
- Create: `LyricsX/AppleMusicLyrics/LyricsTextRenderer.swift`

- [ ] **Step 1: 创建 LyricsTextRenderer.swift**

这是最复杂的组件。实现 `TextRenderer` 协议，支持词级和字符级两种填充模式。

```swift
import SwiftUI
import LyricsXFoundation

// MARK: - Word Timing Data

@available(macOS 15, *)
struct WordTimingEntry {
    var characterIndex: Int
    var timeOffset: TimeInterval  // seconds from line start
}

@available(macOS 15, *)
enum KaraokeMode {
    case wordLevel
    case characterLevel
}

// MARK: - LyricsTextRenderer

@available(macOS 15, *)
struct LyricsTextRenderer: TextRenderer {

    var elapsedTime: TimeInterval     // seconds since line start
    var lineDuration: TimeInterval    // total line duration in seconds
    var wordTimings: [WordTimingEntry]
    var mode: KaraokeMode
    var inactiveOpacity: Double = 0.55
    var highlightBrightness: Double = 0.5
    var blendRadius: CGFloat = 8

    var animatableData: Double {
        get { elapsedTime }
        set { elapsedTime = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let flattenedRuns = layout.flatMap { line in line.flatMap { run in run } }

        // Pass 1: draw all text at inactive opacity
        var inactiveContext = context
        inactiveContext.opacity = inactiveOpacity
        for line in layout {
            inactiveContext.draw(line)
        }

        // Pass 2: draw highlighted portion with clipping
        guard lineDuration > 0 else { return }

        let totalWidth = layout.first.map { line in
            line.map { run in run.typographicBounds.width }.reduce(0, +)
        } ?? 0
        guard totalWidth > 0 else { return }

        let filledFraction: CGFloat
        switch mode {
        case .wordLevel:
            filledFraction = wordLevelProgress(totalWidth: totalWidth, flattenedRuns: flattenedRuns)
        case .characterLevel:
            filledFraction = characterLevelProgress(totalWidth: totalWidth, flattenedRuns: flattenedRuns)
        }

        for line in layout {
            let lineBounds = line.typographicBounds
            let lineRect = CGRect(
                x: lineBounds.origin.x,
                y: lineBounds.origin.y - lineBounds.ascent,
                width: lineBounds.width,
                height: lineBounds.ascent + lineBounds.descent + lineBounds.leading
            )
            let filledWidth = lineRect.width * filledFraction

            var highlightContext = context
            highlightContext.clipToLayer { clipContext in
                clipContext.fill(
                    Path(lineRect),
                    with: .linearGradient(
                        Gradient(colors: [.white, .clear]),
                        startPoint: CGPoint(x: lineRect.minX + filledWidth - blendRadius / 2, y: 0),
                        endPoint: CGPoint(x: lineRect.minX + filledWidth + blendRadius / 2, y: 0)
                    )
                )
            }
            highlightContext.addFilter(.brightness(highlightBrightness))
            highlightContext.draw(line)
        }
    }

    // MARK: - Word-Level Progress

    private func wordLevelProgress(totalWidth: CGFloat, flattenedRuns: [Text.Layout.RunSlice]) -> CGFloat {
        guard !wordTimings.isEmpty else {
            // No timetag: whole line progress
            return CGFloat(min(1, max(0, elapsedTime / lineDuration)))
        }

        // Find the active word boundary
        var activeWordEndFraction: CGFloat = 0
        var activeWordStartFraction: CGFloat = 0
        var wordStartTime: TimeInterval = 0
        var wordEndTime: TimeInterval = lineDuration

        for (timingIndex, timing) in wordTimings.enumerated() {
            let nextTiming = timingIndex + 1 < wordTimings.count ? wordTimings[timingIndex + 1] : nil
            let nextTimeOffset = nextTiming?.timeOffset ?? lineDuration

            if elapsedTime >= timing.timeOffset && elapsedTime < nextTimeOffset {
                wordStartTime = timing.timeOffset
                wordEndTime = nextTimeOffset
                // Approximate character position as fraction of total width
                activeWordStartFraction = CGFloat(timing.characterIndex) / CGFloat(max(1, totalCharacterCount(flattenedRuns)))
                let endCharIndex = nextTiming?.characterIndex ?? totalCharacterCount(flattenedRuns)
                activeWordEndFraction = CGFloat(endCharIndex) / CGFloat(max(1, totalCharacterCount(flattenedRuns)))
                break
            } else if elapsedTime >= nextTimeOffset {
                activeWordStartFraction = CGFloat(nextTiming?.characterIndex ?? totalCharacterCount(flattenedRuns)) / CGFloat(max(1, totalCharacterCount(flattenedRuns)))
                activeWordEndFraction = activeWordStartFraction
            }
        }

        // Whole word lights up at once
        if elapsedTime >= wordStartTime {
            return activeWordEndFraction
        }
        return activeWordStartFraction
    }

    // MARK: - Character-Level Progress

    private func characterLevelProgress(totalWidth: CGFloat, flattenedRuns: [Text.Layout.RunSlice]) -> CGFloat {
        guard !wordTimings.isEmpty else {
            return CGFloat(min(1, max(0, elapsedTime / lineDuration)))
        }

        // Find active word and interpolate within it by character width
        var accumulatedFraction: CGFloat = 0
        let totalCharacters = totalCharacterCount(flattenedRuns)
        guard totalCharacters > 0 else { return 0 }

        for (timingIndex, timing) in wordTimings.enumerated() {
            let nextTiming = timingIndex + 1 < wordTimings.count ? wordTimings[timingIndex + 1] : nil
            let nextTimeOffset = nextTiming?.timeOffset ?? lineDuration
            let nextCharIndex = nextTiming?.characterIndex ?? totalCharacters

            if elapsedTime < timing.timeOffset {
                return CGFloat(timing.characterIndex) / CGFloat(totalCharacters)
            }

            if elapsedTime >= timing.timeOffset && elapsedTime < nextTimeOffset {
                let wordDuration = nextTimeOffset - timing.timeOffset
                guard wordDuration > 0 else { continue }
                let progressInWord = (elapsedTime - timing.timeOffset) / wordDuration
                let startFraction = CGFloat(timing.characterIndex) / CGFloat(totalCharacters)
                let endFraction = CGFloat(nextCharIndex) / CGFloat(totalCharacters)
                return startFraction + CGFloat(progressInWord) * (endFraction - startFraction)
            }
        }

        return 1.0  // past all words
    }

    private func totalCharacterCount(_ runs: [Text.Layout.RunSlice]) -> Int {
        // Approximate: use the last word timing's end or content length
        if let lastTiming = wordTimings.last {
            return max(lastTiming.characterIndex + 1, wordTimings.count)
        }
        return 1
    }
}

// MARK: - Helper to extract word timings from LyricsKit InlineTimeTag

@available(macOS 15, *)
extension LyricsLine {
    var wordTimingEntries: [WordTimingEntry]? {
        guard let timetag = attachments.timetag else { return nil }
        return timetag.tags.map { tag in
            WordTimingEntry(characterIndex: tag.index, timeOffset: tag.time)
        }
    }

    var timetagDuration: TimeInterval? {
        return attachments.timetag?.duration
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/LyricsTextRenderer.swift
git commit -m "feat(apple-music-lyrics): add TextRenderer karaoke with word and character level modes"
```

---

### Task 6: 单行歌词视图 — LyricsLineRowView

**Files:**
- Create: `LyricsX/AppleMusicLyrics/LyricsLineRowView.swift`

- [ ] **Step 1: 创建 LyricsLineRowView.swift**

```swift
import SwiftUI
import LyricsXFoundation

@available(macOS 15, *)
struct LyricsLineRowView: View {

    var line: LyricsLine
    var index: Int
    var isHighlighted: Bool
    var highlightedIndex: Int
    var elapsedTime: TimeInterval     // seconds since this line started
    var lineDuration: TimeInterval    // this line's duration
    var karaokeMode: KaraokeMode
    var onTap: () -> Void

    @State private var isActive: Bool = false
    @State private var isHovering: Bool = false

    private let mainFontSize: CGFloat = 24
    private let translationFontSize: CGFloat = 14
    private let highlightReleasingDelay: TimeInterval = 0.25

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                mainLyricsView
                translationView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(fadingOpacity)
        .blur(radius: fadingBlur)
        .brightness(isActive ? 0.5 : 0)
        .animation(.smooth(duration: 0.8), value: isActive)
        .onChange(of: isHighlighted, initial: true) { _, newValue in
            withAnimation(newValue
                ? .smooth(duration: 0.8)
                : .smooth(duration: 0.8).delay(highlightReleasingDelay)
            ) {
                isActive = newValue
            }
        }
    }

    // MARK: - Main Lyrics

    @ViewBuilder
    private var mainLyricsView: some View {
        let hasKaraoke = line.wordTimingEntries != nil && isHighlighted
        if hasKaraoke {
            let renderer = LyricsTextRenderer(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                mode: karaokeMode
            )
            Text(line.content)
                .font(.system(size: mainFontSize, weight: .bold))
                .textRenderer(renderer)
        } else {
            Text(line.content)
                .font(.system(size: mainFontSize, weight: .bold))
                .foregroundStyle(Color.white)
        }
    }

    // MARK: - Translation

    @ViewBuilder
    private var translationView: some View {
        if defaults[.preferBilingualLyrics],
           let translation = line.attachments.translation() {
            let displayText: String = {
                if let converter = ChineseConverter.shared {
                    return converter.convert(translation)
                }
                return translation
            }()
            Text(displayText)
                .font(.system(size: translationFontSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    // MARK: - Fading Effect

    private var shouldFade: Bool {
        !isActive && !isHovering
    }

    private var distance: Int {
        abs(index - highlightedIndex)
    }

    private var fadingOpacity: Double {
        guard shouldFade else { return 1.0 }
        let factor = 0.55 - Double(distance) * 0.05
        return max(0.125, min(factor, 0.55))
    }

    private var fadingBlur: CGFloat {
        guard shouldFade else { return 0 }
        let factor = CGFloat(distance) * 1.0
        return max(1.0, min(factor, 6.0))
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/LyricsLineRowView.swift
git commit -m "feat(apple-music-lyrics): add lyrics line row view with fading and karaoke"
```

---

### Task 7: 滚动引擎 — AppleMusicLyricsScrollView

**Files:**
- Create: `LyricsX/AppleMusicLyrics/AppleMusicLyricsScrollView.swift`

- [ ] **Step 1: 创建 AppleMusicLyricsScrollView.swift**

```swift
import SwiftUI
import Combine
import LyricsXFoundation

@available(macOS 15, *)
struct AppleMusicLyricsScrollView: View {

    var lyrics: Lyrics
    var highlightedLineIndex: Int?
    var playbackTime: TimeInterval
    var karaokeMode: KaraokeMode
    var interactionState: InteractionStateModel

    var onSeek: (TimeInterval) -> Void

    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var containerSize: CGSize = .zero
    @State private var contentOffset: [Int: CGFloat] = [:]
    @State private var lineHeights: [Int: CGFloat] = [:]
    @State private var previousHighlightedIndex: Int?
    @Namespace private var coordinateSpace

    private let interludeThreshold: TimeInterval = 4.5

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(enabledLineIndices, id: \.self) { index in
                    lineContent(at: index)
                        .id(index)
                }
            }
            .padding(.vertical, containerSize.height / 2)
        }
        .scrollPosition($scrollPosition, anchor: .center)
        .scrollIndicators(interactionState.isFollowing ? .hidden : .visible)
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { newValue in
            containerSize = newValue
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting {
                interactionState.userDidScroll()
            }
        }
        .onChange(of: highlightedLineIndex) { oldValue, newValue in
            previousHighlightedIndex = oldValue
            guard let newValue else { return }
            scrollToHighlighted(index: newValue)
        }
        .onChange(of: lyrics.description) { _, _ in
            // Track changed: reset all offsets
            contentOffset.removeAll()
            lineHeights.removeAll()
            previousHighlightedIndex = nil
        }
    }

    // MARK: - Enabled Lines

    private var enabledLineIndices: [Int] {
        lyrics.lines.indices.filter { lyrics.lines[$0].enabled }
    }

    // MARK: - Line Content

    @ViewBuilder
    private func lineContent(at index: Int) -> some View {
        let line = lyrics.lines[index]
        let isHighlighted = highlightedLineIndex == index
        let highlightedIdx = highlightedLineIndex ?? 0
        let lineStartTime = line.position
        let elapsedTime = playbackTime + (lyrics.adjustedTimeDelay) - lineStartTime
        let lineDuration = computeLineDuration(at: index)

        VStack(spacing: 0) {
            // Interlude dots
            interludeDotsIfNeeded(beforeIndex: index)

            LyricsLineRowView(
                line: line,
                index: index,
                isHighlighted: isHighlighted,
                highlightedIndex: highlightedIdx,
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                karaokeMode: karaokeMode,
                onTap: {
                    onSeek(line.position + 0.01)
                    interactionState.returnToFollowing()
                }
            )
        }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { newValue in
            lineHeights[index] = newValue
        }
        .offset(y: contentOffset[index] ?? 0)
    }

    // MARK: - Line Duration

    private func computeLineDuration(at index: Int) -> TimeInterval {
        // Use timetag duration if available
        if let duration = lyrics.lines[index].timetagDuration, duration > 0 {
            return duration
        }
        // Otherwise compute from next line's position
        let nextEnabledIndex = enabledLineIndices.first(where: { $0 > index })
        if let nextIndex = nextEnabledIndex {
            return lyrics.lines[nextIndex].position - lyrics.lines[index].position
        }
        return 5.0  // fallback for last line
    }

    // MARK: - Interlude Dots

    @ViewBuilder
    private func interludeDotsIfNeeded(beforeIndex index: Int) -> some View {
        let previousEnabledIndex = enabledLineIndices.last(where: { $0 < index })
        if let previousIndex = previousEnabledIndex {
            let gap = lyrics.lines[index].position - lyrics.lines[previousIndex].position
            if gap >= interludeThreshold {
                let gapStart = lyrics.lines[previousIndex].position
                let adjustedPlayback = playbackTime + (lyrics.adjustedTimeDelay)
                let gapProgress = max(0, min(1, (adjustedPlayback - gapStart) / gap))
                ProgressDotsView(progress: gapProgress)
                    .frame(height: 40)
            }
        }
    }

    // MARK: - Cascade Scroll Animation

    private func scrollToHighlighted(index: Int) {
        guard interactionState.isFollowing else { return }

        let offset = (lineHeights[index] ?? 40) / 2

        // Phase 1: spring lines before highlight back to zero
        for lineIndex in max(0, index - 10)..<index {
            withAnimation(.spring(duration: 0.6, bounce: 0.275)) {
                contentOffset[lineIndex] = 0
            }
        }

        // Phase 2: stagger-animate lines at and after highlight
        var delay: TimeInterval = 0.08
        let previousOffset = lineHeights[previousHighlightedIndex ?? index] ?? 40
        let compensate: CGFloat = {
            guard let previousHighlightedIndex else { return 0 }
            let diffBefore = abs(previousOffset - (lineHeights[index] ?? 40))
            let diffAfter = abs((lineHeights[index + 1] ?? 40) - (lineHeights[index] ?? 40))
            if abs(index - previousHighlightedIndex) > 3 {
                return 0
            } else if diffBefore > diffAfter {
                return (previousOffset - (lineHeights[index] ?? 40)) / 2
            } else {
                return ((lineHeights[index + 1] ?? 40) - (lineHeights[index] ?? 40)) / 2
            }
        }()

        for lineIndex in index..<min(lyrics.lines.count, index + 10) {
            delay += 0.08
            withAnimation(.spring(duration: 0.6, bounce: 0.275).delay(delay)) {
                contentOffset[lineIndex] = offset + compensate
            }
        }

        // Scroll to center
        withAnimation(.spring(duration: 0.6, bounce: 0.275)) {
            scrollPosition.scrollTo(id: index, anchor: .center)
        }
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/AppleMusicLyricsScrollView.swift
git commit -m "feat(apple-music-lyrics): add scroll engine with cascade spring animations"
```

---

### Task 8: 根视图 — AppleMusicLyricsRootView

**Files:**
- Create: `LyricsX/AppleMusicLyrics/AppleMusicLyricsRootView.swift`

- [ ] **Step 1: 创建 AppleMusicLyricsRootView.swift**

```swift
import SwiftUI
import Combine
import LyricsXFoundation
import MusicPlayer

@available(macOS 15, *)
struct AppleMusicLyricsRootView: View {

    @State private var currentLyrics: Lyrics?
    @State private var currentLineIndex: Int?
    @State private var playbackTime: TimeInterval = 0
    @State private var artwork: NSImage?
    @State private var interactionState = InteractionStateModel()
    @State private var karaokeMode: KaraokeMode = .characterLevel

    private let playbackTimerPublisher = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var backgroundMode: Int {
        defaults[.appleMusicLyricsBackgroundMode]
    }

    var body: some View {
        ZStack {
            BackgroundView(artwork: artwork, backgroundMode: backgroundMode)
                .ignoresSafeArea()

            if let lyrics = currentLyrics {
                lyricsContent(lyrics: lyrics)
            } else {
                noLyricsView
            }

            // Interaction state button overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    interactionButton
                        .padding(20)
                }
            }
        }
        .onReceive(AppController.shared.$currentLyrics.receive(on: DispatchQueue.main)) { lyrics in
            currentLyrics = lyrics
            artwork = selectedPlayer.currentTrack?.artwork
        }
        .onReceive(AppController.shared.$currentLineIndex.receive(on: DispatchQueue.main)) { index in
            currentLineIndex = index
        }
        .onReceive(playbackTimerPublisher) { _ in
            playbackTime = selectedPlayer.playbackTime
        }
    }

    // MARK: - Lyrics Content

    @ViewBuilder
    private func lyricsContent(lyrics: Lyrics) -> some View {
        AppleMusicLyricsScrollView(
            lyrics: lyrics,
            highlightedLineIndex: currentLineIndex,
            playbackTime: playbackTime,
            karaokeMode: karaokeMode,
            interactionState: interactionState,
            onSeek: { time in
                selectedPlayer.playbackTime = time - (lyrics.adjustedTimeDelay)
            }
        )
    }

    // MARK: - No Lyrics

    private var noLyricsView: some View {
        Text("No Lyrics")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.4))
    }

    // MARK: - Interaction Button

    @ViewBuilder
    private var interactionButton: some View {
        Button {
            interactionState.toggleIsolation()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 36, height: 36)

                if interactionState.state == .countingDown {
                    Circle()
                        .trim(from: 0, to: interactionState.delegationProgress)
                        .stroke(Color.white.opacity(0.6), lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: interactionState.state == .isolated ? "lock.fill" : "arrow.down.to.line")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .opacity(interactionState.isDelegated ? 1.0 : 0.0)
        .animation(.smooth(duration: 0.3), value: interactionState.isDelegated)
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/AppleMusicLyricsRootView.swift
git commit -m "feat(apple-music-lyrics): add root SwiftUI view with data subscriptions"
```

---

### Task 9: 窗口控制器 — AppleMusicLyricsWindowController

**Files:**
- Create: `LyricsX/AppleMusicLyrics/AppleMusicLyricsWindowController.swift`

- [ ] **Step 1: 创建 AppleMusicLyricsWindowController.swift**

```swift
import AppKit
import SwiftUI

@available(macOS 15, *)
final class AppleMusicLyricsWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let rootView = AppleMusicLyricsRootView()
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.setContentSize(NSSize(width: 400, height: 600))
        window.minSize = NSSize(width: 300, height: 400)
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("AppleMusicLyricsWindow")

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)

        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        defaults[.isShowLyricsHUD] = false
    }

    func toggleWindowLevel() {
        guard let window else { return }
        if window.level == .normal {
            window.level = .floating
        } else {
            window.level = .normal
        }
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目并验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add LyricsX/AppleMusicLyrics/AppleMusicLyricsWindowController.swift
git commit -m "feat(apple-music-lyrics): add window controller with transparent titlebar"
```

---

### Task 10: 集成到 AppDelegate — #available 分支

**Files:**
- Modify: `LyricsX/Component/AppDelegate.swift`

- [ ] **Step 1: 在 AppDelegate 中添加新窗口控制器属性**

在 `AppDelegate` 类中，找到 `lazy var lyricsHUD: LyricsHUDWindowController = .create()` 行。在其后添加：

```swift
    @available(macOS 15, *)
    private lazy var appleMusicLyricsWindowController = AppleMusicLyricsWindowController()
```

- [ ] **Step 2: 修改 applicationDidFinishLaunching 中的 HUD 启动逻辑**

找到 `AppDelegate.applicationDidFinishLaunching` 中的：

```swift
        if defaults[.isShowLyricsHUD] {
            lyricsHUD.showWindow(nil)
        }
```

替换为：

```swift
        if defaults[.isShowLyricsHUD] {
            if #available(macOS 15, *) {
                appleMusicLyricsWindowController.showWindow(nil)
            } else {
                lyricsHUD.showWindow(nil)
            }
        }
```

- [ ] **Step 3: 修改 showLyricsHUD 菜单动作**

找到 `@IBAction func showLyricsHUD(_ sender: Any?)` 方法，替换整个方法体为：

```swift
    @IBAction func showLyricsHUD(_ sender: Any?) {
        if defaults[.isShowLyricsHUD] {
            if #available(macOS 15, *) {
                appleMusicLyricsWindowController.close()
            } else {
                lyricsHUD.close()
            }
            defaults[.isShowLyricsHUD] = false
        } else {
            if #available(macOS 15, *) {
                appleMusicLyricsWindowController.showWindow(nil)
            } else {
                lyricsHUD.showWindow(nil)
            }
            defaults[.isShowLyricsHUD] = true
        }

        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 4: 验证编译**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add LyricsX/Component/AppDelegate.swift
git commit -m "feat(apple-music-lyrics): integrate new lyrics window with #available branching"
```

---

### Task 11: 端到端验证与调整

**Files:**
- All files from Tasks 2-10

- [ ] **Step 1: 完整构建验证**

Run: `xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
Expected: BUILD SUCCEEDED with no warnings in our new files

- [ ] **Step 2: 运行应用并手动测试**

启动应用，播放音乐，打开歌词 HUD 窗口：
- 验证新窗口在 macOS 15+ 上正确显示
- 验证歌词行正确加载和高亮切换
- 验证滚动动画是否流畅
- 验证点击跳转是否正常工作
- 验证交互状态机是否正确（手动滚动 → 倒计时 → 回到跟随）
- 验证背景模式切换

- [ ] **Step 3: 对比两种卡拉OK模式**

在 `AppleMusicLyricsRootView` 中切换 `karaokeMode` 为 `.wordLevel` 和 `.characterLevel`，播放有 timetag 数据的歌词（如 `.lrcx` 格式），对比效果。

- [ ] **Step 4: 修复编译错误或运行时问题**

根据测试结果修复任何发现的问题。

- [ ] **Step 5: Final Commit**

```bash
git add -A
git commit -m "fix(apple-music-lyrics): address issues found during end-to-end testing"
```
