# XMMinimumHitTarget 使用说明

`XMMinimumHitTarget` 是紧凑视觉控件的交互基础设施。它只把命中与可访问性轮廓补足到设计系统规定的最小 `44pt × 44pt`，不改变控件的 `frame`、约束、间距、背景或实际绘制尺寸。

- SwiftUI：`xmnote/UIComponents/Controls/Button/XMMinimumHitTarget.swift`
- UIKit：`xmnote/UIComponents/Controls/Button/XMMinimumHitTargetButton.swift`
- 唯一尺寸令牌：`xmnote/Utilities/DesignSystem/InteractionMetrics.swift`

## 快速接入

SwiftUI 中，先使用 `Button`、`Toggle` 或 `NavigationLink` 表达交互语义，再把修饰器加在负责接收点击的控件上：

```swift
Button(action: onClose) {
    Image(systemName: "xmark")
        .frame(width: 24, height: 24)
}
.xmMinimumHitTarget(anchor: .topTrailing)
```

UIKit 中，仅在确实需要小于 44pt 的视觉按钮时使用 `XMMinimumHitTargetButton`；Auto Layout 仍按真实视觉尺寸约束：

```swift
let button = XMMinimumHitTargetButton(type: .system)
button.hitTargetAnchor = .trailing
```

## 参数说明

- `anchor`：决定额外命中区域向哪个方向展开。默认 `.center`；边缘控件应选择对应的语义锚点，避免把热区主要扩到父容器外。
- `InteractionMetrics.minimumTouchTarget`：最小触控目标的唯一 owner，当前为 `44pt`。业务代码不得复制这个数字建立第二套规则。
- `minimumHitTargetSize`：UIKit 的可测试覆盖点，默认取共享令牌；只允许针对平台或容器事实做局部调整。
- `hitTargetAnchor`：UIKit 对应的方向配置，自动遵守从右到左布局。

## 示例

视觉为 `24pt × 24pt` 的关闭图标应用修饰器后，布局和截图仍是 `24pt × 24pt`，但中心外侧、44pt 轮廓以内的坐标可以命中。设计系统展厅提供默认命中与扩展命中的 A/B 场景；`DesignSystemInfrastructureTests` 同时验证 SwiftUI 计算矩形、RTL 锚点、UIKit `bounds` 不变与命中范围扩展。

系统导航栏按钮、标准 `Button` 或其他已经提供合规目标的系统控件无需重复扩展。使用前应先确认真实命中范围，而不是仅根据图标大小判断。

## 常见问题

### 为什么不用 `.frame(minWidth: 44, minHeight: 44)`？

因为 `frame` 会参与布局，可能改变对齐、间距、背景和点击控件的视觉占位。本基础设施使用 SwiftUI 的 interaction `contentShape` 或 UIKit 的 `point(inside:with:)`，只改变交互判定。

### 为什么扩展后仍可能点不到？

命中测试仍受祖先视图边界、裁剪、层级与手势竞争影响。祖先拒绝超出边界的点时，应调整锚点或容器结构；不能用视觉 padding 伪装修复。

### 相邻小按钮都扩展到 44pt 可以吗？

必须检查扩展区域是否重叠。重叠会造成目标歧义，应优先增加真实间距、调整锚点或采用系统控件布局。

### 这会放大图标、背景或高亮效果吗？

不会。组件不产生可见绘制，也不修改视觉 `bounds`。如果界面发生视觉变化，说明调用处还叠加了参与布局或绘制的修饰器，应单独排查。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
