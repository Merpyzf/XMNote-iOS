# 热力图组件样式参数化（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 当组件需要长期演进时，应把尺寸常量从内部 `private const` 提升为公开样式对象，避免业务方只能改源码。
- SwiftUI 组件推荐采用“参数对象 + 预设样式”模型：
  - 参数对象承载细粒度可配项（如 `squareSize/squareSpacing/squareRadius`）。
  - 预设样式承载场景化组合（如 `.default`、`.readingCard`）。
- 对外 API 新增参数时给默认值，可保持调用侧零改动兼容。

## 2. Compose -> SwiftUI 思维映射
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 组件样式可调 | `@Stable data class Style` + 默认参数 | `struct HeatmapChartStyle` + `.default` | 配置前置，避免魔法数散落 |
| 场景化样式 | 业务层传不同 style 对象 | `style: .readingCard` | 业务意图显式化 |
| 兼容历史调用 | 默认参数保底 | `style: HeatmapChartStyle = .default` | 非破坏升级 |

## 3. 可运行示例（SwiftUI）
```swift
import SwiftUI

struct HeatmapStyleDemoView: View {
    let days: [Date: HeatmapDay]
    let earliestDate: Date?

    var body: some View {
        VStack(spacing: 12) {
            HeatmapChart(
                days: days,
                earliestDate: earliestDate,
                statisticsDataType: .all,
                style: .default
            )

            HeatmapChart(
                days: days,
                earliestDate: earliestDate,
                statisticsDataType: .all,
                style: .readingCard
            )
        }
        .padding()
    }
}
```

## 4. 迁移结论
- Android 端 `HistoryChart` 本质是“父容器测量驱动 + 组件内部按比例绘制”。iOS 端对应策略应是“样式参数化 + 内容自适应”，而不是继续堆叠固定高度与硬编码尺寸。
- 通过 `HeatmapChartStyle`，业务方可以在不修改组件源码的前提下完成“方格稍微调大”这类视觉迭代。
