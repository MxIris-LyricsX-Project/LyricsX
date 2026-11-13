# 状态栏菜单自定义行的对齐：实现说明

> 没有配套提案：这是一次 bug 修复。本文记录**实际落地的实现**、为什么这样做，以及已知降级。面向维护者。

## 背景与目标

状态栏菜单里「歌词偏移」那一行是一个 `NSMenuItem.view`（`Main.storyboard` 里的 Lyrics Offset View）。
带自定义视图的菜单项，AppKit 什么都不画，标签放在哪由 app 自己定；要和其他菜单项的标题对齐，就得知道
AppKit 把标题放在哪，而这没有 API。

修复之前，`AppDelegate.menuWillOpen` 把标签的左边距写死成 14 pt，菜单里有勾选项时再加 10 pt。
macOS 27 上，有勾选项时标签比标题左了 6 pt；没有勾选项时，从 macOS 26 起就一直左 2 pt（菜单平时总有勾选项，
所以没人注意到）。目标是让标签文字的起点与普通菜单项标题文字的起点逐像素一致，并且不再随系统改版回归。

## 关键设计决策

### 在打开的菜单里量，而不是按版本写常数

AppKit 每次改版都可能挪标题：macOS 27 把有勾选列时「勾选列到标题」的间距从 8 pt 加到了 14 pt
（见下文「AppKit 怎么摆标题」）。常数只能等坏了再补，所以 `TitleAlignedMenuItemView` 在菜单打开后，
从菜单窗口的视图树里找到参照项的标题文本框，量出它的位置，再把标签挪过去。常数表只是后备。

否掉的两条路：

- **只补 27 的常数**：改动最小，但下一次改版还会坏，而且只有有人跑了回归测试才会发现。
- **调私有方法 `-[NSMenuItemView titleTextFieldHorizontalOffset]` 取偏移**：数值最直接，但依赖私有 API。
  测量只用公开 API（遍历视图树、`convert(_:from:)`、`NSTextField.stringValue`），依赖的只是「标题是同一个窗口里的
  一个 `NSTextField`」这一结构事实；这一点一旦不成立，就退回常数表并记日志。

### 参照项怎么挑

`MenuItemTitleAlignmentPolicy.referenceItemIndex` 先在自定义行所在的分组（分隔线之间，分组标题另起一组）里
找最近的普通项，没有再到不含图标的分组里找最近的。普通项指：不是分隔线、分组标题或 alternate，可见，
没有自定义视图、没有图标，缩进级别与自定义行相同，标题不为空。

同组优先，是因为一组里有带图标的项时，AppKit 会把同组其他项的标题一起右移（共享图标宽度再加 6 pt，
见 `-[NSContextMenuImpl additionalTitleOffsetForItem:]`），自定义行应当跟着自己所在的组走。
退到别组时避开有图标的组，那里的标题被右移过。

### 约束定位的是 alignment rect，AppKit 摆标题用的是 frame

标签由 leading 约束定位，约束定的是它的 alignment rect，而 `NSTextField` 标签的 alignment rect 比 frame 左右
各缩 2 pt。AppKit 的标题文本框（`_NSMenuItemTextField`）则是直接 `setFrame:` 摆的。两种文本框在 frame 里的
文字起点相同（实测 `titleRect(forBounds:)`、`drawingRect(forBounds:)` 都从 0 开始，字形都在 frame 内 3 pt 处起笔），
所以约束常数 = 标题文本框 frame 的 x + 2。测量时把 `alignmentRect(forFrame:)` 与 frame 的差加回去；
常数表里的每个值也都比标题 frame 多 2 pt。

第一版漏了这一项，真实菜单里差 2 pt，是回归测试抓出来的。只对着 frame 或 `titleRect` 做算术的测试，
抓不出这种错。

### 在 `layout()` 里量

菜单窗口拿到视图之后才布局，这一遍是第一次能看到其他菜单项布局结果的时候：`viewDidMoveToWindow` 置
`needsLayout`，`layout()` 先量、再 `super.layout()`。参照项的视图在这一遍里可能排在后面，所以量之前对它调一次
`layoutSubtreeIfNeeded()`。

## AppKit 怎么摆标题

以下来自 macOS 26.6（cache UUID `d64a142b…`）与 27.2（26B123，`b411828b…`）的 dyld shared cache，
伪代码与汇编核对过，函数地址按各自的 cache。

- 普通菜单项是一个 `NSContextMenuItemView`（`NSMenuItemView` 的子类），标题是它的 `_titleTextField`，
  x = `-[NSMenuItemView titleTextFieldHorizontalOffset]` = 实例变量 `_titleTextFieldHorizontalOffset`
  + `-[NSContextMenuImpl additionalTitleOffsetForItem:]`。
- 实例变量在 `-[NSContextMenuItemView _updateStateImage]` 里算：
  - 菜单没有勾选列：`_themeStateOuterPadding − 2`。常规尺寸下，玻璃菜单布局（`NSGlassMenuLayoutEnabled`，
    默认跟随 macOS 26 起的 Liquid Glass 设计）是 16，否则是 14。所以 26、27 上标题 frame 从 14 pt 开始。
  - 有勾选列：`勾选列宽 + (缩进为 0 ? 8 : 5) − 2`。27.2 把 8 改成了 14（26.6 `0x18526B61C` 是
    `FMOV D1, #8.0`，27.2 `0x18A838B74` 是 `FMOV D1, #14.0`）。实测勾选列宽 16，所以标题 frame 在 26 上
    从 22 pt、在 27 上从 28 pt 开始。
  - 这个改动不看 app 链接的 SDK，属于系统变化。
- 自定义视图由 `NSCustomMenuItemView` 经 `NSMenuItemViewer` 放在 x = 0、占满整行
  （`-[NSCustomMenuItemView _titleFieldFrameRect]`；只用于绘制时左右各缩 6 pt）。
- 27.2 上菜单是一个 `NSTableViewBackedMenuRepresentation`，每行的 `NSTableRowView` 里放一个菜单项视图，
  自定义行与其他项在同一个窗口里，x 原点都是 0。

## 模块结构

```
LyricsXPackage/Sources/LyricsXFoundation/
├── MenuItemTitleAlignmentPolicy.swift  # 挑参照项、判断有没有勾选列、后备常数表（纯逻辑）
└── TitleAlignedMenuItemView.swift      # 菜单打开时量参照项的标题并移动标签；量不到时用常数表、记日志
LyricsX/Supporting Files/Base.lproj/Main.storyboard
                                        # Lyrics Offset View 的 customClass 与 label、labelLeadingConstraint 两个 outlet
LyricsXPackage/Tests/
├── LyricsXFoundationTests/MenuItemTitleAlignmentPolicyTests.swift
├── StatusItemProbeSupport/MenuTitleAlignmentProbe.swift   # 在探针宿主里弹出真实菜单并测量
└── MenuBarLyricsTests/StatusMenuTitleAlignmentProbes.swift
```

## 验证

- `MenuItemTitleAlignmentPolicyTests`（在 `LyricsXFoundationTests` 里，不到 1 秒）：参照项怎么挑、勾选列怎么判断、常数表。
- `StatusMenuTitleAlignmentProbes`：在探针宿主里弹出真实菜单四次（有、无勾选列 × 测量、只用常数表），
  比较标签与三个普通标题第一个字形的左边缘，误差不超过 0.5 pt；测量的两种情况还必须确实是量出来的。
  每个位置 = 文本框在菜单窗口里的 frame + 它自己渲染出的第一列非透明像素。不截整个菜单，是因为鼠标停留的那一行
  会高亮，高亮的边缘会被当成文字。所有文字都以「H」开头，避免不同字形的左侧留白影响比较。会在屏幕上闪四次菜单，约 5 秒。
- 修复前后（macOS 27.2，26B123）：常数表换回旧值时，有勾选列差 6 pt（标签 25、标题 31），无勾选列差 2 pt（15 对 17）；
  修复后四种情况都逐像素一致（31 对 31、17 对 17）。
- 没有在 macOS 26 上跑过回归测试，26 的常数来自逆向结论和修复前的旧值；15 及以前沿用旧值，没有核实过。
  也没有在真实的 LyricsX 里人工看过这个菜单。

## 已知降级

- 量不到时——视图不在菜单窗口里、菜单里没有可用的参照项、或者找不到它的标题文本框——退回常数表，并在
  `com.JH.LyricsX.diagnostics` / `TitleAlignedMenuItemView` 下记一条 info 日志。常数表：无勾选列时 macOS 15 及以前 14、
  26 起 16；有勾选列时 26 及以前 24、27 起 30。
- 从右到左的布局不测量，直接用常数表（目前没有从右到左的本地化）。
- AppKit 把菜单放到别的进程里渲染时（`NSMenuIsOutOfProcess`；27.2 上只有 `CFPasteboardVerification` 功能开关、
  `NSMenuEnableOutOfProcessMenus` 或剪贴板隐私开发者预览打开时才这样），窗口里找不到其他菜单项，会退回常数表。
- 常数表只覆盖常规尺寸、默认字体的菜单；小尺寸菜单或改过 `NSMenu.font` 的菜单靠测量。

## 偏移的步进与输入（2026-11-08 修正）

这一节与对齐无关，记的是同一行里步进器和输入框的修正。

**现象。** 这一行显示的是当前歌词自己的偏移，用户没动过也可能不是 0：酷狗的歌词文件常带 `[offset:51]` 这类
标签（曲库里 9 份非零偏移全来自酷狗）。步进器和「提前/延后歌词」两个快捷键每次 ±100 ms，从 51 只能到 151
或 -49，回不到 0。输入框从 2017 年这一行加进来起，在 storyboard 里就没开可选中、可编辑，点了进不去编辑状态。

**修法。**

- 步进规则是 `LyricsOffsetStepPolicy`（纯逻辑）：一步走到这个方向上的下一个 100 的整数倍（51 往上是 100、
  往下是 0），不越出 ±10000；本来就在范围外的偏移（手改过的文件）只会往回走。步进器和两个快捷键都走它。
- 步进器不再绑定偏移值，只表示方向：平时停在 0，点一下变成 1 或 -1，`AppDelegate.lyricsOffsetStepperClicked(_:)`
  按正负走一步，再把它放回 0。绑定着偏移值时，它只会把自己的 increment 加上去，没有地方插入取整。
- 输入框在 `applicationDidFinishLaunching` 里打开可选中、可编辑，storyboard 没改。绑定去掉了
  `continuouslyUpdatesValue`：按回车或点到别处才写入，输入到一半的「-」还不是一个数。

**风险。** Apple 的《Views in Menu Items》（Application Menu and Pop-up List Programming Topics，2014）写明
菜单项视图「收得到鼠标事件，但不支持键盘事件」。打开可编辑之后能不能打字，只能在真实菜单里试；不行的话，
改成点输入框时弹出一个输入窗口。

**验证。** `LyricsOffsetStepPolicyTests`（在 `LyricsXFoundationTests` 里）：自带偏移能走回 0、整百偏移照常走一步、
零头偏移走到下一个整百、范围两端。换回旧的 ±100 算法时 14 处断言失败。输入框没有自动化测试：菜单里的键盘输入
只能在真实菜单里试。

## 延伸阅读

- `apple-os27-regressions` skill 里对应的一行。
- [菜单栏歌词的绘制](MenuBarLyricsRendering.md)：同一个探针宿主为什么必须打包成 App、经 LaunchServices 启动。
