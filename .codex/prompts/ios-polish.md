---
description: 对 XMNote 的 iOS/SwiftUI 界面做最后一轮细节抛光，聚焦对齐、间距、状态与文本质量。
argument-hint: "<功能名、页面名或文件路径，可选>"
---

Use `impeccable-ios-design` and `swiftui-expert-skill`.

对 `$ARGUMENTS` 对应界面做发布前抛光。

要求：
- 只处理会明显提升完成度的细节：间距、对齐、字重、亲密性、状态反馈、图表轨道轻重、分割关系、交互反馈。
- 默认不要改信息架构，除非当前结构明显破坏层级。
- 检查 loading / disabled / error / success 状态是否完整。
- 检查辅助文案是否过远、过淡、过多。
- 检查动画是否克制并尊重 Reduce Motion。
- 若涉及按钮、浮层、功能条，评估是否可用系统风格或更轻的材质替代自定义装饰。
- 实现后如果改了应用源码，执行编译校验。
