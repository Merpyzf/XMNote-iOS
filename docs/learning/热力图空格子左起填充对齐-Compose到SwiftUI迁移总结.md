# 热力图空格子左起填充对齐总结（Android Compose → SwiftUI）

## 1. 问题与目标
- 问题：iOS 在仅有少量周数据（如单月）时，热力图内容在容器内居中。
- Android 对齐目标：热力图应从左到右连续填充，数据不足时在右侧补空格子。

## 2. Android 侧实现要点
- `HistoryChart` 先根据容器宽度计算可视列数 `nColumns`，再按 `nColumns` 固定绘制。
- 当数据不足时，超出数据范围的格子使用默认空色绘制，不会出现大块空白导致居中视觉。

## 3. iOS 迁移关键点
- 从“数据驱动列数”改为“容器宽度驱动最小列数”。
- 真实周列不足时，在右侧追加 padding 列。
- 顶部月份标签与 `scrollToMonth` 锚点只绑定真实列，padding 列只做占位。

## 4. SwiftUI 可运行示例
```swift
import SwiftUI

struct HeatmapFillDemo: View {
    let realWeeks: Int
    let columnWidth: CGFloat = 13
    let spacing: CGFloat = 3

    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(0..<displayCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < realWeeks ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: columnWidth, height: columnWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in viewportWidth = newValue }
            }
        }
    }

    var displayCount: Int {
        guard viewportWidth > 0 else { return realWeeks }
        let minVisible = max(Int((viewportWidth + spacing) / (columnWidth + spacing)), 1)
        return max(realWeeks, minVisible)
    }
}
```

## 5. Compose 对照示例
```kotlin
@Composable
fun HeatmapFillDemo(realWeeks: Int) {
    val columnWidth = 13.dp
    val spacing = 3.dp

    BoxWithConstraints {
        val minVisible = max(
            ((maxWidth + spacing) / (columnWidth + spacing)).toInt(),
            1
        )
        val displayCount = max(realWeeks, minVisible)

        Row(horizontalArrangement = Arrangement.spacedBy(spacing)) {
            repeat(displayCount) { index ->
                Box(
                    Modifier
                        .size(columnWidth)
                        .clip(RoundedCornerShape(2.dp))
                        .background(if (index < realWeeks) Color(0xFF4CAF50) else Color(0xFFE0E0E0))
                )
            }
        }
    }
}
```

## 6. 迁移避坑
- 仅靠 `frame(maxWidth: .infinity, alignment: .leading)` 不能等价 Android 的“空格子补齐”。
- `scrollToMonth` 锚点不要挂在 padding 列上，否则会引入无效滚动目标。
- padding 列建议使用可见空色，不要用透明色，否则视觉会像“未填充”。
