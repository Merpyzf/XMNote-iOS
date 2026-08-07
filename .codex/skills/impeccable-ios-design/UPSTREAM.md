# Upstream

- 上游仓库：`https://github.com/pbakaus/impeccable`
- 锚定提交：`0df1ba59dc80b8b1891ee42eed0ef4e03d7ef165`
- 上游安装路径快照：`.codex/vendor/impeccable-frontend-design-upstream`
- 上游来源 skill：`source/skills/frontend-design`
- 许可证：Apache License 2.0

## 本地改造原则

- 保留：反 AI-slop、层级控制、节制动效、审美评审、避免模板化 UI
- 删除：HTML/ARIA/CSS/OKLCH/container query 等 Web 专属要求
- 改写：响应式改为 Dynamic Type + size class + safe area；交互改为 iOS 触控语义；动效改为 SwiftUI 语义
- 新增：Apple HIG、Liquid Glass 官方约束、XMNote 仓库设计令牌与组件边界优先级

## 评审流程校准来源

- [Wholiver/swiftui-design-skill@2c82638](https://github.com/Wholiver/swiftui-design-skill/commit/2c82638ebd3c801d9d2d12b5f2d6c20495939995)：参考其识别模板化 SwiftUI 表达和从业务上下文审视设计的思路。
- [vermont42/iOS-Design-Agent-Skill@7606a41](https://github.com/vermont42/iOS-Design-Agent-Skill/commit/7606a41ad51fd040dc9cc813533e4d7552be4c49)：参考其结合截图与代码、按影响排序并给出可执行修正的审查方式。

上述来源只用于校准问题意识与评审流程。本地规则均按 XMNote 的 `AGENTS.md`、生产设计真相和 Apple 平台边界重新表述；不复制固定风格、代码、主观评分体系或任意视觉禁令。

## 不直接复用上游的原因

- 上游 skill 面向通用前端，包含大量 Web/CSS 假设
- XMNote 是 iOS SwiftUI 项目，且已存在 `swiftui-expert-skill`
- 直接照搬会引入与当前仓库治理冲突的全局规则，并误导到 Web 方案
