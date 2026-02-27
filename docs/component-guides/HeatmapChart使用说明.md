# HeatmapChart 使用说明

## 组件定位
`HeatmapChart` 是阅读热力图核心组件，支持：
- 周列网格渲染（右侧固定星期标签）。
- 顶部月/年标签绘制与防重叠策略。
- 日期点击回调、今日高亮、未来日期禁点。
- 长时间轴横向滚动与月份锚点跳转。
- 通过 `HeatmapChartStyle` 进行尺寸、间距、圆角与防裁切策略配置。

源码路径：`xmnote/UIComponents/Charts/HeatmapChart.swift`

## 快速接入
```swift
HeatmapChart(
    days: viewModel.days,
    earliestDate: viewModel.earliestDate,
    latestDate: viewModel.latestDate,
    statisticsDataType: .all
) { day in
    // 点击某天
    onOpenReadCalendar(day.id)
}
```

## 参数说明

### 核心入参
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `days` | `[Date: HeatmapDay]` | 无 | 按天聚合后的热力图数据。 |
| `earliestDate` | `Date?` | 无 | 网格起始日期；`nil` 时默认近 20 周。 |
| `latestDate` | `Date?` | `nil` | 网格结束日期；`nil` 时使用今天。 |
| `statisticsDataType` | `HeatmapStatisticsDataType` | `.all` | 方格分段颜色来源维度。 |
| `style` | `HeatmapChartStyle` | `.default` | 视觉与布局策略配置。 |
| `scrollToMonth` | `String?` | `nil` | 月份锚点滚动（格式：`yyyy-M`）。 |
| `onDayTap` | `(HeatmapDay) -> Void` | `nil` | 点击可用日期回调。 |

### Style 参数
| 字段 | 默认值 | 说明 | 推荐区间 |
| --- | --- | --- | --- |
| `squareSize` | `13` | 方格边长基准值 | 13~18 |
| `squareSpacing` | `3` | 方格间距 | 2~4 |
| `squareRadius` | `2.5` | 方格圆角 | 2~4 |
| `axisGap` | `8` | 网格与轴标签间距 | 6~10 |
| `outerInset` | `0` | 组件外侧内边距 | 0~12 |
| `headerFontSize` | `9` | 顶部标签字号 | 9~11 |
| `fitsViewportWithoutClipping` | `false` | 是否启用视口反算防半格/防裁切 | 在读页建议 `true` |
| `preferredVisibleWeekCount` | `nil` | 可见周数偏好（可选） | 16~24 |
| `minSquareSize` | `11` | 防裁切模式最小方格尺寸 | 11~14 |
| `maxSquareSize` | `20` | 防裁切模式最大方格尺寸 | 18~20 |

## 示例

### 在读页推荐配置（沉浸、无半格）
```swift
HeatmapChart(
    days: viewModel.days,
    earliestDate: viewModel.earliestDate,
    latestDate: viewModel.latestDate,
    statisticsDataType: viewModel.statisticsDataType,
    style: .readingCard
) { day in
    onOpenReadCalendar(day.id)
}
```

### 自定义样式（统计页）
```swift
let statsStyle = HeatmapChartStyle(
    squareSize: 15,
    squareSpacing: 3,
    squareRadius: 3,
    axisGap: 8,
    outerInset: 0,
    headerFontSize: 10,
    fitsViewportWithoutClipping: true,
    preferredVisibleWeekCount: 18,
    minSquareSize: 13,
    maxSquareSize: 18
)

HeatmapChart(
    days: days,
    earliestDate: earliestDate,
    latestDate: latestDate,
    statisticsDataType: .all,
    style: statsStyle,
    scrollToMonth: "2026-2"
)
```

### 图例接入
```swift
// 默认图例
HeatmapChart.legend

// 参数化图例
HeatmapChart.legend(squareSize: 12, fontSize: 10)
```

## 常见问题

### 1) 左侧出现半格
原因：可视区宽度与列宽不整除。  
处理：启用 `fitsViewportWithoutClipping = true`，推荐直接使用 `.readingCard`。

### 2) 最左方格圆角被裁切
原因：亚像素尺寸导致边缘抗锯齿被截断。  
处理：组件内部已基于 `displayScale` 做像素对齐；若仍异常，优先确认外层是否额外 `clipShape`/遮罩。

### 3) `scrollToMonth` 不生效
原因：月份 key 格式不匹配。  
处理：使用 `"yyyy-M"`，例如 `"2026-2"`。

## Android Compose 对照
目标不是机械迁移，而是业务意图对齐：
- Android `LazyRow` 对应 SwiftUI `ScrollView(.horizontal) + LazyHStack`。
- Android `BoxWithConstraints` 反算格子尺寸，对应 SwiftUI 视口宽度 + `HeatmapChartStyle` 防裁切模式。

```kotlin
// Compose 关键意图：按可视宽度反算 cell，避免半格
val count = max(1, floor((widthPx + spacingPx) / (preferredPx + spacingPx)).toInt())
val cellPx = (widthPx - (count - 1) * spacingPx) / count
```

## 验收清单
- 首页首屏：左侧无半格、最左圆角完整。
- 快速横向滑动：无明显卡顿、标签与网格对齐。
- 点击回调：可点击日期触发，未来日期不触发。
- 月份锚点：`scrollToMonth` 可跳转到目标月。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
