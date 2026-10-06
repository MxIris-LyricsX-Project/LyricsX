# 0017 - 菜单栏歌词改为自绘，不再用 NSTextField

- **状态**: Implemented
- **创建日期**: 2026-10-06
- **最后更新**: 2026-10-06
- **实现分支 / PR**: `develop`（未单独开分支）
- **配套文档**: [菜单栏歌词的绘制](../Internal/MenuBarLyricsRendering.md)

## 摘要

macOS 26 起，系统菜单栏不再显示状态栏条目自己的窗口，而是显示 AppKit 为它渲染的截图副本（replicant）。
MarqueeLabel 里的 `NSTextField` 会在每次截图的外观切换里把条目重新标脏，形成每秒约 300 次截图的死循环：
本机 macOS 27.2 上 1.9.0 什么都没播也稳定占 ~49% CPU，这很可能就是 issue 195「没在听歌也发烫」的原因。
改为自绘的 `MenuBarMarqueeLabel`：用 MarqueeLabel 那个文字框的同一个 `NSTextFieldCell` 画字，截图逐像素一致；
静止时不再重画，滚动时的开销由帧率决定。思路参考了 PR 198（菜单栏歌词降 CPU 的外部贡献），但不合并它。

## 方案

- **LyricsXFoundation 新增公开类 `MenuBarMarqueeLabel`**
  - `NSControl` 子类，`cellClass` 返回自定义的 `MenuBarMarqueeLabelCell`（`NSTextFieldCell` 子类）；
    整个类标为 `@available(macOS 26, *)`，内部不做版本判断。
  - 画字：用控件自己的 cell，MarqueeLabel 文字框的全部配置都写在这个 cell 的初始化里；尺寸取 `cellSize` 向外对齐到设备像素
    （与 `sizeToFit` 一致）。画好的位图按外观、缩放和色彩空间分别缓存，每帧只做贴图；位图就是文字框大小，
    溢出边框的字形照 App 里的文字框一样裁掉。
  - 滚动：沿用 MarqueeLabel 的时间分配（停 → 匀速走 → 停，走的时长 = 行时长 × 溢出宽度 / 文字宽度）。
    移动阶段由屏幕的 display link 逐帧驱动，跟随刷新率、上限 60 fps；位置对齐到设备像素（Retina 上 0.5 pt），
    比 MarqueeLabel 每帧整 1 pt 的步子还细。帧率上限做成隐藏偏好 `MenuBarLyricsScrollFramesPerSecond`，
    运行时生效，供肉眼对比。
  - 播放暂停、视图隐藏、屏幕休眠、离开窗口时停表。同一行、同时长重复设置不重启滚动（切换前台 App 时控制器会重发当前行）。
  - 收到空字符串时忽略，保留上一句，与 MarqueeLabel 一致。
- **`MenuBarLyricsController`**：macOS 26 及以上用新视图，更早的系统继续用 MarqueeLabel；两者经私有协议统一，
  只在创建时判断一次版本。播放状态变化时通知它暂停或继续。
- **回归探针**：LyricsXPackage 新增 `MenuBarLyricsTests` 测试 target（外观一致 / 空闲不重画 / 滚动开销），
  以及测试支持 target `StatusItemProbeSupport` 和探针宿主可执行 target `StatusItemProbeHost`。
- **未询问、自行取定的假设**：
  - 不加可见的设置项。PR 198 的帧率档位和静态分页这次不做，帧率只留一个隐藏偏好。
  - 只在 macOS 26 及以上启用。
  - 放进 LyricsXFoundation，不新开 target，免得改 `project.pbxproj`；该模块里已有 `LyricsInteractionTextView` 这类 AppKit 视图。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-06 | 创建。用户原话：「先改状态栏歌词，参考它的代码不直接合并，用一个探针测试一下怎么绘制能够还原NSTextField的效果然后性能还更好」 | — |
| 2026-10-06 | 用 `NSTextFieldCell` 画字 | 探针截图对比：cell 32/32 与 `NSTextField` 逐像素一致；`NSAttributedString` 直接画 0/32（每句约 1,500 个像素不同）；PR 198 的白字遮罩填 `labelColor` 0/32，且彩色 emoji 变成单色剪影 |
| 2026-10-06 | 不靠调整 `NSTextField` 的属性来规避 | `drawsBackground = false`、label 式配置同样会间歇进入循环 |
| 2026-10-06 | 位图按外观分别缓存 | 每次截图都会把外观切到截图外观再切回；只缓存一份时每次都要重新渲染。分别缓存后，单独歌词 30 fps 滚动从 21.9% 降到 17.4% CPU |
| 2026-10-06 | 30 fps | 带播放按钮时 CPU 随帧率近似线性：10 / 15 / 20 / 30 fps 约 14 / 22 / 29 / 40%；60 fps 约 45–55%，多出的流畅度换不回成本；与 PR 198 默认一致 |
| 2026-10-06 | 否决 30 fps，改为跟随屏幕、上限 60 fps | 用户：「30帧太卡了」。实测 MarqueeLabel 在 60 Hz 屏上每帧移动整 1 pt、约 60 次/秒，这才是要还原的流畅度；ProMotion 屏上不跟到 120，否则开销翻倍 |
| 2026-10-06 | 位置对齐设备像素，不用小数坐标 | 小数坐标让每次贴图都要软件插值重采样，只有歌词时 60 fps 从 35% 涨到 43%，而 MarqueeLabel 自己也走整数位置，并不更顺 |
| 2026-10-06 | 帧率上限做成隐藏偏好 `MenuBarLyricsScrollFramesPerSecond` | 流畅度与 CPU 的取舍只能靠看，按惯例做成运行时可切换的变体，默认值 60 |
| 2026-10-06 | 不靠钉死条目内容的外观来省重画 | 截图时 AppKit 会强制条目里每个视图重画；钉死外观后重画次数一次不少 |
| 2026-10-06 | 只在 macOS 26 及以上启用 | 循环只出现在截图副本路径上；旧系统本机无法验证，保持原状 |
| 2026-10-06 | 视图标为 `@available(macOS 26, *)`，直接用 `CADisplayLink`，去掉内部版本判断和 Timer 后备 | 用户要求；控制器经私有协议只保留创建时那一处 `#available` |
| 2026-10-06 | 直接创建 `NSTextFieldCell`，不再从 `NSTextField` 复制 | 用户问「不可以直接创建吗」。直接创建的 cell 只有换行策略一项不同（只在 `NSTextField` 上公开），对单行截图无影响，32/32 一致；尺寸改用像素对齐的 `cellSize`，与 `sizeToFit` 完全相同 |
| 2026-10-06 | 缓存位图不再四周留 7 pt，就按文字框大小 | 运行中的 App 里文字框会裁掉溢出的 emoji；留白是在测试进程里比对时被误导的结果（那里的文字框不裁剪） |
| 2026-10-06 | 改为 `NSControl` 子类、`cellClass` 返回 `NSTextFieldCell` | 用户问「继承NSControl重写cellClass会不会更符合AppKit习惯」。先用空闲探针验证它不会像 `NSTextField` 那样循环：两种画法 × 有无播放按钮，24 次启动全部为 0；改完后截图仍 32/32 一致 |
| 2026-10-06 | 改名 `MenuBarMarqueeLabel`，配置全部移进 `NSTextFieldCell` 子类 `MenuBarMarqueeLabelCell` | 用户要求；控件只管滚动、缓存和绘制，长什么样由 cell 决定 |
| 2026-10-06 | 截图比对挪进探针宿主，测试进程不碰 AppKit | 一是测试进程的文字框行为与 App 不同；二是 macOS 27.2 beta 上从终端跑开窗口的测试会在 Dock 留下不消失的图标，用户要求不要这样跑 |
| 2026-10-06 | 落地到 `develop`，编号 0017，状态 Implemented | 用户要求提交并推送。配套文档：实现说明《菜单栏歌词的绘制》写在同一批次，已登记在头部；新术语「截图副本（replicant）」已加进项目术语表 |
