# ReadingDashboardView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Reading/ReadingDashboardView.swift`
- 角色：在读首页真实内容壳层，负责把热力图、趋势总卡、今日阅读、继续阅读、最近在读和年度摘要拼装成完整首页。
- 边界：组件负责首页状态编排与页面级弹层承接，不负责底部 Tab 容器切换，也不直接处理具体导航实现。

## 快速接入
```swift
ReadingDashboardView(
    onAddBook: { path.append(.bookSearch) },
    onOpenReadCalendar: { date in path.append(.readCalendar(date)) },
    onOpenBookDetail: { bookID in path.append(.bookDetail(bookID)) }
)
```

## 参数说明
- `onAddBook: () -> Void`
  - 作用：继续阅读为空时，引导用户进入添加书籍流程。
- `onOpenReadCalendar: (Date) -> Void`
  - 作用：承接热力图点击后的阅读日历跳转。
- `onOpenBookDetail: (Int64) -> Void`
  - 作用：承接继续阅读、最近在读、年度已读列表等书籍详情跳转。

## 依赖关系
- 通过 `@Environment(RepositoryContainer.self)` 读取 `readingDashboardRepository`。
- 内部创建并持有 `ReadingDashboardViewModel`，消费首页 observation。
- 复用 `ReadingHeatmapWidgetView`、`ReadingTrendMetricsSection`、`ReadingFeatureCardsSection`、`ReadingRecentBooksCard`、`ReadingYearSummaryCard`。
- 复用 `ReadingGoalEditorSheet` 与 `ReadingYearSummarySheet` 承接业务弹层。

## 页面结构
1. 顶部 `ReadingHeatmapWidgetView`
2. 错误态 `ReadingDashboardInlineBanner`
3. `ReadingTrendMetricsSection` 三栏趋势总卡
4. `ReadingFeatureCardsSection` 双功能卡（今日阅读 / 继续阅读）
5. `ReadingRecentBooksCard` 横向书籍列表
6. `ReadingYearSummaryCard` 年度摘要入口

## 状态与交互说明
- 首次进入时在 `.task` 内延迟创建 ViewModel，避免直接在 `init` 访问环境对象。
- 页面回到前台时，如发生跨天，会调用 `refreshIfNeeded()` 重建 observation，保证“今日/今年”语义正确。
- 今日目标和年度目标都通过同一个 `ReadingGoalEditorSheet` 编辑，避免表单逻辑重复。
- 年度摘要通过 `ReadingYearSummarySheet` 展开完整已读列表。

## 视觉约束
- 主滚动区横向使用 `Spacing.screenEdge`，顶部使用 `Spacing.half`，底部使用 `Spacing.section`。
- 趋势区为单卡三分栏；分栏之间不使用额外 gap，而是用竖向留白后的分割线分隔。
- 今日阅读与继续阅读卡保持统一卡片比例和卡内边距语义，由 `ReadingFeatureCardsStyle` 统一控制。

## 示例
- 示例 1：作为 `ReadingContainerView` 的首页子页，承接在读主流程。
- 示例 2：在预览或调试环境中通过注入 `RepositoryContainer` 直接查看首页卡片组合效果。

## 接入建议
- 该组件应作为 `ReadingContainerView` 的首页子页使用，不建议在其他功能页直接复用。
- 如果只是复用单张卡片，应下沉到 `xmnote/Views/Reading/Components/ReadingDashboardCards.swift` 对应页面私有子视图，而不是整体复用页面壳层。
- 若要修改首页统计口径，应优先调整 `ReadingDashboardRepository` 和 `ReadingDashboardFormatting`，不要在视图层二次拼装数据。

## 常见问题
### 1) 为什么 ViewModel 不是在 `init` 里创建？
因为首页依赖 `RepositoryContainer` 的环境注入，SwiftUI 在 `init` 阶段还拿不到环境对象。当前做法是在 `.task` 里延迟创建，符合 SwiftUI 生命周期约束。

### 2) 首页卡片能否迁到 `UIComponents`？
不能。`ReadingDashboardView` 及其子卡片绑定在读首页业务语义和仓储口径，属于页面壳层/页面私有组件，不属于跨模块纯展示组件。

### 3) 如果要增加新的首页指标，优先改哪里？
先改 `ReadingDashboardRepository` 的聚合结果和 `ReadingDashboardModels`，再补 `ReadingDashboardFormatting` 与页面私有卡片渲染，最后更新术语表和 feature 文档。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
