# LyricsX 提案索引

- **项目类型**: App（macOS 菜单栏应用）

提案的「影响」一节关注用户可见变化、可发现性、数据与配置兼容、平台与最低版本、发布流程，不涉及 ABI。

**提案未被批准（状态置为 `Accepted`）前不得开始写实现代码。** 被否的提案保留不删 —— 它是「当初为什么
没这么做」的唯一记录。

| # | 标题 | 状态 |
|---|------|------|
| [0001](0001-next-lyrics-candidate.md) | 切换到下一条歌词候选 | Implemented |
| [0002](0002-always-ignore-cached-lyrics.md) | 总是忽略歌词库缓存 | Implemented |
| [0003](0003-source-ordering-modes.md) | 歌词源排序模式：分数优先，同分再看源 | Implemented |
| [0004](0004-user-picked-lyrics-exemption.md) | 手动应用过的歌词豁免于「忽略已保存的歌词」 | Implemented |
| [0005](0005-keyboard-shortcuts-library-swap.md) | 快捷键库从 MASShortcut 换成 KeyboardShortcuts | Draft |
| [0006](0006-swiftui-settings.md) | 设置界面迁移到 SwiftUI | Draft |
| [0007](0007-apple-music-lyrics-animation-parity.md) | 对齐 Apple Music 26.6 歌词动画 | Implemented |
| [0008](0008-apple-music-metal-gradient.md) | 自绘 Metal 歌词渐变背景 | Implemented |
| [0009](0009-apple-music-line-cascade-parity.md) | 行间 cascade 对齐 Apple Music 26.6 并修复全屏掉帧 | Implemented |
| [0010](0010-apple-music-now-playing-backdrop.md) | 歌词面板背景改按 Music 26「正在播放」的 MediaCoreUI 管线重做 | Implemented |
| [0011](0011-apple-music-syllable-lift.md) | 行内抬高改成 Music 26.6 的逐音节软弹簧 | Implemented |
| [0012](0012-inline-tag-syllable-lift.md) | 行内标签歌词也走 Music 26.6 的逐音节抬高 | Implemented |
| [0013](0013-now-playing-lyrics-sizing-parity.md) | 歌词面板的字号、行距、锚点与边缘渐隐改按 Music 26.6「正在播放」模式 | In Progress |
| [0014](0014-panel-full-screen-titlebar.md) | 歌词面板全屏时收起标题栏，pin 按钮改挂标题栏视图 | In Progress |
