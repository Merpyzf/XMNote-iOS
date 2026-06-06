# 首页二级页硬切与 UIKit 动画边界 - Compose 到 SwiftUI 迁移总结

更新日期：2026-06-07

## 背景

本轮问题来自首页 `书籍` / `书单` 二级页切换：用户期望点击后顶部选中态与内容同帧硬切，但录屏中仍能看到顶部滞后、内容叠影或卡片进场感。最初只处理 SwiftUI 父级 transaction 不够，因为真实动画 owner 分布在顶部切换器、保活宿主和 UIKit collection host。

## 核心结论

硬切不是“父级禁一个动画”就结束，而是要按真实写入点逐层收敛：

- 路由 selection：`TopSwitcherSelectionTransactionPolicy.updateRouteSelection` 必须禁动画。
- 顶部视觉反馈：`TopSwitcher` 自己的 `visualSelection` 也必须在同一策略下禁动画。
- 子页保活与显隐：`KeepAliveSwitcherHost` 的 `activatedTabs`、opacity、zIndex、hit testing 都必须禁动画。
- UIKit 桥接内容：`UICollectionView` diff、layout、scroll offset、cell layer 动画必须由 `BookshelfDefaultCollectionView` / `BookshelfAggregateCollectionView` 自己接收 `isPageActive` 并控制 `animated`。

## Android / Compose 视角

Android 参考路径中，`BookContainerFragment` 使用 `ViewPager2 + TabLayoutMediator` 管理书籍/书单；书籍页内部维度由 `BookShelfFragment.switchFragment` 通过 child Fragment `hide/show` 切换。动画 owner 清晰地落在 ViewPager、Fragment transaction 或业务 ViewAnimator 上。

iOS SwiftUI 迁移时不能把 Android 的“一个容器负责切换”机械映射成 SwiftUI 父级 `withTransaction`。一旦子页里有 `UIViewRepresentable`，UIKit 内部的显式动画和 collection 更新仍然是独立 owner。

## SwiftUI 实践规则

- 导航性质的二级页切换默认硬切，使用 `HomeSubtabScaffold(selectionTransactionPolicy: .hardSwitch)`。
- 如果组件内部存在派生 selection，例如顶部视觉 selection，要和外部 route selection 使用同一事务策略。
- 保活容器切换可见性时，`opacity` 也可能被外部动画事务污染；需要在 content 和容器层都用禁动画 transaction。
- UIKit bridge 不应假设 SwiftUI transaction 会覆盖全部动画；`updateUIView` 的 `animated` 参数必须由配置显式计算。
- 页面激活态变化不是业务结构变化。切回页面时应取消残留 cell 动画，避免用户把补帧误认为页面切换动画。

## 迁移核对清单

- 找到真实 owner：顶部控件、内容宿主、UIKit host、业务 drawer 是否分别写状态。
- 找到真实写入点：点击、`onChange`、首次激活、`updateUIView`、collection diff 是否都会触发。
- 找到触发时机：首次进入新 tab、切回旧 tab、外部状态恢复、搜索 drawer 可见性变化是否走同一策略。
- 找到平台边界：SwiftUI transaction 只约束 SwiftUI 状态动画；UIKit 显式动画要单独禁用。
- 保留业务动画：整理模式、搜索 drawer、批量工具栏等结构性业务变化仍应保留既有 motion token，不能被页面硬切修复误伤。
