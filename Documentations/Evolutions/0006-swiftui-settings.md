# 0006 - 设置界面迁移到 SwiftUI

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-11
- **所属愿景**: 无
- **关联提案**: [0005 换快捷键库](0005-keyboard-shortcuts-library-swap.md)（两者在「快捷键」页正面重叠，先后顺序见「与 0005 的关系」一节）
- **实现分支 / PR**: 待定
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

把 `Preferences.storyboard`（2095 行、6 个页、36 个 Cocoa Bindings 键路径）逐页迁到 SwiftUI，
架构参照同作者的 [RuntimeViewer](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer)：
设置界面是 AppKit 应用里的一座 **SwiftUI 岛**，由 `NSHostingController` 托管，
用 `Form` + `.formStyle(.grouped)` + `Section(header:footer:)` 的系统设置样式，
用一个 `@AppSettings(\.keyPath)` 属性包装器把偏好值桥接成 `Binding`。

**最低系统从 macOS 12 提到 14**（`Form(.grouped)`、`LabeledContent`、`NavigationSplitView`
要 13+，`@Observable` 要 14+）。

**两处不照抄 RuntimeViewer**，都是 LyricsX 的硬约束：

1. **存储仍然是 `UserDefaults`，不是 JSON 文件。** RuntimeViewer 把设置存成 Application Support
   里的 `settings.json`；LyricsX 做不到 —— 它的偏好要跨三个进程共享（主 app、非沙盒的
   LyricsXHelper、沙盒的 LyricsXWidget），还要在迁移期间与仍是 Cocoa Bindings 的 storyboard 页
   读写同一份数据。
2. **必须做本地化。** RuntimeViewer 的设置界面一条本地化都没有（全是英文字面量、无字符串目录）；
   LyricsX 有 16 种语言、约 2100 条译文，且它们现在是按 storyboard 对象 ID 存的，迁移意味着
   **全部重新配键**。

## 动机

**一、改一行设置要动四五个地方，而且没有编译期保护。**

本次会话里实测了两回（0002 加一个复选框、0003 把复选框换成单选组）。加一行设置需要：
storyboard 里加 `gridRow` + 两个 `gridCell` + 一条 `<binding>` → 手算并调整 grid 与视图的设计期
高度 → 往 `.xcstrings` 里按对象 ID 插条目 → 有交互的还要拉 outlet 写 view controller。

其中绑定是**字符串键路径**（`keyPath="values.LoadLyricsBesideTrack"`），拼错了编译器不报错、
运行时静默失效。全项目共 36 处这样的绑定。

**二、storyboard 无法在终端环境里验证。** 这不是抽象的不便：本次会话两次改完 storyboard，
我都只能告诉用户「编译过了，但布局请你在 Xcode 里眼看一遍」，因为渲染结果无从检查。
SwiftUI 的布局是代码，能被审阅、能被 diff 读懂。

**三、外观跟不上系统。** 与 [0005](0005-keyboard-shortcuts-library-swap.md) 同一个理由：
现在的设置页是 `NSTabViewController` + 手摆的 `NSGridView`，行距、分组、标签对齐全是固定值，
和 macOS 13 之后的「系统设置」样式对不上。`Form(.grouped)` 由系统提供这套样式，以后自动跟进。

**四、已经有一个成型的、同作者的参照实现。** RuntimeViewer 的设置模块已经在生产里跑，
它的取舍（不用 SwiftUI `Settings` 场景、不用第三方设置库、`@AppSettings` 包装器、
固定 715pt 宽度）都已经过实践检验，不需要在 LyricsX 上重新试错。

## 前期调研

### LyricsX 侧现状（实测）

- **入口**：`@NSApplicationMain` + `NSMainStoryboardFile = Main`，是经典 AppKit 生命周期。
  **因此 SwiftUI 的 `Settings` 场景不可用**（它要求 SwiftUI `App` 生命周期），
  设置窗口只能由 `NSWindowController` + `NSHostingController` 托管 —— 与 RuntimeViewer 相同。
- **窗口**：`PreferenceWindowController: AutoActivateWindowController, StoryboardWindowController`
  （`LyricsX/Preferences/PreferenceWindowController.swift`，6 行），从 storyboard 加载；
  由 `AppDelegate.togglePreferences(_:)`（`AppDelegate.swift:258`）开合。
- **页容器**：`PreferenceTabViewController: NSTabViewController`，`tabStyle="toolbar"`，
  6 个 `tabViewItem`（`Preferences.storyboard:33-63`）。
- **6 个页的规模**（实测统计）：

  | 页 | 绑定键 | 控件 | 需要特别处理的 |
  |---|---|---|---|
  | 通用 | 12 | button×23、popUpButton×3、textField×8 | 播放器选择是图标 + 单选按钮的自定义排布 |
  | 显示 | 12 | button×7、textField×12、colorWell×6 | `FontSelectTextField` 驱动 `NSFontPanel`；`AlphaColorWell` |
  | 快捷键 | 0 | 10 个录制控件 | 与 0005 重叠 |
  | 过滤 | 1 | button×4、`NSTableView`×1 | 可编辑词表 |
  | 实验室 | 11 | button×15、textField×10 | 弹出 305 行的 `NowPlayingApplicationListViewController` |
  | 歌词源 | 0 | button×3、`NSTableView`×1 | 拖拽重排 |

- **自定义控件**：`AlphaColorWell`（`PreferenceDisplayViewController.swift:58`，强制
  `NSColorPanel.shared.showsAlpha = true`）、`FontSelectTextField`（`LyricsX/View/FontSelectTextField.swift`，
  通过 delegate 回调驱动共享的 `NSFontPanel`）。
- **偏好读写遍布全 app**：`Global.swift` 声明 93 个键，`defaults[.key]` 的调用散布在
  `AppController`、各显示控制器、widget 桥接等处，并且 `AppController` 用
  `defaults.publisher(for:)` 订阅变化（`AppController.swift:106`、`:125`）。
- **三个存储域**（`Global.swift:27-42` 有注释说明为何必须分开）：
  - `UserDefaults.standard` —— 主 app 的偏好；
  - `sharedDefaults`（普通 suite）—— 与**非沙盒**的 LyricsXHelper 共享，
    刻意不用 App Group（非沙盒进程读不到 App Group 偏好）；
  - `groupDefaults`（App Group）—— 与**沙盒**的 LyricsXWidget 共享。
- **本地化规模**（实测）：`mul.lproj/Preferences.xcstrings` 有 **152 个键、16 种语言**，
  平均每键 14.2 条译文（约 2100 条）。键是 storyboard 对象 ID（`au8-ou-Duf.title`）。
- **重配键的可行性**（实测）：152 个键只对应 **102 个不同源字符串**，46 个源字符串被多个对象共用。
  其中 **42 组译文完全一致**可直接合并，**4 组不一致需要人工裁决**：

  | 源字符串 | 冲突的简体译文 |
  |---|---|
  | `Shortcut` | 快捷方式 / 快捷键 |
  | `Traditional Chinese(Hong Kong)` | 转换为繁体中文（香港）/ …(香港)（全角 vs 半角括号） |
  | `Traditional Chinese(Taiwan)` | 同上 |
  | `Load lyrics from music file (beside/embedded)` | 从音乐文件加载歌词（同目录/内嵌）/（顺序：内嵌 > 同目录） |

  最后一条其实是**陈旧条目** —— storyboard 现在的文案已改成 "order: embedded > beside"，旧条目没清。
- **最低系统**：`Config/Project-{Debug,Release}.xcconfig` 与 `Config/LyricsX/LyricsX.xcconfig`
  均为 `MACOSX_DEPLOYMENT_TARGET = 12.0`；`LyricsXPackage/Package.swift` 是 `.macOS(.v12)`；
  LyricsXWidget 单独是 15.0。
- **抬高最低版本不需要额外处理老用户**：`Scripts/release/publish-appcast.sh:41-48` 从
  xcconfig 里自动读出 `minimumSystemVersion`（取项目级与主 app 级的最大值，刻意排除 widget 的 15.0）。
  改完 xcconfig，Sparkle 自动停止向 macOS 12/13 推送，他们停在最后一个兼容版本，
  **不会装到一个跑不起来的包**。发布流程不用改。
- **SwiftUI 目前只在 widget target 里用**（9 个文件），主 app 是纯 AppKit。

### RuntimeViewer 的设计模型（实地读源码）

- **不用 SwiftUI `Settings` 场景，不用第三方设置库**（无 `sindresorhus/Settings`）。
  手写 `SettingsWindowController: XiblessWindowController<SettingsWindow>`，
  `contentViewController = NSHostingController<SettingsRootView>`
  （`RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsWindowController.swift:8-55`）。
- **两个 SPM target 分层**：`RuntimeViewerSettings`（纯模型，无 UI 依赖，跨平台）与
  `RuntimeViewerSettingsUI`（SwiftUI，全文件 `#if os(macOS)`）。
  项目的 `AGENTS.md:152-166` 把这条写成硬规矩：「AppKit：除设置外的全部 UI／SwiftUI：仅设置模块」。
- **页由一个 `enum` 声明**，不是协议也不是 `TabView`
  （`SettingsRootView.swift:19-60`）：

  ```swift
  private enum SettingsPage: String, CaseIterable, Identifiable {
      case general = "General"
      case theme = "Theme"
      // …
      var id: String { rawValue }
      var systemImage: String { … }
      @ViewBuilder var contentView: some View {
          switch self {
          case .general: GeneralSettingsView()
          // …
          }
      }
  }
  ```

  导航是 `NavigationSplitView` + 侧边栏 `List(SettingsPage.allCases, selection:)`，
  **内容宽度写死 715pt**（`minWidth: 715, maxWidth: 715`），侧边栏列宽 185pt，最小高度 400。
- **每页的骨架**是一个 13 行的壳（`SettingsForm.swift`）：

  ```swift
  struct SettingsForm<Content: View>: View {
      @ViewBuilder var content: Content
      var body: some View { Form { content }.formStyle(.grouped) }
  }
  ```

  页内一律 `Section { } header: { } footer: { }` + `LabeledContent` + `Toggle`/`Picker`/`Stepper`。
  **长解释文字一律放 `footer:`，不放在行里**；从属控件用 `.disabled(!settings.isEnabled)` 联动。
  不用 `GroupBox`，不在页内写死宽度（宽度只在根视图定一次）。
- **`@AppSettings` 属性包装器**（`AppSettings.swift`，32 行）是整套设计里杠杆最大的一段：

  ```swift
  @propertyWrapper
  struct AppSettings<Value>: DynamicProperty {
      private let keyPath: ReferenceWritableKeyPath<Settings, Value>
      @Dependency(\.settings) private var settings

      var wrappedValue: Value {
          get { settings[keyPath: keyPath] }
          nonmutating set { settings[keyPath: keyPath] = newValue }
      }
      var projectedValue: Binding<Value> {
          Binding(get: { settings[keyPath: keyPath] },
                  set: { settings[keyPath: keyPath] = $0 })
      }
  }
  ```

  因为 `Settings` 是 class，`\.update.automaticallyChecks` 是合法的
  `ReferenceWritableKeyPath`，所以**整段子模型**（`@AppSettings(\.general) var settings`，
  再用 `$settings.appearance`）和**单个叶子键**两种粒度都能用。
- **存储是 JSON 文件**：`~/Library/Application Support/RuntimeViewer/settings.json`，
  `@Observable final class Settings` 的每个顶层字段 `didSet` 触发**防抖 1 秒的整文档重写**
  （`Settings.swift:41-77`）。用 MetaCodable 的 `@Default` 给每个字段兜底，
  所以新增偏好不会让旧文件解码失败。
- **AppKit 侧读设置**用 `SwiftNavigation.observe { }`
  （`AppearanceController.swift:16-29`），这是「SwiftUI 岛驱动 AppKit 主体」的承重胶水。
- **颜色用原生 `ColorPicker`**，不用 `NSColorWell`：
  `ColorPicker("", selection: …, supportsOpacity: true).labelsHidden()`
  （`ThemeSettingsView.swift:296`）。整个设置模块只有**一个** `NSViewRepresentable`
  （富文本 token 输入框），其余全是原生 SwiftUI。
- **本地化：完全没有。** 全项目无 `.xcstrings`、无 `.strings`，唯一的 `.lproj` 里只有 `MainMenu.xib`。
  且有两处把标识符和显示文本混用（`SettingsPage.rawValue` 既当 id 又当标题、
  `CheckInterval.displayName` 返回硬编码英文），**要本地化的项目不能照抄这一点**。
- **最低系统 macOS 15**（app target 与 SPM 包都是），这正是它能用整套现代 API 的前提。
- **两处「锁死侧边栏」的 hack**：swizzle `NSSplitViewItem.canCollapse`
  （`SettingsWindowController.swift:57-73`）+ 用 SwiftUIIntrospect 隐藏工具栏里 SwiftUI 自动加的
  折叠按钮（`RuntimeViewerSettingsStyle.swift:10-21`）。两者都是纯装饰，可以不抄。

## 提议方案

### 一、分层：两个新 target，照搬 RuntimeViewer 的切法

在 `LyricsXPackage` 里加两个 target：

- **`LyricsXSettings`** —— 偏好模型层，不依赖 SwiftUI。放 `PreferencesStore`
  与偏好键的类型化定义。
- **`LyricsXSettingsUI`** —— SwiftUI 页面、`SettingsForm` 壳、`@AppSettings` 包装器、
  以及这个 target 自己的字符串目录。

分层的实际收益不是洁癖：模型层不依赖 SwiftUI，就能被 `LyricsXFoundationTests` 直接测；
UI 层独立成 target，就能像 `AppleMusicLyricsPanel` 那样单独构建。

### 二、存储：留在 `UserDefaults`，但把模型层做成 `@Observable`

**这是与 RuntimeViewer 最大的分歧，理由在前期调研里已经摆明**：偏好要跨三个进程共享，
且迁移期间 SwiftUI 页与仍是 Cocoa Bindings 的 storyboard 页**必须读写同一份数据**，
否则同一个开关在两个页里显示不一致。

做法：`@Observable final class PreferencesStore`，属性是**计算属性**，
读写落到现有的 `defaults[.key]` 上，靠 Observation 的 `access` / `withMutation` 参与 SwiftUI 失效：

```swift
@Observable
public final class PreferencesStore {
    public var desktopLyricsEnabled: Bool {
        get {
            access(keyPath: \.desktopLyricsEnabled)
            return defaults[.desktopLyricsEnabled]
        }
        set {
            withMutation(keyPath: \.desktopLyricsEnabled) {
                defaults[.desktopLyricsEnabled] = newValue
            }
        }
    }
}
```

**外部改动也要能让 SwiftUI 刷新** —— 迁移期间 storyboard 页通过 Cocoa Bindings 直接写
`NSUserDefaultsController`，绕过了上面的 setter。因此 store 还要订阅
`defaults.publisher(for:)`（项目已在用，`AppController.swift:106`），
收到变化时对相应 keyPath 调一次 `withMutation` 把失效补上。

这段样板可以由一个宏或代码生成消掉，但**首版手写**：93 个键里只有 36 个出现在设置界面，
先把这 36 个写出来，确认设计站得住再谈自动化。

### 三、`@AppSettings` 包装器照抄

签名与 RuntimeViewer 一致，只把 `@Dependency(\.settings)` 换成 LyricsX 自己的取法
（项目已有 `AppController.shared` 这类单例约定，不引入 swift-dependencies，见非目标）。

### 四、逐页迁移，`NSTabViewController` 保留到最后

RuntimeViewer 的终态是 `NavigationSplitView` 侧边栏，但**那个终态到不了增量中途** ——
`NavigationSplitView` 没法托管 AppKit 的标签页。所以分两段：

**第一段（第 1–6 步）**：`PreferenceTabViewController` 与 6 个 `tabViewItem` 全部保留，
每次把**一个**页的 `viewController` 从 storyboard 场景换成 `NSHostingController`。
每迁完一页都能独立构建、独立验证，出问题只影响那一页。

**第二段（第 7 步）**：6 页全部迁完之后，整窗换成 RuntimeViewer 那套
`SettingsWindowController` + `NavigationSplitView`，`Preferences.storyboard` 删除。

分两段的代价是「侧边栏样式」要等到最后才看得见，收益是中途每一步都可回退。

### 五、本地化：字符串目录随 target 走，按源字符串重配键

**`LocalizedStringKey` 在 SPM target 里解析的是 `Bundle.module`，不是 app bundle** ——
这一点容易漏。因此 `LyricsXSettingsUI` 要在 `Package.swift` 里声明
`defaultLocalization: "en"`，并带自己的 `Localizable.xcstrings`。

重配键用脚本做，输入是现有的 `Preferences.xcstrings`：对每个 `<对象ID>.title` 条目，
取它的 base 值作新键，把 16 种语言的译文原样搬过去。42 组重复的直接合并，
**4 组冲突的由人工裁决后写进脚本的例外表**（清单见前期调研）。

旧的 `mul.lproj/Preferences.xcstrings` 随 storyboard 一起在第 7 步删除。

### 六、需要 `NSViewRepresentable` 的只有字体选择

对照 RuntimeViewer 的经验（整个设置模块只有 1 个 `NSViewRepresentable`），逐个核对：

| 现在的控件 | SwiftUI 对应 |
|---|---|
| `AlphaColorWell` ×4、`colorWell` ×6 | `ColorPicker(supportsOpacity: true)`，RuntimeViewer 已验证 |
| 过滤词表 `NSTableView` | `List` + `ForEach` + `.onDelete` |
| 歌词源拖拽重排 `NSTableView` | `List` + `.onMove` |
| 快捷键录制 ×10 | **`KeyboardShortcuts.Recorder`（SwiftUI 原生）**，见下节 |
| `FontSelectTextField` → `NSFontPanel` | **需要 `NSViewRepresentable`**（或重做成字体族/字号两个 `Picker`） |
| `NowPlayingApplicationListViewController`（305 行） | 首版**原样保留**，从 SwiftUI 用 `.sheet` 里包 `NSViewControllerRepresentable` 呈现 |

字体那一处是唯一真正的缺口：`NSFontPanel` 是全局共享单例、靠 responder chain 派发变更，
SwiftUI 没有对应物。

### 与 0005 的关系

两份提案在「快捷键」页正面重叠，**必须定先后**。

0005 的方案是「storyboard 留空占位视图 + 代码里 `addSubview(RecorderCocoa)`」，
之所以那样绕，正是因为 `RecorderCocoa` 的 `init?(coder:)` 不可用、进不了 storyboard。
但**如果快捷键页反正要变成 SwiftUI，这个绕法就是白做的** —— SwiftUI 侧有原生的
`KeyboardShortcuts.Recorder`，直接写在 `Form` 里即可，没有 storyboard 参与。

**建议：0005 先落，且快捷键页排在本提案第一段的最后一个迁。** 理由是 0005 独立、风险小、
用户能立刻拿到收益（现在这个控件在 macOS 26 上就是丑的），不该被一个大迁移拖住；
它那点 storyboard 改动在快捷键页迁走时被删掉，是可接受的一次性浪费。

反过来的选择（0005 等本提案）也成立，代价是换库要等整个迁移做完。这个先后请在批准时定。

### 非目标

- **不改任何偏好的语义、默认值或键名。** 本提案只换界面与绑定方式，
  行为层面用户不应察觉除外观外的任何变化。
- **不引入 swift-dependencies / MetaCodable。** 它们在 RuntimeViewer 里解决的是
  「JSON 前向兼容」和「DI 纪律」，LyricsX 既不存 JSON，也已有既定的单例约定。
  只为设置界面引入两个新依赖不划算。
- **不引入 SwiftUIIntrospect，不 swizzle `NSSplitViewItem`。** 那两处只是为了锁死侧边栏不可折叠，
  是纯装饰；可折叠的侧边栏完全可以接受。
- **不迁移 `NowPlayingApplicationListViewController`**（305 行，实验室页弹出的列表）。
  首版包一层继续用，它值不值得重写另说。
- **不动主窗口、桌面歌词、菜单栏歌词等任何非设置界面的 UI。**
  照搬 RuntimeViewer 的规矩：SwiftUI 只出现在设置模块。
- **不做偏好项的增删或重新分组** —— 页与页内顺序保持现状，
  否则用户找不到东西，且本地化重配键会更难对账。

## 详细设计

```swift
// LyricsXPackage/Package.swift
.target(
    name: "LyricsXSettings",
    dependencies: ["LyricsXFoundation"]
),
.target(
    name: "LyricsXSettingsUI",
    dependencies: ["LyricsXSettings"],
    resources: [.process("Resources")]   // 自带 Localizable.xcstrings
),
```

```swift
// LyricsXSettingsUI/AppSettings.swift —— 照抄 RuntimeViewer，换掉取模型的方式
@propertyWrapper
struct AppSettings<Value>: DynamicProperty {
    private let keyPath: ReferenceWritableKeyPath<PreferencesStore, Value>

    init(_ keyPath: ReferenceWritableKeyPath<PreferencesStore, Value>) {
        self.keyPath = keyPath
    }

    var wrappedValue: Value {
        get { PreferencesStore.shared[keyPath: keyPath] }
        nonmutating set { PreferencesStore.shared[keyPath: keyPath] = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { PreferencesStore.shared[keyPath: keyPath] },
            set: { PreferencesStore.shared[keyPath: keyPath] = $0 }
        )
    }
}
```

```swift
// LyricsXSettingsUI/SettingsForm.swift —— 照抄
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { Form { content }.formStyle(.grouped) }
}
```

```swift
// LyricsXSettingsUI/Panes/SourceSettingsView.swift —— 一个真实页的样子
// （挑歌词源页举例，因为 0003 刚把它改成单选组 + 可拖拽列表，两种控件都有）
struct SourceSettingsView: View {
    @AppSettings(\.lyricsSourceOrderingMode) private var orderingMode
    @AppSettings(\.lyricsSourcePriorityOrder) private var priorityOrder

    var body: some View {
        SettingsForm {
            Section {
                Picker("Ranking", selection: $orderingMode) {
                    Text("Rank by match score only").tag(LyricsSourceOrderingMode.qualityOnly)
                    Text("Rank by source order first").tag(LyricsSourceOrderingMode.sourceFirst)
                    Text("Rank by match score, break ties by source order")
                        .tag(LyricsSourceOrderingMode.qualityFirstSourceTieBreak)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Scores within 0.02 of each other count as tied.")
            }

            Section {
                List {
                    ForEach(priorityOrder, id: \.self) { Text($0) }
                        .onMove { $priorityOrder.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
                }
                .disabled(!orderingMode.usesSourcePriorityOrder)
            } header: {
                Text("Source Priority")
            }
        }
    }
}
```

**迁移期的双向同步**（第 1–6 步期间必须成立，第 7 步之后可删）：

```swift
// LyricsXSettings/PreferencesStore.swift
/// Cocoa Bindings in the not-yet-migrated storyboard panes write straight to
/// `NSUserDefaultsController`, bypassing this type's setters. Without this
/// bridge a switch flipped on an old pane would leave a migrated pane showing
/// the stale value until the window was reopened.
private func observeExternalWrites() {
    defaults.publisher(for: migratedKeys)
        .sink { [weak self] change in self?.invalidate(change.key) }
        .store(in: &cancelBag)
}
```

## 替代方案考量

- **存成 JSON 文件，完全照抄 RuntimeViewer** —— 最忠实于参照实现，也最干净
  （类型化模型、前向兼容、无 `UserDefaults` 的字符串键）。**否掉是因为跨进程**：
  LyricsXHelper（非沙盒）与 LyricsXWidget（沙盒）都靠 `UserDefaults` suite 读偏好，
  改成 JSON 要么给两个进程另开一套读取路径，要么让它们去读一个沙盒外的文件 —— 前者是双份实现，
  后者沙盒扩展根本做不到。而且迁移期间两套页共读同一份数据这条也直接落空。
- **用 `@AppStorage` 而不是自建 store** —— 少写一层。否掉有两点：
  `@AppStorage` 只认原始可存类型，LyricsX 有 `NSColor`（keyedArchive 转换器）、
  `[String]`、`[String: String]` 这类键；而且它绕过 `Global.swift` 里已有的 `Key<T>` 类型化声明，
  等于在项目里开第二套偏好访问方式。
- **一次性全换掉 storyboard** —— 已由用户否决，选择逐页迁。
  留档理由：一次改动要同时动 36 个绑定键、6 个页与 152 条本地化，出问题无法定位到页。
- **保持 macOS 12，用 SwiftUI 老 API 手搭布局** —— 已由用户否决。
  留档理由：那样得到的界面既不是 storyboard 的样子也不是系统设置的样子，
  与「让 UI 跟上系统」的初衷相悖，等于付了迁移的代价却拿不到收益。
- **只提到 macOS 13** —— 能拿到 `Form(.grouped)` 与 `LabeledContent`（外观达标），
  但 `@Observable` 要 14。已由用户否决，选 14。
- **用 `sindresorhus/Settings` 之类的设置窗口库** —— RuntimeViewer 评估后没用，
  本提案同样不用：它解决的是「窗口 + 标签栏」这一层，而这一层 LyricsX 现在已经有
  （`NSTabViewController`），最终形态又是 `NavigationSplitView`，库能省的部分正好是不需要的部分。

## 影响

### 用户可见变化

- 设置界面**外观整体改变**：从固定网格排布变成系统设置那种分组卡片式（`Form(.grouped)`）。
  分组标题与说明文字的位置随之变化 —— 现在挤在行里的解释文字会移到分组下方的 footer。
- 第 7 步之后，设置窗口从**顶部工具栏标签**变成**左侧边栏列表**，与 macOS 13+ 的系统设置一致。
- **偏好项本身一个不增不减、不改默认值、不换分组。** 用户原有的操作路径全部保留。
- **macOS 12 与 13 的用户不再能升级**，停留在最后一个兼容版本。这是本次唯一的破坏性影响。

### 可发现性

- 页的名字、顺序、每页里选项的顺序全部保持现状，用户不需要重新找。
- 无新增功能，因此无「默认开启还是关闭」的问题。

### 数据与配置兼容

- **偏好键、存储位置、默认值全部不变** —— 存储仍是 `UserDefaults`，这正是不照抄
  RuntimeViewer 的 JSON 方案的原因。降级回旧版本设置照样在。
- 无迁移代码，因此没有迁移失败这个状态。
- 本地化数据从 `mul.lproj/Preferences.xcstrings`（按对象 ID）搬到
  `LyricsXSettingsUI` 的字符串目录（按源字符串）。**16 种语言的译文全部保留**，
  4 组冲突需人工裁决一次。

### 平台与最低版本

- **`MACOSX_DEPLOYMENT_TARGET` 从 12.0 提到 14.0**（`Config/Project-*.xcconfig` 与
  `Config/LyricsX/LyricsX.xcconfig`），`LyricsXPackage/Package.swift` 从 `.macOS(.v12)` 到 `.macOS(.v14)`。
- LyricsXHelper 可以留在 12.0（独立可执行文件，不受影响）；LyricsXWidget 保持 15.0 不变。
- 抬高之后 `AppController.swift:223`、`:242`、`PreferenceLabViewController.swift:42`、`:126` 等
  `#available(macOS 12/13)` 判断变成恒真，可顺手清理（不影响行为）。

### 发布

- 不需要新权限、entitlement 或隐私清单条目。
- **Sparkle 侧不需要任何改动**：`Scripts/release/publish-appcast.sh` 自动从 xcconfig 读
  `minimumSystemVersion`，改完部署目标即自动生效，macOS 12/13 用户不会收到装不上的更新。
- 发布说明需明确写出「本版本起需要 macOS 14」。

## 落地步骤

0. **前置**：把部署目标提到 14.0（xcconfig + `LyricsXPackage/Package.swift`），
   清理变成恒真的 `#available` 判断。这一步单独提交，行为不变。
1. 新增 `LyricsXSettings` target 与 `PreferencesStore`，先只覆盖「歌词源」页用到的键；
   加 `LyricsXSettingsUI` target 与 `SettingsForm`、`@AppSettings`、`SettingsPage` 骨架。
   此时无人使用，可独立构建。
2. **迁「歌词源」页**（最小、最独立：2 个键、一个单选组 + 一个可拖拽列表，
   且刚在 0003 里重写过，行为记忆最新鲜）。`tabViewItem` 的 view controller 换成
   `NSHostingController`。可构建、可验证。
3. 迁「过滤」页（1 个键 + 一个词表）。
4. 迁「实验室」页（11 个键；`NowPlayingApplicationListViewController` 包一层继续用）。
5. 迁「通用」页（12 个键；播放器选择的自定义排布要重做）。
6. 迁「显示」页（12 个键；**字体选择需要 `NSViewRepresentable`**，本步风险最高，故排在后面）。
7. 迁「快捷键」页（用 `KeyboardShortcuts.Recorder`，前提是 0005 已落）。
8. 6 页全部迁完后，整窗换成 `SettingsWindowController` + `NavigationSplitView`；
   删除 `Preferences.storyboard`、`LyricsX/Preferences/` 下的旧 view controller、
   `mul.lproj/Preferences.xcstrings`。
9. 本地化重配键脚本随第 2 步起逐页执行（每页迁移时搬走属于它的那批字符串），
   第 8 步做最后的清账与 4 组冲突裁决。

每一步都应能单独构建通过并单独验证那一页。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：配套文章、新术语。
预判：**需要一篇实现说明**，至少要记「为什么存储没跟着 RuntimeViewer 换成 JSON」
与「迁移期双向同步为什么必须存在」——两者都是「下次维护会踩、代码本身看不出来」的决策。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-11 | Created as Draft | 起因：用户要求把设置页迁到 SwiftUI，参照 RuntimeViewer 的设计模型。 |
| 2026-08-11 | 最低系统提到 macOS 14 | 用户在三个选项（保持 12 / 提到 13 / 提到 14）中选 14。理由：只有 14 才同时拿到 `Form(.grouped)`、`LabeledContent`、`NavigationSplitView` 与 `@Observable`，写法与 RuntimeViewer 完全一致。代价是放弃 macOS 12/13 用户；实测确认 Sparkle 的 `minimumSystemVersion` 由 xcconfig 自动派生，老用户会停在最后一个兼容版本而非收到装不上的更新。 |
| 2026-08-11 | 逐页迁移，两套并存 | 用户在「逐页迁」与「一次性全换」中选前者。据此把终态的 `NavigationSplitView` 推迟到第 8 步 —— 它无法在增量中途成立，因为 `NavigationSplitView` 托管不了 AppKit 标签页。 |
| 2026-08-11 | 存储不跟随 RuntimeViewer 换成 JSON | RuntimeViewer 把设置存成 Application Support 里的 `settings.json`。LyricsX 不能照抄：偏好要跨主 app、非沙盒的 LyricsXHelper、沙盒的 LyricsXWidget 三个进程共享（`Global.swift:27-42` 已注释说明为何必须用两个不同的 suite），且迁移期间 SwiftUI 页与 Cocoa Bindings 页必须读写同一份数据。改为保留 `UserDefaults`，只照搬模型层的形状（`@Observable` + `@AppSettings`）。 |
| 2026-08-11 | 本地化必须自建，不能照抄 | RuntimeViewer 的设置界面**零本地化**（全项目无字符串目录），而 LyricsX 有 16 种语言约 2100 条译文。实测 152 个按对象 ID 的键对应 102 个源字符串，42 组重复可自动合并、4 组译文冲突需人工裁决。另注意 SPM target 里的 `LocalizedStringKey` 解析的是 `Bundle.module`，字符串目录必须随 target 走。 |
| 2026-08-11 | 不引入 swift-dependencies / MetaCodable / SwiftUIIntrospect | RuntimeViewer 用它们分别解决 DI 纪律、JSON 前向兼容、锁死侧边栏。LyricsX 不存 JSON、已有单例约定、可折叠侧边栏可接受，三个依赖都不划算。 |
