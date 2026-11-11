# 0005 - 快捷键库从 MASShortcut 换成 KeyboardShortcuts

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-11
- **所属愿景**: 无
- **关联提案**: [0001 切换到下一条歌词候选](0001-next-lyrics-candidate.md)（它新增的「下一条歌词候选」是当前 10 个快捷键之一，本提案连同它一起搬）
- **实现分支 / PR**: 待定
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

把全局快捷键的录制与触发从 [MASShortcut](https://github.com/shpakovski/MASShortcut) 换成
[sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)。
偏好设置「快捷键」页的 10 个录制控件由 `MASShortcutView` 换成 `KeyboardShortcuts.RecorderCocoa`，
全局触发由 `MASShortcutBinder` 换成 `KeyboardShortcuts.onKeyDown(for:)`。

**不迁移已存的快捷键设置**：升级后用户设过的快捷键全部为空，需要重新设置一次。

一个必须先讲清的事实：**`RecorderCocoa` 不能直接放进 storyboard**，它的
`init?(coder:)` 是 `@available(*, unavailable)` 并直接 `fatalError`。可行的做法是在 storyboard
里留一个普通 `NSView` 占位、拉 outlet，在代码里把 recorder 塞进去 —— 这是库作者本人给的做法。

## 动机

**一、MASShortcut 已经归档，不再维护。** GitHub 仓库 `archived: true`，最后一次推送
2022-10-18（`gh api repos/shpakovski/MASShortcut` 实测）。它没有 Swift 6 并发适配，
也不会再有。

**二、它的录制控件是自绘的，所以外观不跟随系统。** `MASShortcutView.m` 的 `drawRect:`
里手工绘制圆角矩形与文字（`drawInRect:withTitle:alignment:state:`，第 202、226 行），
外观由这段绘制代码在 2022 年的样子固定下来。macOS 26 的控件外观已经改过，这个控件与偏好页里
其它系统控件放在一起明显不是一套东西。

**三、换过去以后这个问题不会再出现。** `KeyboardShortcuts.RecorderCocoa` 继承自
`NSSearchField`（`Sources/KeyboardShortcuts/RecorderCocoa.swift:31`），外观完全由系统提供，
系统改版它自动跟进 —— 这一点比「现在长得好看」更要紧。

## 前期调研

- **现状：触发** —— `AppDelegate.setupShortcuts()`（`LyricsX/Component/AppDelegate.swift:195-208`）
  用 `MASShortcutBinder.shared()` 绑定 10 个快捷键；辅助方法在同文件 `:502-521`
  的 `extension MASShortcutBinder`（三个重载：绑闭包、绑 `Selector`、绑「翻转某个 Bool 偏好」）。
- **现状：录制 UI** —— 「快捷键」页是一个 `NSGridView`（`Preferences.storyboard:1316`，
  10 行 × 2 列），第 2 列每格放一个 `customClass="MASShortcutView"` 的 `customView`，
  各带一条 `associatedUserDefaultsKey` 运行时属性指向偏好键（`:1346-1552`）。
  每个都被约束成固定 160 × 19。
- **现状：存储格式与声明不符** —— `Global.swift:156-165` 把 10 个键声明成 `Key<String>`，
  但 `MASShortcutBinder` 实际写入的是 `NSKeyedArchiver` 归档的 `MASShortcut` 对象。
  实测本机 `defaults read com.JH.LyricsX ShortcutShowLyricsWindow` 返回 135 字节的二进制 plist，
  解出来是 `$archiver: NSKeyedArchiver`。归档里两个字段：`"KeyCode"` 与 `"ModifierFlags"`
  （`MASShortcut.m:4-5`），后者是 Cocoa 的 `NSEventModifierFlags`。
- **KeyboardShortcuts 的现状** —— 最新 release `3.0.1`（2026-06-17），仓库活跃，2692 stars。
- **最低系统版本不成问题** —— 它的 `Package.swift` 声明 `.macOS(.v10_15)`，远低于 LyricsX 的 12.0。
- **工具链要求** —— 它的 `Package.swift` 是 `swift-tools-version:6.2`，并开启
  `.defaultIsolation(MainActor.self)` 等 upcoming feature。LyricsXPackage 已经是 Swift 6.2 工具链，
  不构成障碍；但这意味着**不能降级到更老的 Xcode 构建**。
- **`RecorderCocoa` 进不了 storyboard（已查证，不是推测）** ——
  `Sources/KeyboardShortcuts/RecorderCocoa.swift:186`：

  ```swift
  @available(*, unavailable)
  public required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
  }
  ```

  作者在 issue [#14 "Allow to use in XIB"](https://github.com/sindresorhus/KeyboardShortcuts/issues/14)
  里明确拒绝支持：「I have decided to pass on this. SwiftUI is quickly maturing and I personally
  don't have any XIB/Storyboard usage left to warrant maintaining this.」
  同一条 issue 里他给出了替代做法：**在 Interface Builder 里放一个自定义视图占位，拉 outlet，
  在代码里 `addSubview` 一个 `RecorderCocoa`**。issue
  [#173](https://github.com/sindresorhus/KeyboardShortcuts/issues/173) 补了一个坑：
  不给 frame 或约束的话它会以零尺寸渲染，看起来像没加上。
- **存储与 API** ——
  - 键名 `KeyboardShortcuts_<Name.rawValue>`，值是 `Shortcut` 的 JSON
    （`{"carbonKeyCode":…,"carbonModifiers":…}`），写死用 `UserDefaults.standard`
    （`KeyboardShortcuts.swift:578-601`）。LyricsX 这 10 个键本来就在 `.standard`，不冲突。
  - `Name` 的 `rawValue` **不能含 `.`**（用作 KVO key path，`Name.swift:29`）。
  - 触发用 `KeyboardShortcuts.onKeyDown(for:action:)` / `onKeyUp(for:action:)`
    （`KeyboardShortcuts.swift:545`、`:573`）。
  - 另有 `NSMenuItem.setShortcut(for:)`（`NSMenuItem++.swift:108`），能让菜单项自动显示并跟随
    用户设置的快捷键 —— 本提案不用，见非目标。

## 提议方案

### 一、10 个 `KeyboardShortcuts.Name`

在 `Global.swift` 旁边新开一个文件集中声明，`rawValue` 用与旧偏好键**不同**的名字，
避免两套存储在同一个键上互相踩：

```swift
extension KeyboardShortcuts.Name {
    static let toggleMenuBarLyrics = Self("ToggleMenuBarLyrics")
    // …其余 9 个
}
```

### 二、storyboard 保留占位视图，recorder 在代码里插入

10 个格子里的 `customView` **保留原样不动**（id、grid 位置、160 × 19 的约束全部不变），
只把 `customClass="MASShortcutView"` 去掉，让它退回普通 `NSView`。
`PreferenceShortcutViewController` 为这 10 个占位各拉一个 `@IBOutlet`，在 `viewDidLoad` 里
按「占位 → Name」的对应表创建 `RecorderCocoa` 并铺满占位（四边 0 约束）。

这样做而不是「删掉占位、让 view controller 自己造整个 grid」，是因为前者的差异只有
一行 `customClass` 与一段插入代码，布局、行标签、本地化全部不动。

### 三、触发改用 `onKeyDown`

`setupShortcuts()` 保留同样的形状（一个方法、10 行、一眼看完），只把 binder 换掉：

```swift
KeyboardShortcuts.onKeyDown(for: .toggleMenuBarLyrics) {
    defaults[.menuBarLyricsEnabled].toggle()
}
```

`extension MASShortcutBinder` 里那三个重载随之删除；「绑 Selector」那个重载改写成一个
自由函数或 `KeyboardShortcuts` 的扩展，保持 `setupShortcuts()` 的可读性。

### 四、依赖增删

Xcode 项目里加 `KeyboardShortcuts`（`from: "3.0.1"`），移除 `MASShortcut`。

### 非目标

- **不迁移已有快捷键设置。** 用户明确选择重新设置（见决策日志）。技术上可行的迁移路径已在
  「替代方案考量」里留档，将来若改主意可以照着做。
- **不增删快捷键**，仍是现在这 10 个，功能一一对应。
- **不重画偏好页布局** —— 行、标签、顺序、本地化文案全部不动。
- **不接 `NSMenuItem.setShortcut(for:)`** —— 让主菜单项显示快捷键是一个独立的、用户可感知的
  改动（菜单会多出一列快捷键文字），值得单独判断，不塞进换库里。
- **不改这 10 个快捷键的默认值** —— 现在全部无默认值，保持不变。
  `Name(_:initial:)` 支持默认快捷键，但作者自己也提醒别用（抢用户已有的快捷键很讨厌）。
- **不动 `Global.swift` 里那 10 个旧的 `Key<String>` 声明的存在** —— 见「数据与配置兼容」。

## 详细设计

```swift
// LyricsX/Utility/KeyboardShortcutNames.swift（新文件）
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleMenuBarLyrics = Self("ToggleMenuBarLyrics")
    static let toggleKaraokeLyrics = Self("ToggleKaraokeLyrics")
    static let showLyricsWindow = Self("ShowLyricsWindow")
    static let increaseOffset = Self("IncreaseOffset")
    static let decreaseOffset = Self("DecreaseOffset")
    static let writeToiTunes = Self("WriteToiTunes")
    static let searchLyrics = Self("SearchLyrics")
    static let wrongLyrics = Self("WrongLyrics")
    static let nextLyricsCandidate = Self("NextLyricsCandidate")
    static let togglePreferences = Self("TogglePreferences")
}
```

```swift
// LyricsX/Preferences/PreferenceShortcutViewController.swift
class PreferenceShortcutViewController: PreferenceViewController {
    @IBOutlet var toggleMenuBarLyricsRecorderContainer: NSView!
    // …其余 9 个占位

    override func viewDidLoad() {
        super.viewDidLoad()
        // `RecorderCocoa` cannot be instantiated from a storyboard — its
        // `init?(coder:)` is unavailable — so Interface Builder holds an empty
        // container per row and the recorder is inserted here.
        for (container, name) in recorderContainersByShortcutName {
            install(KeyboardShortcuts.RecorderCocoa(for: name), in: container)
        }
    }

    /// Pins the recorder to all four edges. Without constraints (or an explicit
    /// frame) it renders at zero size and reads as simply missing.
    private func install(_ recorder: KeyboardShortcuts.RecorderCocoa, in container: NSView) {
        recorder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(recorder)
        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            recorder.topAnchor.constraint(equalTo: container.topAnchor),
            recorder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
```

```swift
// LyricsX/Component/AppDelegate.swift
private func setupShortcuts() {
    KeyboardShortcuts.onKeyDown(for: .toggleMenuBarLyrics) { defaults[.menuBarLyricsEnabled].toggle() }
    KeyboardShortcuts.onKeyDown(for: .toggleKaraokeLyrics) { defaults[.desktopLyricsEnabled].toggle() }
    KeyboardShortcuts.onKeyDown(for: .showLyricsWindow, perform: #selector(showLyricsHUD))
    // …
}
```

**占位视图的高度约束要重新量。** 现在是 19pt（贴合 `MASShortcutView` 的自绘尺寸）；
`RecorderCocoa` 的固有尺寸是 130 × 24（`RecorderCocoa.swift:156`）。19pt 会把搜索框压扁，
落地时按实际渲染调整这 10 条约束，并相应调整 grid 行高与「快捷键」页的视图高度。

## 替代方案考量

- **Fork MASShortcut，自己把 `MASShortcutView` 改成跟随系统外观** —— 等于接手维护一个已归档的
  Objective-C 库，而且「跟随系统外观」这件事只要还是自绘就永远做不到，下一次系统改版又要再改一遍。
- **KeyHolder（Clipy/KeyHolder）** —— 仍在维护（最后推送 2026-08-09），而且**原生支持 XIB**，
  在「不用改 storyboard」这一点上比 KeyboardShortcuts 强。否掉的理由是生态：424 stars
  对 2692，且 KeyboardShortcuts 已经跟进了 Swift 6 并发（`defaultIsolation(MainActor.self)`）。
  换库的目的是**以后不用再换**，这时维护活跃度与跟进速度比省一次 storyboard 改动重要。
- **用 SwiftUI 的 `KeyboardShortcuts.Recorder` + `NSHostingView`** —— 也能塞进现有 grid，
  但会为了 10 个控件在一个纯 AppKit 的偏好页里引入 SwiftUI 宿主，多一层尺寸协商；
  `RecorderCocoa` 本身就是 `NSView`，没有理由绕这一圈。
- **把 `RecorderCocoa` 直接填进 storyboard 的 `customClass`** —— **做不到**，
  `init?(coder:)` 不可用，运行到该页就崩。这条不是权衡，是硬约束。
- **迁移已存快捷键** —— 用户否决（就那么几个，重设即可）。留档可行路径，以备将来：
  读旧键的 `Data` → `NSKeyedUnarchiver` 解出 `MASShortcut` → 取 `KeyCode` 与
  `ModifierFlags`（Cocoa flags）→ `KeyboardShortcuts.setShortcut(Shortcut(carbonKeyCode:carbonModifiers:), for:)`。
  需要注意本机实测中存在**归档值为 nil**（用户清空过快捷键）的情况，迁移必须容忍。

## 影响

### 用户可见变化

- **所有自定义快捷键在升级后清空，需要重新设置一次。** 这是本次唯一的破坏性变化，
  必须在发布说明里写在最前面。共 10 项，位置不变（偏好设置 →「快捷键」）。
- 录制控件外观从自绘控件变成系统搜索框样式：未设置时显示「Record Shortcut」占位文字
  （该文案由库自带多语言，不再由 LyricsX 的字符串目录提供），点击后录制，已设置时右侧出现清除按钮。
- 录制体验有实质增强：库会**主动拦截**与系统快捷键、与 app 主菜单快捷键冲突的组合，
  并弹出说明性提示，而不是像现在这样静默接受一个不会生效的组合。

### 可发现性

- 偏好页位置、行顺序、行标签全部不变，用户不需要重新找。
- 10 个快捷键**依旧没有默认值**（保持现状）。升级后一片空白配合发布说明即可，
  不做首次启动引导 —— 为一次性事件加引导流程不划算。

### 数据与配置兼容

- **旧的 10 个 `Shortcut*` 偏好键不删、不读、不写**，成为孤儿数据（每个几十到一百多字节）。
  保留的理由是降级：用户装回旧版本时，快捷键还在。
- 新数据写在 `KeyboardShortcuts_*` 系列键上，两套互不干扰。
- 无迁移，因此没有「迁移失败」这个状态；用户看到的就是一页空白的快捷键设置。
- `Global.swift` 里那 10 个 `Key<String>` 声明保留但标注为「已弃用，仅供降级读取」——
  顺带修正一个既有的错误：它们声明成 `String` 而实际存的是归档 `Data`。

### 平台与最低版本

不变（macOS 12+）。KeyboardShortcuts 要求 macOS 10.15，低于本项目。
构建侧要求 Swift 6.2 工具链（依赖的 `Package.swift` 是 `swift-tools-version:6.2`），
LyricsXPackage 已经满足。

### 发布

- 不需要新权限、entitlement 或隐私清单条目。全局快捷键走 Carbon HotKey，与现在相同。
- 不影响公证与 Sparkle 更新。
- **发布说明必须显著提示「快捷键需要重新设置」**，中英两份都要。这是本次唯一需要用户动手的事。

## 落地步骤

1. Xcode 项目加 `KeyboardShortcuts`（`from: "3.0.1"`）依赖，**先不删 MASShortcut** ——
   这一步应能独立构建通过。
2. 新增 `KeyboardShortcutNames.swift`，声明 10 个 `Name`。此时无人使用，仍能独立构建。
3. `setupShortcuts()` 改用 `KeyboardShortcuts.onKeyDown`，删掉 `extension MASShortcutBinder`。
   此时快捷键可触发但还没有 UI 能设置它们 —— 可构建、可运行。
4. storyboard 去掉 10 处 `customClass="MASShortcutView"` 与 `associatedUserDefaultsKey`
   运行时属性，为占位视图拉 outlet；`PreferenceShortcutViewController` 插入 recorder。
   **实际渲染后调整 10 条尺寸约束、grid 行高与页面高度**（19pt → 按 `RecorderCocoa` 的 24pt 固有高度）。
5. 移除 `MASShortcut` 依赖与全部 `import MASShortcut`；`Global.swift` 的 10 个旧键加弃用注释。
6. 补发布说明的「快捷键需重新设置」提示（中英各一份）。
7. 手工验证：10 个快捷键逐个录制 → 触发 → 重启 app 后仍在；录一个与系统冲突的组合，
   确认弹出提示而不是静默接受。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：配套文章、新术语。
目前预判：**大概率需要一篇实现说明** —— 「`RecorderCocoa` 进不了 storyboard，所以 IB 里是空占位」
正是那种「下次维护会踩、代码本身看不出来」的决策。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-11 | Created as Draft | 起因：用户指出 MASShortcut 已无人维护，且其录制控件在 macOS 26 上与系统 UI 不匹配，要求换成 sindresorhus/KeyboardShortcuts。 |
| 2026-08-11 | 查证「支持 Storyboard」的说法 | 用户认为该库支持 Storyboard 与绑定。实测 `RecorderCocoa.init?(coder:)` 标了 `@available(*, unavailable)` 且 `fatalError`，**不能**直接放进 storyboard；作者在 issue #14 明确拒绝支持。可行的是作者本人给的替代做法：IB 里放空占位、代码里 `addSubview`。方案据此确定为「保留占位视图 + 代码插入」，storyboard 的布局与本地化因此仍然不用动。 |
| 2026-08-11 | 不做数据迁移 | 用户决定：快捷键只有 10 个，升级后重新设置即可，不值得为一次性迁移写解归档代码。可行的迁移路径已在「替代方案考量」留档。 |
