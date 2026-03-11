---
description: 为 XMNote 的 iOS/SwiftUI 界面补充有业务意义的结构动效和交互反馈，避免装饰性动画。
argument-hint: "<功能名、页面名或文件路径，可选>"
---

Use `impeccable-ios-design` and `swiftui-expert-skill`.

对 `$ARGUMENTS` 对应界面补充或修正动画与交互反馈。

要求：
- 动效只能服务结构变化、焦点转移、状态反馈和层级建立。
- 优先使用 SwiftUI 原生动画语义：`.snappy`、`.smooth`、`.spring`。
- 不要为了“灵动”加入弹跳过多、无意义转场、无意义延迟或装饰性渐隐渐现。
- 检查 Reduce Motion，并提供低运动量替代。
- 如果页面存在多个玻璃元素联动，评估是否需要 `GlassEffectContainer` 和 `glassEffectID(_:in:)`。
- 实现后如果改了应用源码，执行编译校验。
