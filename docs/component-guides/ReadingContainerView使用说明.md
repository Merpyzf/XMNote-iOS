# ReadingContainerView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Reading/ReadingContainerView.swift`
- 角色：在读模块根容器，统一承载“在读 / 时间线 / 统计”三段切换、顶部操作入口和子页生命周期。
- 边界：
  - 负责创建并托管 `TimelineViewModel`。
  - 负责通过 `SubtabBootstrapCoordinator<ReadingSubTab>` 调度时间线 warmup。
  - 负责把内容查看、阅读日历、书籍详情等事件继续上抛给更外层导航。
  - 不负责时间线内部日历与列表的具体渲染细节。

## 快速接入
```swift
ReadingContainerView()
```

如果需要承接首页路由事件，建议在接入点一次性传齐回调：

```swift
ReadingContainerView(
    onAddBook: onAddBook,
    onAddNote: onAddNote,
    onOpenReadCalendar: onOpenReadCalendar,
    onOpenBookDetail: onOpenBookDetail,
    onOpenContentViewer: onOpenContentViewer
)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `onAddBook` | `() -> Void` | 空实现 | 顶部新增书籍入口回调。 |
| `onAddNote` | `() -> Void` | 空实现 | 顶部新增笔记入口回调。 |
| `onOpenDebugCenter` | `(() -> Void)?` | `nil` | 调试入口回调。 |
| `onOpenReadCalendar` | `(Date) -> Void` | 空实现 | 在读页打开阅读日历。 |
| `onOpenBookDetail` | `(Int64) -> Void` | 空实现 | 打开书籍详情。 |
| `onOpenContentViewer` | `(ContentViewerSourceContext, ContentViewerItemID) -> Void` | 空实现 | 打开内容查看页。 |

## 示例
### 示例 1：作为首页阅读 Tab 的根容器
```swift
NavigationStack {
    ReadingContainerView(
        onAddBook: onAddBook,
        onAddNote: onAddNote,
        onOpenReadCalendar: onOpenReadCalendar,
        onOpenBookDetail: onOpenBookDetail,
        onOpenContentViewer: onOpenContentViewer
    )
    .environment(repositoryContainer)
}
```

### 示例 2：容器内统一接入时间线 warmup
```swift
.task {
    guard timelineViewModel == nil else { return }
    let viewModel = TimelineViewModel(repository: repositories.timelineRepository)
    timelineViewModel = viewModel
    await Task.yield()
    warmTimelineIfNeeded(priority: .utility)
}

.onChange(of: selectedSubTab) { _, newSelection in
    guard newSelection == .timeline else { return }
    warmTimelineIfNeeded(priority: .userInitiated)
}
```

## 常见问题
### 1. 为什么 warmup 放在 `ReadingContainerView` 而不是 `ReadingTimelineView`
因为 warmup 需要结合二级页切换时机、状态保活和去重策略统一调度。这是容器职责，不是页面内容职责。

### 2. `KeepAliveSwitcherHost` 和 warmup 是什么关系
`KeepAliveSwitcherHost` 只负责在“在读 / 时间线 / 统计”之间保留子页存活状态，不直接触发业务预热。warmup 由容器显式调用 `SubtabBootstrapCoordinator` 完成，职责边界更清晰。

### 3. 首次切到时间线时为什么有时还会先看到壳层
因为预热只是优化项，不是正确性路径。即便 warmup 未命中，容器仍会立即切到 `ReadingTimelineView`，由页面先展示静态壳层，等首屏快照完成后再 reveal 正式内容。

### 4. 这个组件是否可抽到 `UIComponents`
不建议。它属于页面级业务容器，持有状态、路由回调与启动调度逻辑，不符合跨模块无业务状态组件的约束。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
