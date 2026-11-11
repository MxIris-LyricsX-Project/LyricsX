# Beta Update Channel

## 背景与动机

LyricsX 此前只通过 Sparkle 推送正式版（stable）更新：
`Scripts/release/publish-appcast.sh` 在检测到 `IS_PRERELEASE=true` 时直接
`exit 0`，`.github/workflows/release.yml` 也用
`env.IS_PRERELEASE == 'false'` 跳过 appcast 写入。结果是
`v1.x.y-beta.*` / `v1.x.y-rc.*` 这类预发布 tag 只能产生
`gh release --prerelease`，不会进入 `appcast.xml`，用户也无法在 App 内
"Check for Updates" 时收到 beta 版本。

本次改动为 beta 版本开通一条独立的更新通道，用户可以在
*Preferences → General* 勾选 "Receive beta updates" 来订阅，未勾选的用户
依旧只会看到正式版。

## 技术方案

采用 Sparkle 2 的 channel 机制（单 feed，多 channel 标签），不引入第二份
appcast。Sparkle 的契约：

- `<item>` 中**没有** `<sparkle:channel>` 的条目对所有客户端可见。
- `<item>` 中**有** `<sparkle:channel>foo</sparkle:channel>` 的条目，
  仅当客户端的 `SPUUpdaterDelegate.allowedChannels(for:)` 返回的集合
  包含 `"foo"` 时才会被采纳。

因此：

- Beta 版本的 `<item>` 会被打上 `<sparkle:channel>beta</sparkle:channel>`。
- 正式版的 `<item>` 不带任何 channel 标签 → 所有用户都能收到。
- 订阅了 beta 的用户会**同时**收到 stable + beta，永远拿到最新的可用版本。

## 修改清单

### 客户端

| 文件 | 改动 |
|---|---|
| `LyricsX/Utility/Global.swift` | 新增 `static let receiveBetaUpdates = Key<Bool>("ReceiveBetaUpdates")`，默认 `false`（未注册到 `UserDefaults.plist`） |
| `LyricsX/Component/AppDelegate.swift` | `SPUStandardUpdaterController` 挂上 `updaterDelegate: self`；新增 `extension AppDelegate: SPUUpdaterDelegate` 实现 `allowedChannels(for:)`；`applicationDidFinishLaunching` 里 `observeDefaults(.receiveBetaUpdates)` 触发立即重新检查 |
| `LyricsX/Supporting Files/Base.lproj/Preferences.storyboard` | General 面板的 `gridView` 末尾新增一行（`bta-rW-001`），承载一个 checkbox（`bta-bC-005`），绑定 `values.ReceiveBetaUpdates` |
| `LyricsX/Supporting Files/mul.lproj/Preferences.xcstrings` | 新增 `bta-bC-005.title` 条目：英 "Receive beta updates"、简中 "接收 Beta 版更新"、繁中 "接收 Beta 版更新" |

### Release pipeline

| 文件 | 改动 |
|---|---|
| `Scripts/release/update-appcast.py` | 读取 `IS_PRERELEASE` 环境变量；为 `true` 时在 `<item>` 中注入 `<sparkle:channel>beta</sparkle:channel>` |
| `Scripts/release/publish-appcast.sh` | 移除 prerelease 早退；两处 `python3 update-appcast.py` 调用都显式向下传递 `IS_PRERELEASE` |
| `.github/workflows/release.yml` | "Update canonical appcast" 与 "Mirror to legacy Pages repo" 两步的 `if` 由 `!inputs.dry_run && env.IS_PRERELEASE == 'false'` 改为 `!inputs.dry_run`，让 prerelease tag 也能进入 appcast |

## 影响面与迁移说明

- **历史 beta tag 不会自动回填**：本次改动仅影响**未来**推送的 tag。
  现存的 `v1.9.0-beta.1…8` 从未进过 appcast；用户即便立即勾上开关，
  也要等到下一个 tag（无论 stable 还是 beta）发布之后才会看到。
- **退订是 "粘性" 的，不会回退版本**。Sparkle 不做降级。一个已经在
  `v1.9.0-beta.8` 的用户取消勾选后，不会被推回 `v1.8.x`；他会停留在
  `v1.9.0-beta.8`，直到某个 stable 版本号严格高于它（例如 `v1.9.0`
  正式版发布）才会收到下一次推送。
- **channel 名称是 wire-format，一旦上线不可改名**。后续若想把
  `"beta"` 改成别的，所有已订阅用户都会"孤儿化"。本次锁死为 `"beta"`。
- **签名链路、公钥、`SUFeedURL` 完全不变**。`<item>` 只是多了一个子元素。
- **`SUEnableAutomaticChecks=true`** 已经在 `Info.plist` 设置，订阅 beta
  的用户无需任何额外操作就能在后台周期检查到新 beta。
- **镜像仓库同步**：`MxIris-LyricsX-Project.github.io/appcast.xml` 是
  `SUFeedURL` 指向的真正 feed，`publish-appcast.sh mirror` 会一起更新，
  beta 用户因此也能从镜像站拿到。
- **`update-appcast.py` 的幂等性保留**：仍以
  `<sparkle:shortVersionString>` 作为去重键，重跑某个 tag 是 no-op。

## 验证

- `python3 Scripts/release/update-appcast.py` 用 `IS_PRERELEASE=true`
  smoke 跑过，输出 `<item>` 包含 `<sparkle:channel>beta</sparkle:channel>`；
  不带该变量时，输出 `<item>` 不含 channel 标签。
- `xcodebuild -workspace ../MxIris-LyricsX-Project.xcworkspace -scheme LyricsX
  -configuration Debug build` 通过，0 errors / 0 warnings。
- 编译后的 nib 中可搜到 `Receive beta updates` 与
  `values.ReceiveBetaUpdates` 绑定；`zh-Hans.lproj/Preferences.strings`、
  `zh-Hant.lproj/Preferences.strings` 中 `bta-bC-005.title` 的值为
  "接收 Beta 版更新"。
