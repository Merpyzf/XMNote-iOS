# 热力图每列月份全显防重叠与右侧间距总结（Android Compose → SwiftUI）

## 1. 问题与目标
- 问题 1：月份标签只在月份切换列显示，信息密度不足。
- 问题 2：月份标签在窄列中发生重叠。
- 问题 3：网格与右侧星期列紧贴，层次不清。
- 目标：
  - 每列显示月份；
  - 仅跨年列附带年份；
  - 文本不重叠；
  - 网格与星期列保持明确间距。

## 2. iOS 关键知识点
- 在 SwiftUI 中，`fixedSize()` 会让文本坚持理想宽度，容易在窄列出现越界重叠。
- “窄列文本不重叠”的核心做法：
  - 给文本明确列宽（`frame(width:)`）；
  - 限制单行（`lineLimit(1)`）；
  - 允许缩放（`minimumScaleFactor`）；
  - 允许字符紧缩（`allowsTightening(true)`）。
- 相邻区域结构分离建议使用显式 `HStack` 间距常量，避免“贴边感”。

## 3. Android Compose 对照思路
- Compose 等价方案：
  - `Text(maxLines = 1, softWrap = false)`
  - `Modifier.width(fixedDp)`
  - `overflow = TextOverflow.Clip` 或 `Ellipsis`
  - 需要保留信息时用 `BasicText` + `TextStyle` 缩放策略。

## 4. SwiftUI 可运行示例
```swift
import SwiftUI

struct MonthHeaderColumnDemo: View {
    let labels = ["12月", "26年1月", "1月", "1月", "1月"]
    let columnWidth: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.2)
                        .allowsTightening(true)
                        .frame(width: columnWidth)
                }
            }
            Text("一\n三\n五")
                .font(.system(size: 9))
        }
    }
}
```

## 5. Compose 可运行示例
```kotlin
@Composable
fun MonthHeaderColumnDemo() {
    val labels = listOf("12月", "26年1月", "1月", "1月", "1月")

    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            labels.forEach { label ->
                Text(
                    text = label,
                    fontSize = 9.sp,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                    modifier = Modifier.width(13.dp)
                )
            }
        }
        Text(text = "一\n三\n五", fontSize = 9.sp)
    }
}
```

## 6. 迁移结论
- “每列都显示信息”与“绝不重叠”可同时达成，关键在于文本必须服从列宽约束。
- 视觉层级靠明确间距而不是透明占位来表达更稳健。
