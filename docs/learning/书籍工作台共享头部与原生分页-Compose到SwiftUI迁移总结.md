# 书籍工作台共享头部与原生分页：Compose 到 SwiftUI 迁移总结

## 背景

书籍工作台同时包含可收起书籍概览、四域横向分页、各域独立纵向列表、章节吸顶和封面主题色。若把这些连续几何全部提升为 SwiftUI 状态，列表会因逐帧状态写入扩大重绘；若为每个内容域复制一套头部和 Tab，又会产生切页跳变和重复指示线。

本次实现采用 SwiftUI 管业务状态、UIKit 管高频几何的边界，并在修复 Tab 指示线残影时进一步明确了“谁拥有动画”的原则。

## 第一性原理：先分清三类 owner

### 1. 数据 owner

- Repository observation 是书籍资料和四域内容的真相源。
- `BookDetailViewModel` 只编排订阅、取消和后台展示派生。
- `BookWorkspacePresentationStore` 只把输入转换为不可变列表快照。

### 2. 几何 owner

- 横向 `contentOffset`、纵向滚动量、标题 Frame 和指示线 Frame 都由 UIKit 宿主持有。
- SwiftUI 只接收最终选中域和少量阈值状态，不接收逐帧滚动坐标。

### 3. 动画 owner

- 主题取色拥有背景颜色过渡。
- Pager 拥有用户切页运动。
- 指示线没有独立动画，它只是 Pager 连续位置的几何投影。

当三个 owner 混在一个容器转场中时，主题动画会截取标题和指示线的旧画面；真实视图同时按新位置布局，于是出现两个视觉实例。

## 共享 Chrome，而不是四份 Header

每个内容域仍需要为头部收起保留相同的滚动空间，但不需要各自渲染 Header。当前做法是：

1. 四个 Collection 的首个 section 只放 `chromeSpacer`。
2. 宿主在 Pager 上方唯一渲染书籍 Header 和 Scope Bar。
3. SwiftUI Hosting View 测得真实动态高度后，同步刷新四页占位。
4. 横向分页时，对相邻页的纵向滚动量做插值，决定共享 Chrome 的唯一位置。

这与 Compose 中“每页复制同一个 collapsing header”不同，更接近把 nested scroll 的连续位置留在单一宿主，再让内容页提供各自滚动来源。

## 指示线几何生命周期

一个可见指示线至少依赖四个有效条件：

- Scope Bar 自身宽高为非零有限值。
- 内部 Scroll View 宽高为非零有限值。
- 当前标题锚点已经完成布局。
- 计算后的指示线 Frame 位于有效纵向范围。

因此初始化时应隐藏指示线，布局无效时继续隐藏；只有全部条件满足后，才无动画设置 Frame 并显示。旋转或动态字体改变时，保存的连续页位置仍然有效，重新布局只需要按该位置立即计算新 Frame。

对应的 Compose 思路是：不要在 `onGloballyPositioned` 尚未得到稳定坐标时绘制 Indicator；稳定坐标改变后直接重算，只有 Pager 的 `currentPageOffsetFraction` 驱动连续移动。

## 动画事务要窄

错误做法是对整个 Tab 容器做交叉溶解，因为快照会包含所有子视图。正确边界是只动画发生语义变化的属性：背景颜色。

UIKit 侧采用：

~~~swift
UIView.animate(
    withDuration: 0.18,
    delay: 0,
    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
) {
    scopeBar.backgroundColor = nextColor
}
~~~

而指示线布局使用无动画事务：

~~~swift
UIView.performWithoutAnimation {
    indicatorView.frame = nextFrame
    indicatorView.isHidden = false
}
~~~

Compose 中对应的边界是只对背景 `animateColorAsState`，不要用包含 Tab 全部内容的 `AnimatedContent` 或整体 Crossfade。

## 连续位置与提交状态必须分离

分页过程中存在两种状态：

- 连续位置：例如 `1.35`，用于标题颜色、指示线和共享 Chrome 插值。
- 业务选中态：例如 `.notes`，只有页面落定后才用于搜索、菜单和创建入口。

如果拖动中途提前提交业务选中态，用户会看到工具栏语义抢跑；如果外部选中态在交互未结束时反向校准 Pager，又会造成回跳。

Compose 的对应实现也应把 `PagerState.currentPageOffsetFraction` 与最终 `settledPage` 分开消费。

## 不可变快照与稳定身份

四个域的数据量和更新频率不同。将分组、排序、HTML 纯文本派生放在渲染热路径中，会让滚动承担与显示无关的 CPU 工作。

本次采用以下规则：

- Item ID 使用业务主键，不使用数组下标。
- 搜索只对对应域去抖和重建。
- 每个域拥有独立 revision；旧任务完成时先检查取消和 revision。
- 单条书摘展开状态按 Note ID 独立持有。
- 页面退出取消所有展示派生和预热任务。

这与 Compose 中使用稳定 `key`、把 `derivedStateOf`/过滤排序移出 Item Composable、用最新请求 token 拒绝过期结果的目标一致。

## Android Compose 开发者迁移示例

### Compose 侧概念

~~~kotlin
val page = pagerState.currentPage
val fraction = pagerState.currentPageOffsetFraction

BookWorkspaceTabs(
    settledPage = page,
    continuousPosition = page + fraction,
    animateBackgroundOnly = true
)
~~~

### SwiftUI/UIKit 侧概念

~~~swift
let position = BookWorkspacePagerPosition(
    offsetX: pager.contentOffset.x,
    pageWidth: pager.bounds.width,
    pageCount: sections.count
)

scopeBar.updatePagePosition(position.rawValue, revealsTarget: true)
~~~

两段代码表达的是同一约束：连续分页位置留在滚动框架内部，业务层只接收最终落定页。

## 可复用检查清单

- 页面是否只有一个共享 Header 和一个 Tab 实例？
- 连续滚动位置是否留在真实滚动 owner 内？
- 指示线是否在几何无效时隐藏？
- 主题动画是否只覆盖颜色属性？
- 首次布局、旋转和动态字体是否无动画校准？
- 用户切页和外部状态同步是否使用不同动画边界？
- 快照是否使用业务稳定 ID，并拒绝过期异步结果？
- Reduce Motion 是否能让程序化分页和可见区域调整立即完成？

## 结论

复杂分页页面稳定性的关键不是增加更多协调状态，而是缩小状态和动画的 owner。数据由 Repository/ViewModel 管，派生由 Store 管，高频几何由原生宿主管，背景过渡只动画颜色。边界清楚后，指示线残影、页面回跳和无意义重绘会同时得到约束。
