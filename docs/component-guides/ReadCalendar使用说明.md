# ReadCalendar 使用说明

## 组件定位
`ReadCalendarView` 是阅读日历页面壳层，负责：
- 导航入口承接与仓储注入。
- 持有 `ReadCalendarViewModel` 并加载数据。
- 承接页面级 UI 状态（显示模式切换、设置页弹层）。
- 将数据状态映射到 `ReadCalendarPanel` 公共组件。

源码路径：`xmnote/Views/Reading/ReadCalendar/ReadCalendarView.swift`

## 本次更新（2026-03-01）
- 页面映射 `monthPages` 改为窗口化（当前月前后各 1 页），减少 `TabView` 重内容页面数。
- 日 payload 改为按需计算，不再预构建全月 `dayPayloads`。
- 保留 `TabView` 翻月；修复手势冲突后不再在月页叠加竞争性拖拽手势。
- ViewModel 颜色回填改为批量提交，减少高频状态写入抖动。

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
- 顶部单行控制区：左侧月份标题菜单快速切月。
- 顶部单行控制区：右侧图标分段切换（热力图/活动事件/书籍封面）。
- 顶部右侧：设置按钮（`gearshape`）打开设置页。
- 月页支持纵向滚动，月份支持横向分页切换。

## 数据流要点
1. `ReadCalendarViewModel` 维护全量 `availableMonths` 与页状态缓存。
2. 页面层仅构建窗口月份 `monthPages`（降低视图重建成本）。
3. `MonthPage.payload(for:)` 按需读 `dayMap` 计算今日/选中/未来态。
4. 颜色回填采用批量写回，减少 `@Observable` 高频刷新。

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

## 交互约束
- 不要在 `ReadCalendarPanel` 月页 `ScrollView` 上叠加会抢占横向拖拽的手势（会导致左右翻月失效）。
- 需要控制 shimmer 时，优先通过 `ReadCalendarMonthGrid.isShimmerEnabled` 输入控制，而不是靠手势拦截推断滚动状态。

## 常见问题

### 1) 热力图入口传入日期是否仍然生效？
生效。`ReadCalendarViewModel` 会按入口日期定位当月并保持选中态。

### 2) 为什么要拆 `ReadCalendarView` 和 `ReadCalendarPanel`？
页面层负责导航与依赖，组件层负责复用 UI，便于后续在其他入口复用日历面板。

### 3) 为什么 `availableMonths` 仍是全量？
它负责分页边界与选择合法性；性能优化在于只映射窗口 `monthPages`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
