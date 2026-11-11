# 0001 - 切换到下一条歌词候选

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-11
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `develop`（未单独开分支）
- **配套文档**: [歌词候选池](../Internal/LyricsCandidatePool.md) —— 实现说明，含与本提案的差异；
  新术语登记在 [项目术语表](../Glossary.md)

## 摘要

新增一个菜单项与全局快捷键「Next Lyrics Candidate」，让用户在当前这首歌的多条候选歌词之间循环切换。
为此 `AppController` 要从现在的「只留擂台赛胜者」改成保留一份完整的候选池；每次切换用一个一闪即逝的
浮层显示「第几条 / 共几条 · 来源」。现有的 Wrong Lyrics 行为原样保留，不在本提案范围内。

## 动机

自动匹配总是选质量分最高的那条，但质量分并不总是对的 —— 翻唱、同名歌、live 版、多版本混排的情况下，
排第一的经常不是用户想要的那条。

现在唯一的纠正手段是打开「搜索歌词」窗口（`Search Lyrics...`）：把窗口激活到前台 → 等它重新搜一遍 →
在列表里逐条点开预览 → 双击选中。对一个 `LSUIElement` 菜单栏应用来说，为了「换一条」而走五步、还要
抢占前台焦点，代价太大。用户实际想要的是一个按键：不对就按一下，再不对再按一下。

还有一个直接证据说明这个缺口存在：用户误以为 Wrong Lyrics 就是「换一条」。它实际做的是把这首歌加进
黑名单 `NoSearchingTrackIds`、清空音乐 App 里的歌词字段、**永久删除本地歌词文件**，然后清屏
（`LyricsX/Component/AppDelegate.swift:369`）—— 语义与「换一条」完全相反，而且不可逆：想恢复只能回到
搜索面板手动选一条，把 id 从黑名单里摘出来（`LyricsX/Search/SearchLyricsViewController.swift:106`）。
一个高频需求被误导到了一个破坏性动作上。

## 前期调研

以下每条都在当前 `develop` 分支上查证过。

- **自动搜索是擂台赛，不是列表** —— `AppController.lyricsReceived`
  （`LyricsX/Component/AppController.swift:493`）每收到一条就与 `currentLyrics` 比优先级，赢了替换、
  输了当场 `return`。**落败的候选没有任何地方持有，随即被释放。** 这是本提案的主要工作量所在。
- **手动搜索面板已经有一份排序好的候选列表** ——
  `SearchLyricsViewController.searchResult: [Lyrics]`（`:20`），用
  `lyricsHasHigherPriority`（`LyricsX/Utility/Global.swift:235`）做插入排序，选中走
  `useLyricsAction`（`:94`）。**排序规则可以直接复用，不需要发明新算法。**
- **两条路径的搜索参数不同** —— 自动搜索 `limit: 5`（`AppController.swift:443`），手动面板
  `limit: 8`（`SearchLyricsViewController.swift:79`）。
- **存在一个「优先级窗口」** —— 默认 5 秒（`lyricsPriorityWindow`）。窗口外到达的直接结果会被
  丢弃，只有 Route B 的 name-recovery 结果豁免（`AppController.swift:466-476`）。**这些迟到结果
  目前连进候选池的机会都没有** —— 它们本身是合法候选，只是不该自动顶掉已上屏的那条。
- **本地缓存命中会直接 `return`，根本不发起网络搜索** —— `AppController.swift:418-425`：本地
  `.lrcx` / `.lrc` 读到就 `return`。所以重启后播老歌、或任何上次已保存过歌词的歌，**内存里一条
  候选都没有**。这是必须单独处理的场景，不能假设候选池非空。
- **本地歌词有加载优先级** —— 开启「读取音乐文件旁边的歌词」时，音乐文件同目录的 `.lrc` 排在
  `~/Music/LyricsX/` 之前（`AppController.swift:387-401`）。切换后若只往默认目录写，下次仍会先
  读到旁边那个旧文件。
- **项目里没有任何一闪即逝的提示组件** —— 对 `Toast` / `Notification` / `Banner` / `Hint` 全库
  grep 无命中。`LyricsHUD/` 是常驻的歌词面板，不是提示。这部分要新写。
- **快捷键机制** —— `MASShortcutBinder` 绑定 UserDefaults key
  （`AppDelegate.swift:188-199`、`Global.swift:151-160`）；偏好页是 `Preferences.storyboard` 里的
  `NSGridView`，每行一个 `MASShortcutView`，靠运行时属性 `associatedUserDefaultsKey` 绑定。
- **菜单位置** —— `Main.storyboard` 的 `Lyrics` 子菜单（tag 202）内，依次是 Show In Finder、
  Wrong Lyrics（tag 203）、Disable Lyrics for Entire Album、Write to iTunes。
- **全局快捷键不经过菜单校验** —— `validateMenuItem`（`AppDelegate.swift:203`）只处理
  `writeToiTunes` 与 `searchLyrics` 两项，其余走 `default: return true`；而快捷键路径本身就不调用
  它。新动作的可用性判断必须写在动作实现里，不能只靠 `validateMenuItem`。

## 提议方案

### 一、候选池落在 `AppController`

新增按优先级排序的候选池与当前位置。排序复用 `lyricsHasHigherPriority`，与手动搜索面板同一规则，
保证两处看到的顺序一致。

`lyricsReceived` 拆成两件独立的事：

1. **入池** —— 只要通过 session id 校验与 `strictSearchEnabled` 过滤就无条件入池，**不看优先级窗口**。
   迟到的直接结果、被现任压住的低分结果，全都留下。
2. **上屏** —— 现有的窗口判断、Route B 优先、优先级比较，一字不改。

也就是说：默认行为完全不变，只是不再把落败者扔掉。

### 二、候选池为空时按键要能自救

本地缓存命中的歌根本没搜过（前期调研第 5 条），候选池必然为空。此时按快捷键**发起一次补充搜索**，
用与自动搜索相同的参数，把结果收进候选池后再切到第二条。用户按这个键的前提就是「当前这条不对」，
让他等一次网络往返，比弹一句「没有其他候选」有用得多。补充搜索期间浮层显示进行中状态。

### 三、用户选定后要「钉住」

手动切换后置 `candidateSelectionIsPinned = true`：后续到达的结果**继续入池**，但**不再自动替换**
`currentLyrics`。否则用户切到第 2 条，两秒后一个高分结果到达，屏幕又跳回去 —— 这是必须堵死的竞态。
钉住状态随切歌一起清除。

### 四、切换后写回本地，让选择能被记住

切换后把新选中的这条 `persist()`，覆盖同一目标路径；开了「自动写入 iTunes」的话一并重写。
这样下次再播这首歌，本地缓存命中的就是用户选定的那条。

**这里有一个必须处理的坑**：如果原来的歌词是从音乐文件旁边加载的（`localURL` 指向音轨目录），而新
选中的这条 `localURL` 为 `nil`，`persist()` 会把它写进默认目录 —— 但下次加载时旁边那个旧文件优先级
更高，用户的选择会被无声地覆盖掉。处理方式：切换后若检测到「旧歌词在音轨旁边、新歌词写去了别处」，
就把这次选择记进一个按 track id 索引的覆盖表，加载时优先查这张表。

### 五、一闪即逝的浮层

新增 `TransientMessageWindowController`：无边框、不夺焦点的 `NSPanel`，显示 `2 / 5 · QQ音乐`，
1.5 秒后淡出。**不叫 HUD**，避免与既有的 `LyricsHUD`（常驻歌词面板）混淆。

### 六、与手动搜索面板打通

`useLyricsAction` 选中时，把面板的 `searchResult` 整体交给 `AppController` 作为新候选池，并把位置
定到选中项。否则用户在面板里选完再按快捷键，会从一个陈旧的位置往下跳，行为无法解释。

### 非目标

- **不动 Wrong Lyrics** —— 包括它永久删除用户自有 `.lrc` 文件这个问题（与
  `3f1c1ab` 建立的 beside-track 只读策略不一致），另案处理。
- **不做「上一条」** —— 循环一圈就能回去。候选通常 5 条以内，不值得再占一个快捷键。
- **不持久化候选池** —— 重启后不保留候选列表，只保留「用户选定的那条歌词」本身。
- **不碰质量分与优先级算法** —— 本提案只负责「让用户能绕过排序结果」，不负责「让排序更准」。
- **不在菜单里列出全部候选** —— 见替代方案。

## 详细设计

### `AppController` 新增状态

```swift
@Published private(set) var lyricsCandidates: [Lyrics] = []
@Published private(set) var selectedCandidateIndex: Int?

/// Set once the user picks a candidate by hand. While pinned, arriving
/// results still enter the pool but never replace `currentLyrics`.
private var candidateSelectionIsPinned = false

private var candidateReplenishTask: Task<Void, Never>?
```

### 入池与上屏的拆分

```swift
func lyricsReceived(lyrics: Lyrics) {
    guard let request = searchRequest,
          lyrics.metadata.request?.id == request.id,
          let track = selectedPlayer.currentTrack else {
        return
    }
    if defaults[.strictSearchEnabled], !lyrics.isMatched() {
        return
    }

    prepare(lyrics, for: track)      // associate / filtrate / recognizeLanguage
    insertIntoCandidatePool(lyrics)  // unconditional — ordering by lyricsHasHigherPriority

    guard !candidateSelectionIsPinned else { return }
    // …existing display-priority logic, unchanged…
}

private func insertIntoCandidatePool(_ lyrics: Lyrics) {
    let insertionIndex = lyricsCandidates.firstIndex {
        lyricsHasHigherPriority(lyrics, over: $0)
    } ?? lyricsCandidates.endIndex
    lyricsCandidates.insert(lyrics, at: insertionIndex)
    if let selectedCandidateIndex, insertionIndex <= selectedCandidateIndex {
        // Keep pointing at the same object after an insertion above it.
        self.selectedCandidateIndex = selectedCandidateIndex + 1
    }
}
```

排序不是稳定的追加，插入点可能落在当前选中项之前，所以 `selectedCandidateIndex` 必须跟着修正 ——
否则用户按一次键会跳到一条他刚看过的歌词上。

### 切换动作

```swift
enum NextCandidateOutcome {
    case switched(index: Int, total: Int, service: String?)
    case replenishing
    case unavailable
}

@MainActor
func advanceToNextCandidate() -> NextCandidateOutcome
```

行为分三种：

| 候选池状态 | 行为 |
|---|---|
| ≥ 2 条 | 位置前进一位，到尾回绕到 0；钉住；`persist()`；返回 `.switched` |
| ≤ 1 条且未在补充搜索 | 起一个补充搜索任务，返回 `.replenishing`；结果到齐后自动切到第二条 |
| 无正在播放的曲目 | 返回 `.unavailable`，`NSSound.beep()` |

### 动作与快捷键接线

```swift
// AppDelegate
@IBAction func nextLyricsCandidate(_ sender: Any?)

// setupShortcuts()
binder.bindShortcut(.shortcutNextLyricsCandidate, to: #selector(nextLyricsCandidate))

// Global.swift
static let shortcutNextLyricsCandidate = Key<String>("ShortcutNextLyricsCandidate")
```

`validateMenuItem` 增一条：`selectedPlayer.currentTrack != nil` 才可用。

### 浮层

```swift
@MainActor
final class TransientMessageWindowController: NSWindowController {
    static let shared: TransientMessageWindowController
    func present(message: String, dismissAfter duration: TimeInterval = 1.5)
}
```

面板取 `.nonactivatingPanel`、`level = .floating`、`ignoresMouseEvents = true`，显示在当前鼠标所在
屏幕的下方居中。连续按键时重置计时器而不是叠加多个面板。

## 替代方案考量

- **复用 Wrong Lyrics 的快捷键与菜单项**（把它改造成「下一条」）—— 用户已明确选择保留 Wrong Lyrics
  作为独立功能。它的「彻底拉黑这首歌」语义仍有用，只是被误当成了换歌词。
- **在菜单里列出全部候选、打勾标出当前项** —— 表达力更强（可跳选、可回退），但要维护一个动态子菜单
  并处理搜索期间的实时增长，工作量明显更大。**留作后续提案**：本提案的候选池正是它的前置条件。
- **不建候选池，每次按键重新搜索并取第 N 条** —— 免去状态管理，但每按一次都要等网络往返；更糟的是
  provider 返回顺序不稳定，「第 N 条」在两次搜索之间可能指向不同歌词，用户按三次可能绕回原点。
- **用系统通知代替浮层** —— `LSUIElement` 应用要申请通知权限（多一个授权弹窗），通知中心还有聚合与
  延迟，用来做按键即时反馈太慢。
- **把候选池放进手动搜索面板、快捷键去驱动那个窗口** —— 面板的生命周期绑在窗口上，窗口没开时列表
  是空的，且它的搜索参数（`limit: 8`）与自动搜索不同。状态该归 `AppController`。

## 影响

### 用户可见变化

- `Lyrics` 子菜单新增一项 **Next Lyrics Candidate**，位置在 Wrong Lyrics 之前（正向操作排在破坏性
  操作前面）。
- 偏好设置「快捷键」页新增一行 **Switch to next lyrics candidate**，默认**不绑定**任何键。
- 触发后屏幕下方出现一个约 1.5 秒的浮层，显示当前是第几条、共几条、来自哪个源。
- 现有操作习惯没有任何失效：Wrong Lyrics、搜索面板、写入 iTunes 全部保持原样。

### 可发现性

- 主入口是菜单项，与既有的歌词操作并列，用户在同一个子菜单里就能看到。
- 快捷键默认留空，与项目现有惯例一致（所有快捷键都由用户自行绑定）。
- 候选池本身没有开关，默认始终启用 —— 它只是「不再丢弃已经拿到的搜索结果」，不产生额外网络请求，
  多占的内存是几条歌词文本，加开关反而是负担。

### 数据与配置兼容

- 新增一个 UserDefaults key `ShortcutNextLyricsCandidate`（`String`），缺省为空即不绑定，旧版本
  配置无需迁移。
- 「音轨旁边歌词」的选择覆盖表是新增数据；缺失时退回现有加载顺序，不影响旧配置。
- 已保存的 `.lrcx` / `.lrc` 文件格式不变。切换会覆盖写同一路径，与现有 `persist()` 的行为一致。

### 平台与最低版本

不变，仍是 macOS 12+（`Config/Project-Debug.xcconfig`）。仅 macOS，无跨平台差异。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle 更新流程。

## 落地步骤

每一步都应能单独构建通过。

1. **候选池与入池/上屏拆分** —— `AppController` 加状态与 `insertIntoCandidatePool`，`lyricsReceived`
   拆成两段，`currentTrackChanged` 里清空池与钉住状态。此步不改变任何可见行为，
   `LyricsXFoundationTests` 应全绿。
2. **`advanceToNextCandidate` 及补充搜索** —— 含回绕、钉住、`persist()`、写入 iTunes。
3. **`TransientMessageWindowController`** —— 独立组件，可单独起一个临时入口验证外观。
4. **接线** —— `AppDelegate` 动作、`Global.swift` 的 key、`setupShortcuts`、`validateMenuItem`；
   `Main.storyboard` 菜单项与 `Preferences.storyboard` 快捷键行（`NSGridView` 插一行）；
   `Localizable.xcstrings` / `Main.xcstrings` 补中英文案。
5. **beside-track 覆盖表** —— 只在检测到路径错配时启用，附单元测试。
6. **搜索面板打通** —— `useLyricsAction` 移交候选池。
7. **测试** —— 在 `LyricsXFoundationTests` 增补：插入排序后的位置修正、回绕、钉住后不被替换。
   这三条都是纯策略，不需要网络也不需要 GPU 会话。

**收尾时必须判断两件事**（结果写进决策日志）：

- 要不要配套实现说明 —— 「钉住」与 beside-track 覆盖表都属于「代码本身看不出来、下次维护会踩」的
  决策，倾向于写一篇。
- 有没有引入新术语 —— 「候选池」「钉住」是本项目自造词，倾向于登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-11 | Created as Draft | 起因：用户误以为 Wrong Lyrics 是「换一条歌词」，实际它是拉黑并删除本地文件。真实需求是「自动匹配的第一条不对时，一键换下一条」。 |
| 2026-08-11 | 确定入口方案 | 用户选择新增独立菜单项与快捷键，Wrong Lyrics 原样保留；其永久删除用户 `.lrc` 文件的问题另案处理。 |
| 2026-08-11 | 确定反馈方案 | 用户选择一闪即逝的浮层显示「序号 / 总数 · 来源」，而非无反馈或菜单内列出全部候选。后者留作后续提案。 |
| 2026-08-11 | Accepted → In Progress | 用户批准方案，开始实现。 |
| 2026-08-11 | 配套文档判断 | **写**。「钉住」与覆盖表都属于「代码本身看不出来、下次维护会踩」的决策，落在 [歌词候选池](../Internal/LyricsCandidatePool.md)。不写使用指南 —— 这个功能对调用方没有 API 契约，菜单项和快捷键本身就是全部说明。 |
| 2026-08-11 | 术语表判断 | **登记**。新建 [项目术语表](../Glossary.md)，收录候选池、钉住、补充搜索、覆盖表，并顺带补上此前一直没有落纸的 Route B、优先级窗口、beside-track 歌词。 |
| 2026-08-11 | In Progress → Implemented | 干净构建 0 error、无新增警告；`LyricsXFoundationTests` 34 项通过（退出码 0）。落地步骤第 7 条的「钉住后不被替换」**未能**做成自动化测试 —— 它是 `AppController` 的状态，而 app target 没有测试宿主，只能手工验证，已记入实现说明的「已知空白」。 |
| 2026-08-11 | 修复实现缺口 | 首版漏了提案「入池无条件、窗口只管上屏」这一条：优先级窗口外的直接结果在 `searchTask` 里被直接丢弃，连 `lyricsReceived` 都没调用，因此也没进候选池。改为照常入池、打上 `arrivedAfterPriorityWindow` 标记后拒绝上屏。标记挂在 `Lyrics` 上而非做成参数，是因为封面加分异步落地，`applyArtworkBonus` 必须能看到同一个事实，否则迟到结果会绕过正门从封面这条路上屏。 |
| 2026-08-11 | 补上欠的测试 | 借上一条的重构，把「能不能上屏」的完整判定抽成 `LyricsDisplayEligibilityPolicy`（纯函数，可测）。落地步骤第 7 条欠下的「钉住后不被替换」由此补上，含一条穷举所有输入组合的断言。`LyricsXFoundationTests` 增至 42 项，全部通过（退出码 0）。 |
