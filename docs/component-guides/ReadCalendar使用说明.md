# ReadCalendar 使用说明

## 组件定位
`ReadCalendarView` 是阅读日历页面壳层，负责：
- 导航入口承接与仓储注入。
- 持有 `ReadCalendarViewModel` 并加载数据。
- 承接页面级 UI 状态（显示模式切换、设置页弹层）。
- 将数据状态映射到 `ReadCalendarPanel` 公共组件。

源码路径：`xmnote/Views/Reading/ReadCalendar/ReadCalendarView.swift`

## 快速接入
```swift
.navigationDestination(for: ReadingRoute.self) { route in
    switch route {
    case .readCalendar(let date):
        ReadCalendarView(date: date)
    default:
        EmptyView()
    }
}
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `date` | `Date?` | `nil` | 初始选中日期。传 `nil` 时默认今天。 |

## 关键交互
- 顶部单行控制区：左侧月份标题菜单（无日历图标）快速切月。
- 顶部单行控制区：右侧图标分段切换（热力图/活动事件/书籍封面）。
- 顶部右侧：设置按钮（`gearshape`）打开设置页，当前为交互设计稿。

## 示例

### 示例 1：从热力图点击日期进入
```swift
ReadingHeatmapWidgetView(
    onOpenReadCalendar: { date in
        readingPath.append(ReadingRoute.readCalendar(date: date))
    }
)
```

### 示例 2：我的页入口
```swift
.navigationDestination(for: PersonalRoute.self) { route in
    switch route {
    case .readCalendar:
        ReadCalendarView(date: nil)
    default:
        EmptyView()
    }
}
```

## 常见问题

### 1) 为什么把设置入口放到导航栏右上角？
设置属于页面级全局偏好，不应混入月网格内部控制区。

### 2) 模式切换和设置里的“默认模式”会冲突吗？
当前都绑定同一个 `displayMode` 状态，交互一致；设置页暂未持久化。

### 3) 热力图入口传入日期是否仍然生效？
生效。`ReadCalendarViewModel` 会按入口日期定位当月并保持选中态。

### 4) 为什么要拆 `ReadCalendarView` 和 `ReadCalendarPanel`？
页面层负责导航与依赖，组件层负责复用 UI，便于后续在其他入口复用日历面板。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
