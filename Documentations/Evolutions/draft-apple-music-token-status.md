# Draft - 实验室页显示 Apple Music token 是否有效

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-18
- **最后更新**: 2026-11-18
- **所属愿景**: 无
- **关联提案**: [0018 实验室页的 Apple Music 设置归入一组并补齐翻译](0018-lab-apple-music-group.md)（token 输入框所在的组框）
- **实现分支 / PR**: LyricsX `feature/apple-music-token-status`；LyricsKit `feature/apple-music-authorization-status`
- **配套文档**: 无（见决策日志 2026-11-18「不写配套专题文章」）；LyricsKit README 新增「Apple Music source requires a media-user-token」一节
- **网页版**: 同目录同名的 `.html`

## 摘要

设置窗口「实验室」页 Apple Music 组框里的 User Token 输入框下面加一行状态：检查中、有效（附账号所在地区）、
被 Apple Music 拒绝、暂时无法检查，旁边一个「重新检查」按钮。检查结果来自 LyricsKit 新增的公开 API
`LyricsProviders.Service.appleMusic.authorizationStatus(for:)`，它把 amp-api 的回答分成三种
（`authorized` / `denied` / `couldNotDetermine`），取代原来只给 true / false 的 `isAuthorized`。
`AppController` 用同一次检查决定要不要启用 Apple Music 歌词源并把结果发布给设置页，不额外发请求；
顺带让不依赖 token 的歌词源在检查期间就先装上，修掉「设置了 token 时启动后第一首歌搜不到歌词」。
LyricsKit 因此发布 1.13.0。

## 动机

- **用户反馈**：issue #223（「无法知道 musickit 令牌是否有效」，macOS 26.2.1、LyricsX 1.9.1）——用户从 Safari 的
  cookie 里复制了 `media-user-token` 贴进设置，「没有任何办法知道是否生效」，希望「输入好之后旁边显示一个 ✅」，
  以分清是解析成功了还是自己复制错了。
- **其实检查一直在做，只是结果没给用户看**：`AppController.updateLyricsManager()`
  （`LyricsX/Component/AppController.swift:266`）在启动、改 token、改地区或语言、切换播放器时都会请求一次
  `/v1/me/storefront`，不通过就不装 Apple Music 歌词源。结果只决定装不装，界面上没有任何反馈。
- **只有布尔值不够用**：LyricsKit 的 `AppleMusicSession.isAuthorized()`
  （`LyricsKit/Sources/LyricsService/Provider/Services/AppleMusic/AppleMusicSession.swift:81`）把所有失败——token 错了、
  没网、取不到网页播放器的开发者令牌、amp-api 返回 5xx——一律变成 `false`。直接把它显示出来，Apple 一改网页播放器，
  所有用户都会看到「token 无效」，引来更多误会。
- **报告者的 token 很可能本来就有效**：他说歌词列表里出现了 Apple Music 的歌词，而这个源只有检查通过才会装上。
  他真正的不满（标题仍是英文）归 MusicKit 原名恢复开关管，和 token 无关（见非目标）。有了状态行，这类混淆能当场排除。

## 前期调研

- **现状代码**
  - `AppController.updateLyricsManager()`（`AppController.swift:266-302`）：先建五个不需要凭据的歌词源；有 token 时
    构造 Apple Music provider，`await appleMusicProvider.isAuthorized` 为真才加入；最后整组替换 `lyricsManager`。
    调用方：初始化（`:262`）、原名恢复开关或播放器变化（`:174`）、设置页四个输入框的 action
    （`PreferenceLabViewController.swift:698/713/723/733`）。
  - 这个方法是 `@MainActor async`，几次调用可以在 `await` 处交错，后发起、先结束的那次会被先发起、后结束的覆盖——
    现有代码就有这个竞态，只是以前只影响装不装 Apple Music。
  - `AppleMusicSession`（LyricsKit，`actor`）：`isAuthorized()` 按实例缓存结果；`musicAPI(_:)`（`:110`）对非 2xx 一律抛
    `AppleMusicError.api(String)`，状态码只留在描述字符串里；遇到 401 或 403 时清掉开发者令牌缓存和授权缓存（`:139`）。
  - `LyricsProviders.Group.isAuthorized`（`Group.swift:24`）只是把各 provider 的结果取或，搜索时不逐个检查。
  - token 输入框在 storyboard 的 Apple Music 组框里：内层 grid `AMB-Gd-001`，token 一行是 `AMT-Ro-W01`
    （行高 28），左列标签宽 138，右列宽 338。实验室页已整体嵌进滚动视图（`embedContentInScrollView()`，
    `PreferenceLabViewController.swift:433`），多一行不会把窗口撑出屏幕。
  - 这一页已有两处在代码里插行的先例：`insertLyricsTranslationBox()`（`:259`）和
    `insertMenuBarKaraokeProgressColorRow()`（`:173`）。
  - `LyricsX/` 是 Xcode 的文件系统同步组（`PBXFileSystemSynchronizedRootGroup`），新建的 Swift 文件自动进 target，
    不用改 pbxproj。
- **amp-api 的实际回答**（2026-11-18 用 curl 实测 `/v1/me/storefront`，开发者令牌取自网页播放器）
  - 开发者令牌有效、`media-user-token` 是伪造的：**HTTP 403**，
    `{"errors":[{"title":"Forbidden","detail":"Invalid authentication","code":"40300"}]}`。
  - 开发者令牌有效、不带 `media-user-token`：**HTTP 403**，`detail` 为 `"Authentication required for request"`。
  - 开发者令牌本身是坏的：**HTTP 401**，空响应体。
  - 结论：403 表示「用户 token 被拒」，401 表示「开发者令牌被拒」，两者可以分开。有效 token 的 200 响应
    形如 `{"data":[{"id":"jp","type":"storefronts",…}]}`，取法与现有 `resolveStorefront()`
    （`AppleMusicProvider.swift:179`）相同。没有用真实 token 实测。
  - 顺带发现：`findDeveloperToken` 的首选正则 `qc="eyJ…"` 在当前网页播放器里已经匹配不到，靠的是后备的
    「第一个 JWT 形状的字符串」才取到令牌（实测这个令牌被 amp-api 接受）。功能目前正常，但后备规则已经在扛全部流量。
- **先例**
  - `MusicAuthorization.Status`（MusicKit）：`.authorized` / `.denied` / `.notDetermined` / `.restricted`。
  - `CKContainer.accountStatus()` → `CKAccountStatus`：`.available` / `.noAccount` / `.couldNotDetermine` /
    `.temporarilyUnavailable`——「暂时下不了结论」作为状态之一返回，而不是抛错。
  - LyricsKit 里同一个概念一直叫 authorization（协议要求 `isAuthorized`），新 API 沿用这个词。
- **推测，未验证**：订阅已过期但仍登录的账号，`/v1/me/storefront` 大概率仍返回 200（地区是账号属性），之后取逐字歌词时
  才失败。状态行会显示「有效」。没有过期账号可测。

## 提议方案

1. **LyricsKit 新增公开的检查结果类型和检查入口**（发布 1.13.0，纯新增 API，不破坏已有调用）：
   - `LyricsProviders.AppleMusicAuthorizationStatus`：`authorized(storefront:)`、`denied`、`couldNotDetermine(reason:)`。
   - `LyricsProviders.Service<AppleMusicOptions>.authorizationStatus(for:)`：与 `create(_:)` 并列，拿同一份 options
     问 amp-api。
   - 判定：2xx 取地区 → `authorized`；403 → `denied`；401 → 重新抓开发者令牌后重试一次，再 401 →
     `couldNotDetermine`；其他状态码、网络错误、取不到开发者令牌、响应体不对 → `couldNotDetermine`。没有 token 或为空
     → 直接 `denied`，不发请求。
   - `AppleMusicSession.isAuthorized()` 改为由同一套判定得出，因此也获得「开发者令牌刚过期时自动重抓重试」，
     不再把这种情况当成 token 无效。只缓存 `authorized` 和 `denied`，`couldNotDetermine` 不缓存。
2. **`AppController` 用这次检查装源并发布结果**：
   - 新增 `@Published private(set) var appleMusicTokenCheck: AppleMusicTokenCheck`，状态为
     无 token / 检查中 / 已有结论。
   - `updateLyricsManager()` 先立即装上不需要凭据的歌词源，再检查 token，检查通过才换成带 Apple Music 的一组。
     每次调用取一个递增的序号，检查回来时序号已过期就丢弃结果，不改状态也不换歌词源。
3. **实验室页显示状态**：
   - token 输入框下面插一行（左列空、右列放状态视图）：图标 + 一到两行说明 + 「重新检查」按钮。
   - 状态视图订阅 `appleMusicTokenCheck`。
   - 打开实验室页时若已填 token 就重新检查一次，按钮也触发重新检查，两者都走 `updateLyricsManager()`。
   - 各状态的显示：

     | 状态 | 图标 | 文字（英文原文） | 按钮 |
     |---|---|---|---|
     | 无 token | 无 | Paste a token to turn on Apple Music lyrics. | 隐藏 |
     | 检查中 | 小号转圈 | Checking token… | 隐藏 |
     | `authorized` | `checkmark.circle.fill`，绿色 | Valid. Apple Music lyrics are on (region: %@). | 显示 |
     | `denied` | `xmark.circle.fill`，红色 | Apple Music rejected this token. Copy it again from music.apple.com while signed in. | 显示 |
     | `couldNotDetermine` | `exclamationmark.triangle.fill`，橙色 | Couldn't check the token. Apple Music lyrics stay off until a check succeeds. | 显示 |

   - 地区按当前语言显示成地区名（`jp` → 「日本」），系统没有这个名字时显示原始代码。
   - `couldNotDetermine` 的技术原因放在 tooltip 里，所有状态的 tooltip 都带完整文字（防止两行放不下）。
   - 新文案补英文、简体中文、繁体中文。

### 非目标

- **原名恢复**：issue #223 的另一半（Apple Music 的日文标题仍显示成英文）归 MusicKit 原名恢复开关，不用 token。1.9.1
  在「系统级正在播放」模式下这个开关不生效；develop 已经钉了能报出播放器的 MusicPlayer 1.12.0，但还没实机验证。
  本提案不碰它。
- **token 搬进钥匙串**：`ReviewDecisions.md` 已裁决暂缓，本次不动存储位置。
- **订阅状态**：不判断账号订阅是否有效，只判断 amp-api 接不接受 token。
- **修首选正则**：`qc=` 规则失效、后备规则在扛流量，是单独的问题，另行处理。
- **取歌词失败时自动更新状态**：会话中途 token 过期，状态行要到下次打开实验室页或点按钮才更新，不从 provider 往上推。
- **自动修正用户输入**：不去掉 `media-user-token=` 前缀、引号之类，校验结果会告诉用户复制错了。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `LyricsKit/Sources/LyricsService/Provider/Services/AppleMusic/AppleMusicAuthorizationStatus.swift` · `LyricsProviders.AppleMusicAuthorizationStatus` | 新增 | 公开枚举，三种结果 | 让调用方分清「被拒」和「查不了」 | 1 |
| 同上文件 · `LyricsProviders.Service where Options == AppleMusicOptions` | 新增扩展 | `public func authorizationStatus(for:) async -> AppleMusicAuthorizationStatus` | 公开检查入口，与 `create(_:)` 并列 | 1 |
| `LyricsKit/…/AppleMusic/AppleMusicAuthorizationProbe.swift` · `AppleMusicAuthorizationProbe` | 新增（internal） | 按状态码与抛出的错误分类，401 时重抓开发者令牌重试一次 | 分类规则纯函数化，可用闭包替身测 | 1 |
| `LyricsKit/…/AppleMusic/AppleMusicSession.swift` · `AppleMusicSession` | 修改 | 新增 `send(_:)`（返回状态码与响应体，非 2xx 不抛错）和 `authorizationStatus()`；`musicAPI(_:)` 改为建在 `send(_:)` 上，行为不变；`authorizedCache: Bool?` 改为 `authorizationStatusCache`；`isAuthorized()` 由 `authorizationStatus()` 得出 | 状态码不能再丢在字符串里 | 1 |
| `LyricsKit/…/AppleMusic/AppleMusicSession.swift` · `AppleMusicAPIErrorParser`、`AppleMusicStorefrontResponse` 解码 | 修改 | probe 复用错误描述；地区解码从 `AppleMusicProvider.resolveStorefront()` 抽成 session 与 provider 共用的一处 | 两处解析同一个响应，不复制 | 1 |
| `LyricsKit/Tests/LyricsKitTests/Providers/AppleMusicAuthorizationProbeTests.swift` | 新增 | 分类规则的单元测试 | 见步骤 1 行为清单 | 1 |
| `LyricsKit/Tests/LyricsKitTests/Providers/AppleMusicAuthorizationLiveProbes.swift` | 新增 | 设了 `LYRICSKIT_LIVE_NETWORK=1` 才跑：伪造 token 对真实 amp-api 应得 `denied` | 403/401 的含义是 Apple 的行为，要能复查 | 1 |
| `LyricsXPackage/Sources/LyricsXFoundation/AppleMusicTokenCheck.swift` · `AppleMusicTokenCheck` | 新增 | 无 token / 检查中 / 已有结论；`includesAppleMusicLyrics`；`regionName(forStorefront:locale:)` | 状态与「装不装源」的规则放在可无界面测试的地方 | 2 |
| `LyricsXPackage/Tests/LyricsXFoundationTests/AppleMusicTokenCheckTests.swift` | 新增 | 见步骤 2 行为清单 | | 2 |
| `LyricsX/Component/AppController.swift` · `AppController` | 修改 | 新增 `appleMusicTokenCheck`、更新序号；`updateLyricsManager()` 先装无凭据源、再检查、过期结果丢弃 | 发布结果；修第一首歌搜不到与并发覆盖 | 3 |
| `LyricsX/Preferences/AppleMusicTokenStatusView.swift` · `AppleMusicTokenStatusView` | 新增 | 图标、转圈、说明文字、「重新检查」按钮；`show(_:)` | 状态行本身 | 4 |
| `LyricsX/Preferences/PreferenceLabViewController.swift` · `PreferenceLabViewController` | 修改 | `insertAppleMusicTokenStatusRow()`；订阅 `appleMusicTokenCheck`；`viewWillAppear` 有 token 时重新检查；按钮动作 | 把状态行接进实验室页 | 4 |
| `LyricsX/Supporting Files/Localizable.xcstrings` | 修改 | 新增 7 条文案（英、简中、繁中），按 `localizedStandardCompare` 手工插入 | 界面文字 | 4 |
| `LyricsKit` 标签 `v1.13.0` | 新增 | 在 LyricsKit `develop` 合并后的提交上打 | 发布新 API | 5 |
| `LyricsXPackage/Package.swift` | 修改 | LyricsKit `exact: "1.12.0"` → `"1.13.0"` | 钉住新版本 | 5 |
| `LyricsX.xcodeproj/…/Package.resolved` | 修改 | `-resolvePackageDependencies` 刷新，核对 diff 只动了 LyricsKit | 发版用这里的钉版 | 5 |
| `CLAUDE.md` | 修改 | `LyricsXFoundationTests` 覆盖清单加上 Apple Music token 检查 | 文档与代码同批 | 5 |
| `Documentations/ReviewDecisions.md` | 修改 | 「设置了 Apple Music token 时，启动后第一首歌搜不到歌词」由暂缓改为已修复，指向本提案 | 裁决清单要跟上 | 5 |

## 架构图

改了什么：

```text
LyricsKit · LyricsService/Provider/Services/AppleMusic/
  + AppleMusicAuthorizationStatus.swift
  +   public enum LyricsProviders.AppleMusicAuthorizationStatus
  +     authorized(storefront:) | denied | couldNotDetermine(reason:)
  +   extension Service where Options == AppleMusicOptions
  +     public func authorizationStatus(for:) async -> AppleMusicAuthorizationStatus
  + AppleMusicAuthorizationProbe.swift          (internal, pure classification)
  ~ AppleMusicSession.swift  (actor)
  +   send(_:) -> AppleMusicAPIResponse         (status + body, no throw on non-2xx)
  ~   musicAPI(_:) -> Data                      (built on send(_:), behavior unchanged)
  +   authorizationStatus() -> AppleMusicAuthorizationStatus
  ~   isAuthorized() -> Bool                    (derived from authorizationStatus())
  -   authorizedCache: Bool?
  +   authorizationStatusCache: AppleMusicAuthorizationStatus?

LyricsX
  LyricsXPackage/Sources/LyricsXFoundation/
  +   AppleMusicTokenCheck.swift                (noToken | checking | finished(status))
  LyricsX/Component/AppController.swift
  +   @Published appleMusicTokenCheck
  ~   updateLyricsManager()                     (base providers first, Apple Music after the check, stale checks dropped)
  LyricsX/Preferences/
  +   AppleMusicTokenStatusView.swift
  ~   PreferenceLabViewController.swift         (status row under the token field, re-check on appear)
```

检查的数据流：

```text
launch / token field edited / Lab pane appears / "Check Again" / player change
  └─ AppController.updateLyricsManager()                         @MainActor
       ├─ generation += 1
       ├─ lyricsManager = Group(tokenFreeProviders, plugins)     (installed at once)
       ├─ no token → appleMusicTokenCheck = .noToken, return
       ├─ appleMusicTokenCheck = .checking ─────────────────────► AppleMusicTokenStatusView: spinner
       ├─ await Service.appleMusic.authorizationStatus(for: options)
       │    └─ AppleMusicSession.authorizationStatus()
       │         └─ AppleMusicAuthorizationProbe
       │              GET amp-api /v1/me/storefront
       │                2xx            → .authorized(storefront)
       │                403            → .denied
       │                401            → refresh developer token, retry once
       │                401 again      → .couldNotDetermine
       │                other / throws → .couldNotDetermine(reason)
       ├─ generation changed meanwhile → return (drop this result)
       ├─ appleMusicTokenCheck = .finished(status) ─────────────► ✓ / ✗ / ⚠ + text
       └─ .authorized → lyricsManager = Group(tokenFreeProviders + appleMusic, plugins)
```

## 详细设计

### LyricsKit 公开 API

```swift
// AppleMusicAuthorizationStatus.swift
extension LyricsProviders {
    /// What Apple Music's amp-api made of a `media-user-token`.
    public enum AppleMusicAuthorizationStatus: Hashable, Sendable {
        /// amp-api accepted the token. `storefront` is the account's
        /// storefront identifier, such as `"jp"`.
        case authorized(storefront: String)
        /// amp-api refused the token (HTTP 403): it is mistyped, expired,
        /// or belongs to a session that signed out. A missing or empty
        /// token is also `denied`, without a request.
        case denied
        /// The check reached no verdict: no network, the web player's
        /// developer token could not be fetched or was refused twice, or
        /// amp-api answered something unexpected. `reason` is for logs and
        /// tooltips, not for matching.
        case couldNotDetermine(reason: String)
    }
}

@available(macOS 12.0, *)
extension LyricsProviders.Service where Options == LyricsProviders.AppleMusicOptions {
    /// Asks amp-api whether it accepts `options.mediaUserToken`, the way
    /// the provider made by `create(_:)` will use it.
    public func authorizationStatus(for options: Options) async -> LyricsProviders.AppleMusicAuthorizationStatus {
        await AppleMusicSession(mediaUserToken: options.mediaUserToken).authorizationStatus()
    }
}
```

- 枚举本身不加 `@available`：它是纯值类型，LyricsKit 的最低版本是 macOS 10.15，`LyricsXFoundation` 不必为它包 `#available`。
- 用 enum 而不是 struct 加静态成员：调用方要穷举三种结果来决定显示，和 `MusicAuthorization.Status` 一样。
  LyricsKit 只有 LyricsX 一个使用方、按源码编译，将来加 case 是一次有意的源码破坏，届时随大版本号走。
- 不抛错：`couldNotDetermine` 是正常结果之一（`CKAccountStatus.couldNotDetermine` 的先例），调用方总要显示它，抛错只会
  逼调用方把 catch 再映射回一个状态。

### 分类规则

```swift
// AppleMusicAuthorizationProbe.swift (internal)
struct AppleMusicAPIResponse: Sendable {
    let statusCode: Int
    let body: Data
}

enum AppleMusicAuthorizationProbe {
    static func status(
        requestingStorefront requestStorefront: () async throws -> AppleMusicAPIResponse,
        refreshingDeveloperToken refreshDeveloperToken: () async -> Void
    ) async -> LyricsProviders.AppleMusicAuthorizationStatus {
        for attempt in 1...2 {
            let response: AppleMusicAPIResponse
            do {
                response = try await requestStorefront()
            } catch {
                return .couldNotDetermine(reason: describe(error))
            }
            switch response.statusCode {
            case 200..<300:
                guard let storefront = AppleMusicStorefrontResponse.storefrontIdentifier(in: response.body) else {
                    return .couldNotDetermine(reason: "amp-api's storefront response has no storefront")
                }
                return .authorized(storefront: storefront)
            case 403:
                return .denied
            case 401 where attempt == 1:
                await refreshDeveloperToken()
            case 401:
                return .couldNotDetermine(reason: "amp-api refused the web player's developer token")
            default:
                return .couldNotDetermine(
                    reason: AppleMusicAPIErrorParser.describe(data: response.body, status: response.statusCode)
                )
            }
        }
        preconditionFailure("The second attempt always returns.")
    }
}
```

- `describe(_:)`：`AppleMusicError.developerTokenUnavailable(hint)` → 「couldn't fetch the web player's developer token: hint」；
  其他错误用 `localizedDescription`。
- 取消：`CancellationError` 与 `URLError.cancelled` 归入 `couldNotDetermine`。调用方用序号丢弃过期结果，不靠取消。

### `AppleMusicSession` 的改动

```swift
func send(_ path: String) async throws -> AppleMusicAPIResponse   // 请求构造照旧，只是不对非 2xx 抛错

func musicAPI(_ path: String) async throws -> Data {
    let response = try await send(path)
    if (200..<300).contains(response.statusCode) { return response.body }
    if response.statusCode == 401 || response.statusCode == 403 {
        await AppleMusicDeveloperTokenCache.shared.invalidate()
        authorizationStatusCache = nil
    }
    throw AppleMusicError.api(AppleMusicAPIErrorParser.describe(data: response.body, status: response.statusCode))
}

func authorizationStatus() async -> LyricsProviders.AppleMusicAuthorizationStatus {
    if let authorizationStatusCache { return authorizationStatusCache }
    guard let mediaUserToken, !mediaUserToken.isEmpty else { return .denied }
    let status = await AppleMusicAuthorizationProbe.status(
        requestingStorefront: { try await self.send("/v1/me/storefront") },
        refreshingDeveloperToken: { await AppleMusicDeveloperTokenCache.shared.invalidate() }
    )
    switch status {
    case .authorized, .denied: authorizationStatusCache = status
    case .couldNotDetermine: break                    // transient: ask again next time
    }
    return status
}

func isAuthorized() async -> Bool {
    if case .authorized = await authorizationStatus() { return true }
    return false
}
```

`musicAPI(_:)` 对外行为不变（包括 401/403 清缓存），只是建在 `send(_:)` 上。

### `AppleMusicTokenCheck`（LyricsXFoundation）

```swift
/// Where the check of the Apple Music `media-user-token` stands.
public enum AppleMusicTokenCheck: Hashable, Sendable {
    /// No token is entered; Apple Music lyrics are off.
    case noToken
    /// A check is on its way to amp-api.
    case checking
    /// amp-api answered, or the check gave up.
    case finished(LyricsProviders.AppleMusicAuthorizationStatus)

    /// Whether the Apple Music lyrics source goes into the search.
    public var includesAppleMusicLyrics: Bool {
        if case .finished(.authorized) = self { return true }
        return false
    }

    /// The storefront's region in `locale`'s language — "日本" for `"jp"`
    /// in Simplified Chinese — or the identifier itself when `locale` has
    /// no name for it.
    public static func regionName(forStorefront storefront: String, locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: storefront.uppercased()) ?? storefront
    }
}
```

### `AppController.updateLyricsManager()`

```swift
@Published private(set) var appleMusicTokenCheck: AppleMusicTokenCheck = .noToken
private var lyricsManagerUpdateGeneration = 0

@MainActor
func updateLyricsManager() async {
    lyricsManagerUpdateGeneration += 1
    let generation = lyricsManagerUpdateGeneration

    let tokenFreeProviders: [LyricsProvider] = [/* netease, qq, kugou, lrclib, musixmatch — as today */]
    var plugins: [LyricsSearchRequestPlugin] = []
    if #available(macOS 12.0, *), defaults[.appleMusicNameRecoveryEnabled], selectedPlayer.name == .appleMusic {
        plugins.append(AppleMusicNameRecoveryPlugin())
    }
    lyricsManager = LyricsProviders.Group(providers: tokenFreeProviders, plugins: plugins)

    guard #available(macOS 12.0, *),
          let token = defaults[.appleMusicMediaUserToken], !token.isEmpty else {
        appleMusicTokenCheck = .noToken
        return
    }
    appleMusicTokenCheck = .checking
    let options = LyricsProviders.AppleMusicOptions(
        mediaUserToken: token,
        storefrontOverride: defaults[.appleMusicStorefront].flatMap { $0.isEmpty ? nil : $0 },
        languageOverride: defaults[.appleMusicLanguage].flatMap { $0.isEmpty ? nil : $0 }
    )
    let status = await LyricsProviders.Service.appleMusic.authorizationStatus(for: options)
    guard generation == lyricsManagerUpdateGeneration else { return }

    appleMusicTokenCheck = .finished(status)
    if appleMusicTokenCheck.includesAppleMusicLyrics {
        lyricsManager = LyricsProviders.Group(
            providers: tokenFreeProviders + [LyricsProviders.Service.appleMusic.create(options)],
            plugins: plugins
        )
    }
}
```

- 检查用的 session 与 provider 内部的 session 是两个实例，provider 第一次搜索时自己还会再问一次
  `/v1/me/storefront`（开发者令牌是进程级缓存，不重抓）。多一次轻量请求，换来 provider 不必对外暴露 session。
- 代价：每次重新检查（包括打开实验室页）的那不到一秒里，歌词源暂时没有 Apple Music。那段时间开始的搜索只是少一个源。

### 状态视图

- `AppleMusicTokenStatusView: NSView`，内部一个水平 `NSStackView`：
  - 14 pt 的 `NSImageView`，用 `contentTintColor` 上色。
  - `.small` 的 `NSProgressIndicator`（spinning）。
  - 说明文字：`NSTextField(wrappingLabelWithString:)`，`.smallSystemFontSize`、`secondaryLabelColor`、最多两行。
  - `.small` 尺寸的「Check Again」按钮。
- `func show(_ check: AppleMusicTokenCheck)` 按上表设置图标、文字、tooltip 和按钮显隐；`checkAgainHandler: () -> Void`
  由设置页传入。
- 插行：`appleMusicMediaUserTokenField.superview as? NSGridView` 取到内层 grid，找 token 所在行，在其下
  `insertRow(at:with: [NSGridCell.emptyContentView, statusView])`；找不到就 `preconditionFailure`（与插卡拉OK颜色行同一写法）。
- 订阅：`AppController.shared.$appleMusicTokenCheck.receive(on: DispatchQueue.main).sink { statusView.show($0) }`，
  存进新的 `appleMusicTokenCheckObservation`。
- `viewWillAppear()` 里：已填 token 就 `Task { @MainActor in await AppController.shared.updateLyricsManager() }`。

### 新增文案

| 键（英文原文） | 简体中文 | 繁体中文 |
|---|---|---|
| Paste a token to turn on Apple Music lyrics. | 粘贴 token 即可启用 Apple Music 歌词。 | 貼上 token 即可啟用 Apple Music 歌詞。 |
| Checking token… | 正在检查 token… | 正在檢查 token… |
| Valid. Apple Music lyrics are on (region: %@). | 有效，已启用 Apple Music 歌词（地区：%@）。 | 有效，已啟用 Apple Music 歌詞（地區：%@）。 |
| Apple Music rejected this token. Copy it again from music.apple.com while signed in. | Apple Music 拒绝了这个 token。请登录 music.apple.com 后重新复制。 | Apple Music 拒絕了這個 token。請登入 music.apple.com 後重新複製。 |
| Couldn't check the token. Apple Music lyrics stay off until a check succeeds. | 无法检查 token。检查成功之前不会使用 Apple Music 歌词。 | 無法檢查 token。檢查成功之前不會使用 Apple Music 歌詞。 |
| Check Again | 重新检查 | 重新檢查 |
| Apple Music token status（无障碍标签） | Apple Music token 状态 | Apple Music token 狀態 |

## 替代方案考量

- **只改 app，沿用 `isAuthorized` 的布尔值**：不用发 LyricsKit。否决：网络不通、Apple 改网页播放器导致取不到开发者令牌时，
  所有人都会看到「token 无效」，和 issue 想解决的问题方向相反。用户在两者之间选了区分三种结果。
- **app 自己请求 amp-api 做检查**：等于在 app 里再写一遍开发者令牌抓取，两处会分头失效。否决。
- **本地检查 token 格式**：`media-user-token` 是不透明字符串，格式对不代表没过期。否决。
- **检查与装源分开各做一次**：设置页单独检查、`AppController` 照旧用 `isAuthorized`。否决：两个结果可能不一致
  （一个成功一个超时），界面说有效、歌词源却没装。
- **在输入框里放一个 ✅ 图标**（issue 里的建议）：`NSTextField` 没有现成的附件位，也放不下原因和重试按钮。改用输入框下的一行。
- **只在按按钮时检查**：状态会停在几小时前的结论上。改为打开实验室页时也查一次。
- **`authorizationStatus` 抛错表示「查不了」**：见详细设计，查不了是要显示的正常结果，不是异常。

## 影响

### 用户可见变化

- 实验室页 Apple Music 组框的 User Token 下面多一行状态和一个「重新检查」按钮。
- 打开实验室页、改完 token 后，状态在一两秒内更新。
- 设置了 token 时，启动后的第一首歌不再等 token 检查完才开始搜；Apple Music 的结果在检查通过后的下一次搜索里出现。
- 开发者令牌过期那一刻，不再被当成 token 无效而整段会话不用 Apple Music。

### 可发现性

状态行常驻显示，不需要开关。没填 token 时那一行提示「粘贴 token 即可启用 Apple Music 歌词」，顺带说明了这个输入框是干什么的。

### 数据与配置兼容

不新增偏好键，token 仍存在 `AppleMusicMediaUserToken`。没有迁移。

### 平台与最低版本

不变：app 最低 macOS 12，Apple Music 歌词源本来就要求 macOS 12。

### 发布

- 无新权限、entitlement 或隐私清单条目；amp-api 本来就在请求。
- 发版顺序：LyricsKit 先合进 `develop` 并打 `v1.13.0`，再改 LyricsX 的 `exact:` 和 `Package.resolved`。顺序反了 CI 会在
  archive 阶段报找不到新 API。
- 下一版发布说明在「新增」里加一条；发布后可以回复 #223。

## 落地步骤

1. **（已完成）LyricsKit：检查结果类型、分类规则与 session 改造**（功能分支，合进 LyricsKit `develop`）—— 改动地图第 1–7 行
   - 行为：`storefrontAnswerIsAuthorizedWithTheAccountStorefront`
   - 行为：`forbiddenAnswerIsDeniedWithoutRefreshingTheDeveloperToken`
   - 行为：`unauthorizedAnswerRefreshesTheDeveloperTokenAndAsksOnceMore`
   - 行为：`secondUnauthorizedAnswerCouldNotDetermine`
   - 行为：`unexpectedStatusCouldNotDetermineWithTheAPIErrorText`
   - 行为：`transportFailureCouldNotDetermine`
   - 行为：`unavailableDeveloperTokenCouldNotDetermine`
   - 行为：`storefrontAnswerWithoutDataCouldNotDetermine`
   - 行为：`missingOrEmptyTokenIsDenied`
   - 行为：`liveFakeTokenIsDeniedByAmpAPI`（需 `LYRICSKIT_LIVE_NETWORK=1`，否则跳过）
   - 验证：LyricsKit `swift test` 全绿。
2. **（已完成）LyricsX：`AppleMusicTokenCheck`**（对着本地 LyricsKit 开发：`LYRICSX_USE_LOCAL_DEPENDENCY=1` 或 workspace）—— 第 8–9 行
   - 行为：`onlyAnAuthorizedCheckIncludesAppleMusicLyrics`
   - 行为：`storefrontShowsAsTheRegionNameInTheLocale`
   - 行为：`unknownStorefrontShowsItsIdentifier`
3. **（已完成）`AppController` 发布检查结果并先装无凭据源** —— 第 10 行
   - 行为：`tokenFreeSourcesAreInstalledBeforeTheTokenCheckReturns`
   - 行为：`aCheckThatReturnsAfterANewerOneChangesNothing`
   - 行为：`onlyAnAuthorizedCheckAddsTheAppleMusicSource`
   - `AppController` 没法无界面测试，这三条靠代码审查和 Debug 构建运行时看日志确认。
4. **（已完成）实验室页状态行** —— 第 11–13 行
   - 行为：`statusRowSitsUnderTheTokenFieldInTheAppleMusicBox`
   - 行为：`eachCheckShowsItsSymbolTextAndButton`
   - 行为：`checkAgainStartsANewCheck`
   - 行为：`openingTheLabPaneChecksASavedTokenAgain`
   - 验证：workspace 下 Debug 构建通过。界面截图要等用户授权交互式验证，否则在汇报里说明没做。
5. **（文档已完成；打标签与改钉版待用户确认）发版接线与文档** —— 第 14–18 行
   - LyricsKit 打 `v1.13.0` 并推送，改 `exact:`，`-resolvePackageDependencies` 后只保留 LyricsKit 的变化。
   - 更新 `CLAUDE.md` 与 `ReviewDecisions.md`。
   - 行为：`projectResolvesLyricsKit1_13_0FromItsTag`（不设 `LYRICSX_USE_LOCAL_DEPENDENCY` 时 `swift build` 通过）

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：状态的含义在界面上，403/401 的判定写在提案和代码注释里。落地时再确认。
- **有没有引入新术语** —— 预计没有：「media-user-token」「开发者令牌」已在用。落地时再确认。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-18 | Created as Draft | issue #223 反馈：设置里填了 Apple Music token 之后，看不出它是否有效 |
| 2026-11-18 | 区分「有效 / 被拒 / 暂时无法检查」，为此改 LyricsKit 并发布 1.13.0 | 用户选择。只用现有的布尔结果，网络不通或 Apple 改网页播放器时会把所有人的 token 报成无效 |
| 2026-11-18 | 403 判为被拒，401 先重抓开发者令牌再重试一次 | curl 实测：用户 token 伪造或缺失时 amp-api 返回 403，开发者令牌坏了返回 401 |
| 2026-11-18 | 顺带让无凭据歌词源先装上，修「启动后第一首歌搜不到歌词」 | 同一个方法要重写；`ReviewDecisions.md` 里当初暂缓的理由是要改初始化顺序，这次正好改了 |
| 2026-11-18 | 用户批准，开始实现 | LyricsX 与 LyricsKit 各从 `develop` 切功能分支 |
| 2026-11-18 | 顺带修好 LyricsKit 测试 target 的编译 | 2026-06-30 给 `LyricsProvider` 加 `isAuthorized` 要求时，`GroupProviderTests` 的两个测试替身没跟着实现，整个 `LyricsKitTests` 从那以后就编译不过；不修就跑不了本提案的测试。只给两个替身各补一行，单独一个提交 |
| 2026-11-18 | LyricsKit 的 `.gitignore` 加上 `.worktrees/` | 这是该仓库第一个 worktree，没有忽略规则时主检出的 `git status` 会一直列出它 |
| 2026-11-18 | 测试 `missingOrEmptyTokenIsDeniedWithoutARequest` 改名为 `missingOrEmptyTokenIsDenied` | session 自带 `URLSession`、没有注入点，测试只能经公开 API 断言结果是 `denied`，证明不了「没发请求」；为一个名字去开新的注入点不值得 |
| 2026-11-18 | LyricsKit 功能分支先在本地快进合进 LyricsKit 主检出的 `develop`（未推送） | LyricsX worktree 经 `.worktrees/LyricsKit` 链接到 LyricsKit 主检出，本地开发要对着新 API 编译 |
| 2026-11-18 | LyricsKit 的 README 补「Apple Music source requires a media-user-token」一节 | README 已为 Musixmatch 的 token 写过同样一节，却没提 Apple Music；新 API 是公开的，调用方要知道先问 `authorizationStatus(for:)`、三种结果各是什么，以及联网探针怎么跑 |
| 2026-11-18 | `ReviewDecisions.md` 里那条暂缓的发现改为「已修复」并保留 | 清单只收没修的发现，但这条当初写着「暂缓」，直接删掉会让人以为它还没处理；在原条目下补一段修复说明 |
| 2026-11-18 | 不写配套专题文章；术语表无新增 | 403/401 的判定写在 LyricsKit 的类型文档和 README 里，状态行的含义在界面上，没有代码之外才说得清的维护决策；「media-user-token」「开发者令牌」都是已在用的词 |
| 2026-11-18 | 打 LyricsKit `v1.13.0`、推送 LyricsKit `develop`、把 `exact:` 改成 1.13.0 这三件留给用户确认 | 打标签并推送等于发布 LyricsKit，不在批准开工的授权里。在那之前功能分支钉的仍是 1.12.0，只有用本地依赖（workspace 或 `LYRICSX_USE_LOCAL_DEPENDENCY=1`）才编得过 |
| 2026-11-18 | 实现完成，待用户看过后收尾 | 状态行没有做界面验证（需要用户另外授权交互式操作）；`AppController` 的三条行为靠代码审查和构建确认 |
