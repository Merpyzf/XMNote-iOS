# 阅读日历滚动性能优化与手势冲突修复（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- `TabView(.page)` 与子视图手势会竞争：在分页容器内部额外叠加 `DragGesture`，很容易抢占横向翻页手势。
- 分页容器的性能关键不在“能不能用 TabView”，而在“不要给它塞全量重内容页”。
- `MonthPage` 的日状态计算应按需（格子渲染时计算），避免每次状态变化都重建全月 `dayPayload`。
- `@Observable` 高频写入会放大 SwiftUI diff 成本：颜色回填应批处理提交，不要单条回填即写一次。
- `TimelineView` 动效要控制刷新频率；高频 shimmer 在滚动场景会叠加 GPU/主线程压力。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 横向翻页容器 | `HorizontalPager` | `TabView(.page)` | 容器可保留，重点是数据窗口化 |
| 分页页内容 | `Pager` 内嵌 `LazyColumn` | `TabView` 页内 `ScrollView` | 避免跨轴手势抢占 |
| 可见窗口优化 | 只持有相邻页状态 | `monthPages` 仅当前月前后窗口 | 页容器全量，重内容窗口化 |
| 日格状态计算 | `derivedStateOf`/按项计算 | `payload(for:)` 按需计算 | 让计算跟渲染同粒度 |
| 异步增量回填 | `snapshotFlow/debounce/buffer` | 批量 `applyColors`（计数/时间阈值） | 降低状态写放大 |

## 3. 可运行 SwiftUI 示例（窗口化 + 手势不抢占）
```swift
import SwiftUI

struct CalendarPage: Identifiable, Hashable {
    let monthStart: Date
    let id: Date

    init(monthStart: Date) {
        self.monthStart = monthStart
        self.id = monthStart
    }
}

struct PagerWindowDemoView: View {
    @State private var months: [Date] = {
        let cal = Calendar.current
        let current = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return (-12...0).compactMap { cal.date(byAdding: .month, value: $0, to: current) }
    }()
    @State private var selection: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }()

    private var visibleWindow: [CalendarPage] {
        guard let index = months.firstIndex(of: selection) ?? months.indices.last else { return [] }
        let lower = max(months.startIndex, index - 1)
        let upper = min(months.endIndex - 1, index + 1)
        return months[lower...upper].map(CalendarPage.init)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(months, id: \.self) { month in
                ScrollView {
                    if let page = visibleWindow.first(where: { $0.monthStart == month }) {
                        // 仅窗口页构建重内容
                        MonthHeavyContentView(monthStart: page.monthStart)
                    } else {
                        // 非窗口页轻量占位
                        ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                // 不要叠加 DragGesture 抢占横向翻页
                .tag(month)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

private struct MonthHeavyContentView: View {
    let monthStart: Date

    var body: some View {
        VStack(spacing: 8) {
            Text(monthStart.formatted(date: .abbreviated, time: .omitted))
                .font(.headline)
            ForEach(0..<42, id: \.self) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.16))
                    .frame(height: 20)
                    .overlay(Text("Day \(i + 1)").font(.caption), alignment: .leading)
            }
        }
        .padding()
    }
}
```

## 4. Compose 对照示例（可运行核心意图）
```kotlin
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PagerWindowDemo() {
    val now = remember { YearMonth.now() }
    val months = remember { (-12..0).map { now.plusMonths(it.toLong()) } }
    val pagerState = rememberPagerState(initialPage = months.lastIndex, pageCount = { months.size })

    HorizontalPager(state = pagerState) { page ->
        val visibleRange = (pagerState.currentPage - 1)..(pagerState.currentPage + 1)
        if (page in visibleRange) {
            LazyColumn {
                item { Text(months[page].toString()) }
                items(42) { idx ->
                    Text("Day ${idx + 1}")
                }
            }
        } else {
            Box(Modifier.fillMaxWidth().height(280.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
    }
    // 不在页面内容层额外添加会抢占横向拖拽的手势
}
```

## 5. 迁移中的踩坑与结论
- 卡顿优化和手势优化可能相互影响：
  - 用 `DragGesture` 感知滚动暂停 shimmer，可能直接破坏翻页。
- 正确顺序应是：
  1. 先确保核心交互（左右翻月）可用。
  2. 再做不抢占手势的性能优化（窗口化、批量回填、按需计算、动效降频）。
- Android -> iOS 迁移要对齐“业务意图”，不是照搬控件写法：
  - 业务意图是“可流畅翻月 + 数据及时更新”，而不是“必须某个手势监听实现”。
