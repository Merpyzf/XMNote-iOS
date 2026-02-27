# 热力图顶部日期 overflow 防重叠绘制-Compose到SwiftUI迁移总结

## 1. 本次变更结论
- 不再使用 `minimumScaleFactor` 缩小字体“硬塞”进列宽。
- 顶部日期改为 Android `HistoryChart` 同步策略：`month/year token + headerOverflow 叠加衰减`。
- 左侧补齐列使用真实日期周列，因此无活动数据的方格列也能参与月份/年份交接判断。

## 2. iOS 知识点（SwiftUI）
- `HStack` 单列文本布局不适合长标签防重叠：会被列宽约束，最终只能依赖缩放或裁剪。
- 更稳妥方案是“数据先行”：
  - 先把标签转换成 `Token(text, x)`；
  - 再在 `ZStack(alignment: .leading)` 里按绝对 `x` 绘制。
- 文本宽度可用 `NSString.size(withAttributes:)` + `UIFont` 预估，用于 overflow 计算。
- 对齐原则：顶部行与网格行共享同一列进位 `columnAdvance = squareSize + squareSpacing`，避免视觉漂移。

## 3. Android Compose 对照思路
- Android 旧实现（Canvas）是：
  - 先判断月变化，再判断年变化；
  - 绘制后 `headerOverflow += textWidth + columnWidth * 0.2f`；
  - 每列结束后 `headerOverflow = max(0f, headerOverflow - columnWidth)`。
- Compose/SwiftUI 的迁移关键不是 API 一一对应，而是保留“先算 token，再绘制”的时序与状态机。

## 4. 可运行代码片段

### 4.1 SwiftUI（核心算法）
```swift
import SwiftUI
import UIKit

struct HeaderToken: Identifiable {
    let id: String
    let text: String
    let x: CGFloat
}

func buildHeaderTokens(weekStartDates: [Date], calendar: Calendar) -> [HeaderToken] {
    var tokens: [HeaderToken] = []
    var previousMonth = ""
    var previousYear = ""
    var overflow: CGFloat = 0
    let columnAdvance: CGFloat = 16   // squareSize + spacing
    let font = UIFont.systemFont(ofSize: 9)

    for (index, date) in weekStartDates.enumerated() {
        let month = "\(calendar.component(.month, from: date))月"
        let year = String(calendar.component(.year, from: date))
        var text: String?

        if month != previousMonth {
            previousMonth = month
            text = month
        } else if year != previousYear {
            previousYear = year
            text = year
        }

        if let text {
            let x = CGFloat(index) * columnAdvance + overflow
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            tokens.append(.init(id: "\(index)-\(text)", text: text, x: x))
            overflow += textWidth + columnAdvance * 0.2
        }
        overflow = max(0, overflow - columnAdvance)
    }
    return tokens
}
```

### 4.2 Compose（同构思路）
```kotlin
@Immutable data class HeaderToken(val id: String, val text: String, val x: Float)

fun buildHeaderTokens(
    weekStartDates: List<LocalDate>,
    textMeasurer: (String) -> Float,
    columnAdvance: Float
): List<HeaderToken> {
    val tokens = mutableListOf<HeaderToken>()
    var previousMonth = ""
    var previousYear = ""
    var overflow = 0f

    weekStartDates.forEachIndexed { index, date ->
        val month = "${date.monthValue}月"
        val year = date.year.toString()
        val text = when {
            month != previousMonth -> {
                previousMonth = month
                month
            }
            year != previousYear -> {
                previousYear = year
                year
            }
            else -> null
        }

        if (text != null) {
            val x = index * columnAdvance + overflow
            val width = textMeasurer(text)
            tokens += HeaderToken("$index-$text", text, x)
            overflow += width + columnAdvance * 0.2f
        }
        overflow = max(0f, overflow - columnAdvance)
    }
    return tokens
}
```

## 5. 第一性原理复盘
- 问题本质不是“字太长”，而是“标签密度 > 列进位承载能力”。
- 正确解法应控制“绘制时序与空间分配”（overflow），而不是牺牲可读性（缩小字体）。
