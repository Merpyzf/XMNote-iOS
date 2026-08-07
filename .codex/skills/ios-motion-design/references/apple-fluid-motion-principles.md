# Apple Fluid Motion Principles for XMNote

## 定位与事实来源

本参考把 Apple 官方动效设计原则转成 XMNote 的评审语言，不替代 Apple API 文档，也不提供未经验证的平台行为断言。

官方事实来源：

- [Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Designing Fluid Interfaces, WWDC 2018](https://developer.apple.com/videos/play/wwdc2018/803/)
- [Animate with springs, WWDC 2023](https://developer.apple.com/videos/play/wwdc2023/10158/)
- [Principles of great design, WWDC 2026](https://developer.apple.com/videos/play/wwdc2026/250/)

涉及 API 可用性、参数语义、弃用或平台差异时，必须回到 `apple-doc-mcp`。本参考只能帮助提出正确问题，不能代替平台查证。

## 原生动效判断

### Response

- 让界面在交互开始时立即承认输入。
- 把异步等待表达为明确状态，不让动画延迟实际提交或下一次输入。
- 把响应性视为正确性，而不是最后追加的视觉抛光。

### Direct Manipulation

- 让触点、手势位移与内容变化保持连续关系。
- 保留用户从哪里抓取对象的相对关系，避免拖拽开始时发生视觉跳跃。
- 在交互进行中持续提供反馈，不只在结束时播放结果动画。

### Interruptibility

- 允许用户在动画尚未结束时重复操作、返回、取消或反向。
- 从当前屏幕上可见的状态继续变化，不从已经过期的目标状态重新开始。
- 把中断测试作为手势和高频交互的验收条件，而不是实现细节。

### Velocity Continuity and Projection

- 手势结束后延续用户已经赋予对象的运动趋势，避免落位前出现突兀减速或方向断裂。
- 选择落点时综合当前位置、方向和速度；只有业务确实需要自定义物理时才设计投影算法。
- 不把演讲示例或其他平台实现中的公式、阈值直接固化为 XMNote 规则。

### Soft Boundaries

- 到达边界时优先使用系统滚动与手势行为。
- 必须自定义时，使用逐渐增强的阻力而不是突然冻结。
- 边界反馈只解释限制，不制造额外可操作状态。

### Spatial Consistency

- 进入与退出沿相同空间关系运动。
- 浮层、展开态和共享对象保持与触发源的可理解关系。
- 使用方向、层级和对象身份帮助用户回答“它从哪里来、现在在哪里、如何回去”。

### Multimodal Feedback

- 让视觉、触感和声音指向同一个因果事件。
- 只为重要确认、错误、提交或物理 snap 使用额外感官反馈。
- 不依赖单一感官传递关键信息，也不通过密集触感制造“高级感”。

### Reduce Motion

- 运动不能成为传递重要状态的唯一方式。
- 开启 Reduce Motion 时，降低自动运动、重复运动、缩放、弹性、深度变化、动画模糊和大范围位移。
- 使用淡入淡出、即时层级变化、文本、图标或状态色保留信息。
- 直接跟随手势、且能帮助理解因果的反馈可以保留，但要去掉非必要惯性和装饰。

## Apple 设计原则在 Motion 中的落点

- **Purpose**：每段运动都必须有业务或理解价值。
- **Agency**：运动不得夺走取消、返回、重复操作和恢复的控制权。
- **Familiarity**：优先遵循系统组件与既有导航、手势和物理预期。
- **Craft**：检查落点、速度接缝、中断、性能和无障碍细节。
- **Delight**：把愉悦感视为正确响应、清晰关系和细节一致的结果，不在末尾追加装饰。

字体、颜色、材质、整体信息层级与 Liquid Glass 归 `impeccable-ios-design`；SwiftUI API 与性能事实归 `swiftui-expert-skill`。

## 上游启发与迁移边界

本参考受 `emilkowalski/skills` 仓库提交 [`f736679`](https://github.com/emilkowalski/skills/commit/f736679c420f34e5a63d2dfdc74db35520d75a7b) 中 `apple-design` 的主题组织启发，但内容按 Apple 官方来源和 XMNote 约束重新编写，没有复制原文。

不迁移任何面向 Web 平台的样式表、浏览器输入事件、动画库、DOM 组件库、浏览器调试工具、曲线或滤镜实现。也不把 Web 性能经验改写成 SwiftUI 性能定律。
