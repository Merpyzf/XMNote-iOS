---
name: update-swiftui-apis
description: 按用户要求核查 SwiftUI API 弃用与替代信息，或更新仓库 .agents 中 SwiftUI Expert Skill 的 API 参考。检查请求只报告，更新请求修改参考；不因系统发布自动触发，不自动提交或创建 PR。
---

# Update SwiftUI APIs

按用户指定范围核查 Apple 官方资料，维护 [主版本 API 参考](../../../.agents/skills/swiftui-expert-skill/references/latest-apis.md)。遵守仓库 `AGENTS.md` 的权限、文档任务例外、Apple 查证顺序和 Git 门禁。

## 任务模式与边界

- “检查、扫描、有哪些变化”是只读核查，交付证据、差异及未验证项；不自动修改参考或生产代码。
- “更新、刷新参考/Skill”授权对应参考文件修改及必要检查，不必另等“任务已完成”。完成已授权更新，不停在建议阶段。
- 读取用户指定的 API、版本或类别；未限定类别的完整刷新才遍历清单。当前项目默认保持 Xcode 26、iOS 26.1 和 Swift 5 语言模式，SDK 27 专属内容仅用于明确要求的 SDK 27 工作。
- 本 Skill 不授权生产代码现代化、工程升级、分支切换、提交、推送或创建 PR。已授权的额外动作按各自规则完成，不重复询问；未授权时交付本地结果即可。

## 1. 确认现有覆盖

读取主版本 `latest-apis.md` 中与任务相关的版本段和 Quick Lookup Table，并参考 [迁移范围](../../../.agents/skills/swiftui-expert-skill/references/soft-deprecation-scope.md)。

主维护目标是仓库根下的 `.agents/skills/swiftui-expert-skill/references/latest-apis.md`；`.codex`、`.claude` 的 Skill 入口均指向它，不更新旧参考副本。目标路径固定，不凭当前工作目录猜测同名文件。

## 2. 选择查证范围

需要按类别扫描时读取 [扫描清单](references/scan-manifest.md)，使用其中与任务有关的 API 区域、文档路径、搜索词和 WWDC 路径。清单不是每次都要完整扫描的要求，也不要求启用某个旧工具。

## 3. 查证官方资料

优先使用当前可用的 `apple-doc-mcp`：

- 已知符号：`choose_technology -> get_documentation`。
- 未知符号但技术栈明确：`choose_technology -> search_symbols -> get_documentation`。
- 技术栈不明确：`discover_technologies -> choose_technology -> search_symbols -> get_documentation`。

MCP 不可用或资料不足时，采用 Apple 官方文档或相关本机 SDK。记录实际来源、适用版本和局限；Sosumi 不再是必需依赖。已有且仍适用的证据可复用，不重复同一查询。

区分正式弃用、软弃用、仅有推荐替代和新 API 可用性，不根据示例样式推断弃用状态。查不到直接替代时明确记录，不编造替代关系；仍无法证实的条目不写成确定事实，继续处理独立且已查证的条目。

## 4. 比较并更新

将发现归为新增条目、现有条目纠正或用户所请求的新版本段：

- 检查模式：报告与当前参考的差异和官方依据，不写入文件。
- 更新模式：只修改有证据且在授权范围内的条目、版本段及对应 Quick Lookup Table，保留其他内容和已有归属声明。
- 条目沿用现有“API 对照 + 最小示例 + 可用版本”的格式；说明适用目标和迁移边界。“优先使用”不代表所有任务都要立即迁移旧代码。
- 新增或纠正内容注明实际官方来源；已有 Sosumi 归属声明是历史来源，不把本次通过其他渠道取得的资料伪称为 Sosumi 核查结果。
- SDK 27 专属参考保留显式启用边界，不反向改变当前项目的生成默认值。

## 5. 验证与交付

检查引用路径、版本段与表格的一致性、代码围栏，以及修改过的 Skill 的 `quick_validate.py` 结果。纯参考更新不自动构建 App 或运行 App 测试；确需编译实验时按任务需要和仓库预检规则执行。

交付已更新或已核查的范围、依据、实际检查结果及未验证项。没有查到有证据的新增变化也是完整核查结果，不为产生 diff 而修改。

仅当用户明确要求额外 Git 操作时，才执行对应动作：需要创建分支时默认使用 `codex/` 前缀，不擅自切换基线；历史写入先使用 [xmnote-git-commit](../../../.agents/skills/xmnote-git-commit/SKILL.md) 并取得 PASS；推送和 PR 创建分别确认已在用户授权范围内。未授权这些动作不妨碍本地核查或参考更新完成。
