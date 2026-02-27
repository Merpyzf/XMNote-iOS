# 热力图头部标签与周列宽度对齐总结（Android Compose → SwiftUI）

## 1. 本次问题与对齐目标
- 问题 1：周标签列使用固定宽度，导致在部分布局中占比过大。
- 问题 2：顶部日期每个月都显示 `yyyy-M`，与 Android 的“月份为主、跨年补年”策略不一致。
- 对齐目标：
  - 周标签列宽按文字实际宽度动态计算。
  - 顶部标签仅在月份切换列显示；同年显示月份，跨年显示 `yyyy-M`。
  - `scrollToMonth` 继续使用稳定锚点 `yyyy-M`，不与展示文案耦合。

## 2. iOS 知识点（SwiftUI）
- 文本测量：SwiftUI 的 `Text` 不直接暴露测量 API；工程中可通过 `UIFont + NSString.size(withAttributes:)` 计算文本宽度，再喂给 `.frame(width:)`。
- 展示文案与行为 ID 解耦：
  - 展示文案用于视觉（如 `2月` / `2026-1`）。
  - 行为 ID 用于滚动定位（固定 `yyyy-M`）。
  - 两者分离后，UI 调整不会破坏 `scrollToMonth` 协议。
- 周列热力图常见结构：`HStack(ScrollView + 固定右侧标签)`，右侧标签与滚动内容平级，天然不跟随横向滚动。

## 3. Android Compose 对照思路
- Compose 中可用 `rememberTextMeasurer()` 动态测量周标签最大宽度。
- 顶部标签推荐抽离纯函数：输入当前周首日与前一周首日，输出可选标签文本。
- 同样保持“显示文本”和“滚动 key（yyyy-M）”分离，避免 UI 文案变更导致 `LazyListState` 定位失效。

## 4. SwiftUI 可运行示例
```swift
import SwiftUI
import UIKit

struct HeaderLabelRuleDemo: View {
    let calendar = Calendar.current
    let weeks: [Date] // 每周首日

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, day in
                Text(labelText(day, previous: index > 0 ? weeks[index - 1] : nil) ?? "")
                    .font(.system(size: 12))
                    .frame(height: 16)
            }
        }
    }

    func labelText(_ day: Date, previous: Date?) -> String? {
        guard let previous else { return monthKey(day) }
        let monthChanged = calendar.component(.month, from: day) != calendar.component(.month, from: previous)
        let yearChanged = calendar.component(.year, from: day) != calendar.component(.year, from: previous)
        guard monthChanged else { return nil }
        return yearChanged ? monthKey(day) : monthText(day)
    }

    func monthText(_ date: Date) -> String {
        let m = calendar.component(.month, from: date)
        return "\(m)月"
    }

    func monthKey(_ date: Date) -> String {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        return "\(y)-\(m)"
    }
}

func weekdayLabelWidth(labels: [String], fontSize: CGFloat = 9) -> CGFloat {
    let font = UIFont.systemFont(ofSize: fontSize)
    let maxWidth = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    return ceil(maxWidth + 2)
}
```

## 5. Compose 可运行示例
```kotlin
@Composable
fun WeekdayColumn(labels: List<String>) {
    val textMeasurer = rememberTextMeasurer()
    val textStyle = TextStyle(fontSize = 9.sp)
    val width = remember(labels) {
        labels.maxOfOrNull { textMeasurer.measure(it, style = textStyle).size.width } ?: 0
    }

    Column(modifier = Modifier.width(with(LocalDensity.current) { (width + 2).toDp() })) {
        labels.forEach { label ->
            Text(text = label, style = textStyle)
        }
    }
}

fun headerLabelText(curr: LocalDate, prev: LocalDate?): String? {
    if (prev == null) return "${curr.year}-${curr.monthValue}"
    val monthChanged = curr.monthValue != prev.monthValue || curr.year != prev.year
    if (!monthChanged) return null
    return if (curr.year != prev.year) "${curr.year}-${curr.monthValue}" else "${curr.monthValue}月"
}
```

## 6. 迁移避坑清单
- 不要把“显示格式”直接当“滚动锚点 ID”。
- 不要给周标签列写死较大常量宽度；必须跟字号联动。
- 不要把“跨年显示年份”误实现成“每月都显示年份”。
