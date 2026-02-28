# ReadCalendarPanel 使用说明

## 组件定位
`ReadCalendarPanel` 是阅读日历的完整公共控件，包含：
- 顶部单行控制区：左侧月份标题菜单（点击快速跳月，移除日历图标）。
- 顶部单行控制区：右侧图标分段切换（热力图/活动事件/书籍封面）。
- 顶部控件去容器化，减少“控件层”对内容层的压制。
- weekday 标题与月分页容器。
- 月网格渲染（通过 `ReadCalendarMonthGrid`）。
- 加载/空态/内容态与内联错误重试。

源码路径：`xmnote/UIComponents/Foundation/ReadCalendarPanel.swift`

## 快速接入
```swift
ReadCalendarPanel(
    props: panelProps,
    onDisplayModeChanged: { mode in
        displayMode = mode
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
| `props` | `ReadCalendarPanel.Props` | 无 | 组件完整展示状态（标题、模式、分页、页面数据、错误态）。 |
| `onDisplayModeChanged` | `(DisplayMode) -> Void` | 无 | 顶部模式切换回调。 |
| `onPagerSelectionChanged` | `(Date) -> Void` | 无 | 月份切换回调（菜单/分页统一）。 |
| `onSelectDate` | `(Date) -> Void` | 无 | 点击某天日期回调。 |
| `onRetry` | `() -> Void` | 无 | 空态/错误态重试回调。 |

### `Props` 字段说明
| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `monthTitle` | `String` | 顶部月份标题（建议 `yyyy年M月`）。 |
| `availableMonths` | `[Date]` | 可展示月份序列（按时间升序）。 |
| `pagerSelection` | `Date` | 当前分页选中月份起始日。 |
| `displayMode` | `DisplayMode` | 当前展示模式（热力图/活动事件/书籍封面）。 |
| `laneLimit` | `Int` | 每日事件条显示上限。 |
| `rootContentState` | `RootContentState` | 根内容态（loading/empty/content）。 |
| `errorMessage` | `String?` | 顶层错误文案。 |
| `monthPages` | `[MonthPage]` | 每个月的周网格与日状态数据。 |

## 示例

### 示例 1：页面壳层接入
```swift
ReadCalendarPanel(
    props: panelProps,
    onDisplayModeChanged: { displayMode = $0 },
    onPagerSelectionChanged: { viewModel.pagerSelection = $0 },
    onSelectDate: { viewModel.selectDate($0) },
    onRetry: { retryCurrentContext() }
)
```

### 示例 2：模式变化带动画
```swift
onDisplayModeChanged: { mode in
    withAnimation(.snappy(duration: 0.26)) {
        displayMode = mode
    }
}
```

### 示例 3：单行顶部布局（组件内部）
```swift
HStack {
    monthSwitcher   // 左侧月份菜单
    modeSwitcher    // 右侧图标 segmented
}
```

## 常见问题

### 1) 这个组件是否允许直接访问 Repository？
不允许。组件是纯展示驱动，数据加载由外层页面或 ViewModel 负责。

### 2) 切换模式会影响数据加载吗？
不会。模式切换仅改变展示形态，不改变月数据请求策略。

### 3) 为什么模式切换改为图标而不是文字？
顶部空间有限，图标分段能在单行里保留 3 模式切换能力，同时不压缩左侧月份可读性。

### 4) 为什么不再暴露 `onStepMonth`？
切月行为已统一为“菜单选择 + 分页滑动”写回 `pagerSelection`，避免重复入口。

### 5) 如何保证和 Android 业务意图一致？
模式切换只影响可视表达，不改变日级聚合、跨周分段和 lane 分配逻辑。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
