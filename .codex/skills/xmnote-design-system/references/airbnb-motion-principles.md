# Airbnb Product Motion Lens for SwiftUI

## 定位

Airbnb 在本专题中只提供产品动效视角：对话感、上下文保持、轻量产品个性和规模化复用。Apple 官方设计与系统行为负责平台底线，XMNote 已有生产页面、组件和交互习惯负责本地事实。

不要复制 Airbnb 的视觉表面，也不要把旧文章中的 UIKit 基建直接等同于现代 SwiftUI 实现。

## 公开来源

- Airbnb DLS 使用 `Unified`、`Universal`、`Iconic` 与 `Conversational` 描述设计语言。动效应成为产品沟通的一部分，而不是装饰。来源：[Building a Visual Language](https://medium.com/airbnb-design/building-a-visual-language-behind-the-scenes-of-our-airbnb-design-system-224748775e4e)、[Airbnb Design Principles](https://principles.design/examples/airbnb-design-principles)
- Airbnb 工程文章把动效视为可跨团队复用的产品系统，用转场保持上下文，用少量动画建立产品个性。来源：[Motion Engineering at Scale](https://medium.com/airbnb-engineering/motion-engineering-at-scale-5ffabfc878)
- Host Passport iOS 案例展示了复杂动效需要分别协调位置、缩放、旋转、阴影、内容和深度。来源：[Bringing the Host Passport to life on iOS](https://medium.com/airbnb-engineering/animations-bringing-the-host-passport-to-life-on-ios-72856aea68a7)
- Lottie 用于减少复杂品牌资产从设计到工程的损失。来源：[Introducing Lottie](https://www.engineering.fyi/article/introducing-lottie)、[Lottie iOS](https://airbnb.io/projects/lottie-ios/)

## 产品动效原则

### Conversational Motion

让动画像对用户动作的简短回答：“已选择”“已展开”“已移动”“现在是主状态”。先写出动效要表达的句子，再选择最小实现。

### Context Preservation

让用户能追踪同一个对象从列表到详情、从卡片到展开态、从搜索框到搜索界面。优先稳定业务 ID 和对象连续性，不用无关联淡变替代应当保持的空间关系。

### Effortless Timing

让运动及时响应，用户再次操作时能够接续。柔和感来自协调的属性时序和干净落点，不来自漫长尾巴或处处弹跳。同步是配合整体过程，不要求所有属性同起同止：Host Passport 案例分别设置属性曲线和关键帧时机，并调校转场结束时临时表现与目标视图的交接，避免最后一刻跳位。

### Dimensional but Restrained

阴影、模糊、旋转和深度应服务真实空间层级或对象角色变化；低幅缩放也可表达直接操作反馈，并遵守系统反馈不重复叠加的边界。普通状态切换优先使用更少属性完成表达。

### Motion as a Product System

重复出现的运动沉淀为有业务语义的 animation、transition、motion spec 或 view modifier。使用 `selectionFeedback`、`cardExpansion`、`panelReveal` 这类意图命名，不用曲线参数充当语义。

### Small Product Voice

更丰富的品牌编排优先留给低频、非阻塞的时刻。生产力路径、高频选择和导航优先清晰与速度，也允许短促、低幅的操作确认和响应质感；不因静态信息仍清楚就自动删除有价值的反馈。具体取舍沿用 [动效专题](motion.md) 的价值判断与系统反馈边界。

## SwiftUI 落地映射

| UI 时刻 | 产品意图 | SwiftUI 工具 | 约束 |
| --- | --- | --- | --- |
| 按钮、chip、row 选择 | 简短确认 | 局部 `snappy`、前景或轻微 scale 变化 | 不延迟反馈，不带动父布局 |
| 列表项到详情 | 保持对象身份与导航关系 | 保留合适的系统转场；需要来源缩放时评估 `matchedTransitionSource` + `navigationTransition(.zoom)` | 核对来源 ID、呈现方式、返回和取消；不把 `matchedGeometryEffect` 当通用导航转场 |
| 同一视图树内卡片展开/收起 | 同一对象改变角色 | `matchedGeometryEffect`、局部 transition | 同一语义对象、共享 namespace；不让无关兄弟视图被宽泛动画带动 |
| 搜索框到搜索界面 | 延续输入对象 | field/background 连续性、建议区分阶段出现 | 键盘与焦点优先，动画不得延迟输入 |
| sheet 或 panel | 解释层级 | 系统 presentation 优先，必要时局部 move/opacity | 不覆盖系统已有转场物理 |
| 数值或文本变化 | 说明值已改变 | `contentTransition` 或短淡变 | 高频计时或滚动值不默认逐次动画 |
| 完成或空状态 | 少量产品个性 | 非阻塞 Lottie 或符号动效 | 提供静态表达，不阻塞下一步 |
| 复杂卡片编排 | 协调多属性职责 | `keyframeAnimator`、`PhaseAnimator` | 分离时序并检查中断与 Reduce Motion |

本表是场景候选，不是逐项套用的 API 清单；选择边界、复杂交互的最小编排说明和运行验收统一遵循 [动效专题](motion.md)。时序精度来自本次主体与陪衬的配合，不要求复刻 Host Passport 的三维结构或建设同类框架。

## Lottie 边界

- 允许：品牌插画、空状态、非阻塞完成时刻、图标级资产。
- 禁止：核心导航、信息架构转场、必须保持 live SwiftUI 对象身份的结构变化。
- 必须提供静态或低运动量替代，且动画不能阻止用户继续操作。

## 公开事实与 SwiftUI 推断

- 可以归因于 Airbnb：对话式设计、上下文保持、规模化动效系统、Lottie 的设计到工程协作价值，以及精细的 iOS 属性编排。
- 将这些原则映射到 `matchedGeometryEffect`、`matchedTransitionSource`、`navigationTransition`、`keyframeAnimator`、`PhaseAnimator` 和 `contentTransition` 属于 XMNote 的实现推断；平台能力依据见动效专题中的 Apple 文档。
- 除非来源明确说明，不宣称 Airbnb 使用某个具体 SwiftUI API。
