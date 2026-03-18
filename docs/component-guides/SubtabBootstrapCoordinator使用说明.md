# SubtabBootstrapCoordinator 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Tabs/SubtabBootstrapCoordinator.swift`
- 角色：容器级二级页启动协调器，用于给分段页、子页或 pager 子面板提供一次性 warmup 去重能力。
- 边界：
  - 负责跟踪 `idle / warming / ready` 三态。
  - 负责保证同一个分段的首开任务只执行一次。
  - 不负责持有业务数据，也不负责决定具体页面如何展示 loading / 壳层。

## 快速接入
```swift
@State private var coordinator = SubtabBootstrapCoordinator<ReadingSubTab>()
```

在容器中发起 warmup：

```swift
coordinator.warm(.timeline, priority: .utility) {
    await timelineViewModel.loadInitialData()
}
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `selection` | `Selection` | 无 | 当前要调度 warmup 的子页标识。 |
| `priority` | `TaskPriority` | `.utility` | warmup 任务优先级。 |
| `operation` | `@MainActor @Sendable () async -> Void` | 无 | 真正的启动任务，通常是 ViewModel 的首屏加载方法。 |

## 示例

### 示例 1：容器首帧后低优先级预热
```swift
.task {
    guard timelineViewModel == nil else { return }
    let viewModel = TimelineViewModel(repository: repositories.timelineRepository)
    timelineViewModel = viewModel
    await Task.yield()
    coordinator.warm(.timeline, priority: .utility) {
        await viewModel.loadInitialData()
    }
}
```

### 示例 2：用户主动切换后补发高优先级请求
```swift
.onChange(of: selectedSubTab) { _, newSelection in
    guard newSelection == .timeline else { return }
    coordinator.warm(.timeline, priority: .userInitiated) {
        await timelineViewModel?.loadInitialData()
    }
}
```

## 常见问题

### 1. 为什么不能直接在页面 `.task` 里做 warmup
因为 warmup 的本质是容器级启动策略，不是页面内容职责。放在页面内会让 View 生命周期、保活策略和业务预热绑在一起，边界会变脏。

### 2. `SubtabBootstrapCoordinator` 是否等于缓存
不是。它只负责“同一个子页的首开任务不要执行多次”，不持有业务数据，也不缓存结果。

### 3. 如果 warmup 失败怎么办
协调器本身不处理失败 UI。正确做法是让页面自己的状态机兜底，例如时间线使用静态壳层和首屏快照，即使 warmup 未命中也不会暴露破碎中间态。
