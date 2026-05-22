# Apple Music 官方歌词 — 实现计划

> 分支:`feature/apple-music-lyrics`。本文件是冷启动可执行的完整计划;实现前先读「已确认事实」与「关键代码事实」两节。
>
> **进展(2026-05-21):** §3.5 的私有 `SystemMusicPlayer` 歌曲识别方案经 PoC **证伪**(详见 §3.5 与 `AppleMusicLyricsPoC/FINDINGS.md`);歌曲识别改走 MediaRemote 方向(§3.6,待 PoC)。Route A/B 的歌词获取机制(WKWebView/amp-api)不受影响。

## 0. 背景与目标

- Issue:`MxIris-LyricsX-Project/LyricsX#17` —— Apple Music 会按系统/账号地区把歌名本地化(日文歌→罗马音「雨のメヌエット→Ame No Minuet」、中文歌→英译「新浪漫主义→Neo-Romanticism」),导致按歌名搜第三方歌词(网易/QQ)失败。
- 目标:
  - **Route A** —— 取 Apple Music 官方逐字(syllable)歌词,从根本绕开本地化问题。
  - **Route B** —— 恢复歌曲原文名,喂给现有第三方歌词源,丰富候选。
  - 两者结果都进 `LyricsProviders.Group`,沿用现有候选列表/排序 UI。

## 1. 已确认的技术事实(PoC 验证通过,2026-05-20)

- Endpoint:`GET https://amp-api.music.apple.com/v1/catalog/{storefront}/songs/{adamID}/syllable-lyrics`
- 返回 JSON:`data[0].attributes.ttml`(TTML 字符串)、`data[0].attributes.playParams.displayType`(`3` = 逐字 syllable)。
- **鉴权关键发现**:
  - 原生 `URLSession` 带 `Authorization: Bearer` + `media-user-token` 头打 amp-api → **HTTP 401**(缺浏览器会话 cookie / credentials)。
  - **在 WKWebView 内调用页面自己的 `MusicKit.getInstance().api.music(path)` → 成功**。MusicKit JS 自带正确的 developer token + user token + cookie + origin,且 token 过期自动刷新。这是采用的机制。
- 登录:WKWebView 加载 `music.apple.com`,用户登录**自己的** Apple ID(无需任何人提供/内嵌 token)。`MusicKit.getInstance().isAuthorized && musicUserToken` 标志登录完成。
- 前提:用户需有 Apple Music 订阅。
- TTML 形态(实测「晴天」样例):
  ```xml
  <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
      xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="zh-Hant">
    <head><metadata>
      <ttm:agent type="person" xml:id="v1"/>
      <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
        <translations/><songwriters><songwriter>周杰倫</songwriter></songwriters>
      </iTunesMetadata>
    </metadata></head>
    <body dur="4:29.747">
      <div begin="29.188" end="42.720">
        <p begin="29.188" end="32.398" itunes:key="L1" ttm:agent="v1">
          <span begin="29.188" end="29.605">故</span><span begin="29.605" end="30.449">事的</span>
          <span begin="30.449" end="31.330">小</span><span begin="31.330" end="31.797">黃</span>
          <span begin="31.797" end="32.398">花</span>
        </p>
      </div>
    </body>
  </tt>
  ```
- 代价/风险:私有未公开 endpoint,违反 Apple ToS,**不能上 Mac App Store**(LyricsX 独立分发可接受);Apple 可能变更;登录态(cookie)数月级过期需重连。

## 2. PoC 与可复用资产

- PoC:`/Volumes/Code/Personal/AppleMusicLyricsPoC`(独立 SwiftPM,`./build.sh` → `open AMLyricsPoC.app`,日志 `/tmp/amlyricspoc.log`)。
- **直接可移植**:`Sources/AMLyricsPoC/main.swift` 里的 `lyricsJavaScript` 常量 —— 页面内 JS:`amGet()` 封装 `MusicKit.getInstance().api.music(path)`、storefront、search、syllable-lyrics 全流程;以及 `callAsyncJavaScript(..., contentWorld: .page)` 与轮询 `isAuthorized` 的写法。
- 参考开源:`rryam/MusanovaKit` 的 `Sources/MusanovaKit/Lyrics/LyricsParser.swift`(TTML→结构化歌词,解析逻辑可借鉴,含时间码解析、CJK/拉丁空格处理、XMLParser 多字节拆包处理);`rryam/MusadoraKit`。

## 3. 架构决定(已与用户确认)

- 整套放 **LyricsKit**(含 WebView 传输)。
- LyricsKit 新增 target `LyricsServiceAppleMusic`,引入 WebKit;做成独立 product `LyricsKitAppleMusic`,避免 widget 扩展被迫链接 WebKit。
- Route A 与 Route B 都实现,候选合流。
- 登录:持久化 WKWebView 会话,用户登录一次;登录入口放 LyricsX 的 Source 偏好面板。

## 3.5 歌曲识别尝试 —— 私有 `SystemMusicPlayer`(❌ PoC 已证伪,2026-05-21)

> **❌ PoC 实证结论(2026-05-21,macOS 26.5):此方案不可行。**
> 私有符号桥接技术本身完全成功(`@_silgen_name` 绑定 `SystemMusicPlayer.shared`/`.queue` 的 mangled 符号,链接 + 运行均通过),但 `SystemMusicPlayer` 在 macOS 上功能残缺:`queue.currentEntry` 永远 `nil`,底层 `MPMusicPlayerController.nowPlayingItem` 永远 `nil`,`state` 只是陈旧快照。**拿不到 `Song` → 拿不到 adamID/ISRC。** 这正是 Apple 标 `@available(macOS, unavailable)` 的实质原因 —— 不是藏 API,是它在 macOS 真不工作。
> 歌曲识别改走 §3.6。PoC:`AppleMusicLyricsPoC/`(与 LyricsX 仓库同级),完整结论见其 `FINDINGS.md`。
> 以下原始设想与逆向分析**保留作记录** —— 符号桥接技术可复用;教训:静态 dump 显示调用链符号存在 ≠ 运行时功能完整。

**原始设想:不靠本地化名模糊搜索,直接从正在播放的歌拿到精确 adamID + ISRC**,A/B 共用,从根上免疫 #17。

dump(`/Volumes/Code/Dump/DyldSharedCaches/macOS/26.4/MusicKit{,Internal}`)确认:
- `MusicKit.SystemMusicPlayer.shared` → `.queue.currentEntry?.item` → `enum Item` 的 `case .song(MusicKit.Song)` → `Song.id`(`MusicItemID`,目录歌即 adamID)、`Song.isrc`、`Song.playParameters`。
- **整条链上除 `SystemMusicPlayer` 类本身,全是 macOS 公开 API** —— `MusicPlayer`/`MusicPlayer.Queue`/`Queue.currentEntry`/`Entry`/`Entry.item`/`Entry.Item`/`Song`/`Song.isrc`,在 SDK `arm64e-apple-macos.swiftinterface` 里都是 `public @available(macOS 14.0+)`。
- 唯一卡点:`SystemMusicPlayer` 标了 `@available(macOS, unavailable)`(SDK 隐藏;但二进制里类与 `shared`/`queue` 都在)。

**调用机制(私有面仅 1 处):**
1. `objc_getClass("_TtC8MusicKit17SystemMusicPlayer")` → 该 Swift 类的 metadata(= metatype)。
2. `dlsym` `SystemMusicPlayer.shared` 静态 getter,传 metatype 调用 → 实例指针。
3. `dlsym` `SystemMusicPlayer.queue` getter → `Queue` 指针 → `unsafeBitCast` 到公开类型 `MusicKit.MusicPlayer.Queue`。
4. 之后 `.currentEntry?.item` → `case .song(let song)` → `song.id` / `song.isrc` —— 全程类型安全的公开 Swift。
- 脆弱面 = 2 个 mangled 符号 + 1 个 objc 类名字符串,可从 `MusicKit+MusicKitInternal.i64` 重新提取;下游不依赖内存布局。

**接线:LyricsX 侧读 `SystemMusicPlayer` 得 `(adamID, isrc)`,写进 `LyricsSearchRequest.userInfo`**(`[String:String]`,键如 `appleMusicAdamID`/`appleMusicISRC`);LyricsKit 的 Apple Music provider 从 `userInfo` 读。没有(非 Apple Music 播放器/识别失败)→ 回退按名搜索。仅当 `SelectedPlayer` 为 Apple Music 时调用。

**附带发现(暂不采用):** `MusicKitInternal.MusicLyricsRequest(for: Song).response()` → `CatalogLyrics.ttml`(逐字 TTML,`displayKind: .syllableSynced`)是「原生取官方歌词」的完整 API。但 `MusicKitInternal` 是私有 framework、`response()` 为 `async`(dlsym 调 async Swift 极难)→ 歌词仍用已验证的 WKWebView/amp-api,只是改成按精确 adamID 直取 `syllable-lyrics`。

**PoC 实测结果(2026-05-21,macOS 26.5,见 `AppleMusicLyricsPoC/FINDINGS.md`):**
- ⑤ 精确 mangled 符号已提取:`shared` getter = `$s8MusicKit06SystemA6PlayerC6sharedACvgZ`(无参 `swift_once` 单例,不读 metatype);`queue` getter = `$s8MusicKit06SystemA6PlayerC5queueAA0aD0C5QueueCvgTj`(method dispatch thunk);`_queue` 字段偏移 `0x30`。用 `@_silgen_name` 绑定即可,连 `objc_getClass` 都不需要;`SystemMusicPlayer` 经 Swift word-substitution mangled 为 `06SystemA6Player`。
- ① 访问需 `MusicAuthorization` 授权,授权链路要求:`.app` bundle + `Info.plist` 带 `NSAppleMusicUsageDescription` + 经 `open`/LaunchServices 启动(命令行裸进程会被 TCC `abort()`)。LyricsX 本身是签名 .app,天然满足。
- ②③④ **全部无法验证 —— `currentEntry` 恒为 `nil`**:`SystemMusicPlayer.queue` 在 macOS 不被填充,底层 `MPMusicPlayerController.nowPlayingItem` 同样恒 `nil`;授权前后、playing/paused、catalog 歌均如此。`state`(playbackStatus/playbackTime)能连上 Music.app 但只是陈旧快照、不实时刷新。
- **结论:整条 `SystemMusicPlayer.shared.queue.currentEntry.item.song` 链在 macOS 拿不到数据,§3.5 作废。**

## 3.6 歌曲识别(修订方向)—— MediaRemote(待 PoC 验证)

§3.5 证伪后,「从正在播放的歌直接拿精确 adamID/ISRC」改走 **MediaRemote**:

- LyricsX 的 `MusicPlayer` 库**已经在用** `mediaremote-adapter` 读取 Music.app 的 now-playing 信息 —— 基础设施现成。
- **待验证(下一个 PoC):** `MRMediaRemoteGetNowPlayingInfo` 返回的 dictionary 是否含 adamID / iTunes Store ID。候选键:`kMRMediaRemoteNowPlayingInfoContentItemIdentifier`、`kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier`、`kMRMediaRemoteNowPlayingInfoiTunesStoreSubscriptionAdamIdentifier`。
- **若任一键存在** → 精确识别就地解决,无需任何新私有符号桥接;LyricsX 侧把 `(adamID, isrc?)` 写进 `LyricsSearchRequest.userInfo`,接线与原 §3.5 设想一致。
- **若都不存在** → 退路:① WKWebView amp-api 的「最近播放」类 endpoint(如 `/v1/me/recent/played/tracks`,登录态实测是否含 adamID);② 接受按歌名搜索 + duration 容差(保留 #17 的本地化局限)。
- 这一步是 Route A/B「精确识别」优化的前置;**即使识别拿不到 adamID,Route A/B 仍能按歌名工作**,只是回退到 #17 的局限。

## 4. 关键代码事实(冷启动参考)

### LyricsKit —— `/Volumes/Code/Personal/LyricsKit`
（LyricsX 默认用本地依赖:`LyricsXPackage/Package.swift` 中 `LYRICSX_USE_LOCAL_DEPENDENCY` 默认 true → 改 LyricsKit 本地即生效。）

- `Lyrics`(`Sources/LyricsCore/Lyrics.swift`):`final class`;`lines: [LyricsLine]`、`idTags: [IDTagKey: String]`、`metadata: Metadata`;`init(lines:idTags:metadata:)`。`IDTagKey` 有 `.title/.artist/.album/.length` 等。
- `LyricsLine`(`Sources/LyricsCore/LyricsLine.swift`):`content: String`、`position: TimeInterval`(行起始**绝对**时间)、`attachments: Attachments`。
- 逐字轴模型 `LyricsLine.Attachments.InlineTimeTag`(`Sources/LyricsCore/LyricsLineAttachment.swift`):
  - `tags: [Tag]`,`Tag(index: Int, time: TimeInterval)` —— `index` = 行内**字符索引**,`time` = 相对**行首**的偏移秒数。
  - `duration: TimeInterval?` = 行时长。
  - 通过 `line.attachments.timetag = InlineTimeTag(tags:duration:)` 挂载(`.timetag` tag,description 形如 `<msec,index>...`)。
- 翻译:`line.attachments[.translation()] = "译文"`;带语言 `.translation(languageCode: "zh-Hans")`。
- `LyricsProvider` 协议(`Sources/LyricsService/Provider/LyricsProvider.swift`):`func lyrics(for: LyricsSearchRequest) -> AsyncThrowingStream<Lyrics, Error>`;`Sendable`。内部可参考 `_LyricsProvider`(`search`+`fetch`)。
- `LyricsProviders.Group`(`Sources/LyricsService/Provider/Group.swift`):并发聚合多个 provider,逐个 `yield`。
- `LyricsProviders.ServiceID`(`Sources/LyricsService/Provider/Service.swift`):`enum`,现有 `netease/qq/kugou/musixmatch/lrclib`,有 `displayName`。需加 `appleMusic`。
- `LyricsSearchRequest`(`Sources/LyricsService/LyricsSearchRequest.swift`):`searchTerm: .keyword(String) | .info(title:artist:)`、`duration: TimeInterval`、`limit: Int`、`userInfo: [String:String]`。
- `Package.swift`:targets `LyricsCore` / `LyricsService` / `LyricsServiceUI` / 伞 `LyricsKit`;`platforms: [.macOS(.v10_15)]`;`swiftLanguageModes: [.v5]`。

### LyricsX —— `/Volumes/Code/Personal/LyricsX`

- **接入点** `AppController.updateLyricsManager()`(`LyricsX/Component/AppController.swift:156-167`):构建 `providers: [LyricsProvider]`(现 5 个:netease/qq/kugou/lrclib/musixmatch)→ `lyricsManager = LyricsProviders.Group(providers:)`。
- 搜索流程(`AppController.swift:372-417`):`searchTitle`(可去括号)→ `LyricsSearchRequest(.info(title:artist:), duration:, limit: 5)` → `lyricsManager.lyrics(for:)` 流式 → `lyricsReceived(lyrics:)` 收集候选(有优先级窗口逻辑)。
- `PreferenceSourceViewController`(`LyricsX/Preferences/PreferenceSourceViewController.swift`):源开关面板,列 `ServiceID.allCases` 的 displayName。登录按钮 + Apple Music 开关加这里。
- 偏好键:`LyricsX/Utility/Global.swift` 的 `extension UserDefaults.DefaultsKeys`。
- 构建:优先 workspace `xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift`。

## 5. 实现 —— LyricsKit 新 target `LyricsServiceAppleMusic`

### 5.1 `Package.swift`
加 target `LyricsServiceAppleMusic`(依赖 `LyricsCore`、`LyricsService`;`import WebKit`,WebKit 是系统框架无需包依赖);加 product `LyricsKitAppleMusic` 暴露该 target。

### 5.2 `AppleMusicTTMLParser.swift` —— 纯 Foundation(`XMLParser`)
- 输入 TTML `String`,输出 `Lyrics`。
- `<div>` → `<p>` → `<span>` 遍历。
- 每个 `<p begin end itunes:key>`:
  - `content` = 子 `<span>` 文本拼接(CJK 不加空格、拉丁词间加空格,参考 MusanovaKit)。
  - `LyricsLine(content:, position: parseTimecode(p.begin))`。
  - 逐字:每个 `<span begin end>` → `InlineTimeTag.Tag(index: 该 span 文本在 content 内的起始字符索引, time: spanBegin - pBegin)`;`InlineTimeTag.duration = pEnd - pBegin`;`line.attachments.timetag = ...`。
- `<head>` 内 `<iTunesMetadata><translations>`(逐行翻译,按 `itunes:key` 对应)→ 给对应行加 `.translation(languageCode:)` attachment。
- 时间码:支持 `SS.mmm` / `MM:SS.mmm` / `HH:MM:SS.mmm`。
- 注意 `XMLParser` 可能把多字节字符拆到多次 `foundCharacters` 回调 —— 累积后再处理。
- 单测:用 PoC 抓的「晴天」TTML 做 fixture(LyricsKit 已有 `Tests/.../Fixtures` 机制)。

### 5.3 `AppleMusicWebSession.swift` —— `@MainActor`,WebKit
- `final class AppleMusicWebSession`,`static let shared`。
- `let webView: WKWebView`:`WKWebViewConfiguration` 默认(持久化 data store);自定义桌面 Safari UA;加载 `https://music.apple.com`。
- 登录态:轮询 JS `(()=>{try{const m=MusicKit.getInstance();return !!(m&&m.isAuthorized&&m.musicUserToken)}catch(e){return false}})()`;暴露 `@Published var isAuthorized` 或 `func waitUntilAuthorized() async`。
- `func musicAPI(_ path: String) async throws -> Data`:`callAsyncJavaScript`(`contentWorld: .page`)执行 `const r = await MusicKit.getInstance().api.music(path); return JSON.stringify(r && r.data!==undefined ? r.data : r);` → 返回 body;JS 抛错→ Swift 抛错(含 HTTP 状态)。
- `func json(_ path: String) async throws -> [String: Any]`:上面 + `JSONSerialization`。
- 登录时 `webView` 由 LyricsX 呈现到窗口;之后可后台常驻(不可见)。

### 5.4 `AppleMusicCatalog.swift` —— amp-api 封装(用 `AppleMusicWebSession`)
- `func storefront() async throws -> String`(`/v1/me/storefront` → `data[0].id`)。
- `func searchSongs(term:storefront:limit:) async throws -> [CatalogSong]`(`/v1/catalog/{sf}/search?types=songs&limit=N&term=<encoded>`)。
- `func song(id:storefront:) async throws -> CatalogSong`(`/v1/catalog/{sf}/songs/{id}`)。
- `func songsByISRC(_ isrc:storefront:) async throws -> [CatalogSong]`(`/v1/catalog/{sf}/songs?filter[isrc]={isrc}`)—— Route B 跨区桥接用,ISRC 精确匹配。
- `struct CatalogSong`:`id`(adamID)、`name`、`artistName`、`durationInMillis`、`isrc?`、`hasLyrics?`。
- 注:catalog endpoint 路径里的 `{sf}` 可与账号所在 storefront 不同 —— 跨区查目录靠这点(待 PoC 验证,见 §9)。

### 5.5 `AppleMusicLyricsProvider.swift` —— Route A
- `struct AppleMusicLyricsProvider: LyricsProvider`。
- `lyrics(for:)` → `AsyncThrowingStream`:
  1. 未授权 → 直接 `finish()`。
  2. **`userInfo` 带 adamID(§3.6 识别成功时)→ 直取该 id,跳过搜索**;否则(§3.6 未落地或识别失败)回退:storefront → `searchSongs(request.searchTerm 描述)` → 按 `request.duration` 与 song 时长容差(±3s)过滤/排序,取前若干。
  3. 并发对候选取 `/songs/{id}/syllable-lyrics` → TTML → `AppleMusicTTMLParser` → `Lyrics`;设 `metadata.service`、`metadata.request`;404/无歌词跳过。
  4. 逐个 `yield`。

### 5.6 `AppleMusicNameRecoveryProvider.swift` —— Route B(ISRC 跨区桥接)

**机制(2026-05-20 用公开 iTunes Search API 实证,样本「晴天/周杰倫」「晴る/ヨルシカ」):**
- Apple Music 歌名本地化的轴是 **storefront**,**不是**语言设置:`lang`/`l` 参数实测对 `name` 无效(`country=cn&lang=en_us` 仍返回「晴天」)。
- storefront S 只对「S 地区本土内容」给原文(jp→日文、cn→简中、tw/hk→繁中、kr→韩文),对外来内容给英文/罗马音 —— 「晴る」在 jp 库是「晴る」,在 us **和 cn** 库都是「Sunny」。要拿原文名必须查这首歌**本土的 storefront**。
- adamID **可能全球通用**(「晴る」`1721450223` 在 jp/us/cn 都解析,名字随 storefront 变),**也可能按区拆分**(「晴天」cn=`535824738`、us=`1721464906`,互查 0 结果)。**不可依赖 adamID 跨区。**
- 跨区唯一可靠主键 = **ISRC**(全球唯一、storefront 无关)。
- Apple 搜索不对称:用本地化名去本土 storefront 反查会失败(在 cn 搜 "Sunny Day Jay Chou" 只搜到翻唱,找不到「晴天」)→ 不能靠「换 storefront 重新搜」,**必须靠 ISRC**。

**实现:**
- `struct AppleMusicNameRecoveryProvider: LyricsProvider`,持 `session` 与 `wrapped: [LyricsProvider]`(网易/QQ/Kugou/LRCLIB/Musixmatch)。
- `lyrics(for:)` → `AsyncThrowingStream`:
  1. 未授权 → `finish()`。
  2. 取 `isrc`:**优先 `userInfo`(§3.6 识别成功时)**;没有则回退 `resolver.identity(for: request)`(storefront X search → `adamID_X` + `isrc`)。无 `isrc` → `finish()`(降级,无回归)。
  3. 选目标本土 storefront:① Route A 已取 TTML → 用其 `xml:lang`(`ja→jp`、`zh-Hant→tw,hk`、`zh-Hans→cn`、`ko→kr`);② 否则用 ISRC 国家前缀(`JP→jp`/`TW→tw`/`HK→hk`/`CN→cn`/`KR→kr`);③ 都没有 → fan-out 整个 CJK 集 `{jp,cn,tw,hk,kr}`。
  4. 对每个目标 storefront S 并发 `songsByISRC(isrc, storefront: S)` → 收 `(name, artistName)`。ISRC 精确匹配,无需时长容差。
  5. 去重;**只保留「含 汉字/假名/谚文、且与原始本地化名不同」的变体** —— 纯拉丁的、与原名相同的全部丢弃(避免与直连 provider 重复搜索;用户本就在本土区时变体==原名→自动跳过)。
  6. 每个保留变体 → `LyricsSearchRequest(.info(title:artist:))` → 转发内部 `LyricsProviders.Group(providers: wrapped)` → `yield` 其结果。
- **共享缓存**:`actor AppleMusicResolver`(原计划的 `AppleMusicContext`),按 request memoize `SongIdentity{ storefrontX, adamID_X, isrc, durationMillis }` 与 `adamID_X → TTML`,让 A、B 只做一次 storefront X 的 search。
- Route B 是**纯增量**:只补充候选、不替换直连 provider 结果;任一步失败只是少几个候选,不构成回归。

### 5.7 ServiceID / 构造
- `ServiceID` 加 `case appleMusic`(`displayName = "Apple Music"`)。
- 两个 Apple Music provider 需 `AppleMusicWebSession`,不套现有 `Service(Options,HTTPClient)` 工厂;由 LyricsX 侧直接构造,或加专用工厂。

## 6. 实现 —— LyricsX

### 6.1 偏好
- `Global.swift` 加 `static let appleMusicNameRecoveryEnabled = Key<Bool>("AppleMusicNameRecoveryEnabled")`(默认 false)。开关展示在「偏好设置 → 实验室」中,标题 `Recover original track names via Apple Music`;`AppController.updateLyricsManager()` 据此决定是否挂载 `AppleMusicNameRecoveryPlugin`。

### 6.2 登录 UI
- `PreferenceSourceViewController` 加:「连接 Apple Music」按钮、连接状态标签、Apple Music 歌词开关。
- 点按钮 → 弹 sheet/window,contentView 嵌 `AppleMusicWebSession.shared.webView`;检测到 `isAuthorized` → 关闭、刷新状态。
- `LyricsKitAppleMusic` 是独立 product;LyricsX 主 target(及/或 `LyricsXFoundation`)需 `import`/链接它。

### 6.3 接线 `updateLyricsManager()`
```swift
var providers: [LyricsProvider] = [ netease, qq, kugou, lrclib, musixmatch ]
if defaults[.appleMusicNameRecoveryEnabled], AppleMusicWebSession.shared.isAuthorized {
    providers.insert(AppleMusicLyricsProvider(session: .shared), at: 0)              // A
    providers.append(AppleMusicNameRecoveryProvider(session: .shared, wrapped: <上面5个>)) // B
}
lyricsManager = LyricsProviders.Group(providers: providers)
```
- 登录态变化 / 开关变化 → 重新 `updateLyricsManager()`。

### 6.4 Info.plist / entitlement
- WKWebView 传输本身不需要权限。
- §3.6 走 MediaRemote(`mediaremote-adapter`):权限按其自身要求 —— LyricsX 现有 `MusicPlayer` 集成已覆盖,预计无新增。
- 若 §3.6 退而调用 `MusicAuthorization` 相关 API:需 `Info.plist` 带 `NSAppleMusicUsageDescription`(PoC 已确认);LyricsX 是签名 .app,满足 TCC 的 bundle 要求。

### 6.5 歌曲识别(§3.6)
- ⚠️ 原计划经私有 `SystemMusicPlayer`(§3.5)实现已证伪。改走 §3.6 的 MediaRemote 方向 —— **先做 §3.6 PoC** 再定此处实现。
- 若 MediaRemote 能给出 adamID/ISRC:新文件(LyricsX 侧,如 `Component/AppleMusicNowPlayingIdentifier.swift`)从 `mediaremote-adapter` 的 now-playing 信息取 `(adamID, isrc)`。
- LyricsX 在换歌、发起 Apple Music 搜索前调用,把结果写进 `LyricsSearchRequest.userInfo`;仅 `SelectedPlayer` 为 Apple Music 时调用。
- 若 MediaRemote 也拿不到 adamID:此节作废,Route A/B 全部退回按歌名搜索(保留 #17 局限)。

## 7. 分阶段执行

0. **歌曲识别 PoC**:① §3.5 的 `SystemMusicPlayer` 路径 ✅ 已验证 —— 结论**证伪**(PoC `AppleMusicLyricsPoC/`,详见 §3.5 / `FINDINGS.md`)。② 转 §3.6:做 MediaRemote PoC,验证 `MRMediaRemoteGetNowPlayingInfo` 的 now-playing dict 是否含 adamID/ISRC。此 PoC 不阻塞阶段 1-2。
1. **LyricsKit:Package.swift + `AppleMusicTTMLParser`** —— 可独立 `swift build` + 单测(「晴天」TTML fixture)。
2. **LyricsKit:`AppleMusicWebSession` + `AppleMusicCatalog` + `AppleMusicLyricsProvider`(A)** —— `swift build` 过。
3. **LyricsX 接入 A**:登录 UI + `updateLyricsManager` + 偏好开关;若 §3.6/阶段 0 的 MediaRemote 识别成功,接 `userInfo` 识别;workspace 构建;真机验证「晴天」出官方逐字歌词。
4. **Route B**:先用 PoC 实测 §9 的 amp-api 未验证项 → 再写 `AppleMusicNameRecoveryProvider`(ISRC 跨区桥接)+ `AppleMusicResolver` 共享缓存 + 接线。
5. **联调打磨**:时长匹配、TTML 边角(对唱 `ttm:agent`、背景人声 `<span ttm:role>`、多语言翻译)、登录态失效检测与重连、无订阅/非目录歌曲降级。

## 8. 构建/验证

- LyricsKit:`cd /Volumes/Code/Personal/LyricsKit && swift build 2>&1 | xcsift`
- LyricsX:`xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX -configuration Debug build 2>&1 | xcsift`
- 端到端验证:「晴天 周杰伦」应得到 `displayType: 3` 的逐字 TTML 歌词。

## 9. 风险/注意

- `InlineTimeTag.Tag.index` 是**字符索引**:CJK/拉丁混排、`<span>` 含多字时索引要算准;`XMLParser` 多字节拆包要累积。
- catalog search 可能返回错歌 → 必须用 `duration` 容差匹配。
- 登录态(cookie/session)数月级过期 → 检测未授权并提示重连。
- `api.music()` 方法名/amp-api 若变需适配;`callAsyncJavaScript` 需 `contentWorld: .page`。
- 不能上 MAS。
- **Route B 关键未验证项**(需登录态 PoC 实测,公开 API 无法验证):① amp-api 是否支持 `GET /v1/catalog/{sf}/songs?filter[isrc]=`;② 账号在 storefront X 能否查 `/v1/catalog/{他区}/...` 目录;③ 按区拆分的歌(如「晴天」cn=535824738 / us=1721464906)cn/us 两个 entry 是否共用同一 ISRC —— 不共用则该歌无法 B 桥接(仅降级,Route A 不受影响);④ amp-api `?l=` 对 `name` 是否有效(iTunes Search API 的 `lang` 实测无效,预期 amp-api `l` 同样无效)。
- **`SystemMusicPlayer` 私有路径(§3.5)已证伪** —— PoC 证明 `queue.currentEntry` / `MPMusicPlayerController.nowPlayingItem` 在 macOS 恒 `nil`,不再采用;歌曲识别改走 §3.6 MediaRemote。
- **§3.6 MediaRemote 路径(待 PoC)**:`mediaremote-adapter` 用私有 API,同样不可上 MAS(LyricsX 独立分发可接受);now-playing dict 的键随 macOS 版本可能变动。

## 10. 相关链接

- Issue:https://github.com/MxIris-LyricsX-Project/LyricsX/issues/17
- 触发本调研的 Teages 试验提交(iTunes Search API 方案,已评估为不够好):`Teages/LyricsX@c52c5cd`
- 记忆:`route_a_apple_music_lyrics.md`(调研结论)、`research_ios_nowplaying.md`(相关 RE)
- PoC(§3.5 验证):`AppleMusicLyricsPoC/`(与 LyricsX 仓库同级)—— 见其 `FINDINGS.md`(可行性结论)与 `README.md`
