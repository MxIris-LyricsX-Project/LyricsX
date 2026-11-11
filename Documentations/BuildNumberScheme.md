# Build Number Scheme

## 背景与动机

LyricsX 之前用一个手动维护的、单调递增的整数 build 号（每次发版手工
`+1`）。这个方案在单一发布通道下没问题，但在引入 beta 通道
（参见 [`BetaUpdateChannel.md`](BetaUpdateChannel.md)）后立刻暴露问题：

- 假设 `v1.9.0-beta.5` 发布时 build = `2920`。
- 之后在 master 分支为 `v1.8.x` 系列发了一个 hot fix `v1.8.7`，
  build = `2925`。
- Sparkle 默认的版本比较器 `SUStandardVersionComparator` 比较的是
  `CFBundleVersion`（即 `<sparkle:version>`）。
- 已订阅 beta 通道的用户当前在 `2920`，看到 `2925` → 判定为"更新"
  → 实际被推回了一个 marketing version 更低的 stable hot fix。

根因是 build 号承担了"识别构建"和"排序构建"两个职责，但跨通道时
"递增整数"与"marketing version 的语义顺序"必然冲突。

## 方案

把 build 号从一个"无关的递增计数器"改成一个**marketing version 的
保序编码**——一个由 VERSION 字符串机械派生的整数，并且这个整数同时满足：

- 严格单调反映 semver 顺序（包括 prerelease 规则
  `alpha < beta < rc < stable`）；
- 还是个正整数（满足 Apple 对 `CFBundleVersion` 的格式约定，也
  满足 Sparkle 默认比较器的处理逻辑）；
- 不依赖手工维护，发版脚本自动计算。

### 编码公式

```
build = MAJOR * 10_000_000
      + MINOR * 100_000
      + PATCH * 1_000
      + sublabel
```

`sublabel` 把 prerelease 后缀编码为一个 `0..999` 的整数，按
`alpha.N < beta.N < rc.N < stable` 的顺序划分：

| 后缀 | sublabel |
|---|---|
| `alpha.N`（N=1..99） | `N` |
| `beta.N`（N=1..99） | `100 + N` |
| `rc.N`（N=1..99） | `200 + N` |
| 无后缀（stable） | `999` |

任何无法解析的后缀（例如 `bata.1`、`beta`、`beta.100`、`beta.0`）
都会让脚本直接 `die`，防止打错版本号悄悄上线。

### 典型例子

| Marketing version | Encoded CFBundleVersion |
|---|---|
| `1.8.7` | `10_807_999` |
| `1.8.8` | `10_808_999` |
| `1.9.0-alpha.1` | `10_900_001` |
| `1.9.0-beta.5` | `10_900_105` |
| `1.9.0-beta.6` | `10_900_106` |
| `1.9.0-rc.1` | `10_900_201` |
| `1.9.0` | `10_900_999` |
| `1.9.1-beta.1` | `10_901_101` |
| `1.10.0` | `11_000_999` |
| `2.0.0-beta.1` | `20_000_101` |

### 跨通道排序验证

- beta 用户 `1.9.0-beta.5`（`10_900_105`）
  + 看到后发的 stable hot fix `1.8.8`（`10_808_999`）
  + `10_900_105 > 10_808_999` → **不会被推回 stable** ✓
- beta 用户看到下一个 beta `1.9.0-beta.6`（`10_900_106`）
  + `10_900_106 > 10_900_105` → 正常 update ✓
- stable 用户 `1.8.7`（`10_807_999`）
  + 看到 stable hot fix `1.8.8`（`10_808_999`）→ update ✓
  + 看到 beta `1.9.0-beta.6`（`10_900_106`，但订阅了 beta 通道）→ update ✓
  + 看到 beta `1.9.0-beta.6` 但未订阅 → channel 过滤掉，无更新 ✓

## 实现

### 编码函数：`Scripts/release/lib.sh`

新增 `encode_build_number()` 函数，纯 bash，可被其他脚本 `source` 后
调用：

```bash
source Scripts/release/lib.sh
encode_build_number "1.9.0-beta.5"   # → 10900105
```

### 写入时机：CI 的 `validate` 步骤

`Scripts/release/validate.sh` 在 release 流程的早期就把编码后的 BUILD
通过 `PlistBuddy` 直接写入两个 plist：

- `LyricsX/Supporting Files/Info.plist`
- `LyricsXWidget/Supporting Files/Info.plist`

然后导出 `BUILD` 环境变量给后续步骤（archive、appcast 写入、
Sparkle 签名、产物命名等）使用。

### Info.plist 里 committed 的 `CFBundleVersion` 不再权威

由于 CI 在 archive 之前会覆盖它，仓库里 committed 的值只是个
"上一次有人手动改过的快照"，不必维护、不会影响 release。
发版者只需要保证 `CFBundleShortVersionString`（marketing version 的
基线，例如 `1.9.0`）与 tag 匹配即可——`validate.sh` 也会校验这一点。

### 删除的脚本/Phase

原本由 `LyricsX.xcodeproj/project.pbxproj` 维护的两个
`PBXShellScriptBuildPhase` 已经删除：

- **"Bump Build"**：在 archive 时把 `CFBundleVersion +1`。与编码方案
  冲突（会把 `10_900_105` 错误地变成 `10_900_106`，假装是下一个 beta），
  且其 widget 同步路径 `LyricsXWidget/Info.plist` 因为文件被搬到
  `LyricsXWidget/Supporting Files/Info.plist` 后就一直是失效的。
- **"Update Build Time"**：每次构建写一个时间戳到
  `LX_BUILD_TIME` 这个自定义 Info.plist 键。该键全仓库没有任何消费者
  （代码、脚本、appcast、文档均不读它），属于纯粹的 git noise 源头。
  现已连同 Info.plist 里那一行 key 一起删除。

附带清理：CI 工作流和 `Scripts/release/build.sh` 中原本用来抑制
"Bump Build" 的 `LYRICSX_SKIP_BUILD_BUMP=1` 环境变量也一并移除，
因为它现在已经是空操作。

## 跟 Beta 通道方案的关系

`BetaUpdateChannel.md` 描述的 channel 机制决定"客户端**看得见**哪些
`<item>`"；本方案决定"被看见的 item 里**哪个最新**"。两层职责正交：

- channel 标签控制可见性（订阅 beta 的用户才看到带
  `<sparkle:channel>beta</sparkle:channel>` 的 item）；
- 编码 build 号控制比较结果（同样可见的 item 之间，谁的整数大谁就是
  更新版本）。

只有这两层都对，才能保证"beta 用户在 beta 通道内单调前进，
不会被 stable hot fix 拉回"。

## 为什么不用 macOS 风格（`25F80`）

最初讨论时曾提到 macOS 系统的 build 号格式（如 `25F80`：年.字母.序号）。
不采用的原因：

1. **Sparkle 默认比较器不认这种格式**。`SUStandardVersionComparator`
   会尝试按"看似版本号"的规则拆 `25F80`，遇到字母段 `F` 行为不可预期。
2. **要让 Sparkle 正确比较，必须写自定义 `SUVersionComparator`**，
   还得给字母段定义一套显式映射（`F` 之于 `G` 谁大？beta 怎么编码？）。
3. **Apple 自己的 macOS build 号也不是用 Sparkle 比的**——苹果走自家
   Software Update 服务端逻辑，build 号在客户端这层只是个标签。硬把
   语义塞进字母段会与现有工具链脱节。
4. **本方案的整数编码已经满足所有需求**（保序、可比较、向后兼容
   Sparkle 默认比较器、无需任何客户端代码），并且把"build 号"留作
   纯整数也让 Apple 各种工具链（notarization、Console、`vtool`、
   `otool` 等）的行为可预测。

## 迁移说明

**不需要任何过渡发布**。

- 存量用户 `CFBundleVersion` 大约在 `2920`–`2929` 区间。
- 下一次 release 起，新编码起步于 `1.9.x` 系列对应的 `~10_900_000+`，
  远高于任何存量值。
- Sparkle 比较 `2925`（host）vs 新发布的 `10_900_999` → host 严格 ≤
  item → 推送更新，存量用户自然 forward update 到新方案下的版本。
- 之后所有版本都在新编码空间内，单调推进。

唯一**不能做**的事：将来若想"重新启用某个 marketing version 序列里
比当前更老的版本"作为 release 时，需要小心 build 号不会回落到存量
区间——但因为编码本身严格反映 marketing version，这种情况只会在
marketing version 也回退（语义上不合理）时才会出现。

## 验证

发版前可在本地直接验证：

```bash
source Scripts/release/lib.sh
for version in 1.8.7 1.9.0-beta.5 1.9.0-rc.1 1.9.0 1.8.8 1.9.1-beta.1; do
    printf '%-20s -> %d\n' "$version" "$(encode_build_number "$version")"
done
```

预期输出严格对应上文"典型例子"表。
