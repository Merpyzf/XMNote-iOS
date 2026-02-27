# 热力图右边缘贴齐与标签不撑宽总结（Android Compose → SwiftUI）

## 1. 问题与根因
- 现象：热力图网格右边缘没有贴齐卡片右边缘，右侧出现明显空白。
- 根因：顶部月份标签行在 SwiftUI 中使用了 `.fixedSize()`，但没有把“每列宽度”钉死。标签文本（如 `2026年2月`）会撑宽标签行，导致“标签行总宽 > 方格行总宽”，视觉上就像网格右侧缺了一截。

## 2. iOS 迁移知识点
- `.fixedSize()` 的作用是保持文本理想尺寸，不被父布局压缩；它并不会自动遵守你想象中的“列宽”。
- 如果希望“文本可溢出显示、但不参与列宽计算”，应采用：
  - 固定列宽容器（例如 `Color.clear.frame(width: squareSize)`）
  - 在容器上 `overlay(alignment: .leading)` 叠加文本
- 布局诊断建议：
  - 记录 `viewportWidth / minVisibleWeekCount / paddingCount`
  - 记录 `headerRowWidth` 与 `gridRowWidth` 的差值，直接验证“谁在撑宽”。

## 3. Android Compose 对照思路
- Compose 下同样要避免“表头文本参与列宽计算”。
- 方式：外层先固定列宽，再用 `Box` 的 `wrapContentWidth(unbounded = true)` 让文本向右自然溢出显示，但不改变列宽。

## 4. SwiftUI 可运行示例
```swift
import SwiftUI

struct HeaderCellOverlayDemo: View {
    let squareSize: CGFloat = 13
    let labels: [String?] = [nil, "2月", nil, nil, "2026年3月", nil]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(labels.indices, id: \.self) { i in
                Color.clear
                    .frame(width: squareSize, height: 16)
                    .overlay(alignment: .leading) {
                        if let text = labels[i] {
                            Text(text)
                                .font(.system(size: 9))
                                .fixedSize()
                        }
                    }
            }
        }
        .border(.green)
    }
}
```

## 5. Compose 可运行示例
```kotlin
@Composable
fun HeaderCellOverlayDemo() {
    val square = 13.dp
    val labels = listOf<String?>(null, "2月", null, null, "2026年3月", null)

    Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        labels.forEach { text ->
            Box(
                modifier = Modifier
                    .width(square)
                    .height(16.dp),
                contentAlignment = Alignment.CenterStart
            ) {
                if (text != null) {
                    Text(
                        text = text,
                        fontSize = 9.sp,
                        maxLines = 1,
                        modifier = Modifier.wrapContentWidth(unbounded = true)
                    )
                }
            }
        }
    }
}
```

## 6. 迁移结论
- “列宽”与“文本展示”必须解耦：列宽固定，文本可溢出。
- 诊断布局时优先记录“同层关键行宽差值”，比纯视觉猜测更快定位问题。
