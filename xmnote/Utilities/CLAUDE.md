# Utilities/
> L2 | 父级: /CLAUDE.md

## 成员清单

- `DesignSystem/AppTypography.swift`: 生产排版唯一入口与图表等跨组件组合排版 token；页面优先使用 `AppTypography` 或已登记的组合 token。
- `DesignSystem/SharedContentTypography.swift`: 书架、书摘、阅读日历与时间线等已证明跨组件复用的排版组合。
- `DesignSystem/SemanticColors.swift`: Brand、Surface、Text、Icon、Border、Action、Selection、Status、Feedback 与阅读日历颜色语义。
- `DesignSystem/ColorConstruction.swift`: `Color`/`UIColor` 的集中式 hex、sRGB、浅深色和桥接构造入口；页面与业务组件禁止自行复制构造器。
- `DesignSystem/Spacing.swift`: 通用间距阶梯与屏幕/内容边距；单页特殊几何保留为页面级语义常量。
- `DesignSystem/CornerRadius.swift`: inlay、block、container 三层圆角语义；标准领域标签复用 4pt、内容卡片复用 12pt、设置分组使用 24pt，并统一保留 continuous 轮廓。
- `DesignSystem/InteractionMetrics.swift`: 交互尺寸语义，`minimumTouchTarget` 是 44pt 热区的唯一 owner。
- `SemanticTypography.swift` / `BrandTypography.swift`: 底层动态字体与品牌字体基础设施，不是页面层默认入口。

设计系统架构与 AI 执行入口见 `docs/architecture/iOS设计系统工程规范.md`；修改生产 UI 前先运行 `python3 scripts/design-system/ds.py context --paths <路径>`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
