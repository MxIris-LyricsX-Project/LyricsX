# Build Settings xcconfig 化迁移

> 把原本散落在 `LyricsX.xcodeproj/project.pbxproj` 里的全部 build settings 抽离到顶层 `Config/` 目录下的分层 xcconfig 文件，让 pbxproj 只保留 `baseConfigurationReference`。

## 动机

- **Xcode 升级时不再被覆盖**：以前每次升 Xcode，`LastUpgradeCheck` + "Update to recommended settings" 会改一大堆 pbxproj 里的 warning 开关，diff 噪音大、容易把人工调整也覆盖掉。xcconfig 化后所有 warning 选项明确锁在文本文件里。
- **集中、可读、可 review**：所有非默认 setting 都在 `Config/` 下的纯文本文件里，PR diff 清爽。
- **Debug/Release 差异显式**：bundle id、entitlements 路径、optimization 级别等 Debug/Release 不同的 setting 不再混在同一个 dict 里靠 key 区分，而是天然分到不同文件，一眼能看出差异。
- **变量复用**：`LX_BUNDLE_ID_PREFIX = dev.JH` / `com.JH` 通过 xcconfig 变量只声明一次，`PRODUCT_BUNDLE_IDENTIFIER` 之类的字段引用 `$(LX_BUNDLE_ID_PREFIX).LyricsX` 即可。

## 分层结构

```
Config/
├── Shared.xcconfig                 # 跨 target 跨 config 共同底座
├── Shared-Debug.xcconfig           # #include Shared.xcconfig + Debug 公共差异
├── Shared-Release.xcconfig         # #include Shared.xcconfig + Release 公共差异
├── Project-Debug.xcconfig          # #include Shared-Debug.xcconfig + Project 级 Debug
├── Project-Release.xcconfig        # #include Shared-Release.xcconfig + Project 级 Release
├── LyricsX/
│   ├── LyricsX.xcconfig            # LyricsX target 共同部分（Info.plist、framework search、min OS 12.0）
│   ├── LyricsX-Debug.xcconfig      # #include LyricsX.xcconfig + Debug 专属（entitlements、PRODUCT_NAME=*-Debug 等）
│   └── LyricsX-Release.xcconfig    # 同上 Release
├── LyricsXHelper/
│   ├── LyricsXHelper.xcconfig
│   ├── LyricsXHelper-Debug.xcconfig
│   └── LyricsXHelper-Release.xcconfig
└── LyricsXWidget/
    ├── LyricsXWidget.xcconfig      # widget target，独立保持 min OS 15.0
    ├── LyricsXWidget-Debug.xcconfig
    └── LyricsXWidget-Release.xcconfig
```

共 14 个 xcconfig 文件。

## pbxproj 里发生了什么

8 个 `XCBuildConfiguration`（4 target × Debug/Release）变成下面这种空壳：

```
BB4141B71E458BA900A51775 /* Debug */ = {
    isa = XCBuildConfiguration;
    baseConfigurationReference = E9C00C0100000000000000B4 /* Project-Debug.xcconfig */;
    buildSettings = {
    };
    name = Debug;
};
```

所有原 `buildSettings` 里的键值对都搬到了对应的 xcconfig 文件里。`buildSettings = { }` 必须保留（pbxproj 规范要求），但内容为空。

新增的 PBX 对象：
- 14 个 `PBXFileReference`（每个 xcconfig 一个），UUID 前缀 `E9C00C01...`
- 4 个 `PBXGroup`（`Config` 主 group + 3 个 target 子 group），UUID `E9C00C0100000000000000A1..A4`
- `Config` group 加入 mainGroup 的 children

## Setting 评估顺序与变量展开

Xcode build setting 评估顺序（后者覆盖前者）：

1. Platform defaults
2. Project xcconfig（`Project-{Debug,Release}.xcconfig`）
3. Project pbxproj `buildSettings`（已清空）
4. Target xcconfig（`<Target>-{Debug,Release}.xcconfig`）
5. Target pbxproj `buildSettings`（已清空）
6. 命令行 / 环境变量

变量展开是把所有上述层 merge 完成之后做一次替换。因此 `Shared-Debug.xcconfig` 里定义的 `LX_BUNDLE_ID_PREFIX = dev.JH` 可以在 `LyricsX-Debug.xcconfig` 的 `PRODUCT_BUNDLE_IDENTIFIER = $(LX_BUNDLE_ID_PREFIX).LyricsX` 里被解析为 `dev.JH.LyricsX`。

`#include "X.xcconfig"` 是 xcconfig 文件内部的层级机制（不在 pbxproj 里），加载顺序是先解析 include 文件再解析当前文件，所以当前文件里的同名 setting 会覆盖 include 文件里的。

## Debug / Release 的运行时差异

| Key | Debug | Release |
|---|---|---|
| `LX_BUNDLE_ID_PREFIX` | `dev.JH` | `com.JH` |
| `LX_HELPER_BUNDLE_ID` | `dev.JH.LyricsXHelper` | `com.JH.LyricsXHelper` |
| `LX_ICLOUD_CONTAINER` | `iCloud.dev.JH.LyricsX` | `iCloud.com.JH.LyricsX` |
| `PRODUCT_BUNDLE_IDENTIFIER` (LyricsX) | `dev.JH.LyricsX` | `com.JH.LyricsX` |
| `PRODUCT_NAME` (LyricsX) | `LyricsX-Debug` | `LyricsX` |
| `SWIFT_OPTIMIZATION_LEVEL` | `-Onone` | `-O` |
| `OTHER_SWIFT_FLAGS` | `-DDEBUG` | `-DRELEASE` |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` | `dwarf-with-dsym` |
| `ENABLE_NS_ASSERTIONS` | (default YES) | `NO` |
| `MTL_ENABLE_DEBUG_INFO` | `YES` | `NO` |
| `SWIFT_COMPILATION_MODE` | (default incremental) | `wholemodule` |

## 一次性变更：MACOSX_DEPLOYMENT_TARGET 归一

原 pbxproj 里 Project 级是 `10.11`，target 级 LyricsX/Helper 是 `12.0`，Widget 是 `15.0`。

迁移时把 Project 级从 `10.11` 提升到 `12.0` 与 LyricsX/Helper 对齐。Widget 保持 `15.0`（widget 代码本身只需要 macOS 14+ 的 `AppIntentConfiguration` / `containerBackground(for: .widget)`，15.0 是 Xcode 默认值，本次不动以避免连带风险）。

最终结果：
- Project: `12.0`
- LyricsX: `12.0`
- LyricsXHelper: `12.0`
- LyricsXWidget: `15.0`

实际编译产物不变（因为之前 target 级 12.0 / 15.0 已经覆盖了 Project 级 10.11）。

## 修改 build settings 的指引

- **改某一 setting**：找到它逻辑上属于的层级（跨 target 跨 config / per-config / per-target / per-target-per-config），改对应的 xcconfig 文件。**不要**回过头去在 pbxproj 里加 build setting。
- **新增一个 target**：为新 target 创建 `Config/<NewTarget>/<NewTarget>.xcconfig` + `-Debug.xcconfig` + `-Release.xcconfig`，并在 pbxproj 里给新 target 的 `XCBuildConfiguration` 设 `baseConfigurationReference`。
- **新增一个 build configuration**（除 Debug/Release 外）：先在 `Config/` 下增加对应 xcconfig，再让 pbxproj 里的新 `XCBuildConfiguration` 指过去。
- **检查 effective 值**：`xcodebuild -project LyricsX.xcodeproj -target <Target> -configuration <Config> -showBuildSettings | grep <KEY>` 可以快速验证某个 setting 在指定 target/config 下最终展开成什么。
