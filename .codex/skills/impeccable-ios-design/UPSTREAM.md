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

## 不直接复用上游的原因

- 上游 skill 面向通用前端，包含大量 Web/CSS 假设
- XMNote 是 iOS SwiftUI 项目，且已存在 `swiftui-expert-skill`
- 直接照搬会引入与当前仓库治理冲突的全局规则，并误导到 Web 方案
