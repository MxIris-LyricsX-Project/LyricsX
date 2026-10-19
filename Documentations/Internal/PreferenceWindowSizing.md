# 设置窗口的尺寸

> 面向维护者。讲的是「为什么这么实现」，不是「实现了什么」——后者读代码更快。

## 一句话

设置窗口不可缩放，尺寸全靠内容算；但 `NSTabViewController` 只在选中页**把自己钉死成一个尺寸**时
才会去动窗口，所以内容可拉伸的页会原样留着上一页的窗口大小 —— 表现为「同一个 tab，从不同 tab
切过去高度不一样」。修法是切页后按选中页的 `fittingSize` 主动定窗口尺寸，
并给几个可拉伸的控件补上优先级 700 的尺寸约束。

## 为什么窗口会「继承」上一页的尺寸

窗口自己带一条**保持现有大小**的约束，优先级 500（`NSLayoutPriorityWindowSizeStayPut`）。
选中页的内容要压过它，那个方向上必须解出**唯一**尺寸；只给出下界（`>=`）、或者链条上有个
hugging 优先级低于 500 的控件，500 那条就赢，窗口纹丝不动。

`NSTabViewController` 本身没有任何窗口尺寸逻辑 —— 它的 `updateViewConstraints` 只把 tabView
钉到自己 view 的四边（优先级 742），剩下的完全交给 Auto Layout。所以这不是「AppKit 的 bug」，
是「约束没写完整」的正常结果。

修之前六个页里有四个中招：

| 页 | 内容真正需要 | 可拉伸的元凶 | 症状 |
|---|---|---|---|
| General | 611×782 | —— | 正常（它最大，别人缩不进来，看着像好的） |
| Display | 439×398 | 嵌套的 `NSTabView`（宽度只有下界） | 宽度继承 |
| Shortcut | 600×376 | —— | 正常 |
| Filter | 600×408 | `NSScrollView`（只有 `width>=160` / `height>=200`） | 宽高都继承 |
| Lab | 615×732 | `NSGridView`（hugging 250 < 500） | 高度继承 |
| Source | 449×294 | `NSScrollView`（完全没有尺寸约束） | 宽高都继承 |

General 和 Shortcut「正常」有一半是巧合 —— General 是最大的那个，任何页切过去都得放大到它，
required 的下界自然生效。**不要把「现在看着没问题」当成「这一页写对了」。**

修完的实际尺寸（每一页都只有这一个值，与从哪一页切过来无关）：

| 页 | General | Display | Shortcut | Filter | Lab | Source |
|---|---|---|---|---|---|---|
| 窗口 | 611×870 | 600×486 | 600×464 | 600×496 | 615×866 | 600×448 |

Lab 的内容高度跟着页里的设置走，表里是英文界面的值：修的时候是 820，加「高清封面」一行后变成 865，
2026-10-14 把 Apple Music 的四项收进一个组框后是 866。文字长的语言会多折几行，德语、印尼语、
荷兰语约 930，西班牙语、法语、俄语约 946。

**Lab 现在可以滚动，页高封顶在通用页的高度。** 13 寸 MacBook Air 默认分辨率下屏幕高 900 pt，减去
菜单栏，窗口最多约 876 pt；超出的部分会落到屏幕底边以下，这个窗口又不能缩放，最底下的设置就看不到了。
英文 866 时上面那几种语言已经超了，2026-10-19 要再加「歌词翻译」组框，JH 选了改成可滚动，没有拆页：

- `PreferenceLabViewController` 在 `viewDidLoad` 里把 storyboard 的 grid 挪进一个 `NSScrollView`，
  document view 是 flipped 的，打开时停在第一行。storyboard 本身不动。
- 滚动视图的高度 `== 内容高度 @700`，再加一条 required 的 `<= 上限`，所以 `fittingSize` 取两者中
  较小的那个，窗口照常按 `fittingSize` 定尺寸。700 的理由见下文「约束优先级为什么是 700」。
- 上限是通用页的 `fittingSize` 高度（英文 782，窗口 870），每次 Lab 页出现时现量，量不到时用 782。
  通用页是不滚动的页里最高的，它的窗口本来就得放得下。
- 宽度等于内容宽度。系统设成「始终显示滚动条」时，传统滚动条只在内容超出时出现，盖在 grid 右侧
  20 pt 的边距上；clip view 不许横向滚动，免得触控板把内容横着推开一个滚动条的宽度。
- 「歌词翻译」组框也在代码里建，照 Apple Music 组框的结构：内层 grid 缩进 12 pt、标签列 138 pt，
  正好对齐外层 150 pt 的标签列。全部交给 Auto Layout，从右到左的语言会跟着镜像。**代码里建的 `NSBox`
  要把 `contentViewMargins` 设成 0**：它默认四周留 5 pt，storyboard 里的组框是 0，不改的话框里的控件
  整体偏 5 pt、输入框窄 10 pt。

往 Lab 加行不用再顾虑页高。通用页要加行时，得先想好通用页怎么办 —— 它同样顶到了 870。

**Display 的 600 是硬撑出来的**：它的内容其实只要 439 宽，根 view 上那条
`width == 600 @700`（`dsp-rt-wid`）是为了让它和其余各页一样宽，不然切到这一页时窗口会
明显缩一截。代价是右侧留白 —— 这是有意的取舍，**不要看到留白就把这条约束删掉**，
删了它就退回 439。真要消掉留白，得让页里的内容用满这个宽度，而不是动这个数字。

General 的 611 和 Lab 的 615 没有硬撑，是这两页内容自己要的宽度，压不下去。

## 约束优先级为什么是 700

补的尺寸约束用等式 + 优先级 700，两边都卡着：

- **必须 > 500**，否则压不过窗口的 stay-put，等于没补。
- **必须 < 750**，因为 750 是 `NSTextField` / `NSButton` 默认的**内容压缩阻力**。
  取 750 会和它打平，Auto Layout 解不出唯一值，实测窗口宽度会在两个值之间漂移
  （同一页两次运行分别是 335 和 540）。取 700 则本地化后文字变长时压缩阻力赢，
  窗口自动撑宽，不产生约束冲突。

**不要图省事写成 required。** 那样德语之类的长文本会直接撞出「Unable to simultaneously
satisfy constraints」。

## 为什么测的是选中页，不是 controller 自己的 view

`resizeWindowToFitSelectedTabViewItem` 量的是 `children[selectedTabViewItemIndex].view`
的 `fittingSize`，不是 `self.view` 的。

Display 页里套了另一个 `NSTabView`。向外层 view 要 `fittingSize` 时，嵌套 tabView 报的是
**它当前的尺寸**而不是内容需要的尺寸，于是算出来的目标尺寸恰好等于当前窗口尺寸，
`guard targetFrame.size != window.frame.size` 直接 return —— 修复静默失效，Display 页
照旧继承上一页尺寸。改量选中页本身就没这个问题（tabView 是 `noTabsNoBorder`，
和页面之间没有边距）。

窗口 frame 是自己算的而不是用 `setContentSize`：后者保持左下角不动，窗口会「往上长」，
标题栏乱跑。这里保持 `maxY` 不变，让窗口向下伸缩。

## 为什么切 tab 没有动画

**目前是瞬间改变窗口尺寸，没有任何动画。** 试过一版
（`NSAnimationContext` 包窗口 frame，0.25s、ease-in-ease-out，frame 算法和时长取自
[sindresorhus/Settings](https://github.com/sindresorhus/Settings) 的 `SettingsTabViewController`），
实际观感被否掉了：只有窗口在动、内容瞬切，反而比不动更难看。**要重做请连内容过渡一起做，
不要只加窗口动画。**

而内容 crossfade（`transitionOptions = [.crossfade]`）在当前架构下做不出来，试过三种写法都不行：

参考的那个库自己拥有容器，过渡前会把旧页的约束整个摘掉（`view.removeConstraints(activeChildViewConstraints)`），
过渡期间两个页都不参与布局，窗口尺寸完全由代码说了算。`NSTabViewController` 不给这个机会 ——
crossfade 期间新旧两页**同时挂在容器里且都受约束**，旧页的 required 约束会把窗口按住不让缩，
实测窗口动画走到目标尺寸后又弹回原尺寸（870 → 449 → 870）。

试过的绕法和结果：

| 写法 | 结果 |
|---|---|
| 在 `transition(from:to:options:)` 里包动画组，先 resize 再 `super` | 目标页还没进层级，`fittingSize` 测不准，Display / Lab 尺寸继承回归 |
| 同上，改成先 `super` 再 resize | 测量准了，但旧页仍在撑窗口，尺寸继承回归 |
| 再加 `fromViewController.view.translatesAutoresizingMaskIntoConstraints = true` 把旧页踢出布局 | 动画平滑了，但破坏了页自身的布局，六个 tab 里五个不稳 |

最后落在 `tabView(_:didSelect:)`：这时**新页已进层级并布局完**（`fittingSize` 可信），
**旧页已被移除**（撑不住窗口了），两个前提同时成立，只有这里成立。代价是内容瞬切、只有窗口是动的。

真要 crossfade，就得像参考库那样彻底接管容器（不再用 `NSTabViewController` 的 tab 切换），
这笔账要和[提案 0006 设置界面迁 SwiftUI](../Evolutions/0006-swiftui-settings.md) 一起算，
不值得单独为它重写一遍旧架构。

## 加新 tab 时要注意什么

新页里只要有 `NSScrollView`、`NSTableView`、`NSGridView`、嵌套 `NSTabView`，或任何
hugging 优先级 ≤ 500 的控件夹在从顶到底（或从左到右）的约束链里，就得给它补一条
优先级 700 的尺寸等式，否则这一页的尺寸又会跟着来源变。

代码层面的兜底（按 `fittingSize` 定窗口）能保证**尺寸稳定**，但保证不了**尺寸合理** ——
Source 页没补约束前 `fittingSize` 算出来是 449×294，那是表格被压扁到最小的状态。
两层都要有。

**grid 里的可编辑输入框必须给定宽度。** 可编辑的 `NSTextField` 没有固有宽度，放进 `NSGridView`
默认 leading 对齐的单元格后，「0 到整列宽」之间的任何宽度都满足约束，结果由求解器随意决定。
实验室页的四个输入框（Musixmatch 一个、Apple Music 三个）原来就是这样：从左到右时碰巧撑满整列，
从右到左（阿拉伯语、波斯语）时塌成 0 宽。现在这四个单元格都是 `xPlacement="fill"`。新加输入框
同样处理，或者直接给它一条宽度约束。storyboard 里的 `placeholderIntrinsicWidth` 只在 Interface
Builder 里生效，运行时不算数。

## 怎么验证

设置界面没有自动化测试。手工验证方式是**逐一从每个 tab 切到每个其他 tab**，确认同一个目的
tab 的窗口尺寸与来源无关 —— 只切一两次很容易漏掉，因为从「比它小的页」切过去时窗口本来就得放大，
看起来是对的。

单个页的布局可以离屏检查，不用开 app：给 storyboard 副本里的那个场景加一个 storyboard identifier，
编译后单独实例化（custom class 用一个同名、同模块名的替身类接住 outlet），布局后量 `fittingSize`，
并对每个子 view 调 `hasAmbiguousLayout`。有两个坑：
- 场景所在的 bundle 跟着**主 bundle** 的语言走，裸可执行文件只会按英文加载。要把探针包成 `.app`，
  storyboard 和各语言的 `.strings` 放进它自己的 `Resources`，`-AppleLanguages` 才生效。
- 这样直接运行时，AppKit 不会因为语言是阿拉伯语就切成从右到左，还要另加
  `-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`。
