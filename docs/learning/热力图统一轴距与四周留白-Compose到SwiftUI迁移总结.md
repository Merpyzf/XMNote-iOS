# 热力图统一轴距与四周留白-Compose到SwiftUI迁移总结

## 1. 本次结论
- 把“顶部日期到方格”的距离与“右侧星期到方格”的距离统一为同一个设计令牌：`axisGap = 8pt`。
- 组件四周外边距统一为 `outerInset = 8pt`，避免上下左右节奏不一致。
- 顶部日期区不再用固定魔法高度，而是 `headerTextLineHeight + axisGap`。

## 2. iOS 知识点（SwiftUI）
- `HStack(spacing:)` 控制的是列间关系，适合右侧星期与网格的统一轴距。
- 顶部日期区若想与右侧保持同一间距，应把日期区拆成两层：
  - 文本行高度（`headerTextLineHeight`）
  - 与方格的轴距（`axisGap`）
- 组件级 `.padding(outerInset)` 比散落在子视图的多处 `padding(.vertical)` 更稳定，维护成本更低。

## 3. 面向 Compose 开发者的对照思路
- Compose 常见写法是通过 `Arrangement.spacedBy(...)` + `Modifier.padding(...)` 统一节奏。
- SwiftUI 对应关系：
  - `Arrangement.spacedBy(8.dp)` ≈ `HStack(spacing: 8)`
  - `Modifier.padding(8.dp)` ≈ `.padding(8)`
- 原则一致：先定义“空间令牌”，再让顶部轴和右侧轴都引用同一令牌。

## 4. 可运行代码片段

### SwiftUI
```swift
import SwiftUI
import UIKit

private enum SpacingToken {
    static let axisGap: CGFloat = 8
    static let outerInset: CGFloat = 8
    static let textSize: CGFloat = 9
    static let textLineHeight: CGFloat = ceil(UIFont.systemFont(ofSize: textSize).lineHeight)
}

struct HeatmapFrameDemo: View {
    var body: some View {
        HStack(alignment: .top, spacing: SpacingToken.axisGap) {
            VStack(spacing: 0) {
                Color.clear.frame(height: SpacingToken.textLineHeight) // 顶部日期文本行
                Color.clear.frame(height: SpacingToken.axisGap)        // 顶部到方格统一轴距
                Rectangle().frame(width: 120, height: 80)
            }
            VStack(spacing: 0) {
                Color.clear.frame(height: SpacingToken.textLineHeight + SpacingToken.axisGap)
                Rectangle().frame(width: 20, height: 80) // 右侧星期列
            }
        }
        .padding(SpacingToken.outerInset)
    }
}
```

### Compose
```kotlin
@Composable
fun HeatmapFrameDemo() {
    val axisGap = 8.dp
    val outerInset = 8.dp
    val textLineHeight = 11.dp

    Row(
        modifier = Modifier.padding(outerInset),
        horizontalArrangement = Arrangement.spacedBy(axisGap),
        verticalAlignment = Alignment.Top
    ) {
        Column {
            Spacer(Modifier.height(textLineHeight))
            Spacer(Modifier.height(axisGap))
            Box(Modifier.size(width = 120.dp, height = 80.dp))
        }
        Column {
            Spacer(Modifier.height(textLineHeight + axisGap))
            Box(Modifier.size(width = 20.dp, height = 80.dp))
        }
    }
}
```

## 5. 第一性原理复盘
- 视觉问题的根因是“间距语义不统一”，不是某个单独数值不对。
- 先定义统一空间语义（轴距、外边距），再把所有相关布局绑定到语义令牌，才能长期稳定。
