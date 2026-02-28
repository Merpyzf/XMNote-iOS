# ReadCalendarMonthGrid 使用说明

## 组件定位
`ReadCalendarMonthGrid` 是阅读日历的底层周网格组件，负责：
- 按周渲染日期格与事件条分段。
- 渲染今天、选中、未来日期状态。
- 处理跨周连续事件条端点形态与文本。
- 支持事件条颜色三态（取色中骨架/取色成功/取色失败回退）。

源码路径：`xmnote/UIComponents/Foundation/ReadCalendarMonthGrid.swift`

## 快速接入
```swift
ReadCalendarMonthGrid(
    weeks: page.weeks,
    laneLimit: 4,
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
| `laneLimit` | `Int` | 无 | 每周最多显示 lane 数，决定行高。 |
| `dayPayloadProvider` | `(Date) -> DayPayload` | 无 | 返回某天的 UI 状态（读完/选中/未来/溢出等）。 |
| `onSelectDay` | `(Date) -> Void` | 无 | 点击日期回调（未来日期可在 payload 中禁用）。 |

`EventSegment.color` 字段说明：
- `state`: `pending / resolved / failed`
- `backgroundRGBAHex`: 事件条背景 RGBA（`0xRRGGBBAA`）
- `textRGBAHex`: 事件条文本 RGBA（`0xRRGGBBAA`）

## 示例

### 示例 1：在 ReadCalendarPanel 中使用
```swift
ReadCalendarMonthGrid(
    weeks: page.weeks,
    laneLimit: props.laneLimit,
    dayPayloadProvider: { page.payload(for: $0) },
    onSelectDay: onSelectDate
)
```

### 示例 2：事件段映射
```swift
ReadCalendarMonthGrid.EventSegment(
    bookId: segment.bookId,
    bookName: segment.bookName,
    weekStart: segment.weekStart,
    segmentStartDate: segment.segmentStartDate,
    segmentEndDate: segment.segmentEndDate,
    laneIndex: segment.laneIndex,
    continuesFromPrevWeek: segment.continuesFromPrevWeek,
    continuesToNextWeek: segment.continuesToNextWeek,
    color: ReadCalendarMonthGrid.EventColor(
        state: .resolved,
        backgroundRGBAHex: segment.color.backgroundRGBAHex,
        textRGBAHex: segment.color.textRGBAHex
    )
)
```

## 常见问题

### 1) 为什么周内空白格也要渲染？
为了保证月份网格 7 列对齐，前后补位格必须存在，但它们不会参与点击与事件条渲染。

### 2) 如何避免事件条绘制到非当月格？
`weeks.days` 里非当月日期使用 `nil`，组件仅在有日期的格子上渲染日状态与点击。

### 3) 跨周为什么不是一整条连续矩形？
视觉上是连续语义，渲染上按周切段；两端通过渐隐与小半径表达“连接关系”。

### 4) `ReadCalendarMonthGrid` 和 `ReadCalendarPanel` 的边界？
`ReadCalendarMonthGrid` 只管“月内网格绘制”；`ReadCalendarPanel` 负责切月、状态机和整体容器布局。

### 5) 取色中的视觉语义如何表达？
`EventColor.state == .pending` 时，组件会渲染骨架底色 + shimmer；只有失败时才使用回退色，不会在取色前就展示哈希色。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
