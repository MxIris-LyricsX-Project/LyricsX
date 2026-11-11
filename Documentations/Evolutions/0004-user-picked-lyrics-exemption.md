# 0004 - 手动应用过的歌词豁免于「忽略已保存的歌词」

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-12
- **所属愿景**: 无
- **关联提案**: [0002 总是忽略歌词库缓存](0002-always-ignore-cached-lyrics.md)（本提案给它加一个例外）、[0001 切换到下一条歌词候选](0001-next-lyrics-candidate.md)（它引入的覆盖表是本提案第一个考虑过、但不够用的方案）
- **实现分支 / PR**: `develop`
- **配套文档**: [绕过歌词库缓存](../Internal/LyricsLibraryCacheBypass.md)（与 0002 共用一篇 ——
  本提案改的是同一个开关的判定时机，拆成两篇会让「这个开关到底怎么走」没有任何一篇是完整的）

## 摘要

0002 加的开关「总是忽略已保存的歌词」现在忽略得太狠：它跳过整个歌词库，**包括用户自己在搜索面板
里挑好并应用的那一份**。本提案给这份歌词打一个持久标记，让它在开关开启时依然被读取 —— 开关只
对「自动搜到、自动存下」的歌词生效。

标记写在 `.lrcx` 文件里（一行 `[lxpick:…]`），所以它跟着文件走：换设备、恢复备份、手动整理歌词库
都不会丢。升级前存下的旧文件没有这个标记，一律按自动缓存处理，不做迁移。

## 动机

0002 的开关解决的是「歌词库里存了错的歌词，而缓存命中就永远不再搜索」。它按「这是谁的东西」
划线：用户的文件（内嵌歌词、音轨旁边的 `.lrc`）和用户的决定不受影响，只有 LyricsX 自己存的那一层
被跳过。

**但这条线画错了一处**：用户在搜索面板里挑一条歌词并应用，这明明是「用户的决定」，可它最终落盘的
位置和形态与自动搜索的结果**完全一样** —— 同一个目录、同样的文件名规则、文件内容里没有任何字段
说明它是人挑的。所以开关一开，用户上周亲手挑好的歌词和一条自动抓来的错歌词是同等待遇：一起被跳过，
一起重新联网搜索，而重新搜出来的很可能又是当初被用户否掉的那一条。

用户挑一次歌词是有成本的（打开搜索面板、读几条候选、比对哪条对得上），这个成本不该每次播放都付一遍。

### 为什么现有的「覆盖表」救不了

0001 引入过一张覆盖表（`LyricsSelectionOverrides`），语义正是「用户手选过的歌词」，而且它在所有
自动查找之前被查询，天然不受开关影响。但它**在绝大多数歌上根本不记录**：

`AppController.swift:808` 的 `recordUserSelectionIfAutomaticLookupWouldOverrideIt` 只在
「自动查找顺序会盖过这次手选」时才写条目 —— 也就是只有音频文件带内嵌歌词、或音轨旁边躺着一个
`.lrc` 时才记。其余情况（也就是绝大多数流媒体播放的歌）它走的是另一条分支：**主动删掉**条目，
理由是「没有东西排在这份文件前面，普通查找顺序自然会找到它」。

这个判断在 0002 之前是对的，0002 之后就不成立了：开关开启时，普通查找顺序**不再**会找到它。

## 前期调研

- **手动应用歌词的四个入口**，全部查证过代码路径：

  | 入口 | 代码位置 | 现在会不会立刻写盘 |
  |---|---|---|
  | 搜索面板「使用歌词」 | `LyricsX/Search/SearchLyricsViewController.swift:98` `useLyricsAction` | **不会** —— 只设 `needsPersist`，等切歌时才 `persist()` |
  | 快捷键「切换到下一条候选」 | `AppController.swift:770` `applyUserPickedCandidate` | 会，当场 `persist()` |
  | 拖入 / 粘贴导入 | `AppController.swift:1052` `importLyrics` | 不会，同样等切歌 |
  | 编辑当前歌词 | `AppDelegate.swift:316` `editCurrentLyrics` | 用 TextEdit 打开文件，**保存动作完全在 LyricsX 之外** |

- **延迟写盘的兜底是存在的** —— 切歌（`AppController.swift:386`）和退出 app（`AppDelegate.swift:165`）
  都会补一次 `persist()`，所以「不会立刻写盘」目前不导致丢失，只是落盘时机不确定。

- **`.lrcx` 的自定义标签是全量往返的，不需要改 LyricsKit** —— 解析端
  （`LyricsKit/Sources/LyricsCore/Lyrics.swift:20`）把所有 `[key:value]` 收进 `idTags`，
  序列化端（`:72`）原样写回。实测现有库文件里已经存在 `[ti:]` `[ar:]` `[al:]` `[offset:]`
  以外的标签（如 `[by:Kugou]`），说明这条路径确实在用。

- **只有标签行、没有歌词行的文件不会被误当成有效歌词** —— `Lyrics.init?(_:)` 在
  `lines.isEmpty` 时返回 nil（`Lyrics.swift:47`）。这一条决定了「新建空歌词文件时预置一行标记」
  是安全的。

- **开关当前的实现是「压根不把库文件加入候选」**（`AppController.swift:463`），所以现在没有任何
  时机能看到文件内容。要按标记区分，就必须改成「照常读取，读到之后再决定采不采纳」。

- **读一次库文件的代价可以忽略** —— 单个 `.lrcx` 通常几 KB，`loadLyrics` 是同步读 + 正则解析。
  开关开启且文件没有标记时会白读一次，随后照常搜索。

## 提议方案

### 一、给「用户手动应用」的歌词打一个文件内标记

新增一个 `.lrcx` 标签 `[lxpick:<来源>]`。**判断只看这个标签在不在，不看它的值**；值记录具体来源
（`search-panel` / `next-candidate` / `import` / `edit`），纯粹为了日后排查时能一眼看出这份文件是
怎么来的，零成本。

四个入口在把歌词交给用户之前打上标记：

1. 搜索面板「使用歌词」→ `search-panel`
2. 快捷键「切换到下一条候选」→ `next-candidate`
3. 拖入 / 粘贴导入 → `import`
4. 编辑当前歌词 → `edit`

### 二、开关开启时，库文件照常读取，但只采纳带标记的

查找链的形状变了一点：库文件**总是**进候选列表，判断挪到读取之后。

- 开关**关闭**：行为逐字不变 —— 读到就用，不看标记。
- 开关**开启**：读到之后看标记。带标记 → 采纳，不搜索；不带标记 → 丢弃，照常联网搜索。

搜索一无所获时的回退（0002 加的那条）**不看标记**：那是保底，此时有一份可能过时的歌词也远好过
什么都没有。

### 三、搜索面板「使用歌词」改为当场写盘

现在它要等到切歌才落盘。标记的价值全在于「下次播放时读得到」，落盘时机不该悬着 —— 何况用户
双击应用的那一刻，意图已经明确得不能更明确。改成与快捷键切换候选一致：当场 `persist()`。

### 四、编辑入口的两种情况

- **已有歌词文件**：在把文件交给 TextEdit 之前打标记并写盘。用户改完存盘时，标记已经在文件里了。
- **没有歌词、新建空文件**：`LyricsStoragePolicy.prepareEmptyFile` 目前写入 0 字节。改为可以带一个
  初始内容，这里传 `[lxpick:edit]\n` —— 用户在 TextEdit 里看到的第一行就是它，然后在下面写歌词。

### 非目标

- **不为旧文件做迁移** —— 升级前存下的文件里，手选的和自动缓存的**没有任何信息可以区分**，
  猜只会猜错。旧文件一律按自动缓存处理；用户重新应用一次就带上标记了。
- **不提供「取消标记」的入口** —— 标记一旦打上，只能靠删文件或手动编辑掉那一行去除。这在实践上
  不是问题：用户想换歌词就是再手选一次，新的一份同样带标记。
- **不改开关本身的语义与默认值** —— 仍是默认关闭的单个复选框，不做三态。
- **不动内嵌歌词、音轨旁边的文件、覆盖表**这三层 —— 它们本来就不受开关影响，标记与它们无关。
- **不把标记用于排序、优先级或其他任何用途** —— 它只回答一个问题：这份文件是不是人挑的。

## 详细设计

标记的定义与读写，放在 `LyricsXFoundation`（它已经 `@_exported import LyricsKit`）：

```swift
// LyricsXPackage/Sources/LyricsXFoundation/LyricsUserPickMark.swift

extension Lyrics.IDTagKey {
    /// Marks a lyrics file as one the user applied by hand, as opposed to one
    /// the automatic search saved on its own.
    public static let userPick = Lyrics.IDTagKey("lxpick")
}

/// How a hand-applied lyrics file came to be. Recorded as the mark's value for
/// diagnostics only — every reader treats the mark's mere presence as the answer.
public enum LyricsUserPickOrigin: String, Sendable {
    case searchPanel = "search-panel"
    case nextCandidate = "next-candidate"
    case `import` = "import"
    case edit = "edit"
}

extension Lyrics {
    /// Whether this file records a hand-made choice. Any non-empty mark counts:
    /// a value this build does not know about still came from a person.
    public var isUserPicked: Bool {
        idTags[.userPick]?.isEmpty == false
    }

    public func markAsUserPicked(origin: LyricsUserPickOrigin) {
        idTags[.userPick] = origin.rawValue
        metadata.needsPersist = true
    }
}
```

查找链的改动 —— `LyricsLookupCandidateFile` 多带一个字段，说明这个候选是否受开关管辖：

```swift
private struct LyricsLookupCandidateFile {
    let fileURL: URL
    let isSecurityScoped: Bool
    let allowsFurtherSearching: Bool
    /// A file from LyricsX's own library, which the bypass switch may reject
    /// once it has been read and found to carry no user-pick mark.
    let isLibraryFile: Bool
}
```

```swift
// currentTrackChanged: the library layer is no longer skipped outright —
// it is read, and then judged.
candidateLyricsFiles += librarySearchFiles(title: title, artist: artist)

for candidateFile in candidateLyricsFiles {
    guard let lyrics = loadLyrics(…) else { continue }
    // The bypass switch means "do not trust what LyricsX saved for itself".
    // A file the user applied by hand was never LyricsX's own decision.
    if candidateFile.isLibraryFile, defaults[.ignoreCachedLyricsLibrary], !lyrics.isUserPicked {
        continue
    }
    currentLyrics = lyrics
    …
}
```

空文件预置内容：

```swift
public static func prepareEmptyFile(
    at destination: LyricsStorageDestination,
    initialContents: String = "",
    fileManager: FileManager = .default
) throws -> URL
```

## 替代方案考量

- **把覆盖表改成无条件记录** —— 改动最小（一个 `guard` 删掉），且覆盖表查询本来就排在查找链最前面，
  天然绕过开关。否掉的理由有三：它以 `track.id` 为键，而不同播放器给的 id 稳定性不一（换播放器、
  重建资料库都可能变）；它有 300 条上限、超出按时间淘汰，手选过几百首歌的用户会静默失去最早的记录；
  它存在偏好设置里，换设备或重装即丢。文件内标记这三条全都不存在。
- **单独维护一张「手选过的歌词文件路径」表** —— 键换成文件路径，避开了 track.id 的稳定性问题，
  但上限和「不跟文件走」这两条还在，而且用户手动重命名歌词文件就会失配。
- **按文件修改时间判断（比如最近手动改过的就不忽略）** —— 完全猜不准：自动搜索写盘同样会更新
  修改时间，两者从文件系统层面看毫无区别。
- **把开关做成「只忽略 N 天前的缓存」** —— 0002 已经否过一次同类方案（隐式的时间维度让行为不可
  预测），这里的理由不变。
- **手选的歌词换个目录存放（比如 `~/Music/LyricsX/Picked/`）** —— 用目录代替标记，判断更简单。
  但它把用户的歌词库切成两半，任何一次手动整理都会破坏语义，而且已有的库文件要么迁移要么两边都得查。

## 影响

### 用户可见变化

- 「总是忽略已保存的歌词」这个开关的行为变窄：手动应用过的歌词不再被跳过，播放它们时不会再有
  等待网络的延迟。
- 复选框下方的说明文字要相应改写，点明这条例外。
- 搜索面板应用歌词后立刻写盘（此前等到切歌），用户能更早在 Finder 里看到文件。
- 新建空歌词文件去编辑时，TextEdit 里会预先有一行 `[lxpick:edit]`。
- 歌词文件里多出一行标签。其他播放器不认识它，会当作未知标签忽略 —— LRC / LRCX 的标签本来就是
  这样处理的。

### 可发现性

- 没有新增任何设置项，用户不需要学任何新东西：手动应用歌词的操作一如既往，豁免是自动发生的。
- 说明文字是唯一的告知渠道，必须写清楚 —— 否则开着开关的用户会以为手选的歌词也在被重搜，
  从而失去对这个开关的信任。

### 数据与配置兼容

- 不新增偏好键，不改现有偏好键的含义。
- 不迁移任何已有文件。旧文件在开关开启时的行为与现在**完全一致**（被跳过、重新搜索），
  只有在用户重新手动应用一次之后才变化。
- 关闭开关时行为与现在逐字一致，包括不看标记。
- 带标记的文件被旧版本 LyricsX 读到时，标签会被当作普通 id 标签保留，不影响解析，也不影响写回。

### 平台与最低版本

不变（macOS 12+）。无平台差异。

### 发布

不需要新权限、entitlement 或隐私清单条目。不影响公证与 Sparkle 更新。
发布说明需要一句：开着「总是忽略已保存的歌词」时，你自己挑过的歌词从此不会被重搜。

## 落地步骤

1. 在 `LyricsXFoundation` 加标记的定义与读写（`Lyrics.IDTagKey.userPick`、`isUserPicked`、
   `markAsUserPicked(origin:)`），补往返测试：打标记 → 序列化 → 重新解析 → 标记仍在，
   且不影响歌词行与其他标签。
2. 四个入口打标记；搜索面板「使用歌词」改为当场 `persist()`。
3. `prepareEmptyFile` 支持初始内容，编辑入口传入标记行。
4. 查找链改为「库文件照常读取、读后再判断」，`LyricsLookupCandidateFile` 加 `isLibraryFile`。
   搜索落空后的回退保持不看标记。
5. 改偏好页说明文字，补 `Preferences.xcstrings` 的中英文案。
6. 手工验证（这一层在 `AppController` 里，app target 没有测试宿主）：
   - 开关开启 + 手选过的歌 → 瞬时出歌词，无网络搜索；
   - 开关开启 + 没手选过的歌 → 照旧重新搜索；
   - 开关开启 + 断网 + 没手选过的歌 → 回退仍能读到库里那份；
   - 开关关闭 → 行为与升级前一致。

**收尾时必须判断两件事**（结果写进决策日志）：配套文章、新术语。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-11 | Created as Draft | 起因：用户指出 0002 的开关把「自己在搜索面板应用过的歌词」也一起忽略了，要求只对自动获取、自动缓存的歌词生效。 |
| 2026-08-11 | 确定豁免范围 | 用户选择四个入口全部豁免：搜索面板应用、快捷键切换候选、拖入/粘贴导入、手动编辑。理由一致 —— 它们都不是「自动搜到自动存下」的。 |
| 2026-08-11 | 确定标记载体 | 用户选择写进 `.lrcx` 文件，而非存偏好设置。理由：跟着文件走，换设备/恢复备份/整理歌词库都不丢，且没有条数上限。 |
| 2026-08-11 | 确定不迁移旧文件 | 用户选择接受旧文件被当作自动缓存。理由：没有任何信息能区分旧文件是手选还是自动存的，猜测只会猜错。 |
| 2026-08-12 | Accepted → In Progress | 用户批准按提案实现，方案未作改动。 |
| 2026-08-12 | 实现差异一：标记不再顺手设 `needsPersist` | 提案草案里 `markAsUserPicked` 会设 `metadata.needsPersist = true`，实际做不到 —— `needsPersist` 是 app target 的 `Lyrics.Metadata` 扩展，`LyricsXFoundation` 看不见它。四个入口本就都在写盘，改由调用方各自设。 |
| 2026-08-12 | 实现差异二：编辑入口只在「写回原文件」时打标记 | 无条件 `persist()` 会把 beside-track 歌词另存成库文件并改写 `localURL`，导致 TextEdit 打开的是副本、用户的修改永远不生效。新增 `LyricsStoragePolicy.rewritesFileInPlace` 先判定，否则不打标记 —— 那些文件本就不受开关管辖。 |
| 2026-08-12 | 收尾判断：配套文章 | **不新开一篇**，改为扩写 0002 的[绕过歌词库缓存](../Internal/LyricsLibraryCacheBypass.md)。理由：本提案改的是同一个开关的判定时机，拆成两篇会让「这个开关到底怎么走」没有任何一篇是完整的。 |
| 2026-08-12 | 收尾判断：新术语 | **登记一条** ——「手选标记（user-pick mark）」进[项目术语表](../Glossary.md)，并同步修订「歌词库缓存」词条（带标记的库文件不再属于「缓存」）。 |
| 2026-08-12 | In Progress → Implemented | 包层 67 个测试通过（新增 `LyricsUserPickMarkTests` 8 个 + `prepareEmptyFile` 2 个），app target 构建通过。查找链那两个布尔判断在 `AppController` 里，无测试宿主，仍需手工验证。 |
