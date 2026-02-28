# ReadCalendar 使用说明

## 组件定位
`ReadCalendarView` 是阅读日历页面壳层，负责：
- 导航入口承接与仓储注入。
- 持有 `ReadCalendarViewModel` 并加载数据。
- 将页面状态映射到 `ReadCalendarPanel` 公共组件。

源码路径：`xmnote/Views/Reading/ReadCalendarView.swift`

## 快速接入
```swift
// 在导航目标中接入
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

## 视觉设计要点
- 页面采用“纸感 + 轻拟物”风格：二级页背景统一 `windowBackground`（无顶部渐变）+ 浮层主卡片。
- 日历内部以周间距和留白分隔，弱化硬分割线。
- 事件条使用低饱和冷中性色系（雾蓝/灰青/蓝灰紫），跨周端点通过渐隐表达时间连续感。
- 选中日期采用浅底描边 + 字重提升，避免高饱和实心块。
- `weekdayHeader` 与首周日期强制分层 + 正间距，避免首行日期被标题遮挡。

## 示例

### 示例 1：从热力图点击日期进入
```swift
ReadingHeatmapWidgetView(
    onOpenReadCalendar: { date in
        readingPath.append(ReadingRoute.readCalendar(date: date))
    }
)
```

### 示例 2：我的页入口进入当月
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

### 1) 为什么事件条跨周会断开成两段？
这是预期行为。数据层先构建跨周连续 Run，再在渲染层按周切段；通过连接标记表达“同一连续区间”。

### 2) 如何保持与 Android 当前展示一致？
将 `ReadCalendarViewModel` 的 `renderMode` 改为 `.androidCompatible`，即可关闭跨周连接标记并按周重排 lane。

### 3) 为什么同一天看不到全部书籍？
页面默认每日显示上限为 4 条，超出使用 `+N` 提示，属于可读性优先策略。

### 4) 封面取色怎么接入？
当前颜色基于 `bookId` 映射。若要接入封面取色，建议在 ViewModel 层引入取色缓存并输出稳定色值，View 不直接做异步图片分析。

### 5) 为什么去掉了大部分分割线？
这次重构将分周结构从“线框分隔”改为“留白分隔”，能让事件条更突出，视觉更接近阅读记录本而不是工具表格。

### 6) 切换月份后为什么不会自动选中同日号？
这是当前设计：选中态只绑定用户真实点击的那一天，切月不自动迁移选中日期，避免产生“系统替用户改选中”的误解。

### 7) 为什么要把控件拆成 `ReadCalendarPanel` + `ReadCalendarMonthGrid`？
为了复用和解耦：`ReadCalendarView` 只做页面容器；完整交互与视觉在 `ReadCalendarPanel`；底层网格渲染在 `ReadCalendarMonthGrid`，后续可单独复用。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
