# 阅读日历封面取色与骨架动效（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 在 SwiftUI 中做“封面取色”时，必须把网络下载、图像分析、缓存放到 Repository，ViewModel 只编排状态。
- 事件条颜色建议使用三态模型：`pending / resolved / failed`，这样 UI 能稳定表达“取色中”而不是直接跳色。
- `TimelineView(.animation)` 适合做轻量 shimmer，不需要额外定时器。
- 文本可读性不能靠固定黑白，需按背景色动态计算对比度（至少保证基础可读）。
- 月份分页场景里要对异步任务做 ticket + cancel，避免旧月取色结果回写新月页面。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 封面取色入口 | Repository 内用 `Palette` | `ReadCalendarColorRepository` 内下载 + dominant 分析 | 数据获取与分析都留在 Data 层 |
| 取色中反馈 | `placeholder/shimmer` | `EventColor.state == .pending` + `TimelineView` shimmer | 用户必须感知“正在取色” |
| 失败回退 | 生成哈希色 | 仅 `failed` 时回退哈希色 | 不在 pending 阶段误导用户 |
| 文本可读性 | `swatch.bodyTextColor` | 基于 luminance/contrast 动态算文本色 | 可读性优先于“固定风格” |

## 3. 可运行 SwiftUI 示例
```swift
import SwiftUI

enum EventColorState {
    case pending
    case resolved(Color, Color) // bg, text
    case failed(Color, Color)
}

struct EventBarView: View {
    let title: String
    let state: EventColorState

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor.opacity(0.92))

            if case .pending = state {
                TimelineView(.animation(minimumInterval: 0.06)) { timeline in
                    let p = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.2) / 1.2
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.5), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 56)
                    .offset(x: -56 + (160 * p))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .frame(height: 18)
    }

    private var backgroundColor: Color {
        switch state {
        case .pending: return Color.gray.opacity(0.35)
        case .resolved(let bg, _), .failed(let bg, _): return bg
        }
    }

    private var textColor: Color {
        switch state {
        case .pending: return Color.secondary
        case .resolved(_, let text), .failed(_, let text): return text
        }
    }
}
```

## 4. Compose 对照示例（核心意图）
```kotlin
sealed interface EventColorState {
    data object Pending : EventColorState
    data class Resolved(val bg: Color, val text: Color) : EventColorState
    data class Failed(val bg: Color, val text: Color) : EventColorState
}

// ViewModel 只持有状态，Repository 负责取色与缓存
val eventColorState by viewModel.eventColorState.collectAsState()
```

## 5. 迁移结论
- Android 的 Palette 思路在 iOS 可迁移，但要改成 iOS 可维护的 Repository + 状态机结构。
- “未取色不用哈希色”是关键交互点：用户能直观区分“正在处理”和“处理失败”。
- 颜色系统要把“背景色”和“文本色”作为同一结果返回，避免 UI 层再次猜测可读性。
