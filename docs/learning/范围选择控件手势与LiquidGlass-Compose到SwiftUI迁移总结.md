# 范围选择控件手势与 Liquid Glass - Compose 到 SwiftUI 迁移总结

更新日期：2026-06-08

## 背景

本轮围绕搜索范围切换控件推进：最初三枚平铺圆形按钮视觉上像临时实现，缺少 Apple 平台独立产品应有的统一控件语义、跟手拖拽和 iOS 26 Liquid Glass 边界。后续 `XMScopeSelector` 在测试中心验证中暴露两个关键问题：拖拽事件被分段 `Button` 抢占，以及玻璃效果套在复合层上时吞掉选中态。

## 核心结论

自定义 segmented 类控件要拆开三层 owner：

- 语义 owner：外部 `selection` 是唯一事实源，点击和拖拽都只能写它。
- 手势 owner：点击交给分段 `Button` 保持无障碍语义，横向拖拽交给整体胶囊，并通过高优先级手势接管拖动路径。
- 视觉 owner：Liquid Glass 只属于底层交互外壳，选中胶囊、标题和数量 badge 必须在玻璃上方保持可读。

## Android / Compose 视角

Compose 中类似控件通常会用 `Row`、`Box`、`Modifier.pointerInput` 和 `animate*AsState` 自行组织，开发者天然会把指示器、文字和手势分层：

```kotlin
Box(
    modifier = Modifier
        .clip(RoundedCornerShape(50))
        .pointerInput(items) {
            detectDragGestures { change, _ ->
                val index = resolveIndex(change.position.x)
                selection = items[index].id
            }
        }
) {
    Indicator(offset = animatedOffset)
    Row {
        items.forEach { item ->
            SegmentButton(item, selected = item.id == selection)
        }
    }
}
```

SwiftUI 迁移时不能把这直接机械翻译成“外层 `gesture` + 内层 `Button`”。SwiftUI 的手势优先级会影响真实触发路径：如果父级拖拽只是 `simultaneousGesture`，内层 `Button` 的命中和按压状态可能让拖拽无法稳定进入。当前项目用 `highPriorityGesture` 承接整体拖拽，再让 `DragGesture` 保持小距离触发，兼顾点击和横向拖动。

## SwiftUI 实践规则

- 原生控件能力不足时，自定义控件仍应以原生 segmented 为审美标尺：统一胶囊、等宽分段、克制选中面、44pt 最小热区。
- 分段内部保留 `Button`，不要为了拖拽把可访问性语义退化成裸 `Text` 或 `onTapGesture`。
- 跟手拖拽阶段用无动画事务更新 `selection` 和指示器位置；松手后再用 `.snappy` 吸附。
- Reduce Motion 开启时取消吸附滑动动画，但不要取消状态变化。
- `GlassEffectContainer` 和 `.glassEffect` 只应用到外壳底层；前景内容不要被玻璃采样、折射或模糊。
- 数量 badge 是从属 metadata，视觉上低于标题；如果 Dynamic Type 或 5 项长文案过于拥挤，应优先隐藏视觉 badge，并保留 VoiceOver 数量读法。

## 迁移核对清单

- 先确认语义：是否真的是同一内容集合内的互斥范围切换，而不是导航 tab、筛选菜单或多选标签。
- 找到真实 owner：selection、拖拽位置、选中指示器、玻璃背景分别由哪层控制。
- 找到真实写入点：点击当前项不能重复写入；点击其他项、拖拽跨分段、拖出边界都要走同一 selection 规则。
- 找到平台边界：SwiftUI `Button`、`DragGesture`、`highPriorityGesture` 的竞争关系要用最小实验和录屏验证。
- 验证可访问性：VoiceOver 应读出“书籍，18 项，已选中”，视觉 badge 不应重复朗读。
- 验证 iOS 26 玻璃：玻璃表达外壳质感，不覆盖前景文字、选中态和数量 metadata。
