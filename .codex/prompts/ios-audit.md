---
description: 对 XMNote 的 iOS/SwiftUI 界面做设计与体验审计，重点检查 HIG、一致性、可访问性、层级与 Liquid Glass 误用。
argument-hint: "<功能名、页面名或文件路径，可选>"
---

Use `impeccable-ios-design` and `swiftui-expert-skill`.

对 `$ARGUMENTS` 指定的页面、组件或模块进行 iOS 设计审计。

要求：
- 先读当前仓库 `AGENTS.md`、相关 Feature 代码、设计令牌和已有组件。
- 以 Apple HIG、当前设计系统、SwiftUI 可访问性和 Liquid Glass 官方规则为基准。
- 重点检查：信息层级、亲密性、触控热区、Dynamic Type、安全区、次级文本对比度、组件归位、Android 直译痕迹、AI 模板感。
- 若涉及玻璃效果，明确判断它是否错误进入内容层，是否应该改为系统组件或普通材质。
- 输出必须“问题优先”，按严重级排序，并附文件路径与必要的行号。
- 若没有问题，明确写“未发现阻塞级/高优先级问题”，再补残余风险。
- 不要直接改代码，除非用户明确要求实现。
