# 已裁决的 code review 发现

这份清单记录**判定为误报、判定为不值得修、或决定暂缓修**的 code review 发现，以及判定的理由。

**每次 code review 先对照这份清单**：已裁决且理由仍成立的发现直接跳过，不再重复走"能否复现 / main 是否也有 / 值不值得修 / 以前修过吗"这四问。若有新证据推翻当初的理由，更新对应条目并重新裁决，不要另起一条。

确认为真并已修复的发现不记在这里 —— 它们的记录是修复 commit 本身和随之保留的回归测试。

---

## 2026-08-08 · PR #177（拆分为 #179 / #181 / #182 / #183 / #184）

### 新增用户可见字符串未本地化 —— 误报

**发现内容**：AI 翻译相关的界面新增了约 25 条 `NSLocalizedString`，声称只有 `Edit`、`Search`、`Embedded lyrics cannot be edited.` 三条进了 `Localizable.xcstrings`，其余在全部 16 种语言下都是英文。

**裁决：误报。** 实际比对 `Localizable.xcstrings` 的 key 集合，42 条新增 key **全部**已登记。其中 39 条只带 `zh-Hans` / `zh-Hant` 两种译文，其余语言留空 —— 而这正是本项目的正常流程：源字符串即英文，其余语言由 Crowdin（`crowdin.yml`）同步补齐。空译文不等于未登记。

**复核方式**：解析 master 与 PR 两侧的 `.xcstrings`，对 `strings` 的 key 集合求差集，而不是看 diff 行数。

### 歌词窗口占位标签可能弹出空右键菜单 —— 不可达，不修

**发现内容**：`LyricsHUDViewController` 里 `noLyricsLabel.contextMenuProvider` 直接返回 `lyricsViewContextMenu()`，没有像 `ScrollLyricsView` 那样加 `!menu.items.isEmpty` 判断，因此用户右键"暂无歌词"占位文字时可能得到一个空菜单。

**裁决：不修。** `lyricsViewContextMenu()` 只有在 `NSApp.delegate as? AppDelegate` 转换失败时才返回空菜单。本应用的 delegate 恒为 `AppDelegate`，该分支在运行期不可达，构造不出触发场景。

**若理由失效**：若将来引入了替换 app delegate 的测试宿主或插件宿主，这条要重新裁决 —— 届时正确做法是让 `lyricsViewContextMenu()` 在为空时返回 `nil`，而不是在三个调用点各写一遍判断。

### 队列收敛应改用 `@globalActor` —— 属架构建议，不作为缺陷记录

**发现内容**：`AppController` 用 `@unchecked Sendable`、手写的 transfer box、`DispatchQueue.isOnLyricsDisplay` 分支和 continuation 包装来把 `currentLyrics` 收敛到 `DispatchQueue.lyricsDisplay`，而不是用 Swift 6 的 `@globalActor`。

**裁决：不作为缺陷。** 代码能编译、行为正确，这是设计取舍而非 bug。但它是真实缺陷「主线程 `persist()` 与队列上的 `persist()` 竞争」的成因 —— 约定式的收敛没有编译器兜底，所以同一个 PR 自己新增的主线程写入没人拦得住。

**已转入**：PR #183 的设计讨论。若该 PR 最终仍采用手写收敛，则那条竞争缺陷必须单独修复并保留回归测试。

**2026-10-19 重新裁决（PR #204）**：#204 仍是手写收敛（`performOnLyricsDisplayQueue`），竞争本身已修：`persist()` 的每个调用点都挪进了歌词队列，包括搜索面板「使用」按钮那一处。回归测试做不到 —— 这些调用都在 app target 里，而 app 没有测试 target。JH 选定的替代是在 `persist()` 开头加一条只在 Debug 构建生效的 `dispatchPrecondition(condition: .onQueue(.lyricsDisplay))`：以后谁从别的队列写歌词，开发时第一次调用就会 trap，不会悄悄留下竞争。

**若理由失效**：app 有了测试 target，或 `currentLyrics` 改成 `@globalActor` 由编译器检查，这条要重新裁决 —— 前者补回真正的回归测试，后者连断言都可以删。

---

## 2026-10-19 · PR #204

### 设置面板的提示词编辑框宽度为 0 —— 误报

**发现内容**：AI 翻译设置面板把一个裸 `NSTextView()` 设成 `NSScrollView` 的 document view，没设 `autoresizingMask`、
`minSize`、`maxSize`。审查时判断它会停在创建时的零宽度、提示词看不见，为此提交过一次修复（`d13ace10`，改用
`NSTextView.scrollableTextView()`）。

**裁决：误报，那次修复已撤回。** 离屏探针在 macOS 26.7 上实测：照原写法放进 Auto Layout 滚动视图的裸 `NSTextView`
被撑到滚动视图的宽度（381 pt 的滚动视图里 381 pt）；真实的设置面板里也一样，英文、德语、俄语、简体中文、阿拉伯语都
撑满（英文 454 pt、简体中文 499 pt）。

**复核方式**：AppKit 的尺寸行为别凭读代码判断。按《设置窗口的尺寸》「怎么验证」一节的离屏方法，把面板放进透明窗口
布局之后，比较 `promptTextView.frame.width` 和 `enclosingScrollView.contentSize.width`。

---

## 2026-10-27 · 发版前的整项目审查

### `CXExtensions` 里几个 Combine 工具写错了 —— 不可达，不修

**发现内容**：`LyricsX/Utility/CXExtensions/AnyScheduler.swift` 的 `_equalTo` 用 `<` 判断相等（第 126 行），毫秒、微秒、纳秒的时间换算是乘而不是除（第 290–292 行）。

**裁决：不修。** `AnyScheduler`、`Blocking`、`WeakAssign`、`SelfRetainedCancellable`、`DelayedAutoCancellable`、`IgnoreError` 在 app 里都没有调用方（`CXExtensions/` 之外 grep 不到），这些错误在运行期碰不到。真正用到的只有 `Invoke`（`weaklyOn`）、`Signal` 和 `prepend`，审查没在它们身上发现问题。

**若理由失效**：一旦有代码开始用上面任何一个，这条要重新裁决，而且得先修好再用。更省事的做法是直接删掉这些没人用的工具。

### 自动写入会覆盖「音乐」里原有的歌词 —— 确认为真，暂缓到 1.9.0 正式版之后

**发现内容**：开着「写入歌词到 iTunes：自动写入」时，每次搜索跑完，`writeToiTunes(overwrite: true)` 都会覆盖「音乐」里
这首歌原有的歌词，用户自己的纯文本歌词也不例外。

**裁决：这一版不修，正式版之后处理。** 上游 2017 年起就是这样，不是这一版引入的；要修得让 LyricsX 跨启动记住自己写过
什么，超出了发版前的范围。完整说明和绕过办法见
[把歌词写进「音乐」](Internal/MusicLyricsWriting.md#已知问题自动写入会覆盖用户原有的歌词)。

**若理由失效**：1.9.0 正式版发布之后，这条就该修了，不能再以「发版前」为由跳过。

---

## 2026-10-28 · 发 RC2 前的取舍

上面那次审查列为「可以等」的发现里，这次修了四条：菜单栏残留上一首的歌词、app 退出后小组件仍显示正在播放、往歌词源
列表拖数字会崩溃、高清封面存到别的歌名下。下面这些决定留到 1.9.0 正式版之后。除了最后一条（系统翻译是 rc.1 新加的功能），
它们在 1.9.0-beta.14 里就有，不是这一版引入的。

**若理由失效**（这一节每条都一样）：1.9.0 正式版发布之后，不能再以「发版前」为由跳过，要逐条复核再修。

### 设置了 Apple Music token 时，启动后第一首歌搜不到歌词 —— 确认为真，暂缓

**发现内容**：`AppController` 初始化时 `lyricsManager` 是空的 `LyricsProviders.Group()`。设置了 `media-user-token` 时，
`updateLyricsManager()` 要先联网等 `isAuthorized` 返回，才把真正的歌词源装上，这之前开始的搜索一个歌词源都没有。

**裁决：暂缓。** 只影响设置了 token 的用户，而且只影响启动后的第一首，切一首歌或用「下一条候选歌词」就恢复。要修得改
搜索的初始化顺序：先同步装上不依赖 token 的歌词源，验证通过后再补上 Apple Music。

### `media-user-token` 明文存在偏好设置里 —— 确认为真，暂缓

**发现内容**：Apple Music 的 `media-user-token` 存在 `UserDefaults`（`AppleMusicMediaUserToken`），没有放进钥匙串。

**裁决：暂缓。** 搬进钥匙串还要迁移已有用户的值，发版前不动。AI 翻译的 API key 已经存在钥匙串里（`AITranslationService`），
照它的做法改。

### Intel 双显卡的 Mac 会切到独立显卡 —— 疑似，暂缓

**发现内容**：歌词面板的背景用 `MTLCreateSystemDefaultDevice()` 取 Metal 设备，在双显卡的 Intel Mac 上会选中独立显卡，
让系统切过去，开着面板更费电。

**裁决：暂缓。** 只影响开着 Apple Music 风格窗口的 Intel 双显卡 Mac，手上没有这类机器，改了也验证不了。修法方向：优先选
`isLowPower` 的设备，并在 Info.plist 里声明 `NSSupportsAutomaticGraphicsSwitching`。

### 从右到左的文字，扫光方向是反的 —— 未复现，暂缓

**发现内容**：卡拉 OK 的扫光从左往右推进，阿拉伯语、希伯来语这类从右到左的歌词会反着扫。

**裁决：暂缓。** 审查是读代码推出来的，没有用真实的从右到左歌词复现过，这类歌词也少。

### 泰文等文字的附加符号可能被裁掉 —— 疑似，暂缓

**发现内容**：泰文这类在字母上下叠附加符号的文字，符号可能超出行的绘制范围被裁掉。

**裁决：暂缓。** 要先写 probe 用真实字形确认是不是真的会裁。

### 发版流程在 GitHub Release 建好之后不能重跑 —— 确认为真，暂缓

**发现内容**：`release.yml` 中途失败、而 GitHub Release 已经建好时，重跑会在建 Release 那一步因为 Release 已存在而失败。

**裁决：暂缓。** 只影响发版出故障时的补救，用户碰不到。现在的办法是手动删掉那个 Release 再重跑。

### 系统翻译在 macOS 27 上不翻日文歌里的英文行 —— 确认为真，暂缓

**发现内容**：macOS 27.2 上，日译中的会话把「Baby I love you」原样返回，原样返回的行不保存，于是这一行没有译文，也不算失败。
macOS 26.7 上会翻。

**裁决：暂缓。** 要翻这些行，得再开一个英译中的会话，用户就要多下载一个语言，属于改方案，要单独写提案。行为差别已写进
[Lyrics translation](LyricsTranslation.md)，探针 `anEnglishLineInAJapaneseSongIsTranslatedWithTheRest` 在 macOS 27 上
把它记为已知问题，哪天系统又会翻了，探针会失败提醒。

---

## 2026-11-01 · 写 1.9.0 正式版发布说明时的核对

### Apple Music 风格歌词窗口的开关在 macOS 15 以下是灰的 —— 确认为真，暂缓

**发现内容**：窗口本身从 1.9.0-beta.9 起已能在 macOS 12–14 上运行（`bf48beac` 去掉了面板里的 macOS 15 限制），
但实验室页的「Use Apple Music-style lyrics window」开关仍被 `PreferenceLabViewController` 里的
`#available(macOS 15, *)` 禁用，提示「Requires macOS 15 or later」。所以 12–14 的用户只能用
`defaults write com.JH.LyricsX UseAppleMusicLyricsWindow -bool true` 打开，beta.9 发布说明里「12–14 可用」的说法言过其实。

**裁决：1.9.0 维持 macOS 15 起，暂缓到 1.9.x。** 放开要改代码，就得再发一个 RC、重新观察一周；而窗口在 12–14 上
没有经过界面打开的实测。正式版发布说明照现状写「macOS 15 或更高版本」。

**若理由失效**：1.9.0 发布后，在 macOS 12–14 的虚拟机里用上面的 `defaults write` 打开窗口实测；没有问题就删掉这个
版本判断，并在那一版的发布说明里写明支持范围。

---

## 2026-11-08 · 行内扫光改按 Music 26.6 的逐音节推进（`feature/apple-music-syllable-sweep`）

自审发现十条，修了四条：暂停时扫光继续走、行尾不带时间的文字在行结束时突然点亮、时长为零的末音节抢走整个羽化宽的
前沿、扫光与抬高各有一份音节分组。下面六条不修。

### 两个带时间的词之间夹着不带时间的可见文字，会在前一个词的最后一个音节里被扫亮 —— 确认为真，不修

**发现内容**：音节是词的最后一个音节时，目标取同一行下一个**带时间**的词的起点，中间不带时间的文字（比如
`Hello (oh) world` 里没有 span 的 `(oh)`）随前一个词一起扫亮。

**裁决：不修。** LyricsKit 解析 TTML 时，和声 `x-bg` 的外层 span 由内层词的时间合成一个带时间的词，可见文字几乎都在
span 里，只剩 span 之间的空格不带时间。真遇到这种文字，它本来就没有时间，何时点亮都是任意的；旧扫光是在前一个词
唱完时一下全亮，并不更好。

**若理由失效**：库里出现大量 span 之外的可见文字（比如某个来源把括号放在 span 外）时，改成停在下一个含可见字形的
词条起点。

### 从全亮或全暗的状态落进音节之间的空隙时，渐变不就地重放 —— 确认为真，不修

**发现内容**：行结束后时间小幅回退（不到 0.1 秒、不算跳变）落进最后一个音节之前的空隙，或者行首第一个音节短到一帧
都没碰上，阶段变成 `sweeping(lastSyllableIndex: nil)`，渐变停在原来的全亮或全暗，直到下一个音节开始。

**裁决：不修。** 前者要求最后一个音节短于 0.1 秒且前面有空隙，后者要求第一个音节短于一帧，持续时间也都不超过那个
音节本身，肉眼看不出来；Music 在同样的情况下也一样停着不动。

### 跳时间后，即将唱完的词仍会从头放大一次 —— 确认为真，基线已有，不在本分支修

**发现内容**：`synchronizeEmphasisState` 按 `elapsedTime` 把已经唱完的词标成「已安排」，`scheduleDueWords` 却按
`elapsedTime + animationHeadstart` 判断是否该放大，跳到某个词结束前 0.1 秒以内时，那个词会再放大、发光一次。

**裁决：基线已有，不在本分支修。** 审查说「这次改动之前两处都用 `elapsedTime`」不对：`scheduleDueWords` 在 `develop`
上本来就加了提前量，这次只给逐音节抬高也加上了，而抬高每帧按音节重新判断，不受这个标记影响。只影响放大（`.factor`）
的词，且只在跳时间落在词尾 0.1 秒内时出现。已记进提案后续项。

**若理由失效**：用户报告跳转后词「多弹一下」时，把标记条件改成 `upperBound <= elapsedTime + animationHeadstart`。

### `featherLeadFraction` 的 `isFollowedBySyllable` 读到时恒为真 —— 误报，不改

**发现内容**：这个参数等于「不是本行最后一个音节」，而最后一个音节第一档就返回了，所以它从不起作用。

**裁决：不改。** 这是 Music 自己的判断（`sub_1001689D4` 先比较末音节，再看下一个音节是否存在），在从左到右的行里
同样恒真。保留它让函数与它移植的代码逐条对应，文档注释里写明了这一点。

### `characterFraction` 档下抬高也提前 0.1 秒，和改动前的观感不完全相同 —— 有意为之，不改

**发现内容**：旧扫光档本该原样保留改动前的样子，但逐音节抬高在两档下都加了 0.1 秒提前量。

**裁决：不改。** 提案定过：提前量是移植时漏掉的一处，不是两种可供比较的观感，所以不跟开关走；放大在 `develop` 上
本来就提前 0.1 秒。开关只用来比较扫光本身。

### 每次重建行都计算一遍扫光计划，旧扫光档下用不上 —— 确认为真，不值得修

**发现内容**：`rebuild(with:contentsScale:)` 总会调用 `SyllableSweepPlan.make`，`characterFraction` 档下结果用不上。

**裁决：不修。** 重建只在换行、换字号、改宽度时发生，同一次重建还要做 Core Text 排版、建每个字形的 layer；计划只是
按行过滤一遍词、截几段字符串，开销可以忽略。而开关在行变成当前行时也会重读，按档跳过反而要处理切档后计划缺失。

### 第二轮：只审修复那一批

第二轮七条，修两条：时长为零的音节仍在决定「是不是词的最后一个音节」和「下一个词是谁」（第一轮的修复漏掉了这两处，
`aZeroLengthLastSyllableDoesNotHoldTheWordBack`、`aWordThatLastsNoTimeIsPassedOver` 修前红）。下面五条不修。

#### 暂停那一帧仍会安排放大与抬高，已开始的放大照常放完 —— 基线已有，不修

**裁决：不修。** 暂停时只渲染一帧，`develop` 上这一帧就照常安排放大，已开始的弹簧与收回定时器也照常走完，单帧渲染的
注释写明这是有意的（「sung glyphs keep their lift」）。这次新增的只是抬高也提前 0.1 秒，所以离音节开始不到 0.1 秒时暂停，
它会在暂停中抬起；那个音节下一刻就要唱，抬起是状态而不是进度，不会跑到音频前面去。扫光不一样，它表示进度，所以停住。

#### 暂停时扫光放到按时间算出的位置，而不是画面上的位置 —— 确认为真，不值得修

**裁决：不修。** 两者只在动画曾因掉帧落后时才有差别，差的是几帧的位移；改成停在画面上，恢复播放时重新同步也会跳同样
一下，只是换了时机。按时间放，暂停的画面就是暂停时刻该有的样子。

#### 只有前几个词带时间的行，尾部整段文字在最后一个音节里扫过 —— 确认为真，不修

**裁决：不修。** 结构化时间只覆盖一行的一部分属于异常数据；第一轮之前是行结束时整段突然点亮，现在是随最后一个音节扫过，
两种都不对、也都谈不上更糟。正常的行尾只有标点或空格。

#### `isPlaying` 有默认值 `true`，漏传就不会在暂停时停住 —— 不修

**裁决：不修。** 唯一的生产调用点（`AppleMusicLyricsScrollView.updateKaraokeLine`）传了它；改成必填要改十几处只关心运动
轨迹、本来就在「播放中」的测试调用，换不来实际的保护。

#### 重叠的音节让行在结束时先停在半途再跳满 —— 误报

**裁决：误报。** 每段动画的时长是「音节结束 − 当前时间」，而行的结束时刻是所有音节结束时刻的最大值，所以在走的动画
一定在行结束时或之前走完，不会出现先停在半途、过一会儿再跳的情形。重叠时被扫向的若不是最后一个音节，行结束那一刻会
从它的目标跳到全亮，这与 Music 在行结束时直接设成全亮一样。
