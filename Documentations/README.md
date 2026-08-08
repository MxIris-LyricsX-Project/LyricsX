# LyricsX 文档索引

**新增或重命名任何文档都必须同步更新这份索引。**

> **项目类型：App（macOS）**。提案的「影响」一节关注用户可见变化、可发现性、
> 数据与配置兼容、平台与最低版本、发布流程，不涉及 ABI。
> 第一篇提案由 `/evolution <描述>` 创建时会自动建立 `Evolutions/` 目录与提案索引。

## 工程实践

- [已裁决的 code review 发现](ReviewDecisions.md) —— 判定为误报或不值得修的发现及其理由。
  **每次 code review 先对照这份清单**，已裁决的不再重复走四问。

## 发布与版本

- [Beta 更新通道](BetaUpdateChannel.md) —— 此前只通过 Sparkle 推送正式版；这篇记录 beta 通道的引入。
- [Build 号方案](BuildNumberScheme.md) —— 从手工维护的单调递增整数改为编码方案。
  **改发版流程前必读**，build 号的编码规则影响 Sparkle 的版本比较。
