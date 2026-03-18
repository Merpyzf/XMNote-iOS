# HorizontalPagingHost 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Tabs/HorizontalPagingHost.swift`
- 角色：通用横向分页宿主，统一承接分页吸附、选中同步、窗口化懒挂载和页级生命周期回调。
- 边界：
  - 负责横向分页与可见窗口控制。
  - 负责把外部 `selection` 与内部滚动位置同步。
  - 不负责业务数据获取；业务页只通过 `onPageTask` / `onPageDidBecomeSelected` 接入自己的加载逻辑。

## 快速接入
```swift
HorizontalPagingHost(
    ids: viewModel.pageIDs,
    selection: $viewModel.selectedPageID
) { id in
    PageView(id: id)
}
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `ids` | `[ID]` | 无 | 分页 ID 列表，要求稳定且可哈希。 |
| `selection` | `Binding<ID?>` | 无 | 外部选中页绑定。 |
| `windowAnchorID` | `ID?` | `nil` | 窗口化时的锚点页；未传时优先退回当前选中页。 |
| `windowing` | `WindowingStrategy` | `.all` | 控制页面挂载范围，支持全部挂载或按半径窗口化懒挂载。 |
| `showsIndicators` | `Bool` | `false` | 是否显示横向滚动指示器。 |
| `pageAlignment` | `Alignment` | `.top` | 单页内容在分页容器内的对齐方式。 |
| `programmaticScrollAnimation` | `Animation` | `.snappy(duration: 0.24)` | 编程式切页动画。 |
| `onPageTask` | `(@MainActor @Sendable (ID) async -> Void)?` | `nil` | 页面挂载后的异步任务。 |
| `onPageDidBecomeSelected` | `(@MainActor @Sendable (ID) async -> Void)?` | `nil` | 页面真正成为选中页后的回调。 |

## 示例

### 示例 1：阅读日历按月分页
```swift
HorizontalPagingHost(
    ids: monthIDs,
    selection: $selectedMonthID,
    windowAnchorID: selectedMonthID,
    windowing: .radius(1),
    onPageDidBecomeSelected: { id in
        await viewModel.selectMonth(id)
    }
) { id in
    ReadCalendarMonthPage(monthID: id)
}
```

### 示例 2：内容查看页按条目懒挂载
```swift
HorizontalPagingHost(
    ids: itemIDs,
    selection: $selectedItemID,
    windowAnchorID: selectedItemID,
    windowing: .radius(2),
    onPageTask: { id in
        await viewModel.prefetchDetailIfNeeded(for: id)
    }
) { id in
    ContentViewerPage(itemID: id)
}
```

## 常见问题

### 1. 为什么不用 `TabView`
因为 `TabView` 在当前项目的复杂嵌套场景里存在内容区域莫名上移的问题，而且生命周期和懒挂载控制不够稳定。`HorizontalPagingHost` 的目标就是替代这类不稳定分页宿主。

### 2. `windowing: .radius(...)` 的意义是什么
它用于把挂载范围限制在“当前页附近”，避免一次性创建全部页面，降低复杂页面横向滑动时的内存和布局成本。

### 3. 什么时候应该用 `.all`
当页面总数很少、单页结构很轻，或者你明确需要所有页常驻时可以使用 `.all`。否则默认优先考虑窗口化挂载。
