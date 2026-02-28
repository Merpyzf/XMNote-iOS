# 阅读日历跨周连续事件条（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- SwiftUI 日历页面要把“数据计算”和“渲染”彻底解耦：ViewModel 产出稳定 `segments`，View 只负责画，不在 View 内做区间推导。
- 跨周连续视觉不是“跨周不切段”，而是“先连续建模，再按周切段，再用连接语义还原连续感”。
- `@Observable` + `@MainActor` 适合页面状态中枢；Repository 继续作为唯一数据入口，避免 ViewModel 直接触库。
- 月份切换体验在 iOS 上建议“按钮 + 手势”并存：按钮保证可预期，手势提高效率。

## 2. Android Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 连续事件条建模 | 直接在周数据上合并 | 先 Run（自然日）再 Split（按周） | 先表达业务语义，再适配显示结构 |
| 条位分配 | 按周局部排布 | 全局 lane 后分段复用 lane | 保证跨周稳定，减少视觉跳变 |
| 页面状态管理 | `ViewModel + StateFlow` | `@Observable ViewModel` | 状态单源，UI 纯消费 |
| 月份切换 | `HorizontalPager` / 按钮 | 按钮 + `DragGesture` | iOS 原生交互表达，不机械搬运 |

## 3. 可运行示例（SwiftUI）
```swift
import SwiftUI

struct CalendarSegment: Identifiable {
    let id = UUID()
    let startOffset: Int   // 0...6
    let endOffset: Int     // 0...6
    let lane: Int
    let continuesFromPrevWeek: Bool
    let continuesToNextWeek: Bool
    let title: String
}

struct WeekSegmentDemo: View {
    let segments: [CalendarSegment]
    private let rowHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.gray.opacity(0.08))
                            .overlay(Rectangle().stroke(Color.gray.opacity(0.2), lineWidth: 0.5))
                    }
                }

                ForEach(segments) { seg in
                    let width = CGFloat(seg.endOffset - seg.startOffset + 1) * cell - 4
                    let x = CGFloat(seg.startOffset) * cell + 2
                    let y = CGFloat(seg.lane) * (rowHeight + 4)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.opacity(0.75))
                        Text(seg.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                        if seg.continuesFromPrevWeek {
                            HStack { Text("◀︎").font(.system(size: 8)); Spacer() }
                                .padding(.leading, 2)
                        }
                        if seg.continuesToNextWeek {
                            HStack { Spacer(); Text("▶︎").font(.system(size: 8)) }
                                .padding(.trailing, 2)
                        }
                    }
                    .frame(width: max(0, width), height: rowHeight)
                    .offset(x: x, y: y)
                }
            }
        }
        .frame(height: 120)
        .padding()
    }
}
```

## 4. Android Compose 对照示例（核心意图）
```kotlin
// 核心意图：先构建自然日连续 run，再按周 split，最后 lane 分配
val runs = buildRuns(dayBooks) // 不按周截断
val segments = runs.flatMap { run -> splitByWeek(run) }
val lanes = assignLane(runs) // 稳定 lane
```

## 5. 迁移结论
- Android 与 iOS 可以在“业务语义”上 100% 对齐，但表现层不应被控件形态绑死。
- 先构建 Run 再 Split 的架构，能同时满足：
  - Android 一致性（可切兼容模式）
  - iOS 连续可读性（跨周连接）
  - 后续扩展性（筛选、点击、详情、埋点）

## 6. 新增：纸感卡片系统 UI 重构（Compose -> SwiftUI）

### 6.1 关键 iOS 知识点
- 二级页面背景优先与首页体系一致（`windowBackground`），不要额外叠加首页顶部渐变层。
- 通过 `card shadow + 留白分隔` 构建“空间层级”，比大量分割线更自然。
- 视觉调色优先使用冷中性低饱和系（雾蓝/灰青），避免暖色在灰底场景下发脏。
- `glassEffect` 只用于轻量控制层（如月份切换），正文仍保持清晰可读。
- 选中态优先用 `fill + stroke + fontWeight` 建层级，避免高饱和色块造成视觉噪音。
- 跨周事件条可通过 `continuesFromPrevWeek/continuesToNextWeek` 做端点渐隐，表达“时间流”。

### 6.2 Compose 思维对照
| 设计意图 | Android Compose | SwiftUI |
|---|---|---|
| 卡片浮层感 | `Card(elevation)` + 主题色面板 | `windowBackground + RoundedRectangle + soft shadow` |
| 顶部轻控件层 | `Surface + IconButton` | `Capsule + glassEffect + snappy` |
| 跨周连续条视觉 | `RoundedCornerShape + alpha` | `UnevenRoundedRectangle + edge gradient` |
| 选中日期轻强调 | `border + low-alpha bg` | `Circle(fill+stroke) + font weight` |

### 6.3 可运行 SwiftUI 片段
```swift
ZStack {
    Color.windowBackground.ignoresSafeArea()

    RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
        .fill(Color.readCalendarCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.readCalendarCardStroke, lineWidth: CardStyle.borderWidth)
        }
        .shadow(color: .black.opacity(0.07), radius: 18, x: 0, y: 8)
}
```

### 6.4 Compose 对照片段
```kotlin
Box(
    Modifier
        .fillMaxSize()
        .background(MaterialTheme.colorScheme.background)
) {
    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFFFAFCFF)),
        elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
    ) {
        // calendar content
    }
}
```

## 7. 新增：完整控件组件化（ReadCalendarPanel + ReadCalendarMonthGrid）

### 7.1 iOS 侧抽象方式
- `ReadCalendarView`：只做导航与数据装配（壳层）。
- `ReadCalendarPanel`：完整日历控件（月份切换、weekday、分页、错误态）。
- `ReadCalendarMonthGrid`：底层月网格渲染（周行/日期/事件条）。

### 7.2 对 Compose 开发者的映射
| Android Compose | SwiftUI |
|---|---|
| `Screen + ViewModel + HorizontalPager` 全写在一个页面 | 页面壳层 `ReadCalendarView` + 可复用控件 `ReadCalendarPanel` |
| `LazyVerticalGrid` / 自定义 Row 直接画日历格 | `ReadCalendarMonthGrid` 独立成基础渲染组件 |
| 页面直接读状态并处理细节 | 壳层只做状态映射，细节交给 UIComponents |

### 7.3 可运行 SwiftUI 片段
```swift
ReadCalendarPanel(
    props: panelProps,
    onStepMonth: { viewModel.stepPager(offset: $0) },
    onPagerSelectionChanged: { viewModel.pagerSelection = $0 },
    onSelectDate: { viewModel.selectDate($0) },
    onRetry: { retryCurrentContext() }
)
```

### 7.4 对应 Compose 抽象片段
```kotlin
@Composable
fun ReadCalendarScreen(
    state: CalendarUiState,
    onStepMonth: (Int) -> Unit,
    onPagerMonthChange: (LocalDate) -> Unit,
    onSelectDate: (LocalDate) -> Unit
) {
    ReadCalendarPanel(
        state = state,
        onStepMonth = onStepMonth,
        onPagerMonthChange = onPagerMonthChange,
        onSelectDate = onSelectDate
    )
}
```

## 7. 新增：完整公共组件抽取（ReadCalendarPanel）

### 7.1 iOS 知识点
- “页面壳层”和“可复用控件”必须分层：页面只做依赖注入与任务调度，控件只做展示与交互。
- 复用组件优先采用 `Props + Callback` 设计，避免组件内部直接依赖 Repository。
- 底层渲染组件应避免直接依赖业务领域模型，使用 UI 专用输入结构（`DayPayload`、`EventSegment`）降低耦合。

### 7.2 Compose 对照思路
| 目标 | Compose 常见方式 | SwiftUI 本次方式 |
|---|---|---|
| 页面壳层 | `Screen + ViewModel.collectAsState()` | `ReadCalendarView + @State ViewModel` |
| 完整控件 | `CalendarPanel(state, actions)` | `ReadCalendarPanel(props, callbacks)` |
| 底层网格 | `MonthGrid(weeks, dayUiState)` | `ReadCalendarMonthGrid(weeks, dayPayloadProvider)` |

### 7.3 可运行 SwiftUI 片段
```swift
ReadCalendarPanel(
    props: panelProps,
    onStepMonth: { viewModel.stepPager(offset: $0) },
    onPagerSelectionChanged: { viewModel.pagerSelection = $0 },
    onSelectDate: { viewModel.selectDate($0) },
    onRetry: { retryCurrentContext() }
)
```

### 7.4 迁移结论
- Android 语义对齐不等于页面结构照搬。
- 正确抽象应是：
  1) 页面处理数据生命周期；
  2) 公共控件处理视觉与交互；
  3) 低层网格处理绘制细节。
