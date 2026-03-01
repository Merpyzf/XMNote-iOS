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

## 3. TabView 可见窗口优化：实现原理（详细版）

### 3.1 问题本质：TabView 性能瓶颈到底在哪里
`TabView(.page)` 本身不是性能问题根源，真正的瓶颈来自“每个页面都挂着重内容”。
在阅读日历场景中，重内容包括：
- 周网格 `weeks` 的结构映射与 diff。
- 日状态计算（today/selected/future/overflow）。
- 活动事件条、颜色状态、pending 动效层。

如果把所有月份都作为“重页面”传给 `TabView`，任何状态变化（选中日期、颜色回填、模式切换）都可能触发大量页面重算。

核心结论：
- `TabView` 可以全量保留页面标签（保持交互完整）。
- 但“重数据页面”必须窗口化，只保留当前页附近。

### 3.2 架构拆分：容器全集 vs 内容窗口
本次优化的关键不是换容器，而是把“交互边界”和“计算边界”拆开。

1. 容器全集（交互边界）
- `availableMonths` 仍是全量。
- `TabView` 仍按全量月份 `ForEach` + `.tag(month)` 构建。
- 作用：保证分页索引连续、左右滑动行为稳定、快速切月合法性完整。

2. 内容窗口（计算边界）
- `monthPages` 只传可见窗口（当前月前后各 1 页，最多 3 页）。
- 非窗口月份在面板内返回轻量占位状态。
- 作用：把重计算从 `O(M)` 收敛到 `O(W)`，其中 `W=3`。

这是一种典型的“UI 容器全量，内容渲染窗口化”模型。

### 3.3 窗口更新算法：selection 驱动的前后页切换
当前实现采用 `pagerSelection` 作为窗口锚点：

```swift
let anchorIndex = months.firstIndex(of: pagerSelection) ?? ...
let lower = max(0, anchorIndex - 1)
let upper = min(months.count - 1, anchorIndex + 1)
let visible = Array(months[lower...upper])
```

设计点：
- 锚点优先使用 `pagerSelection`，回退到 `displayedMonthStart`。
- 边界月份自动收缩窗口（首月只有右邻，末月只有左邻）。
- 每次选中月份变化时，窗口同步滑动到新锚点。

### 3.4 渲染降载链路：从月级预计算改为格级按需计算
只做窗口化还不够，本次同时把页面内部计算粒度做了下沉：

1. 旧模型
- 先遍历整月所有日期，预构建 `dayPayloads` 字典。
- 再把整个月 payload 交给网格渲染。

2. 新模型
- `MonthPage` 持有 `dayMap + selectedDate + todayStart + laneLimit`。
- 网格真正绘制某一天时才调用 `payload(for:)`。
- “算多少格子、做多少计算”，与渲染粒度一致。

效果：
- 避免每次状态变化重建整月 payload。
- 对窗口页也进一步削减 CPU 峰值。

### 3.5 手势不冲突原则：为什么不能在月页再加 DragGesture
优化期间常见误区是：
- 为了感知滚动状态去暂停 shimmer，给 `ScrollView` 叠加 `DragGesture`。

问题在于：
- 这会与 `TabView(.page)` 横向手势发生竞争。
- 直接表现为“左右翻月失效/不稳定”。

正确策略：
- 让 `TabView` 主导横向分页手势。
- 性能控制通过“窗口化 + 按需计算 + 批量回填 + 动效降频”完成。
- 不依赖抢手势来做性能控制。

### 3.6 复杂度与收益：O(M) 到 O(W) 的窗口模型
定义：
- `M`: 全量月份数（例如 24、36）。
- `W`: 可见窗口页数（本次固定 3）。
- `C_page`: 单个月页面重内容构建成本。

近似成本：
- 全量重建：`Cost_full ≈ M * C_page`
- 窗口重建：`Cost_window ≈ W * C_page`，且 `W << M`

在 `M=24, W=3` 时，理论上页面级重建开销可降到约 `1/8`。
实际体验上会表现为：
- 滑动更跟手。
- 翻页时掉帧显著减少。
- 颜色回填期间的抖动降低。

## 4. 可运行 SwiftUI 示例（窗口化 + 手势不抢占）
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
                ScrollView 
                    if let page = visibleWindow.first(where: { $0.monthStart == month }) {
                        // 仅窗口页构建重内容，降低大规模页面重算
                        MonthHeavyContentView(monthStart: page.monthStart)
                    } else {
                        // 非窗口页保留轻量占位，避免直接空视图导致跳变
                        ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                // 不要在这里叠加 DragGesture 抢占 TabView 横向翻页
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

### 4.1 反例（不要这样做）
```swift
// 反例：看似要感知滚动，实际会和 TabView 分页手势竞争
ScrollView {
    content
}
.simultaneousGesture(
    DragGesture().onChanged { _ in
        // do something
    }
)
```

## 5. Compose 对照示例（可运行核心意图）
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

## 6. 迁移中的踩坑与结论
- 卡顿优化和手势优化可能相互影响：
  - 用 `DragGesture` 感知滚动暂停 shimmer，可能直接破坏翻页。
- 正确顺序应是：
  1. 先确保核心交互（左右翻月）可用。
  2. 再做不抢占手势的性能优化（窗口化、批量回填、按需计算、动效降频）。
- Android -> iOS 迁移要对齐“业务意图”，不是照搬控件写法：
  - 业务意图是“可流畅翻月 + 数据及时更新”，而不是“必须某个手势监听实现”。
