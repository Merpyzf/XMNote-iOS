# ReadingHeatmapWidgetView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Reading/ReadingHeatmapWidgetView.swift`
- 角色：在读首页顶部核心卡片，承接阅读热力图展示、帮助入口与跳转阅读日历的主交互。
- 边界：组件内部只负责热力图加载与展示，不承接首页趋势、目标、继续阅读等其他首页业务。

## 快速接入
```swift
ReadingHeatmapWidgetView { date in
    path.append(.readCalendar(date))
}
```

## 参数说明
- `onOpenReadCalendar: (Date) -> Void`
  - 作用：用户点击热力图某一天时，把对应日期交给上层路由。
  - 调用时机：热力图方格点击后立即触发。

## 依赖关系
- 通过 `@Environment(RepositoryContainer.self)` 读取 `statisticsRepository`。
- 内部使用 `ReadingHeatmapWidgetViewModel` 管理加载态、错误态与跨天刷新。
- 复用 `HeatmapChart` 作为核心图表组件。
- 依赖 `HeatmapHelpSheetView` 展示说明弹层。

## 当前视觉与交互约束
- 外层使用 `CardContainer(cornerRadius: CornerRadius.containerLarge, showsBorder: false)`，与在读首页主卡视觉保持一致。
- 卡内统一使用 `Spacing.base` 作为图表内容边距。
- 右上角帮助入口采用 `24pt` 视觉尺寸 + `32pt` 命中区，避免小图标误触。
- 加载态使用卡内居中 `ProgressView`，错误态使用底部内联“错误文案 + 重试”组合，不弹系统级中断提示。
- 页面回到前台时，若跨天则自动刷新，保证“今天”热力图语义正确。

## 状态说明
- `isLoading = true`
  - 展示中心加载指示器。
- `errorMessage != nil`
  - 在热力图底部展示错误提示和“重试”按钮。
- 正常态
  - 渲染 `HeatmapChart`，支持点击日期进入阅读日历。

## 示例
- 示例 1：在 `ReadingDashboardView` 顶部作为首页热力图概览入口。
- 示例 2：在任何需要“热力图概览 + 跳转阅读日历”语义的页面壳层中，通过路由闭包承接日期点击。

## 接入建议
- 建议只在在读首页或其他需要“概览 + 导航”语义的壳层使用。
- 若只需要纯图表渲染能力，应直接使用 `HeatmapChart`，不要复用这个带数据访问和业务弹层的组件。
- 若页面已有外层滚动容器，保持本组件高度自适应，不要额外再包固定高容器。

## 常见问题
### 1) 是否应该抽到 `UIComponents`？
不应该。该组件直接依赖 Repository 与业务说明弹层，属于在读首页核心业务组件，不满足跨模块纯展示复用条件。

### 2) 为什么组件内部可以直接发起加载？
这里是页面核心组件，不是纯展示子视图。它通过 `RepositoryContainer` 读取仓储并委托给 ViewModel 管理，仍然满足“数据访问经 Repository”这一架构约束。

### 3) 如果要替换热力图样式，应该改哪里？
先看 `HeatmapChart` 的 `style` 能否满足；如果是首页专属边距、帮助按钮或错误态样式，再改 `ReadingHeatmapWidgetView`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
