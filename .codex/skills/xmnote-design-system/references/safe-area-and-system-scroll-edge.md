# 安全区与系统滚动边缘

本参考规定内容延伸至上下安全区时，如何让系统导航栏、工具栏、`safeAreaBar` 与 Tab Bar 使用可追踪的原生渐进模糊。它只处理真实滚动内容与固定系统控件之间的关系，不授权添加装饰性模糊、渐变或材质层。

## 先判断场景

| 场景 | 首选实现 | 禁止替代 |
| --- | --- | --- |
| 系统 Navigation Bar、Toolbar 或 Tab Bar 覆盖真实滚动内容 | SwiftUI 原生安全区延伸与 `.scrollEdgeEffectStyle(.soft)`；UIKit 登记真实滚动 owner | 自绘 blur、gradient、material、mask 或 `UIVisualEffectView` |
| 自定义固定顶部或底部操作栏 | `safeAreaBar`；需要统一双栏骨架时查询 `XMScrollEdgeChrome.overlaySoft` | 用 `overlay` 模拟系统栏，或手写固定安全区高度 |
| 卡片、筛选器等局部非系统滚动视口 | 查询 `XMScrollEdgeWash` | 把 Wash 放在系统 Navigation Bar、Toolbar 或 Tab Bar 下方 |
| 静态内容或没有真实滚动关系 | 不添加滚动边缘效果 | 为制造“沉浸感”伪造渐进模糊 |

系统边缘与局部 Wash 是两套互斥语义：前者由操作系统表达滚动内容和固定控件的层级；后者只在封闭局部视口中柔化内容裁切边界。

## 共同不变量

- 内容延伸必须作用于真实 `ScrollView/List/Form`、真实 `UIScrollView`，或直接承载该 UIKit 滚动视图的 `UIViewRepresentable`。仅让页面背景忽略安全区不构成沉浸式内容。
- 只延伸实际存在系统 chrome 的 `.container` 顶部、底部或两者；不使用无参数 `.ignoresSafeArea()`，不忽略键盘安全区。
- 内容状态下的主滚动容器保持页面根内容的直接滚动主体。无必要的外层 `VStack`、第二层 `ScrollView` 或透明覆盖层会隔断系统识别，应先消除结构问题。
- 新增或修改的系统滚动边缘统一使用 `.soft`。`.automatic` 仅允许未进入当前修改范围的历史页面继续保留；`.hard` 不作为 XMNote 系统边缘选项。
- 第一项和最后一项必须依赖系统调整后的安全区保持可达，不叠加固定高度 spacer、设备常量或重复 safe-area padding。
- 保持有效轴回弹；不得为稳定边缘效果关闭 bounce。
- Reduce Motion 不要求移除系统静态模糊。Reduce Transparency 下接受系统自己的可访问性降级，不叠加自定义替代层。

## SwiftUI

### 系统导航栏或 Tab Bar

将修饰器放在真实滚动容器上：

```swift
ScrollView {
    content
}
.ignoresSafeArea(.container, edges: activeEdges)
.scrollEdgeEffectStyle(.soft, for: activeEdges)
```

- `activeEdges` 只包含当前页面实际需要进入的顶部或底部系统区域。
- 背景可以独立使用 `Color.surfacePage.ignoresSafeArea()`，但它不替代滚动容器上的内容延伸。
- 不在外层容器和滚动容器上重复声明相同安全区策略。

### 自定义固定操作栏

优先使用系统 `safeAreaBar`：

```swift
ScrollView {
    content
}
.safeAreaBar(edge: .bottom, spacing: Spacing.none) {
    bottomBar
}
.scrollEdgeEffectStyle(.soft, for: .bottom)
```

同时存在顶部与底部固定栏，或需要复用项目固定栏骨架时，查询 `XMScrollEdgeChrome` 并选择 `.overlaySoft`。`.contained` 会使用局部 Wash，只适用于不与系统栏重叠的封闭视口。

### UIViewRepresentable

- SwiftUI 层把安全区延伸作用于 representable 本身，并按真实边缘声明 `.soft`。
- UIKit host 仍必须用 `XMSystemScrollEdgeRegistration` 登记内部真实 `UIScrollView`；SwiftUI 修饰器不能替代控制器对 UIKit 滚动 owner 的观察。
- `dismantleUIView` 必须触发 host 的清理入口，避免页面销毁后遗留观察关系。

## UIKit 窄桥接

系统 Navigation Bar、Toolbar 或 Tab Bar 需要观察 UIKit 滚动视图时，查询并使用 catalog 登记的 `XMSystemScrollEdgeRegistration`：

```swift
private let systemScrollEdgeRegistration = XMSystemScrollEdgeRegistration(
    edges: [.top, .bottom]
)

override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
        systemScrollEdgeRegistration.invalidate()
    } else {
        systemScrollEdgeRegistration.update(scrollView: self)
    }
}

override func layoutSubviews() {
    super.layoutSubviews()
    systemScrollEdgeRegistration.update(scrollView: self)
}
```

该桥接只负责：

- 将目标边缘设置为系统 `.soft`。
- 沿 responder chain 找到最近 `UIViewController`。
- 用 `setContentScrollView(_:for:)` 幂等登记真实滚动 owner。
- 仅在控制器仍观察同一对象时解除关系。
- 默认在系统更新前后保持逻辑纵向位置。

该桥接不负责：

- 绘制模糊、渐变、材质、背景或遮罩。
- 设置约束、`contentInsetAdjustmentBehavior`、业务 inset、bounce、Tab Bar 收缩策略或内容顺序。
- 选择嵌套滚动视图、编辑器内部滚动视图或横向子列表作为页面 owner。
- 理解 `IndexPath`、稳定 Item 或业务锚点。

需要延伸的 UIKit 主滚动视图应填满页面容器边缘，而不是只约束到 `safeAreaLayoutGuide`。普通页面优先使用 `.always` 让系统安全区进入 `adjustedContentInset`；已有复杂页面只有在真实布局与锚点策略验证通过时才保留自己的 adjustment 策略。

同一控制器的同一边缘同时只允许一个滚动 owner。内嵌编辑器或局部列表可以直接设置自身 `topEdgeEffect/bottomEdgeEffect`，但不得因此登记为页面系统栏 owner。

### 位置保持事务

默认事务以 `contentOffset.y + adjustedContentInset.top` 保存逻辑位置，在系统重算 inset 后恢复并钳制到合法范围。

依赖首个可见 Item、布局属性或业务锚点的复杂列表，通过 `transaction` 注入自己的保持策略：

```swift
systemScrollEdgeRegistration.update(scrollView: collectionView) { systemUpdate in
    preserveStableItemAnchor {
        systemUpdate()
    }
}
```

不要把稳定 Item 逻辑加入公共注册器；它属于具体列表 owner。

## 审查与验证

代码审查先确认：

- modifier 或注册器是否作用于真实滚动 owner。
- 目标边缘是否与实际 Navigation Bar、Toolbar、`safeAreaBar` 或 Tab Bar 一致。
- 系统路径中是否混入 `XMScrollEdgeWash`、自绘渐变、材质、mask 或 `UIVisualEffectView`。
- 入窗、布局幂等更新、拆卸清理和控制器切换是否完整。
- 手工 inset 是否与系统 `adjustedContentInset` 重复。

运行态至少覆盖长内容、短内容、顶部、底部、双边缘、首次进入、滚动后返回、Push/Pop、Tab 切换和 representable 重建。确认首末内容可达、没有首帧跳动或双重留白，并追加浅深色、横竖屏、辅助功能字号、Reduce Transparency 与 VoiceOver 验证。
