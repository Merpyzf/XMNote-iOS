# 书摘回顾卡组动效与内容可见性 - Compose 到 SwiftUI 迁移总结

## 1. 场景
Android 书摘回顾使用 `CardStackLayoutManager + Adapter` 形成堆叠卡片。iOS 迁移时不能只翻译控件，需要重建两个事实：
- 卡片切换是连续视觉流程，不能在 handoff 时重建成另一套静止视图。
- 后层卡片可以渲染内容，但露出的区域必须由几何约束控制，不能让正文或 footer 进入静止露出范围。

## 2. SwiftUI 关键做法
- 将动效计算从 View 中拆到 `NoteReviewPagingMotionSpec`，用纯函数输出 transform、zIndex、content visibility。
- 使用 `NoteReviewPagingVisualSession` 固定 source identity，避免 selection 提前写回导致 PageView 重建。
- 使用 `.preview` content visibility，让后层卡正文与 footer 可见但不可读、不可点。
- 对旋转后的卡片计算 AABB，再 clamp offset 和 rotation，保证后层露出仍停留在纸面边缘。

## 3. Compose 开发者迁移提示
在 Compose 中常见做法是把 `graphicsLayer`、`zIndex` 和 `alpha` 直接挂在 item 上；迁移到 SwiftUI 时，要格外注意：
- `zIndex` 变化会触发布局树重新排序，和 selection 更新叠加时容易造成视觉硬切。
- SwiftUI 的状态提交可能比动画视觉完成更早，需要显式分出“视觉会话”和“业务 selection”。
- 后层内容的可访问性需要单独处理，不能只依赖透明度。

## 4. 最小示例
```swift
struct CardMotion {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat
    let zIndex: Double
    let contentOpacity: Double
    let isReadable: Bool
}

func contentVisibility(progress: CGFloat, isTarget: Bool) -> (opacity: Double, readable: Bool) {
    if isTarget {
        return (opacity: progress > 0.12 ? 1 : 0.4, readable: progress > 0.7)
    }
    return (opacity: 1, readable: progress < 0.7)
}
```

## 5. 经验结论
- 卡组类交互不要把“当前选中项”同时当作“当前动画 source”。两者生命周期不同。
- 露字问题优先用几何约束解决；隐藏内容会制造新的 handoff 问题。
- 屏幕交互卡与导出分享图应分离，避免一个尺寸需求牵连另一个渲染目标。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
