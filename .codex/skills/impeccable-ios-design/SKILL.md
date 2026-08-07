---
name: impeccable-ios-design
description: 为 XMNote 的 iOS/SwiftUI 界面提供经过 Apple HIG、Liquid Glass 官方规则与本地设计系统校准的全局设计判断。适用于 UI 方案、界面评审、信息层级、字体、颜色、材质、布局、文案与平台表达；复杂手势、转场或动画专项任务需配合 ios-motion-design。
---

# Impeccable iOS Design

把 `impeccable` 的审美判断转化为适合 XMNote 的 iOS 设计能力。目标不是翻译 Web 风格，也不是追求表面独特，而是在 Apple 原生表达内做出有业务语义、克制、可上线且不模板化的 SwiftUI 界面。

## 决策优先级

发生冲突时，按以下顺序决策：

1. 用户当次明确要求。
2. 当前仓库 `AGENTS.md`。
3. XMNote 已有生产页面、导航模式、设计令牌与公共组件。
4. 经 Apple 官方资料确认的平台事实。
5. 本 skill 与上游来源提供的审美启发。

不要让局部审美偏好覆盖仓库治理、生产设计真相或平台事实。

## 先完成事实闭环

1. 明确任务范围、目标用户动作和可用证据。视觉问题优先检查截图、预览或实际渲染上下文；代码只能证明结构与实现事实。
2. 读取目标页面、同模块生产页面、现有令牌与组件，确认当前设计真相源。
3. 涉及行为、状态或根因判断时，找到真实状态 owner、写入点、触发动作与生命周期时机。
4. 区分已证实问题与待验证风险。代码无法证明的颜色观感、密度或层级结论，明确标记“视觉风险，需截图验证”。
5. 涉及 Apple API、可用性、参数语义、系统行为或 Liquid Glass 时，必须按仓库流程使用 `apple-doc-mcp` 查证；工具不可用时停止平台结论，不用记忆或第三方资料补造事实。

单点现象默认局部修正。只有至少两个独立场景被证明具有相同根因和相同修复模式时，才建议新增全局 token、公共样式、组件或基础设施。

## 评审与方案流程

执行界面评审、抛光或优化方案时，先读取 `reference/design-review-workflow.md`，按固定证据与优先级契约输出。默认给出最小可验证修正，不用主观分数制造确定性。

根据问题范围按需读取：

- 字体、文字层级或文案：`reference/typography-and-copy.md`
- 颜色、对比度或材质：`reference/color-materials.md`
- 布局、容器或信息层级：`reference/layout-hierarchy.md`
- 动效是否必要、异步反馈或交互语义：`reference/motion-interaction.md`
- Liquid Glass：`reference/liquid-glass.md`

## 核心判断

### Typography & Copy

- 服从 `AppTypography` 和页面级组合 token；系统字体与系统排版默认不是“AI 味”。
- 不强制衬线字体、固定字号数量或所谓“标志性字体”。品牌字体只在仓库已有规则允许的高价值焦点位使用。
- 让标题、数值、说明和操作形成明确层级；缩短重复、空泛或已被界面表达的文案。

### Color & Materials

- 优先复用现有语义色、surface 与材质；不要为单点效果硬编码随机色，也不要无证据创建全局 token。
- 不默认添加紫蓝渐变、霓虹发光、重阴影或多层半透明来制造“高级感”。
- 只有在具体上下文中破坏语义、可读性或层级时，才把某种颜色或材质组合判为模板化。
- 上下文菜单、长按菜单与更多菜单的普通操作使用系统默认色或项目菜单中性色；品牌色不承担“可点击”提示，只有删除、警告等明确语义操作使用对应语义色。

### Layout & Hierarchy

- 优先用亲密性、留白、对齐、字重、尺寸和分隔关系组织信息，避免卡片套卡片和机械同构的指标块。
- 覆盖项目实际支持的 iPhone/iPad、横竖屏、Dynamic Type、安全区与不同容器宽度。
- 触控目标默认至少 44pt；视觉尺寸可以更小，但交互热区不能随之缩小。

### Motion & Interaction

- 在本 skill 中只判断运动是否服务结构变化、空间关系、状态反馈或操作结果。
- 读取加载遵循仓库 LoadingGate 分级；写入立即反馈并禁用重复触发；成功优先由界面状态变化表达，不强制成功提示。
- 失败、不可执行或需要决策时提供可感知反馈。交互元素优先使用 `Button` 等原生语义控件。
- 涉及手势、转场、spring、matched geometry、keyframe、Lottie、触感、时长、可中断性或 Reduce Motion 时，使用 `ios-motion-design`。

### Liquid Glass

- 只在功能层与导航层评估玻璃，不把内容主体包装成玻璃卡片。
- 优先保留标准系统组件自动提供的外观；系统导航栏中的按钮禁止重复添加 glass/material 包装。
- 自定义 `glassEffect`、`GlassEffectContainer`、`.interactive()` 或相关 API 前先用 `apple-doc-mcp` 验证当前平台语义。

## 反模板化边界

系统默认不等于 AI 味。只批评缺少业务语义的机械重复、破坏层级的默认组合，或为了显得“有设计感”而添加的玻璃、渐变、阴影、霓虹、装饰图表和弹跳。不要为了独特而破坏 iOS 可预测性，也不要把 Android 视觉直接翻译到 iOS。

## 与其他 skill 的分工

- `impeccable-ios-design`：信息层级、字体、颜色、材质、布局、文案与平台表达。
- `ios-motion-design`：运动原因、手势物理、时序、触感、可中断性、Reduce Motion 与验收。
- `swiftui-expert-skill`：SwiftUI API、状态管理、性能、并发、可访问性与代码实现。

完整 UI 改造按实际范围组合使用；不要让任一 skill 越权替代其他 owner。
