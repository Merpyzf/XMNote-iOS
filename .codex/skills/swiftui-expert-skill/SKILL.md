---
name: swiftui-expert-skill
description: XMNote SwiftUI Skill 兼容入口；用于 SwiftUI 实现、重构或审查，统一读取仓库 .agents 中维护的主版本与参考文件。
---

# SwiftUI Expert Skill — 兼容入口

本入口保留已有调用方式，不独立维护规则。开始当前任务前读取 [主版本 SKILL.md](../../../.agents/skills/swiftui-expert-skill/SKILL.md)，按主版本区分只读审查与已授权实施，并选择相关参考。

- 主版本目录：仓库根下的 `.agents/skills/swiftui-expert-skill/`。
- 主版本中的 `references/...` 均相对于主版本目录解析，不相对于本入口。
- 本目录现存的参考文件仅为兼容历史路径保留；当前任务和后续更新以主版本参考为准，不同时加载两套同名参考。
- 用户直接要求维护 SwiftUI Skill 时，修改主版本；仅在兼容路由本身需要变化时修改本入口。
- 主版本确实缺失或不可读时，报告具体路径和阻塞，不静默改用旧参考；继续不依赖该 Skill 的已授权工作。
