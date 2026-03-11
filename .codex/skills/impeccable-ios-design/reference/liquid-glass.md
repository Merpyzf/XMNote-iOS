# Liquid Glass

## 设计定位

Liquid Glass 属于功能层和导航层，不属于内容层主体。
它的职责是让控件浮在内容之上而不压死内容，不是给所有卡片换一个“高级皮肤”。

## 默认策略

- 优先让系统组件自动获得 Liquid Glass 外观。
- 只有在标准组件不够表达时，才对自定义控件使用 `glassEffect`。
- 默认使用 `regular`；只有背景是照片、视频、地图等视觉富内容时才考虑 `clear`。
- `clear` 方案必须检查前景可读性，必要时补 dimming layer。
- 多个玻璃元素同时出现时，优先放进 `GlassEffectContainer`，并让容器 spacing 与真实布局 spacing 一致。
- `.interactive()` 只给真实交互元素。

## 允许场景

- 浮层操作按钮
- 顶部/底部功能条中的关键控件
- 内容之上的瞬时功能控件
- 需要与系统玻璃控件同层表达的局部操作区

## 禁止场景

- 阅读正文容器
- 普通数据卡、列表卡、信息面板主体
- 为了装饰把整屏主要内容都做成玻璃
- 玻璃里再叠玻璃但没有容器组织

## 实现提醒

- 修改器顺序上，先布局和视觉，再 `.glassEffect(...)`
- 涉及 morphing 时，使用 `glassEffectID(_:in:)`
- 设计判断与 API 用法一起出现时，同时参考 Apple 文档和 `swiftui-expert-skill`
