# Draft - 菜单栏歌词的暂停隐藏改用独立开关

- **状态**: In Progress
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **实现分支**: `feature/menu-bar-placeholder-when-paused`

## 摘要

1.9.0-rc.2 修好了菜单栏不理会「隐藏歌词：暂停播放时」的问题，从此一暂停菜单栏就换成占位文字「LyricsX」。可这个设置放在
「偏好设置 → 显示」的桌面歌词选项卡里，而且默认开着，所以没碰过设置的人每次暂停都会看到菜单栏的歌词消失。这次给菜单栏
一个自己的开关「暂停时隐藏菜单栏歌词」，放在实验室页，默认关；桌面歌词那个设置回到只管桌面歌词。

## 方案

- 新增设置键 `MenuBarHidesLyricsWhenPaused`（`Global.swift` 里的 `menuBarHidesLyricsWhenPaused`），在
  `UserDefaults.plist` 里默认 `false`。
- `MenuBarLyricsController` 交给 `MenuBarLyricsLinePolicy` 的 `hidesLyricsWhenPaused` 改读这个键，订阅的设置变化也换成它。
  策略本身不变，`MenuBarLyricsLinePolicyTests` 已经覆盖开、关两种取值。
- 实验室页在「在菜单栏显示播放控制」下面加一个勾选框，绑定这个键；`Preferences.xcstrings` 补齐全部 17 种语言。
- 桌面歌词（`KaraokeLyricsController`）继续读 `DisableLyricsWhenPaused`，不变。
- 1.9.0 正式版的发布说明删掉「菜单栏歌词暂停时隐藏」那条升级提示，在「新增」里写这个开关。
- `Documentations/Internal/MenuBarLyricsRendering.md` 的「什么时候显示占位文字」一节同步更新。

没有询问就采用的假设：

- 开关放在实验室页，和「合并菜单栏图标与歌词」「在菜单栏显示播放控制」这两个菜单栏选项放在一起。
- 开关文案写「Hide menu bar lyrics when paused」，不写「显示 LyricsX」：发布说明不许出现应用名，而说明里要引用开关的名字。
- 不做迁移：rc.2 里开着「隐藏歌词：暂停播放时」的人升级后也回到默认关，想要占位文字的话自己打开新开关。
  rc.2 只是预发布版，而 1.8.9 正式版的菜单栏暂停时一直保留当前那一句。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-08 | Created as Draft | rc.2 让菜单栏跟着桌面歌词默认开着的暂停设置走，默认设置下一暂停菜单栏就只剩「LyricsX」，用户要求单独做成开关 |
| 2026-11-08 | 新开关默认关 | 回到 1.8.9 及更早版本一直以来的表现：暂停时菜单栏保留当前那一句；想要占位文字的人自己打开 |
| 2026-11-08 | 赶 1.9.0 正式版 | 不赶的话，正式版用户在默认设置下一暂停就看到菜单栏歌词消失 |
| 2026-11-08 | 用户批准，开始实现 | 用户定下以上两点即批准方案 |
| 2026-11-08 | 实现完成，待用户看过后收尾 | Debug 构建通过，`LyricsXFoundationTests` 全部通过；没有新增测试：策略本身没变，变的只是控制器读哪个设置键，app target 里没有能测它的接缝 |
