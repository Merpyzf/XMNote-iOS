# ReadingDurationRankingChart 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Charts/ReadingDurationRankingChart.swift`
- 角色：跨模块复用的阅读时长排行组件，用于展示“封面 + 书名 + 时长 + 条形宽度”。
- 典型场景：阅读日历月总结、年度阅读报告、阅读统计卡片。

## 快速接入
```swift
ReadingDurationRankingChart(
    title: "阅读时长",
    insightText: Text("本月累计 8小时"),
    emptyText: "这个月还没有阅读时长。",
    items: rankingItems,
    animationIdentity: "2026-03|month",
    onBookTap: { bookId in
        print("tap", bookId)
    }
)
```

## 参数说明
| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `title` | `String` | 模块标题。 |
| `insightText` | `Text?` | 标题下方洞察文案，可为空。 |
| `emptyText` | `String` | `items` 为空时的占位文案。 |
| `items` | `[ReadingDurationRankingChart.Item]` | 排行数据列表。 |
| `animationIdentity` | `String` | 动画重播标识；值变化时条形重新执行入场动画。 |
| `onBookTap` | `((Int64) -> Void)?` | 点击回调；`nil` 时行不可点。 |

### `Item` 字段说明
| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | `Int64` | 书籍 ID。 |
| `title` | `String` | 书名。 |
| `coverURL` | `String` | 封面 URL。 |
| `durationSeconds` | `Int` | 阅读时长（秒）。 |
| `barTint` | `Color` | 条形颜色。 |
| `barState` | `Item.BarState` | 条形状态（`placeholder/resolved/fallback`）。 |

## 示例
### 示例 1：月总结排行
```swift
let items = topBooks.map { book in
    ReadingDurationRankingChart.Item(
        id: book.bookId,
        title: book.name,
        coverURL: book.coverURL,
        durationSeconds: book.readSeconds,
        barTint: Color.readCalendarEventPendingBase,
        barState: .placeholder
    )
}
```

### 示例 2：防止二次动画
```swift
let identity = "\(monthStart.timeIntervalSince1970)|\(topBooks.map(\.bookId))"
ReadingDurationRankingChart(
    title: "阅读时长",
    insightText: nil,
    emptyText: "暂无数据",
    items: items,
    animationIdentity: identity,
    onBookTap: nil
)
```

## 常见问题
### 1) 为什么需要 `animationIdentity`？
组件只在 `animationIdentity` 变化时重播条形动画，用来避免颜色回填等局部刷新导致重复动画。

### 2) `barState` 该怎么用？
- `placeholder`：颜色未就绪，占位条形。
- `resolved`：取色成功，使用真实条形色。
- `fallback`：取色失败，使用默认回退色。

### 3) 可以在别的页面复用吗？
可以。该组件无业务仓储依赖，只消费纯展示数据，适合月度/年度排行复用。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
