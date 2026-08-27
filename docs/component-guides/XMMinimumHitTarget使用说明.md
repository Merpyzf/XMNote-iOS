# XMMinimumHitTarget 使用说明

`XMMinimumHitTarget` 是默认 44pt 点击热区基线下的紧凑控件交互基础设施。它把需要满足基线的控件命中与可访问性轮廓补足到 `44pt × 44pt`，不改变控件的 `frame`、约束、间距、背景或实际绘制尺寸；它不是要求所有可点击文字都机械扩展到 44pt 的全局修饰器。

- SwiftUI：`xmnote/UIComponents/Controls/Button/XMMinimumHitTarget.swift`
- UIKit：`xmnote/UIComponents/Controls/Button/XMMinimumHitTargetButton.swift`
- 唯一尺寸令牌：`xmnote/Utilities/DesignSystem/InteractionMetrics.swift`

## 接入判断

以下场景必须达到 `InteractionMetrics.minimumTouchTarget`：

- 主操作、导航与关闭。
- 破坏性或不可逆操作。
- 频繁或连续交互。
- 独立图标按钮和表单控件。

只有副标题、状态、元数据等以信息展示为主的内联次级文字，同时满足低频、非破坏性且不是完成主任务的必要入口时，才允许保留小于 44pt 的文字自然命中范围。“低频”本身不能构成例外，独立按钮、图标和主要操作不得借此缩小。

内联例外仍须使用 `Button`、`NavigationLink` 等原生语义控件并保留 VoiceOver label/value/hint，禁止改成 `onTapGesture`。调用处相邻注释必须写明业务角色、低频与非破坏性依据及不扩展命中范围的原因，并通过文字内/外 A/B 点击确认不会让周围空白或邻近控件误响应。

例外不新增更小的全局点击尺寸 token，也不修改 `InteractionMetrics.minimumTouchTarget`。

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

系统导航栏按钮、已经提供合规目标的系统控件或符合上述内联例外的次级文字无需重复扩展。使用前应先确认业务角色和真实命中范围，而不是仅根据图标或文字大小判断。

符合内联例外时保留原生控件与自然命中范围：

```swift
// 该文本以副标题信息展示为主，管理入口低频且非破坏性；保留文字自然命中范围，避免标题栏空白响应点击。
Button("已选择 3 本", action: onOpenSelection)
    .buttonStyle(.plain)
    .accessibilityLabel("已选择 3 本书")
    .accessibilityHint("查看并管理已选书籍")
```

## 常见问题

### 所有小于 44pt 的可点击内容都必须接入吗？

不是。先按“接入判断”确定业务角色。主要、独立、高频、破坏性或任务必要入口仍执行 44pt 基线；只有满足全部条件并完成注释、可访问性与命中歧义验证的内联次级文字可以保留自然范围。不要为了消除单点视觉间距而把整片标题栏变成点击区域。

### 为什么不用 `.frame(minWidth: 44, minHeight: 44)`？

因为 `frame` 会参与布局，可能改变对齐、间距、背景和点击控件的视觉占位。本基础设施使用 SwiftUI 的 interaction `contentShape` 或 UIKit 的 `point(inside:with:)`，只改变交互判定。

### 为什么扩展后仍可能点不到？

命中测试仍受祖先视图边界、裁剪、层级与手势竞争影响。祖先拒绝超出边界的点时，应调整锚点或容器结构；不能用视觉 padding 伪装修复。

### 相邻小按钮都扩展到 44pt 可以吗？

必须检查扩展区域是否重叠。重叠会造成目标歧义，应优先增加真实间距、调整锚点或采用系统控件布局。

### 这会放大图标、背景或高亮效果吗？

不会。组件不产生可见绘制，也不修改视觉 `bounds`。如果界面发生视觉变化，说明调用处还叠加了参与布局或绘制的修饰器，应单独排查。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
