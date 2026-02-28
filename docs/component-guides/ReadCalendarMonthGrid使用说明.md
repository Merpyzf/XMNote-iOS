# ReadCalendarMonthGrid 使用说明

## 组件定位
`ReadCalendarMonthGrid` 是阅读日历的底层周网格组件，负责：
- 按周渲染日期格。
- 支持三种内容模式：`heatmap` / `activityEvent` / `bookCover`。
- 渲染今天、选中、未来日期状态。
- 在 `activityEvent` 模式渲染跨周事件条分段与颜色状态。

源码路径：`xmnote/UIComponents/Foundation/ReadCalendarMonthGrid.swift`

## 快速接入
```swift
ReadCalendarMonthGrid(
    weeks: page.weeks,
    laneLimit: 4,
    displayMode: .activityEvent,
    dayPayloadProvider: { date in
        page.payload(for: date)
    },
    onSelectDay: { date in
        viewModel.selectDate(date)
    }
)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `weeks` | `[ReadCalendarMonthGrid.WeekData]` | 无 | 周网格数据（每周 7 列 + 事件条段）。 |
| `laneLimit` | `Int` | 无 | 事件模式下每日最多展示 lane 数。 |
| `displayMode` | `ReadCalendarMonthGrid.DisplayMode` | 无 | 当前渲染模式（热力图/活动事件/封面）。 |
| `dayPayloadProvider` | `(Date) -> DayPayload` | 无 | 返回某天 UI 状态。 |
| `onSelectDay` | `(Date) -> Void` | 无 | 点击日期回调。 |

### `DayPayload` 字段说明
| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `bookCount` | `Int` | 当日书籍数；热力图强度和封面数量依据该值。 |
| `isReadDoneDay` | `Bool` | 当日是否读完。 |
| `overflowCount` | `Int` | 活动事件模式下的超出数量。 |
| `isToday` | `Bool` | 是否今天。 |
| `isSelected` | `Bool` | 是否选中。 |
| `isFuture` | `Bool` | 是否未来日期。 |

## 模式行为
- `heatmap`：显示热力色块，不渲染事件条。
- `activityEvent`：显示事件条、跨周连接语义和 `+N`。
- `bookCover`：显示最多 3 个封面占位色块，超出显示 `+N`。

## 示例

### 示例 1：活动事件模式
```swift
ReadCalendarMonthGrid(
    weeks: page.weeks,
    laneLimit: props.laneLimit,
    displayMode: .activityEvent,
    dayPayloadProvider: { page.payload(for: $0) },
    onSelectDay: onSelectDate
)
```

### 示例 2：封面模式
```swift
ReadCalendarMonthGrid(
    weeks: page.weeks,
    laneLimit: props.laneLimit,
    displayMode: .bookCover,
    dayPayloadProvider: { page.payload(for: $0) },
    onSelectDay: onSelectDate
)
```

## 常见问题

### 1) 为什么 `heatmap` 模式不显示 `+N`？
热力图强调强度，不强调明细数量，避免视觉噪音。

### 2) `bookCover` 的封面颜色来自真实封面吗？
当前为占位视觉方案，后续可切换为真实封面缩略图或取色结果。

### 3) 跨周连续为什么只在 `activityEvent` 有意义？
跨周连接是事件条语义，热力图/封面模式不展示 segment 层信息。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
