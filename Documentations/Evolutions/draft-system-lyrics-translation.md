# Draft - 实验室：用系统翻译（Translation 框架）翻译歌词

- **状态**: In Progress
- **创建日期**: 2026-10-20
- **最后更新**: 2026-10-20
- **实现分支 / PR**: `feature/system-lyrics-translation`

## 摘要

实验室页的「歌词翻译」加一个系统翻译引擎：用 macOS 的 Translation 框架在本机翻译缺目标语言译文的行，
不用 API key、不发给第三方、不花钱，和 AI 翻译（0020）二选一。译文的存法、显示、落盘全部沿用 0020。

## 方案

**调研结论**（2026-10-20，对照 26.1 / 26.5 / 27.0 / 27.2 SDK 与 macOS 15.5、26.7、27.0 的 dyld cache）：

- 不需要私有接口。`TranslationSession(installedSource:target:)` 从 macOS 26.0 起就是公开 API，26.1 SDK 已有，
  CI 用的 Xcode 26.4 能直接用。27 没有新增任何东西：27.x SDK 的 Translation 接口与 26.5 逐项相同，27.0 与 26.7
  二进制 dump 出的 Swift 接口也逐行相同。
- 二进制里藏着、公开接口里没有的：`init(configuration:)`（15.5–27.0 都在，SwiftUI 的 `.translationTask` 用它）、
  指定构造器（15.x 是 `init(sourceLanguage:targetLanguage:)`，26 起改成多了 `preferredStrategy:isHeadless:`）、
  `allowOnlineTranslation`、`textSessionDelegate`、`hardCancel()`。签名跨版本变过，Swift 里只能按 mangled name 调，不用。
  dump 在 `/Volumes/DyldSharedCaches/macOS/{26.7,27.0}/{Translation,_Translation_SwiftUI}/`。
- 公开构造器的限制：语言没下载时翻译直接抛 `notInstalled`，它自己请求不了下载。请求下载只能走 SwiftUI 的
  `.translationTask`：系统把确认下载的 sheet（`DownloadsHostingView`）挂在宿主视图所在的窗口上。

**要做的**：

1. **选引擎**：组框里「Enable AI translation」勾选框换成下拉框「翻译：关 / 系统翻译 / AI（OpenAI 兼容）」，「配置…」只在
   AI 时可用。新键 `LyricsTranslationEngine`；没有这个键时按旧的 `AILyricsTranslationEnabled` 迁移（开着 → AI），改引擎时
   同步写回旧键，降级回旧版本 AI 开关不变。
2. **目标语言**挪到组框里（AI 设置面板去掉这一栏），两种引擎共用，仍存在 `AILyricsTranslationTargetLanguage`，已存的值不丢。
3. **翻译流程**（macOS 26+）：源语言取歌词已识别的主语言，一首歌的行全进同一个 session（外语行也一样，理由见决策日志的
   探针两行）；原样返回的行（已是目标语言的、罗马音）不存成译文，也不算失败。先查 `LanguageAvailability`：已安装就用
   `TranslationSession(installedSource:target:)` 整批翻，macOS 26.4+ 指定 `.highFidelity`（用 Apple Intelligence 出更通顺的译文，
   不可用时系统自己回退）。结果交给 0020 现成的那段：写成 `tr:<目标语言>` 附件、上屏、落盘，内嵌和旁置歌词同样先读
   歌词库副本里已有的译文。
4. **语言没下载**：状态行写明缺哪一对（「日语 → 简体中文还没下载」），旁边出现「下载…」按钮。按钮经一个不可见的
   SwiftUI 宿主调 `.translationTask` + `prepareTranslation()`，系统的下载确认挂在设置窗口上，下完自动重试。语言对不受支持
   时直说不支持。
5. **macOS 15–25**：下拉框里「系统翻译」置灰，提示需要 macOS 26。
6. **测试**：引擎迁移、按语言分组这些纯策略进 `LyricsXFoundationTests`；另加一个真实调用 Translation 框架的探针测试，
   本机没装对应语言就跳过。实验室页按 `PreferenceWindowSizing.md` 记的离屏方法检查布局。下载 sheet 弹不弹得出来
   要在 app 里实际点一次。
7. **文档**：使用说明 `AITranslation.md` 改名 `LyricsTranslation.md`、改写成两种引擎都讲；术语表的「目标语言」改成两种引擎
   共用，新增「翻译引擎」；项目 `CLAUDE.md` 的测试段与架构段同步。

**落地步骤**（每步单独能构建、测试通过）：

- [x] 1. 探针：在本机用 Translation 框架翻测试文本，确认安装状态的查法和外语行的效果。
- [x] 2. `LyricsXFoundation`：引擎选择与迁移、译文的清洗与「原样返回」的判断、调用 Translation 的翻译器，连同测试。
- [ ] 3. `AppController`：翻译流程按引擎分派，系统翻译接进去，缺语言时把语言对交给界面。
- [ ] 4. 实验室页：引擎下拉框、目标语言挪进组框、「下载…」按钮；离屏检查布局。
- [ ] 5. 文档：使用说明、术语表、项目 `CLAUDE.md`、本提案。

**没有问就采用的假设**：

- 系统翻译不等优先级窗口：本机、免费，等 5 秒只会让译文晚出现；被换掉的歌词由现有的身份检查拦住，不会写进文件。
- 不用私有的 `allowOnlineTranslation`：它免下载，但歌词会发到 Apple 的服务器，第三方 app 能不能用也没验证。
- 新文案只补简体、繁体中文，与 0020 那批一致。
- 动手前先在本机跑一个探针，用 Translation 框架翻几行测试文本，确认固定源语言去翻外语行的效果；
  效果不差就不做逐行识别（结果：效果好，没做）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-20 | Created as Draft | 需求：歌词翻译加一个系统 Translation 框架的引擎。提出时的判断是不经 SwiftUI 创建 session 的构造器 27 才公开、26 里有但没公开，要求先 dump 二进制接口确认 |
| 2026-10-20 | 用公开的 `init(installedSource:target:)`，不调私有构造器 | 调研发现它 26.0 起就公开，27 没有新增；私有构造器的签名在 15 和 26 之间变过 |
| 2026-10-20 | 只支持 macOS 26+；与 AI 翻译二选一 | JH 选定。15–25 要靠私有构造器或藏起来的 SwiftUI 窗口，风险高、工作量翻倍；二选一让一首歌的译文出自同一个引擎 |
| 2026-10-20 | 用户批准，开始实现 | 方案与假设照上文，JH 未提异议 |
| 2026-10-20 | 第一次探针：本机（26.7）一个翻译语言都没下载；`zh-Hant → zh-Hans` 不受支持；不加约束的逐行识别不可靠 | 「Baby I love you」只有 54% 判成英语，一行罗马音 76% 判成土耳其语。当时先按方案做了逐行挑英文行，识别只许在歌词的语言和英语之间选（这样日、韩、中、西、德五种歌的每一行都在 97% 以上） |
| 2026-10-20 | 撤掉逐行识别，一首歌的行全进同一个 session；原样返回的行不存 | 语言包下载后再探：日→中的 session 把「Baby I love you」译成「宝贝，我爱你」，连韩语行也译对，英→中的 session 也译对日语行。逐行挑出来只会多要一个英语下载。原样返回的行（已是中文的、罗马音）存下来只会让双语歌词同一句显示两遍，按方案的假设去掉 |
| 2026-10-20 | 使用说明 `AITranslation.md` 改名 `LyricsTranslation.md` | 两种引擎都在里面，旧名只说 AI；README、文档索引、项目 `CLAUDE.md`、0020 头部的链接一并改 |
| 2026-10-20 | 「Requires macOS 26 or later」照已有的 macOS 15 那条补齐 17 种语言 | 那条已有全部语言的译文，只差数字；其余新文案照 0020 只补简繁中文 |
| 2026-10-20 | 不另写实现说明 | 容易踩的几处（为什么下载要走 SwiftUI、为什么不逐行识别、为什么引擎键要写回旧开关）写在代码注释、本提案和项目 `CLAUDE.md` 里，同 0020 |
