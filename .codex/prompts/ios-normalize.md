---
description: 将 XMNote 的某个 iOS/SwiftUI 页面或组件对齐到现有设计系统、组件边界和 Apple 原生表达。
argument-hint: "<功能名、页面名或文件路径，可选>"
---

Use `impeccable-ios-design` and `swiftui-expert-skill`.

对 `$ARGUMENTS` 对应的 SwiftUI 界面做系统化对齐，而不是局部涂抹。

执行要求：
- 先扫描相关 Feature、公共组件、设计令牌和同类页面，确认已有模式。
- 优先复用现有 token 和组件，禁止引入一页专属的视觉语言。
- 保持 Android 业务意图对齐，但使用 iOS 原生表达，不做 Android 视觉直译。
- 避免卡片套卡片、无意义装饰图表、到处都是主按钮、过重阴影和装饰性玻璃。
- 如果需要改 Liquid Glass，用 Apple 官方规则判断是否该保留、收缩或替换。
- 实现后按仓库规则做最小必要验证；如果改了应用源码，执行编译校验。
