# 菜单栏歌词的绘制：实现说明

> 配套提案见 [菜单栏歌词改为自绘，不再用 NSTextField](../Evolutions/0017-menu-bar-lyrics-without-text-field.md)；
> 卡拉OK进度见 [菜单栏歌词的卡拉OK进度](../Evolutions/draft-menu-bar-karaoke-progress.md)。
> 本文记录**实际落地的实现**、为什么这样做，以及已知降级。面向维护者。

## 背景与目标

macOS 26 起，菜单栏上看到的状态栏条目不是 App 自己的窗口。系统菜单栏（Window Server 的
「Menubar」窗口）显示的是 AppKit 替 App 渲染的条目截图，即[截图副本（replicant）](../Glossary.md#截图副本replicant)。
本机 macOS 27.2 上，LyricsX 的状态栏窗口号是 2³²，不是真正的 window server 窗口，也不在屏幕上。

条目里的东西每变一次，AppKit 就要重新截图。MarqueeLabel 里的 `NSTextField` 会让这个过程停不下来：
1.9.0 在本机什么都没播也稳定占 ~49% CPU，采样显示主线程近一半时间在 `-[NSStatusItem _updateReplicants]` →
`_redrawReplicantSnapshot:sourceView:` → `cacheDisplayInRect:toBitmapImageRep:` 里反复重画那个文字框。
目标是换掉它：外观逐像素不变，滚动和 MarqueeLabel 一样顺，静止时零开销，滚动时也更省。

## 关键设计决策

### 不能用 `NSTextField`，调它的属性也没用

每次截图，AppKit 都会把条目的外观从实时外观（本机是 `VibrantDark`）切到截图外观（`DarkAqua`）、画完再切回。
条目里的 `NSTextField` 对这次切换的反应是把条目重新标脏，于是又安排下一次截图，形成每秒约 300 轮的循环；
同一条目里的按钮、图片也被一并重画，所以带三个播放按钮时是每秒约 1,200 次重画。

这个循环是**间歇性**的：同一个配置，有的启动会进入，有的不会，探针里大约 30–60% 的启动会进入。
一旦进入就不再退出——本机装着的 1.9.0 运行 24.7 小时累计用掉 11.9 小时 CPU，全程平均 48%（`ps -o etime,time`）；MarqueeLabel 滚动途中也会掉进去。

试过的规避都无效：`drawsBackground = false`、`NSTextField(labelWithString:)` 式配置，照样间歇进入循环。
旁边有没有按钮也不是条件，单独一个文字框也会进入。

而「`NSControl` 子类 + `cellClass` 返回 `NSTextFieldCell`」——也就是 `NSTextField` 去掉它自己额外加的那些行为——
**不会**进入循环：无论走 `NSControl` 默认的绘制还是自己在文字框位置画 cell、旁边有没有播放按钮，24 次启动全部为 0。
所以循环来自 `NSTextField` 这个类本身，不是 `NSControl` 把事件转给 cell 造成的（那是之前的猜测，已证伪）。
**不要因为某次启动没进入循环，就认为某个配置把它修好了**，这正是探针要跑多次启动的原因。

### 用 `NSTextFieldCell` 画字，而不是更「快」的写法

截图是 `cacheDisplay(in:to:)` 渲染出来的位图，两种画法截出来的字节一样，菜单栏上就一样。探针逐像素比较的结果：

| 画法 | 与 `NSTextField` 截图一致的张数（共 32） | 问题 |
|---|---|---|
| 复制 `NSTextField` 的 cell 来画 | 32 | — |
| `NSAttributedString` 画进 cell 的 title rect | 0 | 每句约 1,500 个像素不同，整句偏移 |
| PR 198：白字遮罩、填 `labelColor` | 0 | 位置不同；**彩色 emoji 变成单色剪影** |

`MenuBarMarqueeLabel` 本身是 `NSControl` 子类，`cellClass` 返回 `MenuBarMarqueeLabelCell`（`NSTextFieldCell` 的子类）——
这是 AppKit 里「由 cell 绘制的视图」的惯用写法，`NSTextField` 本身就是这样构成的。cell 由控件自己创建、持有，
文字走 `NSControl` 标准的 `stringValue`。全部配置都在 cell 的 `init(textCell:)` 里：按 `MLMarqueeLabel` 的
`-initWithFrame:` 逐项设置，再补上 `NSTextField(frame:)` 留下的那一项——背景是要画的（`drawsBackground = true`），
只是颜色为透明。`NSControl` 经 `init()` 创建 cell，`NSTextFieldCell` 会把它转到 `init(textCell:)`；
要是配置没跑到，cell 会画出边框和白底，截图比对立刻失败。绘制仍然覆盖 `draw(_:)`：控件本身是 183 × 24 的裁剪框，
字要画在滚动后的位置，而且每次都只拷贝缓存位图。
探针里「只画 cell 的自绘视图」从来没有进入过循环，证明问题出在 `NSTextField` 这个视图，不在画字这件事。

两处细节决定了能不能逐像素一致：

- **尺寸**：`sizeToFit` 给出的是把 `cellSize` 向外取整到设备像素（Retina 上 0.5 pt）的结果，所以这里用
  `backingAlignedRect(_:options: .alignAllEdgesOutward)`。窄半个点，句子会被截断；宽半个点，会多露出一截溢出的字形。
- **裁剪**：行尾的彩色 emoji 会溢出文字框。**在运行中的 App 里**，文字框的图层会把溢出部分裁到自己的边框为止，
  所以缓存位图就按文字框大小来画，不留白。
  注意：同样的比对放在测试进程里跑时，`NSTextField` 不裁剪溢出部分，曾经误导出「四周留 7 pt」的做法。
  这正是截图比对也必须放进探针宿主（真正的 App 进程）里跑的原因之一。

这个 cell 和 `NSTextField` 自己的 cell 仍有一处不同：`NSTextField(frame:)` 把 cell 的换行策略
（`lineBreakStrategy`）设成了空集，而这个属性只在 `NSTextField` 上公开，这里的 cell 保持 `.standard`。
它影响的是多行折行，单行歌词的截图里看不出差别（32/32 一致）。

### 位图按外观分别缓存

因为每次截图都会把外观切走再切回，一个视图每张截图要按两种外观各画一次。只缓存一份位图的话，
每次切换都会重新渲染，和直接画 cell 没有区别。按外观（以及缩放、色彩空间）分别缓存后，每次绘制都只是一次拷贝。

### 滚动的开销：每帧一轮截图往返，其中大半不由我们控制

用 swizzle 数 AppKit 私有方法的调用次数得到的结构（诊断代码已删除）：

- 滚动每走一帧，AppKit 调一次 `_updateReplicants`，对条目的**每个**截图副本各截一张图（`_updateReplicant:`）。
  本机（1 块屏、2 个桌面）有 2 个副本，所以每帧 2 张。副本数大概随显示器和桌面配置变化，未验证。
- 每张截图都会让条目里**每个**视图重画三次：按截图外观画进图层、画进截图位图、再按实时外观画回图层。
  所以歌词视图每帧画 6 次，每个播放按钮每帧画约 5 次。
- 这些重画是 AppKit 强制的。试过给条目内容钉死外观，想让截图时的切换传不进来：标脏调用少了，重画次数一次不少。

因此滚动的开销 = 帧率 × 每帧截图往返的固定部分 + 帧率 × 每帧每个视图的绘制。我们能控制的只有帧率和自己的绘制；
歌词视图每次绘制只是拷贝，剩下最大的可变项是三个播放按钮（每次都要重新栅格化 SF Symbol）。

### 帧率：跟随屏幕，上限 60

最初定的是 30 fps（带按钮时约 40% CPU），被否掉了：**「30帧太卡了」**。要还原的是 MarqueeLabel 的流畅度，实测它在
60 Hz 屏上由 `animator().frame` 每帧把文字框挪**整 1 pt**、每秒约 60 次。

所以移动阶段改由屏幕的 `CADisplayLink`（`NSScreen.displayLink(target:selector:)`）逐帧驱动，与刷新同步，
上限 60 fps：60 Hz 屏上与 MarqueeLabel 一致；ProMotion 屏上不跟到 120，否则开销再翻一倍，换来的差别很难看出。

上限做成了隐藏偏好 `MenuBarLyricsScrollFramesPerSecond`（`Int`，0 或不设 = 60；高于屏幕刷新率就等于跟随屏幕），
`MenuBarLyricsController` 在运行时订阅它，`defaults write` 下一帧即生效，供肉眼对比流畅度和 CPU：

```bash
defaults write dev.JH.LyricsX MenuBarLyricsScrollFramesPerSecond -int 30    # Debug 构建；Release 是 com.JH.LyricsX
defaults delete dev.JH.LyricsX MenuBarLyricsScrollFramesPerSecond           # 回到默认 60
```

### 位置对齐设备像素，不用小数坐标

试过让位置带小数、贴图时插值，想比 MarqueeLabel 更顺。结果每次贴图都变成软件插值重采样，乘以每帧 6 次，
只有歌词时 60 fps 从 35% 涨到 43% CPU；而 MarqueeLabel 自己也是整数位置，并不更顺。
现在位置对齐到设备像素（Retina 上 0.5 pt，比 MarqueeLabel 的 1 pt 还细），每次绘制都是纯拷贝。

### 只在 macOS 26 及以上启用

循环只出现在截图副本路径上。更早的系统没有这个问题的报告，而且本机无法验证旧系统上 vibrancy
（菜单栏的毛玻璃混合）下的观感，因此保持 MarqueeLabel 不变。

所以 `MenuBarMarqueeLabel` 整个类标为 `@available(macOS 26, *)`，内部不再做任何版本判断，直接用 `CADisplayLink`。
App 的最低系统是 12，控制器里仍要有一处 `#available`；为了只留这一处，两种视图都遵循控制器里的私有协议
`MenuBarLyricsMarquee`（`MarqueeLabel` 对「暂停」和「帧率上限」两项是空实现，它本来就不支持）。

### 探针必须以真实 App 的身份运行

这是写探针时踩出来的，三个条件缺一不可，缺了任何一个，状态栏条目都会悄悄退回旧的「自己窗口直接显示」路径，
什么都复现不出来：

1. **测试不能在主线程任务里嵌套跑 run loop。** 菜单栏场景的建立要靠主队列回调，嵌套 run loop 期间主队列不会排空。
   测试里要用 `await` 让出主线程。
2. **进程要有 bundle identifier。** 测试进程（`swiftpm-testing-helper`）没有。
3. **要经 LaunchServices 启动。** 由测试进程直接 exec 出来的子进程，即使有 bundle 也不行。

所以 `StatusItemProbeHostLauncher` 把 `StatusItemProbeHost` 可执行文件拷进一个临时 `.app`，写 `Info.plist`、
ad-hoc 签名，再用 `open -n -W` 启动；宿主把测量结果写成 JSON 报告。判断走对了路径的依据是报告里
状态栏窗口号为 2³²、窗口不在屏幕上。

不需要状态栏条目的截图比对也在宿主里跑，测试进程本身完全不碰 AppKit，原因有两个：

- 测试进程里的 `NSTextField` 不裁剪溢出的字形，和真正的 App 不一样（见上文「裁剪」）。
- macOS 27.2 beta 上，从终端启动、又开过窗口的测试进程会在 Dock 留下一个退出后也不消失的终端图标，每跑一次多一个。

### 什么时候显示占位文字

菜单栏这一行由 `MenuBarLyricsLinePolicy` 决定显示什么：当前行、占位文字「LyricsX」（启动后还没有歌词时就是它），
或者保持不变。

- **没有歌词，显示占位文字。** 换歌时 `AppController` 先把歌词清空，所以新歌的前奏、找不到歌词的歌都是占位文字。
  原来这里什么也不做，菜单栏一直停在上一首的最后一句：上游会清空，2024 年 9 月改用占位文字时清空那一行被注释掉了。
- **开着「暂停时隐藏菜单栏歌词」时暂停，显示占位文字。** 这个开关在实验室页，键是 `MenuBarHidesLyricsWhenPaused`，
  默认关，所以默认暂停时菜单栏保留当前那一句。暂停本身既不换歌词也不换行，所以控制器还跟着播放状态和这个设置的变化
  重新判断，继续播放时换回当前行。
- **菜单栏不看桌面歌词的「隐藏歌词：暂停播放时」。** 1.9.0-rc.2 曾让菜单栏也跟着这个设置走，可它放在桌面歌词的选项卡里、
  默认开着，结果没碰过设置的人每次暂停都只看到「LyricsX」。所以菜单栏改用自己的开关，桌面歌词那个设置回到只管桌面歌词。
- **有歌词但没有行号，保持不变。** 每次换下屏幕上的歌词（翻译到了、换了一条候选），`AppController` 都先把行号清空、
  马上再设回来；这时换成占位文字会闪一下，当前行还会从头滚。新歌开头本来就已经是占位文字，所以不受影响。代价是
  同一首歌里往回拖到第一行之前，菜单栏还停在拖动前那一行，直到唱到第一行。
- 行号超出歌词的行数时也保持不变，不去读那一行。

### 卡拉OK进度

实验室页的「Show karaoke progress in menu bar lyrics」（键 `MenuBarKaraokeProgressEnabled`，默认关）打开后，
有逐字时间标签的行把已唱的部分画成系统强调色，未唱的部分照旧。只有行时间的歌词没有进度，和桌面歌词一样。

- **进度怎么算**：`LyricsXFoundation` 的 `KaraokeLineTiming` 从行的 `attachments.timetag` 算出某一时刻已唱了几个字符：
  一个标签表示那个字符从这一刻开始唱，两个标签之间按时间线性增长，第一个之前、最后一个之后保持不动；
  行有时长时在行末补一个「全部唱完」的关键帧。这和桌面歌词的进度动画读标签的方式一致。
- **怎么画**：在原有的按外观缓存的位图之外，再按外观缓存一张强调色版本，由 cell 的副本画出、只换了文字色。
  以进度为界，左边贴强调色位图、右边贴原位图；界线和文字的位置都对齐设备像素，所以两块都是纯拷贝，
  没有哪个像素是两张位图混出来的。还没唱到第一个字时只贴原位图，和关掉开关时逐像素一致。
  系统强调色一变（`NSColor.systemColorsDidChangeNotification`）就清掉强调色缓存。
- **字符在哪**：用 Core Text 按 cell 的属性字符串排成一行，再加上 cell 的文字内边距 2 pt
  （`MenuBarMarqueeLabelCell.horizontalTextPadding`，`cellSize` 比文字宽 4 pt 就是这两边的内边距）。
  探针拿它和截图里的墨迹比：内边距写成 4 时两头都偏 2.2 pt、探针变红；写成 2 时偏差约 0.25 pt。
  只要 Core Text 排出了一段从右到左的 run（从右到左的文字、混排），这一行就不记位置，也就不显示进度。判断看 run 的方向，
  不看位置是否递增：英文里夹一个希伯来字母时，位置照样递增，只是那个字母的宽度被并进了它前面的空格。
- **一份位图缓存**：原样的和强调色的位图放在同一个字典里，key 里多一位「是否已唱」，换行时一起清，强调色变化时只清已唱的。
- **怎么走**：控制器每次给的是「此刻的歌词时间」（播放位置加上歌词偏移），视图记下它和当时的时钟，之后按自己的时钟推进。
  暂停时锚点停在暂停那一刻，继续播放时和滚动的起点一起后移，所以暂停前后进度不跳。
  推进期间和滚动共用同一个 display link 与帧率上限 `MenuBarLyricsScrollFramesPerSecond`，到下一个设备像素才重画；
  还没唱到第一个字时挂一次性定时器，唱完就停。
- **什么时候重新锚定**：换行、播放状态变化（跳转、暂停、继续）、歌词偏移变化（这首歌的和全局的）、开关变化。
  跳到另一行时，新行到达前的一瞬间旧行会按新位置画成全满或全空，随即被新行替换。控制器每次切换 App
  都会重发当前行（开关关着时也一样），带着刚从播放器读到的位置，它会抖动几十毫秒：所以「没有进度」再说一遍什么都不做，
  同一行的时间和视图自己的时钟相差不到 0.1 秒也什么都不做，否则每次切换 App 都会重启滚动的 display link、
  让进度边缘前后抖一下。暂停、继续、跳转都超过这个差值。
- **主线程只读交给它的那一份**：控制器在歌词显示队列上写 `screenLyrics`，每次写完把整份（文字、时长、进度）交给主线程，
  主线程只读这一份。原先主线程直接读 `screenLyrics`，既是跨线程读，也可能把这一行的文字和下一行的进度凑在一起。
- **文字相同的连续两行**：关着进度时，菜单栏把它们当成同一行，不重新滚动（原有行为）。开着进度时第二行有自己的时间，
  视图收到另一行的时间就从头滚动，否则长句第二遍的进度会从左边看不见的地方开始。
- **只在 macOS 26 及以上**：更早的系统用 MarqueeLabel，`setKaraokeTiming` 是空实现，实验室页的勾选框不可用、
  提示「Requires macOS 26 or later」。
- **开销**：进度每走一步都是一轮截图往返，和长句滚动的每一帧一样，所以开关默认关。实测见下文「验证」。

## 模块结构

```
LyricsXPackage/
├── Sources/LyricsXFoundation/MenuBarMarqueeLabel.swift     # 正式实现：滚动、位图缓存、绘制
├── Sources/LyricsXFoundation/MenuBarMarqueeLabelCell.swift # 它的 cell，复刻 MarqueeLabel 文字框的全部配置
├── Sources/LyricsXFoundation/KaraokeLineTiming.swift       # 卡拉OK进度：从逐字时间标签算已唱的字符数
├── Tests/StatusItemProbeSupport/                           # 探针与宿主共用
│   ├── StatusItemContentFixtures.swift                     # 复刻 MarqueeLabel 文字框、播放按钮、条目布局
│   ├── LiveStatusItemHarness.swift                         # 真实状态栏条目、绘制与位置计数、进程 CPU 时间
│   ├── StatusItemSnapshotParity.swift                      # 截图逐像素比对本身（在宿主里跑）
│   ├── StatusItemKaraokeRendering.swift                    # 卡拉OK进度的离屏截图检查与时钟检查（在宿主里跑）
│   └── StatusItemProbeProtocol.swift                       # 宿主的命令行请求与 JSON 报告
├── Tests/StatusItemProbeHost/StatusItemProbeHost.swift     # 探针宿主 App 的入口
└── Tests/MenuBarLyricsTests/
    ├── StatusItemProbeHostLauncher.swift                   # 打包临时 .app、经 LaunchServices 启动、读报告
    ├── StatusItemTextParityProbes.swift                    # 截图逐像素比对（宿主里离屏渲染）
    ├── StatusItemKaraokeProbes.swift                       # 卡拉OK进度的画法、字符位置与暂停（宿主里离屏渲染）
    ├── StatusItemKaraokeCostProbes.swift                   # 卡拉OK进度推进时的步长、频率与开销（真实条目）
    ├── StatusItemIdleRedrawProbes.swift                    # 静止时是否还在重画（真实条目）
    └── StatusItemScrollCostProbes.swift                    # 滚动的流畅度与开销（真实条目）
```

App 端：`MenuBarLyricsController` 按系统版本选视图（唯一一处 `#available`），经私有协议 `MenuBarLyricsMarquee`
转发文字、卡拉OK时间、播放状态和帧率偏好；`Global.swift` 声明隐藏偏好 `menuBarLyricsScrollFramesPerSecond`、暂停开关 `menuBarHidesLyricsWhenPaused`
和卡拉OK开关 `menuBarKaraokeProgressEnabled`。显示哪一行由
`LyricsXFoundation` 里的 `MenuBarLyricsLinePolicy` 决定，测试是 `LyricsXFoundationTests` 里的
`MenuBarLyricsLinePolicyTests.swift`。

## 核心数据流

1. 控制器把当前行和行时长交给 `setStringValue(_:lineDisplayTime:)`；空字符串和重复的同一行直接忽略。
   开着卡拉OK进度时，紧接着用 `setKaraokeTiming(_:lyricsTime:)` 交上这一行的 `KaraokeLineTiming` 和此刻的歌词时间。
2. 新的一行会重建 cell、清空位图缓存、量出每个字符的位置、丢掉上一行的进度、记下起始时间。
3. `updateMotion()` 按「停 → 走 → 停」的时间表算出当前位置，并按歌词时间算出已唱的宽度：两者有一个在动就开
   display link（加在 common modes 上，菜单展开时也会继续走），否则为先开始动的那个挂一次性定时器。每一帧把位置和
   宽度对齐到设备像素后写进 `scrollPosition` 与 `sungWidth`，变化时触发 `needsDisplay`；都停了就关掉 display link。
4. `draw(_:)` 取当前绘制外观对应的缓存位图，没有就现画一张，然后在像素对齐的位置拷贝；有进度时以已唱的宽度为界，
   左边换成强调色位图。

## 与提案的差异

无。

## 验证

```bash
cd LyricsXPackage
# 截图逐像素比对：启动一次探针宿主，在里面离屏渲染，约 5 秒
swift test --filter StatusItemTextParityProbes
# 卡拉OK进度：同样在宿主里离屏截图，再检查字符位置与暂停（约 1 秒）
swift test --filter StatusItemKaraokeProbes
# 卡拉OK进度在真实条目上推进时的步长、频率与 CPU（约 15 秒，会在菜单栏出现测试条目）
swift test --filter StatusItemKaraokeCostProbes
# 真实条目：会启动一个临时 App，并在菜单栏出现几秒测试条目；空闲约 80 秒，滚动约 25 秒
swift test --filter "StatusItemIdleRedrawProbes|StatusItemScrollCostProbes"
```

- **外观**：5 句短句（含中、英、日文和 emoji）加一句长句停在 3 个滚动位置，在 4 种外观下比对，32 张截图必须全部一致；
  另外每一句的文字框尺寸都要与 `sizeToFit` 完全相同。
- **空闲**：正式实现与 MarqueeLabel 文字框各配三种旁邻（无 / 播放按钮 / 符号图片），每种启动 3 次。
  正式实现任何一次重画都算失败；文字框作为已知问题记录（它会间歇进入循环）。
- **滚动**：只有歌词时，正式实现每秒移动次数不得低于 MarqueeLabel 的 90%，每步不得比它粗 0.5 pt 以上，
  CPU 必须比它低。带播放按钮的配置只打印不断言。本机最近一次（Debug 构建，长句持续滚动 4 秒）：

  | | CPU | 每秒移动 / 每步 |
  |---|---|---|
  | MarqueeLabel，只有歌词 | 48.2% | 60 次 / 1 pt |
  | 新视图，只有歌词 | 39.0% | 58.5 次 / 1 pt |
  | MarqueeLabel + 播放按钮 | 64.9%（滚动中也掉进了循环） | 60 次 / 1 pt |
  | 新视图 + 播放按钮 | 47.9% | 58.5 次 / 1 pt |

  同一场景几次运行之间有 ±5 个百分点的波动。
- **卡拉OK进度（截图）**：两句短句（居中）加一句长句停在滚动中途，在 4 种外观下各截「还没唱」「唱完」「唱到一半」三张，
  共 36 张：还没唱的与没有进度的逐像素一致；唱到一半的，界线左边与「唱完」、右边与没有进度的逐像素一致；唱完的必须看得出不同。
  另外核对字符位置与墨迹（偏差不得超过 1 pt），以及暂停、继续、暂停时重新锚定之后的进度，和文字相同的另一行会让长句从头滚动。
- **卡拉OK进度（真实条目）**：短句「Let It Go, let it go」在 4 秒里唱完，步长不得超过一个设备像素、每秒步数不得超过 60 的上限，
  CPU 只打印。本机（Mac Studio M3 Ultra，macOS 27.2，Debug 构建）2026-11-15 的一次：

  | | CPU | 每秒移动 / 每步 |
  |---|---|---|
  | 卡拉OK进度，只有歌词 | 43.9% | 47.5 次 / 0.5 pt |
  | 卡拉OK进度 + 播放按钮 | 45.9% | 47.0 次 / 0.5 pt |
  | 同一次运行里的长句滚动，只有歌词 | 46.0% | 58.2 次 / 1 pt |

  步数由句子宽度和时长决定（这句约 110 pt 唱 4 秒），比上限低；和滚动一样，开销几乎全是每一步的截图往返。
- **本次没有做**：在真实 App 里肉眼看菜单栏效果，以及用真实 App 测整体 CPU。

## 已知降级

- **滚动时仍有开销**：带播放按钮的长句在走的那一段约 48% CPU，大头是 AppKit 每帧的截图往返和按钮重画，不在画字。
  滚动只发生在超长的句子、且只在一句里「走」的那一段，整首歌平均要低得多。
- **静止开销**：画字部分为零。条目若因别的原因变化（播放按钮状态切换等），仍会照常截图。
- **卡拉OK进度一直在走**：开着进度时，有逐字时间的歌整首都在推进，开销和长句滚动「走」的那一段相当，见「验证」里的实测；
  所以开关默认关。
- **卡拉OK进度的几处粗糙**：从右到左书写的文字、以及两种方向混排的行不显示进度（这类行
  从左边填会先显示成全唱完、再从左往右变空）；只有行时间的歌词没有进度；换歌、跳到另一行、在行的交界处调偏移时，
  新行到达前的一瞬间旧行会画成全满或全空。
- **实机外观没看过**：探针比的是截图字节，真实菜单栏里强调色在各种壁纸、浅色深色菜单栏上的观感还没有肉眼确认。
- **探针的副作用**：会在菜单栏短暂出现名为「LyricsX Status Item Probe」的测试条目，临时 App
  （bundle id `dev.JH.LyricsX.StatusItemProbe`）会在 LaunchServices 里留下一条记录，可能出现在系统设置的菜单栏 App 列表里。

## 后续工作

- 播放按钮也改成按外观缓存的贴图（每帧每个按钮约 5 次 SF Symbol 栅格化），是滚动开销里剩下最大的可变项。
- PR 198 的静态分页（翻页式，不连续滚动）可以作为可见设置项另行提案。
- 等最低系统升到 macOS 26，再删掉 MarqueeLabel 依赖和旧路径。
- 卡拉OK进度的颜色目前固定为系统强调色；要的话可以另加颜色设置，但别沿用桌面歌词的进度色（默认青色在浅色菜单栏上看不清）。
- 长句的滚动目前按固定时间表走，与演唱进度无关；可以改成跟着进度滚，让进度边缘始终在可见区域里。

## 延伸阅读

- [菜单栏歌词改为自绘，不再用 NSTextField](../Evolutions/0017-menu-bar-lyrics-without-text-field.md)
- PR 198（SmallSquare，未合并）：同一问题的另一种实现
