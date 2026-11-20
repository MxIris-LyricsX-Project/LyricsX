# Draft - 歌词源可以单独关掉

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-20
- **最后更新**: 2026-11-20
- **所属愿景**: 无
- **关联提案**: [0003 歌词源排序模式](0003-source-ordering-modes.md)（同一个设置页、同一张歌词源表）；
  [Draft 拆分 LyricsXFoundation](draft-split-lyricsx-foundation.md)（若它先落地，本提案的新文件改放进 `LyricsPolicies`）
- **实现分支 / PR**: `feature/lyrics-source-switches`（LyricsX），功能树 `.worktrees/MxIris-LyricsX-Project-LyricsSourceSwitches`（父仓库）
- **配套文档**: 待定 —— 落地时在 `Documentations/Internal/LyricsSourceOrdering.md` 补一节「关掉的歌词源」
- **网页版**: 同目录同名的 `.html`

## 摘要

「设置 → 歌词源」页的歌词源表里，每个歌词源名字前加一个复选框，默认全部勾选。取消勾选的歌词源不再参与任何联网搜索——
换歌时的自动搜索、手动搜索面板、「下一条候选」快捷键都不会再向它发请求，也就不会再出现它的歌词。设置存成一个
「被关掉的歌词源」列表（`DisabledLyricsSources`，存 `LyricsProviders.ServiceID` 的 rawValue），空列表即全开，
以后 LyricsKit 新增的歌词源默认也是开的。判断逻辑是 `LyricsXFoundation` 里的一个纯值类型 `LyricsSourceSwitches`，
有单元测试；`AppController.updateLyricsManager()` 只为开着的歌词源创建 provider。

## 动机

- **现在没有办法排除一个歌词源**：`AppController.updateLyricsManager()`（`LyricsX/Component/AppController.swift:274`）
  每次都把五个免凭据的歌词源（NetEase、QQMusic、Kugou、LRCLIB、Musixmatch）全部装进 `LyricsProviders.Group`，
  token 有效时再加 Apple Music。用户能调的只有排序：0003 的三种排序模式与拖动排序只决定「谁排前面」，
  不决定「谁参与」。
- **排序挡不住不想要的歌词**：默认的「只按匹配分数」模式下，一个用户不信任的歌词源只要分数高就会上屏；
  即使改成「按歌词源顺序」并把它拖到最后，别的源都没结果时它仍然会上屏，并且照样出现在搜索面板与候选池里。
- **有些源对某些用户只有坏处**：所在地区连不上的源每次搜索都白等到超时；某个源的歌词质量对用户的曲库系统性地差
  （例如时间轴总是对不上）时，用户只能一首首手动换掉。关掉它是最直接的办法，也省掉了无用的网络请求。

## 前期调研

- **歌词源是怎么装进来的**
  - `LyricsProviders.ServiceID`（LyricsKit，`LyricsKit/Sources/LyricsService/Provider/Service.swift:12`）是
    `String` rawValue 的 `CaseIterable` 枚举：`netease`、`qq`、`kugou`、`musixmatch`、`lrclib`、`appleMusic`；
    `displayName` 分别是 `NetEase`、`QQMusic`、`Kugou`、`Musixmatch`、`LRCLIB`、`Apple Music`。
  - 每个 `LyricsProviders.Service` 都带 `id: ServiceID`，`create(_:)` 造出 provider。免凭据的四个是
    `Service<EmptyOptions>`，Musixmatch 是 `Service<MusixmatchOptions>`，Apple Music 是 `Service<AppleMusicOptions>`。
    **LyricsKit 已有按 ID 挑选歌词源所需的一切，不需要发新版本。**
  - `updateLyricsManager()`（`AppController.swift:274-332`）先装免凭据的五个（`:279-286`），再在 Apple Music token
    检查通过后整组替换成「五个 + Apple Music」（`:324-329`）。它有代号计数器 `lyricsManagerUpdateGeneration`，
    后发起的调用会让先发起、还在等 token 检查的那次作废。
  - 调用方：初始化（`:271`）、原名恢复开关或播放器变化（`:183`）、实验室页的 Apple Music 输入框
    （`PreferenceLabViewController.swift:259`、`:738` 等）——设置页直接调用它是现成的做法。
- **所有联网搜索都走同一个 `lyricsManager`**
  - 换歌时的自动搜索：`AppController.swift:583`。
  - 「下一条候选」快捷键在候选池用完后补搜：`AppController.swift:1369`。
  - 手动搜索面板：`SearchLyricsViewController.swift:17` 直接读 `AppController.shared.lyricsManager`。
  - 所以只要 `lyricsManager` 里没有某个源，三条路径都不会再得到它的歌词。
- **一个源都不开时不会卡住**：`LyricsProviders.Group.lyrics(for:)`（`LyricsKit/.../Provider/Group.swift:35`）在
  `providers` 为空时 task group 立即结束并 `finish()`；自动搜索随即走「搜索没结果就读歌词库」的现有分支
  （`loadLibraryLyricsIfSearchFoundNothing`）。
- **已保存的歌词分辨不出来源**：歌词库 `.lrcx` 不记录 `service`。2026-11-20 统计本机 `~/Music/LyricsX` 的 2891 个文件，
  元数据标签只有 `ti`、`ar`、`offset`、`by`、`al`、`length`、`id`、`total`、`hash`、`kana`、`lang`、`lxpick` 等，
  没有任何一个记录歌词源；`[by:Kugou]` 是歌词作者字段，不可靠（同一库里还有 `[by:QQ音乐动态歌词]`、个人用户名等上百种值）。
  因此「关掉的源」只能作用于联网搜索，作用不到已经存下来的歌词。
- **歌词源表现在的样子**（`LyricsX/Preferences/PreferenceSourceViewController.swift`、
  `Preferences.storyboard` 场景 `KTZ-mJ-lpY`）
  - 两列：`priority`（序号）和 `source`（名字，storyboard 原型单元格 `VGV-SG-dwt`，
    `Preferences.storyboard:2128-2150`）。行是 `displayName` 字符串，顺序存在 `LyricsSourcePriorityOrder`。
  - 「只按匹配分数」模式下整张表 `isEnabled = false`、`alphaValue = 0.5`（`:63-64`）。**这个模式是默认值**，
    表一旦放进复选框就必须在所有模式下都能点，所以「禁用整张表」的做法要改成「只禁止拖动、只淡化序号」。
  - 原型单元格的 `KUU-qx-NSS` / `ow1-De-Qmh` 在 `mul.lproj/Preferences.xcstrings` 里没有条目，删掉它不影响翻译。
- **偏好键怎么取默认值**：`GenericID` 的 `Key<[String]>` 未注册时读出空数组（`noSearchingTrackIds` 就没在
  `UserDefaults.plist` 注册，`AppController` 直接 `.contains`）。新键沿用这一点，不需要改 `UserDefaults.plist`。
- **API 先例**：`NSSegmentedControl` 的 `isEnabled(forSegment:)` / `setEnabled(_:forSegment:)`——「逐项开关」在
  AppKit 里就是这对名字。

## 提议方案

1. **设置页**：歌词源表的「来源」一列改成复选框，标题就是歌词源名字，默认勾选。取消勾选立即保存并重建 `lyricsManager`。
   表在三种排序模式下都可以点；排序模式不看顺序时（「只按匹配分数」），只是不能拖动、序号淡化显示，
   代替原来整张表变灰。复选框带一句提示（tooltip）：「从这个歌词源搜索歌词」。
2. **存储**：新偏好键 `DisabledLyricsSources: [String]`，存被关掉的歌词源的 `ServiceID.rawValue`。存「关掉的」而不是
   「开着的」，这样空列表就是全开，以后新增的歌词源也默认开着。读不懂的值（更新的版本写进来的未知歌词源）原样保留。
3. **策略**：`LyricsXFoundation` 新增值类型 `LyricsSourceSwitches`，负责「某个源开没开」与「开关之后存什么」，
   单元测试覆盖。
4. **搜索**：`updateLyricsManager()` 读开关，只为开着的歌词源调用 `create(_:)`。Apple Music 的 token 检查照常进行
   （实验室页的状态行要用它的结果），只是检查通过后，Apple Music 也要开着才装进去。
5. **生效时机**：下一次搜索生效。屏幕上正显示的歌词、本首歌已经收集到的候选不动；正在进行的那次搜索沿用旧的那组歌词源跑完。

### 非目标

- **不过滤已保存的歌词**：歌词库、歌曲旁边的 `.lrc` / `.lrcx`、写进「音乐」的歌词都不记录来源（见前期调研），无从判断。
  想让某首歌重新搜索，用现有的「忽略已保存的歌词」开关或手动搜索。
- **不影响歌词以外的联网请求**：面板高清封面查 NetEase 曲库（0028）、Apple Music 原名恢复插件、Apple Music token 检查
  都各有自己的开关，不跟着歌词源开关走。
- **不按播放器分别设置**：一套开关全局生效。
- **全关时不加额外提示**：一个都不开是合法设置（只用本地歌词），搜索面板此时搜不到任何结果，不另做说明。
- **不改动排序**：关掉的源仍留在表里原来的位置，重新打开后排序不变。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `LyricsXPackage/Sources/LyricsXFoundation/LyricsSourceSwitches.swift` · `LyricsSourceSwitches` | 新增 | 值类型：由存储的 rawValue 列表构造；`isEnabled(_:)`、`setEnabled(_:for:)`；`disabledSourceIdentifiers` 供写回 | 开关的唯一判断处，脱离 `UserDefaults` 便于测试 | 1 |
| `LyricsXPackage/Tests/LyricsXFoundationTests/LyricsSourceSwitchesTests.swift` | 新增 | 默认全开、关掉 / 重新打开、重复关闭只记一次、未知值保留 | 锁定存储格式与默认值 | 1 |
| `LyricsX/Utility/Global.swift` · `UserDefaults.DefaultsKeys` | 修改 | 加 `disabledLyricsSources = Key<[String]>("DisabledLyricsSources")`，放在 `lyricsSourcePriorityOrder` 旁 | 新偏好键 | 2 |
| `LyricsX/Component/AppController.swift` · `updateLyricsManager()` | 修改 | 免凭据的源按开关过滤后再 `create`；Apple Music 在 token 通过且开着时才加入 | 关掉的源不再被请求 | 2 |
| `LyricsX/Preferences/PreferenceSourceViewController.swift` | 修改 | 行带上 `ServiceID`；「来源」列改用代码创建的复选框单元格；`toggleSource(_:)` 保存并调 `updateLyricsManager()`；`updateUI()` 不再禁用整张表，改为序号淡化；不看顺序时 `writeRowsWith` 拒绝拖动 | 默认模式下复选框也要能点 | 3 |
| `LyricsX/Supporting Files/Base.lproj/Preferences.storyboard` · 原型单元格 `VGV-SG-dwt` | 删除 | 删掉「来源」列不再使用的原型单元格（`:2128-2150`），列本身保留 | 单元格改由代码创建，留着是死代码 | 3 |
| `LyricsX/Supporting Files/Localizable.xcstrings` | 修改 | 新增 tooltip 文案「Search for lyrics from this source」，补简体 / 繁体中文 | 新界面文案 | 3 |
| `Documentations/Internal/LyricsSourceOrdering.md` | 修改 | 新增一节「关掉的歌词源」：为什么存关掉的 rawValue、为什么表不再整体禁用、为什么管不到已保存的歌词 | 下次维护会踩的决策 | 4 |
| `CLAUDE.md`（LyricsX） | 修改 | `LyricsXFoundationTests` 覆盖范围里加一句「哪些歌词源被关掉」 | 测试清单与代码同步 | 4 |
| `Documentations/Evolutions/draft-lyrics-source-switches.md`（及 `.html`）、两份索引 | 修改 | 落地时取号、状态改 Implemented | 提案收尾 | 4 |

## 架构图

改了什么：

```text
LyricsXFoundation/
+ LyricsSourceSwitches            stored [String] -> isEnabled(ServiceID)
  LyricsSourceOrderingPolicy      (unchanged)

LyricsX app
  Global.swift
+   DefaultsKeys.disabledLyricsSources   "DisabledLyricsSources": [String]
  PreferenceSourceViewController
~   source column: text field -> checkbox (title = displayName)
~   updateUI: table always enabled; priority column dimmed when order unused
~   drag: refused when order unused
+   toggleSource(_:) -> save -> AppController.updateLyricsManager()
  AppController.updateLyricsManager()
~   [netease, qq, kugou, lrclib, musixmatch]
~     .filter(switches.isEnabled) -> create()
~   appleMusic: token authorized && switches.isEnabled(.appleMusic)
  Preferences.storyboard
-   prototype cell VGV-SG-dwt (source column)
```

数据流：

```text
checkbox click
  -> PreferenceSourceViewController.toggleSource(_:)
       -> LyricsSourceSwitches.setEnabled(_:for:)
       -> defaults[.disabledLyricsSources] = switches.disabledSourceIdentifiers
       -> AppController.updateLyricsManager()
            -> LyricsSourceSwitches(disabledSourceIdentifiers: defaults[...])
            -> lyricsManager = LyricsProviders.Group(providers: enabled only)

next search (track change / search panel / next-candidate refill)
  -> lyricsManager.lyrics(for:)        disabled sources were never created
```

## 详细设计

### `LyricsSourceSwitches`

```swift
import Foundation

/// Which lyrics sources the user has switched off on the Source pane.
///
/// Every source is on unless the user switched it off, so a source that a
/// later LyricsKit adds starts out on. The stored form is the raw values of
/// the switched-off sources; values this build does not know — written by a
/// newer build — are kept as they are, so switching another source here does
/// not switch that one back on.
public struct LyricsSourceSwitches: Equatable, Sendable {
    /// What the preference stores, in the order the sources were switched off.
    public private(set) var disabledSourceIdentifiers: [String]

    public init(disabledSourceIdentifiers: [String] = []) {
        var seenIdentifiers = Set<String>()
        self.disabledSourceIdentifiers = disabledSourceIdentifiers.filter { seenIdentifiers.insert($0).inserted }
    }

    public func isEnabled(_ service: LyricsProviders.ServiceID) -> Bool {
        !disabledSourceIdentifiers.contains(service.rawValue)
    }

    public mutating func setEnabled(_ isEnabled: Bool, for service: LyricsProviders.ServiceID) {
        disabledSourceIdentifiers.removeAll { $0 == service.rawValue }
        if !isEnabled {
            disabledSourceIdentifiers.append(service.rawValue)
        }
    }
}
```

- 名字取「switches」：界面上就是一排开关，`isEnabled` / `setEnabled(_:for:)` 照 `NSSegmentedControl` 的逐项开关命名。
- 存 rawValue 而不是 `displayName`：`LyricsSourcePriorityOrder` 存的是 `displayName`，那是历史做法，显示名改一个字
  旧设置就对不上；rawValue 是 LyricsKit 的标识符，不随显示改变。
- 构造时去重，避免手改 plist 或旧 bug 写进重复值后「打开一次还关着」。

### `AppController.updateLyricsManager()`

```swift
let sourceSwitches = LyricsSourceSwitches(disabledSourceIdentifiers: defaults[.disabledLyricsSources])
let musixmatchToken = defaults[.musixmatchToken].flatMap { $0.isEmpty ? nil : $0 }
var tokenFreeProviders: [LyricsProvider] = [
    LyricsProviders.Service.netease,
    LyricsProviders.Service.qq,
    LyricsProviders.Service.kugou,
    LyricsProviders.Service.lrclib,
]
.filter { sourceSwitches.isEnabled($0.id) }
.map { $0.create() }
if sourceSwitches.isEnabled(.musixmatch) {
    tokenFreeProviders.append(LyricsProviders.Service.musixmatch.create(.init(usertoken: musixmatchToken)))
}
// ... token check unchanged ...
appleMusicTokenCheck = .finished(status)
if appleMusicTokenCheck.includesAppleMusicLyrics, sourceSwitches.isEnabled(.appleMusic) {
    lyricsManager = LyricsProviders.Group(
        providers: tokenFreeProviders + [LyricsProviders.Service.appleMusic.create(options)],
        plugins: plugins
    )
}
```

- 原来的顺序（NetEase、QQMusic、Kugou、LRCLIB、Musixmatch）保持不变。
- token 检查无论 Apple Music 开没开都照做：它的结果给实验室页的状态行看，用户可能正先配 token、后打开源。
- 不新增 `defaults` 订阅：开关只在歌词源页改，那里直接调用 `updateLyricsManager()`，与实验室页一致。
  原有订阅链的 `removeDuplicates` 只比较原名恢复开关与播放器名，把新键加进去反而会被它吞掉。

### 设置页

- 行模型：`sourcePriorityOrder: [String]`（`displayName`）保持不变，另用私有辅助把 `displayName` 映射回 `ServiceID`
  （`LyricsProviders.ServiceID.allCases.first { $0.displayName == name }`）。
- 「来源」列：`makeView(withIdentifier: "sourceSwitch")` 复用，取不到就新建一个 `NSTableCellView`，里面放
  `NSButton(checkboxWithTitle:target:action:)`，左对齐、垂直居中、前缘 2 pt（与原文本框一致）。`state` 取
  `sourceSwitches.isEnabled(serviceID)`，`toolTip` 取本地化文案。
- `toggleSource(_ sender: NSButton)`：`sourceTableView.row(for: sender)` 取行，改 `sourceSwitches`，写回
  `defaults[.disabledLyricsSources]`，再 `Task { @MainActor in await AppController.shared.updateLyricsManager() }`。
- `updateUI()`：删掉 `isEnabled` / `alphaValue` 两行；改为 `reloadData(forRowIndexes:columnIndexes:)` 刷新序号列，
  序号文字在 `!mode.usesSourcePriorityOrder` 时用 `.disabledControlTextColor`，否则 `.labelColor`。
- `tableView(_:writeRowsWith:to:)`：`!lyricsSourceOrderingMode.usesSourcePriorityOrder` 时返回 `false`，
  保持原来「这个模式下不能拖」的行为。
- 删除 storyboard 里「来源」列的原型单元格之前，先确认 Xcode 没打开 `Preferences.storyboard`，否则保存会被覆盖。

## 替代方案考量

- **存「开着的」歌词源列表**：以后新增的歌词源会默认关闭，与「默认全开」相反；还要给没存过的老用户造一份初始列表。否。
- **复用 `displayName` 当标识符**（与 `LyricsSourcePriorityOrder` 一致）：显示名是界面文字，改名即失配。
  一致性不值得把新设置也建在这个弱点上。否。
- **照常搜索、再把关掉的源的结果丢掉**：请求照发，连不上的源照样拖慢搜索，与用户关掉它的目的相反。否。
- **在 LyricsKit 里加「启用的源」参数**：LyricsKit 已经按源提供工厂，挑选在 App 里做就够；改 LyricsKit 要发新版本、
  改 `exact:` 版本号，收益为零。否。
- **在 storyboard 里新增一列复选框**：多一列窄列加表头，表格更挤；复选框带标题本身就说明了开关的是哪个源。
  而且在 storyboard 里画新列要算 frame、改约束，比代码创建单元格风险大。否。
- **切换后立即重搜当前歌曲**：会把屏幕上正在看的歌词换掉，用户只是在调设置，不应打断播放。下一次搜索生效即可。否。

## 影响

### 用户可见变化

- 「设置 → 歌词源」表的「来源」一列变成复选框，默认全部勾选。
- 「只按匹配分数」模式下，表不再整体变灰：复选框可以点，只是不能拖动、序号淡化。拖动排序在另外两种模式下照旧。
- 关掉的歌词源不再出现在自动搜索、手动搜索面板和「下一条候选」里。

### 可发现性

- 开关就在歌词源表里，用户调排序时自然会看到；默认全开，现有用户的行为不变。
- 复选框的 tooltip 说明它的作用。

### 数据与配置兼容

- 新键 `DisabledLyricsSources`，未写入时为空数组，即全开，不需要迁移。
- 降级到旧版本：旧版本不认识这个键，所有歌词源恢复开启；再升级回来，开关设置仍在。
- 更新的版本写入的未知标识符原样保留。
- 已保存的歌词不受影响（见非目标）。

### 平台与最低版本

无变化。只用到 macOS 10.12 起就有的 `NSButton(checkboxWithTitle:target:action:)`，部署目标仍是 macOS 12。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。下一版的发布说明加一条「歌词源可以单独关掉」。

## 落地步骤

1. **策略类型与测试**（已完成）—— 改动地图第 1、2 行
   - 行为：`everySourceIsEnabledByDefault`
   - 行为：`switchingASourceOffRecordsItsIdentifier`
   - 行为：`switchingASourceBackOnForgetsIt`
   - 行为：`switchingOffTwiceRecordsOnce`
   - 行为：`duplicateStoredIdentifiersCollapse`
   - 行为：`identifiersFromANewerBuildSurviveAnotherSwitch`
2. **搜索只装开着的源** —— 第 3、4 行
   - 行为：没有关掉任何源时，`lyricsManager` 的 provider 与改动前一致（同样的五个 + 有效 token 时的 Apple Music）
   - 行为：关掉的源不出现在 `lyricsManager.providers` 里（App 没有测试 target，用构建 + 运行时日志或断点核对）
   - 行为：Apple Music 关掉时 token 检查仍然执行、状态行照常更新
3. **设置页复选框** —— 第 5、6、7 行
   - 行为：三种排序模式下复选框都能点，勾选状态在重开设置窗口后保持
   - 行为：「只按匹配分数」模式下不能拖动、序号淡化；另外两种模式下拖动照旧
   - 行为：取消勾选后手动搜索面板不再出现该源的结果
4. **文档与收尾** —— 第 8、9、10 行
   - 行为：`swift test --filter LyricsXFoundationTests` 全绿；App 的 Debug 构建通过

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计在 `Internal/LyricsSourceOrdering.md` 补一节即可，不单独成文。
- **有没有引入新术语** —— 「歌词源开关」是否进术语表，落地时判断。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-20 | Created as Draft | 用户希望能单独关掉某个歌词源：默认全开，关掉的源在获取歌词时不再返回结果。 |
| 2026-11-20 | Accepted | 用户批准，开始实现。 |
| 2026-11-20 | In Progress | 在功能树 `MxIris-LyricsX-Project-LyricsSourceSwitches` 的 `feature/lyrics-source-switches` 上实现。 |
