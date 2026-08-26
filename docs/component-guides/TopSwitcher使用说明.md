# TopSwitcher 使用说明

`TopSwitcher` 位于 `xmnote/UIComponents/Navigation/Tabs/TopSwitcher.swift`，用于首页顶部标题/二级标签切换。组件支持标签模式和单标题模式，标签模式默认采用 `TopSwitcherSelectionTransactionPolicy.hardSwitch`：路由 selection 与顶部视觉 selection 都在禁动画事务内写入，保证顶部反馈与内容页同帧落位。

## 快速接入

- 适用场景：首页顶部二级 tab、单标题顶部栏。
- 默认策略：`.hardSwitch`，用于书籍/书单这类导航切换。
- 显式动画：仅当业务确实需要顶部切换动效时传 `.animated(...)`。
- 职责边界：`TopSwitcher` 只负责顶部标题/选中态与 selection 写入，不负责内容容器的保活、显隐和 UIKit 内部动画。

## 参数说明

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `selection` | `Binding<Tab>` | 必填 | 外部路由 selection。点击 tab 时由策略写回。 |
| `tabs` | `[Tab]` | 必填 | 顶部 tab 集合。 |
| `quote` | `String` | `"“"` | 顶部品牌引号装饰。 |
| `selectionTransactionPolicy` | `TopSwitcherSelectionTransactionPolicy` | `.hardSwitch` | selection 写入和顶部视觉反馈的事务策略。 |
| `titleProvider` | `(Tab) -> String` | 必填 | tab 标题文案。 |
| `trailing` | `() -> Trailing` | 必填 | 顶部右侧 action 区。 |
| `title` | `String` | 必填 | 单标题模式文案，仅 `Tab == Never` 时使用。 |

## 示例

```swift
TopSwitcher(
    selection: $selection,
    tabs: BookSubTab.allCases,
    selectionTransactionPolicy: .hardSwitch,
    titleProvider: { $0.title }
) {
    AddMenuCircleButton(...)
}
```

需要标题模式时：

```swift
TopSwitcher(title: "书籍") {
    AddMenuCircleButton(...)
}
```

## 常见问题

**为什么组件内部还有 `visualSelection`？**
外部 selection 可能被父级路由或状态恢复改写。`visualSelection` 让顶部反馈能独立同步到最新 selection，同时在 `.hardSwitch` 下避免外部动画事务造成顶部文字滞后。

**`.hardSwitch` 禁止哪些动画？**
它会用 `Transaction(animation: nil)` 且 `disablesAnimations = true` 写入路由 selection 和顶部视觉 selection。内容页是否淡入、横滑或重排，仍由内容宿主与子页内部 owner 控制。

**为什么不把顶部切换动画作为默认体验？**
首页二级页切换更接近导航切换，用户期望点击后当前页立即成为事实。默认硬切能减少页面级过渡感；需要动画的页面应显式声明。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
