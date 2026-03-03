# Debug/
> L2 | 父级: Views/CLAUDE.md

调试与验证专用视图集合，仅在开发期用于组件/算法验证，不进入正式业务导航主路径。

## 成员清单

- `DebugCenterView.swift`: 调试中心入口，聚合测试页面跳转
- `HeatmapTestView.swift`: 热力图组件可视化调试页面
- `HeatmapTestViewModel.swift`: 热力图测试数据与状态编排
- `ImageLoadingTestView.swift`: 图片加载测试页面（静态图/GIF/失败链路与缓存来源观测）
- `ImageLoadingTestViewModel.swift`: 图片加载测试状态编排（批量样例、手动 URL、缓存来源统计）
- `RichTextTestView.swift`: 富文本编辑器调试页面
- `RichTextTestViewModel.swift`: 富文本测试数据与交互状态编排

## 子目录

- `Prototypes/`: 交互/视觉原型组件目录（仅调试演示，不进入业务路径）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
