# ReadCalendarPanel 使用说明

## 组件定位
`ReadCalendarPanel` 是阅读日历的完整公共控件，包含：
- 顶部单行控制区：左侧月份标题菜单（点击快速跳月）。
- 顶部单行控制区：右侧图标分段切换（热力图/活动事件/书籍封面）。
- `TabView(.page)` 月份容器（横向翻月）。
- weekday 标题与月网格渲染（通过 `ReadCalendarMonthGrid`）。
- 加载/空态/内容态与内联错误重试。

源码路径：`xmnote/UIComponents/Foundation/ReadCalendarPanel.swift`

## 本次更新（2026-03-01）
- 保留 `TabView` 作为月份容器，但业务侧仅提供“当前月前后窗口页”重数据，降低重建成本。
- 移除页内 `DragGesture` 抢占，恢复左右翻月手势。
- `MonthPage` 从“预构建 dayPayloads”改为按需 `payload(for:)` 计算，减少全量映射。

## 快速接入
```swift
ReadCalendarPanel(
    props: panelProps,
    onDisplayModeChanged: { displayMode = $0 },
    onPagerSelectionChanged: { viewModel.pagerSelection = $0 },
    onSelectDate: { viewModel.selectDate($0) },
    onRetry: { retryCurrentContext() }
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
| `monthPages` | `[MonthPage]` | 建议传“窗口化月份页”（如当前月前后各 1 页）。 |

### `MonthPage` 关键字段（性能相关）
| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `weeks` | `[ReadCalendarMonthGrid.WeekData]` | 周网格结构与事件段。 |
| `dayMap` | `[Date: ReadCalendarDay]` | 原始日聚合数据。 |
| `selectedDate` | `Date` | 选中日（用于按需 payload 计算）。 |
| `todayStart` | `Date` | 当天零点（用于 today/future 判断）。 |
| `laneLimit` | `Int` | overflow 计算基线。 |

## 示例

### 示例 1：页面壳层窗口化传参
```swift
let months = viewModel.availableMonths
let index = months.firstIndex(of: viewModel.pagerSelection) ?? 0
let lower = max(0, index - 1)
let upper = min(months.count - 1, index + 1)
let visible = Array(months[lower...upper])

let panelProps = ReadCalendarPanel.Props(
    monthTitle: viewModel.monthTitle,
    availableMonths: months,
    pagerSelection: viewModel.pagerSelection,
    displayMode: displayMode,
    laneLimit: viewModel.laneLimit,
    rootContentState: .content,
    errorMessage: nil,
    monthPages: visible.map(makeMonthPage)
)
```

### 示例 2：模式变化动画
```swift
onDisplayModeChanged: { mode in
    withAnimation(.snappy(duration: 0.26)) {
        displayMode = mode
    }
}
```

## 性能与交互约束
- 保持 `TabView(.page)` 横向手势完整，不在月页 `ScrollView` 上叠加横向竞争手势。
- `monthPages` 使用窗口化数据，避免每次状态变更都重建全量月份页面。
- 日状态按需计算，不要在页面层预构建完整 `dayPayloads` 字典。

## 常见问题

### 1) 为什么左右翻月会突然失效？
通常是页内额外 `DragGesture` 抢占了手势。应移除冲突手势，保留 `TabView` 原生分页手势。

### 2) 为什么 `availableMonths` 是全量，但 `monthPages` 建议窗口化？
`availableMonths` 用于分页范围与 tag 对齐；`monthPages` 控制重内容渲染范围，二者职责不同。

### 3) 这个组件是否允许直接访问 Repository？
不允许。组件是纯展示驱动，数据加载由外层页面或 ViewModel 负责。

### 4) 切换模式会影响数据加载吗？
不会。模式切换仅改变展示形态，不改变月数据请求策略。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
