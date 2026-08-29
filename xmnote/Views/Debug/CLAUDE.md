# Debug/
> L2 | 父级: Views/CLAUDE.md

调试与验证专用视图集合，仅在开发期用于组件/算法验证，不进入正式业务导航主路径。

## 成员清单

- `DebugCenterView.swift`: 调试中心入口，聚合测试页面跳转
- `HeatmapTestView.swift`: 热力图组件可视化调试页面
- `ImageLoadingTestView.swift`: 图片加载测试页面（静态图/GIF/失败链路与缓存来源观测）
- `ReadCalendarCoverStackTestView.swift`: 阅读日历封面堆栈可视化调试页面
- `NoteReviewPagingTestView.swift`: 书摘回顾分页卡组可视化调试页面
- `RichTextTestView.swift`: 富文本编辑器调试页面
- `SheetCatalogTestView.swift`: 生产 Sheet 目录与隔离验收入口，常驻提供真实目标打开操作并对照实现详情展开方式
- `SheetProductionValidationTestView.swift`: 生产 Sheet 目标的独立调试宿主，承载隔离快照与真实呈现配置验证
- `StatePresentationTestView.swift`: 通用状态组件全量视觉、环境覆盖与阶段切换验收页
- `SystemColorsTestView.swift`: 系统语义色与自定义语义色调试页面

## 子目录

- `Prototypes/`: 交互/视觉原型组件目录（仅调试演示，不进入业务路径）

说明
- Debug 相关 ViewModel 已统一迁移至 `xmnote/ViewModels/Debug/`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
