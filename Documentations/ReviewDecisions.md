# 已裁决的 code review 发现

这份清单记录**判定为误报、或判定为不值得修**的 code review 发现，以及判定的理由。

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
