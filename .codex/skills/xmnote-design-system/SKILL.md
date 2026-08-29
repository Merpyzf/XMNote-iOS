---
name: xmnote-design-system
description: 为 XMNote 的 iOS/SwiftUI/UIKit 界面提供项目级设计系统决策与验证。用于新增、修改、迁移、重构、适配、抛光或审查界面，按场景选择当前排版、间距、颜色、表层、组件与交互，并阻止无证据的公共抽象和不成熟视觉模式。
---

# XMNote Design System

让后续 UI 工作持续遵守 XMNote 已经形成的设计语言，而不是重新设计产品或机械复制某个现存页面。这个 Skill 负责设计真相、组件归位、视觉语言、交互语义、公共能力准入和验证；SwiftUI 实现事实与专项动效分别交给对应 Skill。

## 决策优先级

发生冲突时按以下顺序判断：

1. 用户当次明确要求与仓库 `AGENTS.md`。
2. 真实 owner 源码、`scripts/design-system/policy.json` 与 `component-catalog.json`。
3. 独立生产消费路径、测试、Preview 和 Debug 验证宿主。
4. 当前协作文档与组件指南。

文档快照、单个生产页面、Debug 实验和 Android 视觉都不能单独成为设计真相。来源冲突时先查真实 owner 与 Git 历史，不引用不存在的 token、旧组件名称或过期统计。

已登记 canonical 条目的 catalog 元数据与其当前真实 owner 冲突时，核对 Git 历史和独立生产消费者；确认 owner 已迁移后，以当前 owner 的可执行接口与稳定职责为准，并报告 catalog 漂移，不能用过期 `useWhen/avoidWhen` 迫使页面恢复旧方案。这不赋予未登记文件或符号公共身份，也不授权在当前任务范围外顺手修改 catalog。

## 所有任务先走事实流程

任何 UI 新增、修改、迁移、重构、适配、抛光或审查都先读取 [工作流](references/workflow.md)，并完成其中的修改前发现步骤。最少需要：

1. 明确目标页面、用户任务、导航关系和当前证据类型。
2. 对相关 Swift 路径运行 `ds.py context`；已知组件使用真实符号片段查询 `ds.py catalog --symbol`，未知组件读取完整 catalog 后按 `useWhen/avoidWhen` 筛选。
3. 读取目标 owner、同模块成熟生产页面、候选公共组件及其 Preview/测试。
4. 将结论区分为已确认事实、视觉风险和待验证假设。

代码可以证明结构、API、token、状态分支和点击语义，不能单独证明最终密度、颜色观感或视觉层级。没有截图或实际渲染时，相关结论必须标记为“视觉风险，需截图验证”。

用户可以限制读取、运行或修改范围，但范围限制不会把不足的证据升级为设计事实。只允许读单个文件时，交付“受限代码审查”，明确未核对的 owner、catalog、生产消费者和渲染状态；不得暗中扩大范围，也不得对最终观感作确定性结论。

不要把“读取 owner”当作完成。对任务涉及的每个设计维度，都必须说明：内容或控件的语义角色、选择的 token/组件及 owner、为什么不选相邻入口、需要验证的状态。实现中使用当前 owner 的真实数值；Skill 参考中的数值只用于理解既有层级，不能复制为页面字面量。

## 实现选择顺序

按以下顺序选择方案，前一层能够解决时不得进入后一层：

1. 复用机器目录登记的 canonical 组件。
2. 使用现有 token 做页面级组合或 `Views/<Feature>/Components` 私有子视图。
3. 两个独立生产场景证明相同语义、状态边界和修复模式后，扩展现有公共能力。
4. 满足完整准入、依赖方向、Preview、目录登记和收口要求后，新建公共能力。
5. 拒绝会污染设计系统的方案，并给出最小可行替代。

不要用公共 token 收藏单页数字，不要用参数膨胀的万能组件覆盖业务差异，也不要因为某种样式已经存在就默认它值得复用。

当 canonical 骨架没有规定具体业务布局时，优先读取当前项目中用户任务、内容密度和交互关系最接近的成熟生产实现，复用其信息组织逻辑，不复制孤立尺寸，也不为满足抽象模板重新设计一套布局语言。骨架规则只统一跨场景稳定关系，业务内容继续由真实场景 owner 组织。

## 按任务读取参考

- 整体信息层级、品牌表达、文案、适配或可访问性：读取 [设计语言](references/design-language.md)。
- 字体角色、字号层级、行距、间距、圆角、描边或布局密度：读取 [排版、间距与布局](references/typography-and-layout.md)。
- 颜色、表层、卡片、图标、品牌 tint、操作按钮前景—背景配对、阴影或 Liquid Glass：读取 [颜色、表层、图标与材质](references/color-surfaces-and-material.md)。
- 页面或局部空态、搜索/筛选无结果、加载、失败、内容失效、保留内容错误、状态组件治理或状态视觉评审：读取 [页面状态与反馈](references/state-presentation.md)。
- 业务 Sheet 的骨架、标题操作、内容边距、卡片、圆角、Detent、退出保护或专项例外：读取 [业务 Sheet](references/sheets.md)。
- 组件归位、Settings、导航、Toast/Alert、点击热区或滚动：读取 [组件与交互](references/components-and-interaction.md)。
- 评审、规范缺口、疑似丑陋设计或公共抽象提议：读取 [证据与评审](references/evidence-and-review.md)。

只读取当前任务涉及的参考；一个任务跨越多个维度时组合读取。公共组件的实时清单始终通过 `ds.py catalog` 获取，不从参考文件猜测。

## 直接阻断

- 从 Android 界面、Debug 实验或单个页面复制新的全局视觉语言。
- 重复实现已有 canonical 组件，或绕过集中字体、颜色与组件入口。
- 仅凭一个场景新增全局 token、公共样式、公共组件或基础设施。
- 用品牌色泛化“可点击”，在内容层滥用玻璃，或用卡片嵌套、渐变、重阴影和装饰动效掩盖层级问题。
- 在操作按钮中把品牌派生文字或图标叠加到品牌派生实心/弱填充表层，或让 `.bordered` 无审查地继承根级 `appTint`；按钮必须按语义成对选择前景与背景，并验证实际对比度。
- 没有运行态证据却把主观观感写成已确认缺陷。
- 通过扩大排除范围、降低规则级别或新增 baseline 消除设计系统失败。

## 专项 Skill 边界

- 使用 `swiftui-expert-skill` 处理 SwiftUI API、状态管理、并发、性能、可访问性实现和现代化重构。
- 使用 `ios-motion-design` 处理手势物理、转场、spring、matched geometry、keyframe、Lottie、触感、可中断性和 Reduce Motion。
- 涉及 Apple API、可用性、参数语义、弃用、系统行为或 Liquid Glass 平台事实时，按仓库要求使用 `apple-doc-mcp`；工具不可用时只陈述本地事实，不凭记忆补造平台结论。

完整 UI 改造按实际范围组合 Skill，但设计语言与公共能力准入始终由本 Skill 决定。
