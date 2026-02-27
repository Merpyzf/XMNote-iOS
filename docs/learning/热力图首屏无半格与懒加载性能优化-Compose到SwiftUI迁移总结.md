# 热力图首屏无半格与懒加载性能优化（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- `LazyHStack` 适合超长时间轴：仅创建可见区附近子视图，显著降低首屏与滚动压力。
- 首页“左侧半格裁切”不是 padding 问题，而是 `viewportWidth` 与网格列宽不整除导致的裁切问题。
- 正确做法是“容器宽度反算方格尺寸”：给定可见列数与间距，动态求 `squareSize`，让可见区恰好容纳整数列。
- 组件应提供可配置入口（如 `fitsViewportWithoutClipping`、`minSquareSize`、`maxSquareSize`），让业务可调而非改源码。

## 2. Compose -> SwiftUI 思维映射
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 长列表性能 | `LazyRow` | `ScrollView(.horizontal) + LazyHStack` | 先控制创建数量，再谈局部优化 |
| 避免首屏半格 | `BoxWithConstraints` 里按宽度反算格子尺寸 | 根据 `gridViewportWidth` 反算 `squareSize` | 用数学约束替代视觉补丁 |
| 保持样式可调 | `data class ChartStyle` | `HeatmapChartStyle` 新增防裁切参数 | 能配置就不硬编码 |

## 3. 可运行示例

### 3.1 Android Compose（可运行）
```kotlin
@Composable
fun HeatmapRow(
    modifier: Modifier = Modifier,
    preferredCellDp: Dp = 16.dp,
    spacingDp: Dp = 3.dp
) {
    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val widthPx = constraints.maxWidth.toFloat()
        val spacingPx = with(LocalDensity.current) { spacingDp.toPx() }
        val preferredPx = with(LocalDensity.current) { preferredCellDp.toPx() }
        val count = max(1, floor((widthPx + spacingPx) / (preferredPx + spacingPx)).toInt())
        val cellPx = (widthPx - (count - 1) * spacingPx) / count
        val cellDp = with(LocalDensity.current) { cellPx.toDp() }

        LazyRow(horizontalArrangement = Arrangement.spacedBy(spacingDp)) {
            items(3000) {
                Box(
                    Modifier
                        .size(cellDp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(Color(0xFF2ECF77))
                )
            }
        }
    }
}
```

### 3.2 SwiftUI（可运行）
```swift
import SwiftUI

private struct GridMetrics {
    let cell: CGFloat
    let count: Int
}

private func resolveMetrics(width: CGFloat, preferred: CGFloat, spacing: CGFloat) -> GridMetrics {
    let count = max(Int(floor((width + spacing) / (preferred + spacing))), 1)
    let cell = max((width - CGFloat(count - 1) * spacing) / CGFloat(count), 1)
    return GridMetrics(cell: cell, count: count)
}

struct HeatmapRowDemo: View {
    @State private var width: CGFloat = 0
    private let spacing: CGFloat = 3

    var body: some View {
        let metrics = resolveMetrics(width: max(width, 1), preferred: 16, spacing: spacing)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(0..<3000, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green)
                        .frame(width: metrics.cell, height: metrics.cell)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
```

## 4. 迁移结论
- Android 端没有“左侧半格”并非平台特性，而是布局数学约束正确导致的结果。
- iOS 端只要使用同样的“反算尺寸 + 懒加载”策略，就能在保持沉浸感的同时解决性能与裁切两个问题。
