# 在读页热力图小组件接入总结（Android Compose → SwiftUI）

## 1. 本次 iOS 知识点

- 页面级“业务组件”与“基础复用组件”分层：
  - 热力图绘制本体继续放在 `UIComponents/Charts/HeatmapChart.swift`
  - 在读页业务拼装放在 `Views/Reading/ReadingHeatmapWidgetView.swift`
  - 避免把业务状态塞进可复用组件，保证 `HeatmapChart` 仍是纯展示组件。

- SwiftUI 路由事件上抛：
  - 子组件只抛 `onOpenReadCalendar(date)` 回调。
  - 路由 append 统一在 `MainTabView` 的 `NavigationPath` 执行。
  - 这样能保持“页面组件无全局导航耦合”。

- `scenePhase` 做跨天刷新：
  - 在 `.active` 时判断是否跨天，跨天才重新拉取热力图。
  - 避免每次回前台都无条件刷新。

- 帮助弹层 + 设置入口拆分：
  - 说明内容用独立 `HeatmapHelpSheetView`。
  - “设置”只负责触发统计类型选择，不直接写数据层逻辑。

## 2. Android Compose 对照思路

| Android 思路 | iOS 对齐实现 | 说明 |
|---|---|---|
| Fragment 中嵌入 HeatChartFragment | Reading 页中嵌入 `ReadingHeatmapWidgetView` | 业务容器里挂载图表组件 |
| Presenter 拉取统计数据 | `ReadingHeatmapWidgetViewModel` 调 Repository | 状态层集中处理加载与切换 |
| 热力图方格点击打开 ReadCalendar | `ReadingRoute.readCalendar(date:)` | 用 NavigationStack 路由打通 |
| 帮助 Dialog + 设置入口 | `HeatmapHelpSheetView` + `confirmationDialog` | 文案和设置入口都在页面内闭环 |

## 3. 可运行示例（最小骨架）

### 3.1 SwiftUI

```swift
import SwiftUI

@MainActor
@Observable
final class HeatmapWidgetVM {
    var days: [Date: HeatmapDay] = [:]
    var type: HeatmapStatisticsDataType = .all

    func load(using repo: any StatisticsRepositoryProtocol) async {
        let result = try? await repo.fetchHeatmapData(year: 0, dataType: type)
        days = result?.days ?? [:]
    }
}

struct ReadingHeatmapWidget: View {
    @Environment(RepositoryContainer.self) private var repos
    @State private var vm = HeatmapWidgetVM()
    let onOpenCalendar: (Date) -> Void

    var body: some View {
        HeatmapChart(days: vm.days, earliestDate: nil, statisticsDataType: vm.type) { day in
            onOpenCalendar(day.id)
        }
        .task { await vm.load(using: repos.statisticsRepository) }
    }
}
```

### 3.2 Compose 对照

```kotlin
@Composable
fun ReadingHeatmapWidget(
    marks: List<Mark>,
    onOpenCalendar: (Long) -> Unit
) {
    AndroidView(factory = { context ->
        HistoryChart(context).apply {
            setIsClickable(true)
            setController { timestamp -> onOpenCalendar(timestamp.unixTime) }
        }
    }, update = { chart ->
        chart.setCheckMarks(marks)
    })
}
```

## 4. 迁移经验

- Android 的“Fragment 组合”迁移到 SwiftUI 时，优先拆成“页面业务组件 + 纯图表组件”两层。
- 路由动作放在上层容器，子视图只上抛意图，能显著降低耦合。
- 帮助弹层与设置入口尽量保持“说明”和“动作”解耦，后续迭代更稳。
