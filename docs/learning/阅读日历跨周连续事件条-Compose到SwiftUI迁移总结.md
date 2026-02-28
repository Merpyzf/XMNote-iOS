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
