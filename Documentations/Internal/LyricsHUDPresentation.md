# 歌词 HUD 窗口显示与关闭

歌词 HUD 的菜单动作以实际窗口状态为准，不能只读取 `isShowLyricsHUD` 偏好值。偏好值可能仍为 `true`，但窗口
已经被隐藏、移到后台或失去前台焦点；此时再次触发菜单动作应该把现有窗口带回前台，而不是关闭它。

`LyricsWindowPresentationDecision` 把判断保持为可测试的纯逻辑：

- 窗口不可见：显示现有窗口；不存在时创建窗口，并激活应用。
- 窗口可见、应用不在前台：把窗口和应用带到前台。
- 窗口可见、应用已经在前台：关闭窗口，并清除 controller 与显示偏好状态。

`AppDelegate.showLyricsHUD(_:)` 只执行上述结果。窗口是否可见来自 `activeLyricsHUD?.window?.isVisible`，应用是否
在前台来自 `NSApp.isActive`；`UserDefaults` 只在完成显示或关闭后同步，不再参与动作选择。

回归测试覆盖三种状态组合，防止以后重新把偏好值当成窗口可见性的真值。
