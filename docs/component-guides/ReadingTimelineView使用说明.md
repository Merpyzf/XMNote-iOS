# ReadingTimelineView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Reading/Timeline/ReadingTimelineView.swift`
- 角色：在读模块的正式时间线页面壳层，承接日历浏览、分类过滤、按日时间线列表与粘性日期头。
- 边界：
  - 负责承接外部注入的 `TimelineViewModel`，并根据状态源是否就绪决定展示静态壳层还是正式内容。
  - 不负责 item 级跳转、复制、删除、TTS 等业务动作。
  - 不负责 warmup 调度与 ViewModel 生命周期创建。

## 快速接入
```swift
ReadingTimelineView(
    viewModel: timelineViewModel,
    onOpenContentViewer: onOpenContentViewer,
    onOpenBookDetail: onOpenBookDetail
)
```

推荐由外层容器先创建并持有 `TimelineViewModel`：

```swift
@Environment(RepositoryContainer.self) private var repositories
@State private var timelineViewModel: TimelineViewModel?

.task {
    guard timelineViewModel == nil else { return }
    timelineViewModel = TimelineViewModel(repository: repositories.timelineRepository)
}
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `viewModel` | `TimelineViewModel?` | `nil` | 时间线状态源。为 `nil` 时展示首开静态壳层；有值时进入正式内容树。 |
| `onOpenContentViewer` | `(ContentViewerSourceContext, ContentViewerItemID) -> Void` | 空实现 | 事件点击后上抛到内容查看页。 |
| `onOpenBookDetail` | `(Int64) -> Void` | 空实现 | 书籍类事件点击后上抛到书籍工作台。 |

## 示例

### 示例 1：在在读容器中作为正式子页接入
```swift
@ViewBuilder
private func segmentedPage(for tab: ReadingSubTab) -> some View {
    switch tab {
    case .reading:
        ReadingDashboardView(
            onAddBook: onAddBook,
            onOpenReadCalendar: onOpenReadCalendar,
            onOpenBookDetail: onOpenBookDetail,
            onStartReading: onStartReading,
            readingTimerZoomConfigurationFactory: readingTimerZoomConfigurationFactory
        )
    case .timeline:
        ReadingTimelineView(
            viewModel: timelineViewModel,
            onOpenContentViewer: onOpenContentViewer,
            onOpenBookDetail: onOpenBookDetail
        )
    case .statistics:
        XMContentStateView(
            role: .instruction,
            title: "统计功能暂未开放",
            systemImage: "chart.bar"
        )
    }
}
```

### 示例 2：独立预览时间线页面
```swift
#Preview {
    let repositories = RepositoryContainer(databaseManager: .sharedPreview)

    NavigationStack {
        ReadingTimelineView(
            viewModel: TimelineViewModel(repository: repositories.timelineRepository)
        )
    }
}
```

## 状态边界

- 首次状态源尚未注入或仍在首读时，使用 `ReadingTimelineBootstrapShellView` 与列表占位保持日历、筛选和列表几何稳定，不把加载误呈现为空数据。
- 首次读取失败且没有可用时间线内容时，列表区域使用 `XMCompactStateView(role: .failure)`，标题为“暂时无法加载时间线”，并提供纯文字“重试”。
- 首读完成后，当选中日期与分类没有匹配事件时，列表区域使用 `XMCompactStateView(role: .noResults)`，标题为“当日没有匹配事件”。
- 已有内容仍可信但日期、分类或外部写入后的刷新失败时，保留当前时间线并使用 `XMInlineStatusBanner` 提供纯文字“重试”；不得用页面级失败替换已有内容。
- “统计”页属于尚未开放的功能说明，使用中性 `.instruction` 与“统计功能暂未开放”，不伪装成数据为空。

## 常见问题

### 1. 为什么 `ReadingTimelineView` 现在改成接收 `TimelineViewModel?`
因为时间线的 warmup、生命周期和首开状态机都需要由容器统一协调。若页面自己创建 ViewModel，就无法和 `ReadingContainerView` 上的预热调度、二级页保活建立一致边界。

### 2. `viewModel == nil` 为什么不是直接空白
`nil` 代表容器尚未完成状态注入，这时页面会展示 `ReadingTimelineBootstrapShellView`。这样即便 warmup 未命中，用户也会先看到稳定结构，而不是空白页或碎裂中的半成品页面。

### 3. 为什么列表要用 `LazyVStack + pinnedViews`
因为粘性日期头是页面主交互的一部分，必须依赖 `Section` 的系统语义来保证吸顶效果稳定，不能为了局部优化把它改成普通 overlay。

### 4. 为什么日历面板和列表要拆成两个子树
时间线页面的高频变化主要发生在列表。把 `TimelineCalendarPanel` 和列表热区拆开，可以减少 `HorizonCalendar` 桥接层在滚动过程中的无关刷新。

### 5. 为什么静态壳层不做骨架屏
当前要解决的是“首开结构反复变化”而不是“缺少加载反馈”。静态壳层的目标是稳定页面版式、减少 reveal 次数，因此保持低视觉噪音，不引入重 loading 表达。
