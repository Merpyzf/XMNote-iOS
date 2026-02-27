# 热力图像素对齐防圆角裁切（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- “左侧圆角被裁切”常见根因是亚像素布局：方格尺寸或容器宽度落在 0.5px 等非像素网格上。
- SwiftUI 可通过 `@Environment(\.displayScale)` 获取屏幕 scale，并把关键尺寸做像素下取整（`floor(value * scale) / scale`）。
- 对热力图这类密集网格，优先保证“单格边长 + 行总宽”都落在像素网格，视觉比硬加 padding 更稳定。
- Debug 日志要同时输出 `rawSquareSize` 与 `resolvedSquareSize`，便于确认是“数学尺寸”还是“像素对齐尺寸”导致差异。

## 2. Compose -> SwiftUI 思维映射
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 像素对齐 | `with(LocalDensity.current)` 转 px 后再 round/floor | `displayScale` + `floor(value * scale) / scale` | 统一在像素网格做最终布局 |
| 避免边缘裁切 | 容器宽度与 cell 尺寸同尺度计算 | 视口宽度和 `squareSize` 都做 snap | 先消除亚像素，再谈视觉补丁 |
| 调试定位 | 输出 px 值与布局差值 | 输出 `rowWidth - viewportWidth` | 让问题可量化 |

## 3. 可运行示例（SwiftUI）
```swift
import SwiftUI

struct PixelSnapDemoView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0

    private func snapDown(_ value: CGFloat) -> CGFloat {
        guard displayScale > 0 else { return value }
        return floor(value * displayScale) / displayScale
    }

    var body: some View {
        let snappedWidth = snapDown(width)
        let spacing: CGFloat = 3
        let count = 18
        let rawCell = (max(snappedWidth, 1) - CGFloat(count - 1) * spacing) / CGFloat(count)
        let cell = snapDown(rawCell)

        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.green)
                        .frame(width: cell, height: cell)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
```

## 4. 迁移结论
- Android 端“看起来没问题”往往是因为布局天然跑在像素网格；iOS 若直接使用浮点反算尺寸，边缘更容易暴露裁切。
- 在 SwiftUI 热力图中，`LazyHStack + 反算尺寸 + 像素对齐` 是同时解决性能与边缘裁切的稳定组合。
