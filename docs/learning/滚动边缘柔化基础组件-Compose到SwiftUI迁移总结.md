# 滚动边缘柔化基础组件 - Compose 到 SwiftUI 迁移总结

更新日期：2026-06-08

## 背景

全局搜索范围栏固定后，列表滚动到顶部时出现明显硬切边界。最初尝试使用 iOS 26 的 `safeAreaBar + scrollEdgeEffectStyle(.soft)`，但录屏验证后发现它会让内容进入范围选择器下方，再用系统 soft edge 弱化边界。这适合系统导航栏或 Sheet 顶部 chrome，不适合业务筛选控件。

本轮最终拆出两个基础能力：`XMScrollEdgeChrome` 负责固定边缘栏容器，`XMScrollEdgeWash` 负责滚动视口边缘柔化。这样既保留系统 chrome 路径，也避免把页面级补丁写成一次性遮罩。

## 核心结论

- 先区分滚动层级语义：业务筛选栏通常是 contained layout，列表不应该出现在控件背后。
- 系统 `scrollEdgeEffectStyle(.soft)` 是系统/Sheet chrome 的能力，不应强行套到普通业务筛选栏。
- 自定义边缘柔化层应是装饰能力：不拦截点击、不产生无障碍节点、不承载业务状态。
- `.automatic` 可见性只需要监听“顶部是否已滚离”和“底部是否仍可滚动”两个布尔值，不应该跟随每一帧 offset 重绘。

## Android / Compose 视角

Compose 里类似能力通常会以 `Modifier.drawWithContent` 或外层 `Box` overlay 实现：

```kotlin
Box {
    LazyColumn(state = listState) {
        items(results) { item ->
            ResultRow(item)
        }
    }

    if (listState.canScrollBackward) {
        Box(
            Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .height(24.dp)
                .background(
                    Brush.verticalGradient(
                        colors = listOf(surface, surface.copy(alpha = 0f))
                    )
                )
        )
    }
}
```

迁移到 SwiftUI 时不要机械追求每帧透明度同步。SwiftUI 的 `onScrollGeometryChange` 可以直接把滚动几何压缩成 `Equatable` 的布尔状态，减少重组和动画噪声。复杂背景下再考虑 mask 或 material，普通页面优先用语义 surface 渐隐。

## SwiftUI 实践规则

- 固定业务栏使用 `.contained`：栏参与布局，滚动内容从栏下方开始。
- 系统导航、系统 Sheet 顶部栏才使用 `.overlaySoft`：交给 `safeAreaBar` 和 `scrollEdgeEffectStyle(.soft)`。
- Wash 默认高度控制在 16-24pt；36pt 只用于测试或特殊大容器。
- Surface 必须匹配承托背景：页面用 `.page`，卡片内滚动用 `.card`，Sheet 用 `.sheet`。
- Wash 不提供点击拦截参数，防止业务页误用成半透明遮罩。
- 深色模式下优先保证内容干净，不用品牌色或强阴影增强边界。

## 迁移核对清单

- 确认边缘控件是否应该参与布局，还是允许内容进入其背后。
- 确认边缘效果是系统 chrome 语义还是业务滚动视口语义。
- 检查静止顶部是否没有发灰、发脏或遮挡首项内容。
- 检查滚动后边界是否柔和，但不影响正文可读性。
- 检查 overlay 是否 `allowsHitTesting(false)` 且 `accessibilityHidden(true)`。
- 检查滚动状态监听是否只写必要布尔值，避免每帧 offset 驱动重绘。
