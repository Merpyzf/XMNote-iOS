# ReadCalendar 使用说明

## 组件定位
`ReadCalendarView` 是阅读日历核心页面组件，负责：
- 月视图日历网格展示。
- 按日显示阅读事件条与读完标记。
- 月份快速切换（胶囊步进控件 + 滑动）。
- 承接在读页热力图与我的页入口。

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

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
