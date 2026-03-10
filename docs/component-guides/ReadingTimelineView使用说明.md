# ReadingTimelineView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Reading/Timeline/ReadingTimelineView.swift`
- 角色：在读模块的正式时间线页面壳层，承接日历浏览、分类过滤、按日时间线列表与粘性日期头。
- 边界：
  - 负责从环境中读取 `RepositoryContainer` 并创建 `TimelineViewModel`。
  - 不负责 item 级跳转、复制、删除、TTS 等业务动作。

## 快速接入
```swift
ReadingTimelineView()
```

需要保证外层已注入 `RepositoryContainer`：

```swift
NavigationStack {
    ReadingTimelineView()
}
.environment(repositoryContainer)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| 无 | - | - | 当前组件不暴露外部参数，依赖环境中的 `RepositoryContainer` 自行构建状态层。 |

## 示例

### 示例 1：在在读容器中作为正式子页接入
```swift
@ViewBuilder
private func segmentedPage(for tab: ReadingSubTab) -> some View {
    switch tab {
    case .reading:
        ReadingListPlaceholderView(onOpenReadCalendar: onOpenReadCalendar)
    case .timeline:
        ReadingTimelineView()
    case .statistics:
        StatisticsPlaceholderView()
    }
}
```

### 示例 2：独立预览时间线页面
```swift
#Preview {
    NavigationStack {
        ReadingTimelineView()
            .environment(RepositoryContainer(databaseManager: .sharedPreview))
    }
}
```

## 常见问题

### 1. 为什么 `ReadingTimelineView` 不直接暴露 `TimelineViewModel` 参数？
它是页面壳层，不是纯展示组件。当前设计要求它在 `.task` 中从 `RepositoryContainer` 安全创建 ViewModel，避免把环境依赖泄漏给上层容器。

### 2. 为什么列表要用 `LazyVStack + pinnedViews`？
因为粘性日期头是页面主交互的一部分，必须依赖 `Section` 的系统语义来保证吸顶效果稳定，不能为了局部优化把它改成普通 overlay。

### 3. 为什么日历面板和列表要拆成两个子树？
时间线页面的高频变化主要发生在列表。把 `TimelineCalendarPanel` 和列表热区拆开，可以减少 `HorizonCalendar` 桥接层在滚动过程中的无关刷新。
