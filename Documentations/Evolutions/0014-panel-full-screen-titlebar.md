# 0014 - 歌词面板全屏时收起标题栏，pin 按钮改挂标题栏视图

- **状态**: In Progress
- **创建日期**: 2026-09-12
- **最后更新**: 2026-09-13
- **所属愿景**: 无

## 摘要

Apple Music 风格歌词面板进入原生全屏后，屏幕顶部常驻一条纯黑的横带。它不是工具栏画出来的颜色，
而是内容视图被标题栏挤下去之后露出的全屏 Space 黑底 —— 面板的窗口背景是 `.clear`，挡不住它。

根因在 AppKit 的两条判定上，都是读反编译确认的，不是推测：

- `-[_NSFullScreenMenuBarCompanionController _originalWindowShouldAutomaticallyAutohide]`
  决定全屏时标题栏要不要自动隐藏。窗口只要**有 toolbar** 或**有任何 titlebar accessory view
  controller**，它就回答「不自动隐藏」，于是标题栏在整个全屏期间钉在顶部。这个面板两样都占：
  一个空 `NSToolbar`，和一个装 pin 按钮的 `NSTitlebarAccessoryViewController`。
- `-[NSWindow _implicitlyAllowsFullScreenPrimary]` 的第一条判断就是 `_NXIsBackgroundOnly()`
  （走 LaunchServices 查进程的 application type，命中 `kLSApplicationBackgroundOnlyType` 或
  `kLSApplicationUIElementType` 即为真）。LyricsX 的 `LSUIElement = true`，所以窗口拿不到隐式
  全屏能力 —— 这解释了为什么这个窗口必须手动 `collectionBehavior.insert(.fullScreenPrimary)`，
  而项目里其它普通应用的窗口不用。同一函数里 `_level != 0` 也会否决，即 pin 成浮动层级的窗口
  同样拿不到。

## 方案

那个空 `NSToolbar` 不能一删了之 —— 它是撑出窗口大圆角的唯一手段（titled 窗口带 toolbar 才有
macOS 两档圆角里大的那档）。所以按状态分开处理：

- **窗口态**：保留空 toolbar（要圆角）。
- **全屏态**：进入前摘掉 toolbar 和所有 titlebar accessory，退出后装回。全屏窗口本来就没有圆角，
  摘掉不损失任何东西。
- **pin 按钮**：不再用 `NSTitlebarAccessoryViewController`，改成直接 `addSubview` 到标题栏视图
  （`standardWindowButton(.closeButton)?.superview`），与红绿灯 `centerY` 对齐。判定自动隐藏时数的是
  `titlebarAccessoryViewControllers` 的个数，普通子视图不计入，所以这样既能待在标题栏里，又不会把
  黑条招回来。鼠标进入窗口时淡入（0.3 秒），离开淡出；tracking area 挂在 contentView 上，覆盖整个窗口。
  先前试过放进面板内容区（锚 `contentLayoutGuide` 顶部），位置必然低于红绿灯一大截 —— 内容视图在那个
  高度被标题栏盖着，放上去的按钮点不到，只能往下躲。
  AppKit 在进出全屏时会把标题栏交给一个独立窗口再收回，所以两个方向的回调里都要重新挂一次。
- **全屏时的 pin**：按钮还在（唤出标题栏就能点），但只记偏好、不动窗口层级 —— 全屏没有可浮动的对象，
  真去设 `.floating` 反而会盖住滑下来的标题栏。退出全屏时按偏好恢复层级。
- **窗口层级**：进入全屏时强制 `.normal`，退出时按 pin 状态恢复。浮动层级会盖住 AppKit 从顶部
  滑下来的那个独立标题栏窗口，pin 着的面板会挡住自己的红绿灯；而全屏独占一个 Space，pin 本来
  也没有意义。

配置集中到 `LyricsXFoundation.AppleMusicLyricsWindowConfiguration`，照 `LyricsHUDWindowConfiguration`
的样子，带 `AppleMusicLyricsWindowConfigurationTests`。测试断言的正是这次踩的三个坑：配置完的
窗口带得到 `.fullScreenPrimary`、窗口态有空 toolbar、全屏态既没有 toolbar 也没有 titlebar
accessory 且层级是 `.normal`。谁再往标题栏上挂东西，测试立刻变红，而不是等到有人开全屏才发现。

未采用的两条：

- **`.autoHideToolbar` 系列 presentation options**。实测两头堵：只给 `.autoHideToolbar`，标题栏
  藏了却唤不回来（文档原文是它「跟着自动隐藏的菜单栏一起隐藏和显示」，而纯菜单栏应用没有菜单栏
  参与）；补上 `.autoHideMenuBar` 之后黑条又回来了。
- **关掉 `LSUIElement`**。能让所有原生行为回归，但那是应用性质的改变（Dock 常驻图标），已单独
  开题评估，见 [0016-lsuielement-tradeoff](0016-lsuielement-tradeoff.md)。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-12 | 不用 `.autoHideToolbar` / `.autoHideMenuBar` | 实测两头堵：不加菜单栏选项唤不出标题栏，加了黑条重现 |
| 2026-09-12 | 空 toolbar 只在全屏期间摘掉，不整个删除 | 它是窗口大圆角的唯一来源，全屏没有圆角所以摘掉无损 |
| 2026-09-12 | pin 按钮不再用 titlebar accessory | titlebar accessory 本身就是「全屏标题栏不自动隐藏」的触发条件之一 |
| 2026-09-12 | 全屏期间强制窗口层级为 `.normal` | 浮动层级会盖住 AppKit 滑下来的独立标题栏窗口，pin 着就看不到自己的红绿灯 |
| 2026-09-12 | 保留手动 `insert(.fullScreenPrimary)` | `LSUIElement` 应用拿不到隐式全屏，这行不是冗余代码 |
| 2026-09-13 | pin 按钮改挂标题栏视图的普通子视图，不放面板内容区 | 放内容区必然比红绿灯低一截（那个高度被标题栏盖住，点不到）；普通子视图不计入 accessory 计数，两头都占 |
