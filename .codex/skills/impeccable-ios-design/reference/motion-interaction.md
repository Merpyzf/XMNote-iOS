# Motion And Interaction Boundary

## 目标

在全局设计层判断“是否需要运动”和“是否提供了正确反馈”，把运动参数与实现交给专项 owner。

## 职责边界

| 问题 | Owner |
| --- | --- |
| 动效是否服务信息层级、状态反馈与平台表达 | `impeccable-ios-design` |
| 手势、转场、spring、matched geometry、keyframe、Lottie、触感、时长、可中断性与 Reduce Motion | `ios-motion-design` |
| SwiftUI API、状态数据流、性能、并发与可访问性实现 | `swiftui-expert-skill` |

## 全局设计规则

- 只为结构变化、空间关系、状态反馈、操作结果或避免突兀跳变添加运动。
- 不用弹跳、旋转、模糊、阴影或多阶段编排弥补信息层级问题。
- 系统控件已有合适反馈时，不叠加重复缩放、弹跳或装饰性触感。
- 优先使用 `Button`、`Toggle`、`NavigationLink` 等原生语义控件，不用手势模拟普通按钮。
- 触控界面的功能不得依赖 hover 才能发现。

## 异步反馈

- 读取类加载遵循仓库“延迟显示 + 最短驻留”策略，生产页面使用 `LoadingGate + LoadingStateView` 或 `LoadPhaseHost`，不新增裸 `ProgressView` 作为读取主态。
- 写操作立即提供可感知反馈并禁用重复触发入口，不等待网络或数据库完成后才响应。
- 成功优先通过内容、按钮或导航状态变化表达；不要默认新增“已完成”“已更新”类提示。
- 失败、不可执行或需要用户决策时提供可感知反馈，并保留重试、回滚或解释路径。
- 不要求每个操作机械具备 loading、disabled、error、success 四个独立视觉组件；按读写类型与真实状态语义设计。

问题一旦进入运动语义、物理、时序、触感或验收，立即使用 `ios-motion-design`；不在本文件维护具体 curve、duration 或手势参数。
