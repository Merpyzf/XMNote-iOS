# ReadCalendarPanel 使用说明

## 组件定位
`ReadCalendarPanel` 是阅读日历的完整公共控件，包含：
- 顶部月份切换胶囊（左右按钮 + 标题）。
- weekday 标题与月分页容器。
- 月网格渲染（通过 `ReadCalendarMonthGrid`）。
- 加载/空态/内容态与内联错误重试。

源码路径：`xmnote/UIComponents/Foundation/ReadCalendarPanel.swift`

## 快速接入
```swift
ReadCalendarPanel(
    props: panelProps,
    onStepMonth: { offset in
        viewModel.stepPager(offset: offset)
    },
    onPagerSelectionChanged: { month in
        viewModel.pagerSelection = month
    },
    onSelectDate: { date in
        viewModel.selectDate(date)
    },
    onRetry: {
        Task { await viewModel.retryDisplayedMonth(using: repositories.statisticsRepository) }
    }
)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `props` | `ReadCalendarPanel.Props` | 无 | 组件完整展示状态（标题、分页、页面数据、错误态）。 |
| `onStepMonth` | `(Int) -> Void` | 无 | 顶部箭头点击回调，`-1` 上月，`1` 下月。 |
| `onPagerSelectionChanged` | `(Date) -> Void` | 无 | 分页滑动切月后的选择回调。 |
| `onSelectDate` | `(Date) -> Void` | 无 | 点击某天日期的回调。 |
| `onRetry` | `() -> Void` | 无 | 空态/错误态重试回调。 |

### `Props` 字段说明
| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `monthTitle` | `String` | 顶部月份标题（建议 `yyyy年M月`）。 |
| `availableMonths` | `[Date]` | 可滑动月份序列（按时间升序）。 |
| `pagerSelection` | `Date` | 当前分页选中月份起始日。 |
| `laneLimit` | `Int` | 每日事件条显示上限。 |
| `rootContentState` | `RootContentState` | 根内容态（loading/empty/content）。 |
| `errorMessage` | `String?` | 顶层错误文案（内容态展示 inline error，空态展示重试信息）。 |
| `monthPages` | `[MonthPage]` | 每个月的周网格与日状态数据。 |
| `canGoPrevMonth` | `Bool` | 是否允许切到上月。 |
| `canGoNextMonth` | `Bool` | 是否允许切到下月。 |

## 示例

### 示例 1：`ReadCalendarView` 壳层接入
```swift
ReadCalendarPanel(
    props: panelProps,
    onStepMonth: { viewModel.stepPager(offset: $0) },
    onPagerSelectionChanged: { viewModel.pagerSelection = $0 },
    onSelectDate: { viewModel.selectDate($0) },
    onRetry: { retryCurrentContext() }
)
```

### 示例 2：页面级重试策略
```swift
func retryCurrentContext() {
    Task {
        if viewModel.availableMonths.isEmpty {
            await viewModel.reload(using: repositories.statisticsRepository)
        } else {
            await viewModel.retryDisplayedMonth(using: repositories.statisticsRepository)
        }
    }
}
```

## 常见问题

### 1) 这个组件是否允许直接访问 Repository？
不允许。组件是纯展示驱动，数据加载由外层页面或 ViewModel 负责。

### 2) 切月后是否会自动选中同日号？
不会。当前策略是“仅用户点击才更新选中日”，切月只影响当前展示月份。

### 3) 如何保证和 Android 交互一致？
将 `availableMonths + pagerSelection` 作为单一切月状态源，按钮与左右滑动都只改这个状态。

### 4) 为什么还保留 `ReadCalendarView`？
`ReadCalendarView` 是兼容壳层，用于导航与依赖注入；真实 UI 能力已经沉淀到 `ReadCalendarPanel`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
