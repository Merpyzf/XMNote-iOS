# HomeSubtabScaffold 使用说明

`HomeSubtabScaffold` 位于 `xmnote/UIComponents/Tabs/HomeSubtabScaffold.swift`，用于首页一级 Tab 内的二级子页面壳层。它统一接入 `TopSwitcher`、`KeepAliveSwitcherHost` 与 `HomeTopHeaderGradient`，默认采用 `.hardSwitch`，保证顶部选中态、路由 selection 与内容宿主在无动画事务内同步切换。

## 快速接入

- 适用场景：书籍/书单、笔记/书评、阅读二级页等首页内部子页面。
- 默认行为：二级页 selection 硬切，已激活子页保活，顶部高度稳定，顶部渐变由壳层统一承载。
- 动效边界：壳层只禁止二级页切换本身的动画；子页内部整理、搜索、批量工具栏等业务动画仍由子页自己的 motion token 管理。
- UIKit 桥接提醒：如果子页内部使用 `UIViewRepresentable`、`UICollectionView` 或显式 `UIView.animate`，必须继续向 UIKit owner 传递页面激活态，不能只依赖 SwiftUI 父级 transaction。

## 参数说明

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `selection` | `Binding<Selection>` | 必填 | 当前选中的二级页，负责驱动顶部与内容宿主。 |
| `tabs` | `[Selection]` | 必填 | 二级页集合，顺序即顶部展示顺序。 |
| `topBarHeight` | `CGFloat` | `56` | 顶部切换区预留高度，内容区会向下避让。 |
| `lazyActivation` | `Bool` | `true` | 是否仅在首次进入某个 tab 时创建内容，并在之后保活。 |
| `showsTopSwitcher` | `Bool` | `true` | 是否展示顶部切换控件。 |
| `showsHeaderGradient` | `Bool` | `true` | 是否展示首页顶部渐变遮罩。 |
| `selectionTransactionPolicy` | `TopSwitcherSelectionTransactionPolicy` | `.hardSwitch` | selection 写入策略。首页二级页默认硬切；需要动画时必须显式传 `.animated(...)`。 |
| `titleProvider` | `(Selection) -> String` | 必填 | 根据 tab 生成顶部标题。 |
| `trailing` | `(Selection) -> Trailing` | 必填 | 顶部右侧工具区，通常按当前 tab 返回不同 action。 |
| `content` | `(Selection) -> Content` | 必填 | 子页面内容构造闭包。 |

## 示例

```swift
HomeSubtabScaffold(
    selection: $selectedSubTab,
    tabs: BookSubTab.allCases,
    titleProvider: { $0.title }
) { tab in
    topSwitcherTrailing(for: tab)
} content: { tab in
    bookSubtabContent(tab)
}
```

子页内部如果有 UIKit 列表，应继续把页面激活态传入列表宿主：

```swift
BookshelfDefaultCollectionView(
    sections: sections,
    allowsStructuralAnimation: hasPresentedInitialContent,
    isPageActive: selectedSubTab == .books,
    ...
)
```

## 常见问题

**为什么默认是 `.hardSwitch`？**
首页二级页切换属于导航状态切换，不是内容进入动画。硬切能避免顶部文字滞后、内容叠影和首次激活子页时的淡入污染。

**什么时候可以使用 `.animated(...)`？**
只有某个接入页面明确需要二级页过渡动画，并且内容宿主、内部 UIKit 列表和业务动效边界都已验证不会互相污染时，才显式传入 `.animated(...)`。

**`HomeSubtabScaffold` 会自动禁止 UIKit 动画吗？**
不会。SwiftUI transaction 只能约束 SwiftUI 状态更新；`UICollectionView` diff、layout、scroll offset 和 `UIView.animate` 必须由对应 UIKit host 通过 `animated` 参数或 `UIView.performWithoutAnimation` 自己处理。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
