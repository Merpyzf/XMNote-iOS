---
name: impeccable-ios-design
description: 为 XMNote 的 iOS/SwiftUI 界面提供经过 Apple HIG、Liquid Glass 官方规则与 swiftui-expert-skill 校准的设计判断与优化约束。适用于 UI 方案、界面评审、视觉微调与交互抛光。
license: Apache 2.0. Derived from pbakaus/impeccable frontend-design and adapted for XMNote iOS.
---

这个 skill 用来把 `impeccable` 的审美判断力改造成适合 XMNote 的 iOS 设计能力。
目标不是做 Web 风格翻译，而是在 Apple 原生表达内，做出不平庸、可上线、避免 AI 味的 SwiftUI 界面。

## 优先级

发生冲突时，按以下顺序决策：

1. 当前仓库 `AGENTS.md` / `CLAUDE.md` / 现有设计令牌与组件边界
2. Apple HIG 与系统组件默认行为
3. `swiftui-expert-skill`
4. 上游 `impeccable` 的风格建议

## 工作方式

1. 先读目标页面、已有组件、设计令牌与同模块实现，不凭空发明模式。
2. 先判断问题属于哪类：信息层级、视觉亲密性、交互反馈、组件归位、平台表达偏差、还是 Liquid Glass 误用。
3. 优先做系统性修正：token、布局语义、公共样式、组件结构；避免一次性补丁。
4. 涉及 Apple API 行为、平台可用性或 Liquid Glass 语义时，必须优先参考 Apple 官方文档或 `apple-doc-mcp`，不要凭记忆下结论。
5. 视觉结论需要同时满足三点：业务意图正确、iOS 原生、细节不平庸。

## 核心约束

### Typography & Copy
→ 先读 `reference/typography-and-copy.md`

- 允许使用系统字体族作为正文与交互字体；不要机械套用 Web 里“禁用系统字体”的规则。
- 品牌字体只用于标题、关键数字、品牌强调位；前提是中文可读性和系统一致性不被破坏。
- 文案必须更短、更准，避免重复用户已经看到的信息。
- 标题、数值、说明文本要形成明显层级；相关信息要靠近，避免“视觉上断开”。

### Color & Materials
→ 先读 `reference/color-materials.md`

- 一切新增颜色优先落到语义 token，不允许为单页效果硬编码随机色。
- 不要靠紫蓝渐变、霓虹发光、过度阴影制造“高级感”。
- 不要把灰字直接放在彩色底上；若必须压在彩色/材质上，使用语义前景色或该底色系的高对比变体。
- 优先让内容本身可读，再考虑装饰。

### Layout & Hierarchy
→ 先读 `reference/layout-hierarchy.md`

- 避免卡片套卡片；同一张卡片内优先用留白、分割线、字重和层级组织信息。
- 不要复用“AI 模板式指标卡”：大数字、小标题、装饰渐变、无意义小图表。
- 视图必须上下文无关，适配不同容器、安全区、动态字体和尺寸等级。
- 触控目标默认至少 44pt；相关元素遵守亲密性原则，次级说明贴近主值或主操作。

### Motion & Interaction
→ 先读 `reference/motion-interaction.md`

- 动效只服务结构变化、状态反馈和层级过渡，不做炫技装饰。
- 默认优先 `.snappy`、`.smooth`、`.spring` 等 SwiftUI 原生语义；减少自定义夸张曲线。
- 异步操作必须立刻反馈：禁用、加载、错误、完成态缺一不可。
- 交互元素优先 `Button`，不要用手势凑按钮语义。

### Liquid Glass
→ 先读 `reference/liquid-glass.md`

- Liquid Glass 只用于功能层和导航层，不能铺到内容层主体。
- 优先标准系统组件自动获得玻璃效果，其次才是自定义 `glassEffect`。
- 多个玻璃元素必须考虑 `GlassEffectContainer`。
- `.interactive()` 仅用于真实交互元素。

## 反模式

- Android 视觉直译到 iOS
- 为了“有设计感”强上玻璃、渐变、阴影、荧光描边
- 同一页面处处都是同构卡片、同构间距、同构标题结构
- 把信息层级问题误判成配色问题
- 用装饰性小图表假装数据表达
- 为了显眼让所有按钮都变成主按钮
- 为了独特而破坏 iOS 可预测性

## 与现有 skill 的分工

- `impeccable-ios-design` 负责：审美判断、层级组织、平台表达、细节抛光
- `swiftui-expert-skill` 负责：SwiftUI API 正确性、状态管理、性能、可访问性、Liquid Glass 代码用法

需要动手改 SwiftUI 代码时，两个 skill 一起使用。
