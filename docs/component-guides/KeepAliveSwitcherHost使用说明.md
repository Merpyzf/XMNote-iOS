# KeepAliveSwitcherHost 使用说明

`KeepAliveSwitcherHost` 位于 `xmnote/UIComponents/Navigation/Tabs/KeepAliveSwitcherHost.swift`，用于二级页面的懒激活与保活切换。它在 `ZStack` 中常驻已激活子页，通过 `opacity`、`zIndex`、`allowsHitTesting` 和 `accessibilityHidden` 切换可见页，并对 selection、activated tabs 与首次激活写入禁用动画。

## 快速接入

- 适用场景：多个二级子页需要保留滚动位置、搜索状态或编辑状态。
- 默认策略：`lazyActivation = true`，首次进入某个 tab 时创建，之后常驻。
- 显隐策略：只改变可见性与交互，不主动销毁已激活子页。
- 动效边界：selection 与激活集合硬切，避免内容 crossfade；子页内部结构动画由子页自己控制。

## 参数说明

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `selection` | `Selection` | 必填 | 当前选中 tab。 |
| `tabs` | `[Selection]` | 必填 | 可切换 tab 集合。 |
| `lazyActivation` | `Bool` | `true` | 是否延迟创建未访问 tab。传 `false` 时首帧激活全部 tab。 |
| `content` | `(Selection) -> Content` | 必填 | 每个 tab 的内容构造闭包。 |

## 示例

```swift
KeepAliveSwitcherHost(
    selection: selection,
    tabs: BookSubTab.allCases,
    lazyActivation: true
) { tab in
    bookSubtabContent(tab)
}
```

若所有子页都需要首帧预热：

```swift
KeepAliveSwitcherHost(
    selection: selection,
    tabs: tabs,
    lazyActivation: false
) { tab in
    content(for: tab)
}
```

## 常见问题

**`lazyActivation` 和保活是什么关系？**
`lazyActivation` 只决定未访问子页是否延迟创建；一旦某个子页被激活，它就会常驻，切走后只隐藏，不销毁。

**为什么 selection 和 activated tabs 都要禁动画？**
首次进入新 tab 时会插入新的 content view。如果插入发生在外层动画事务里，SwiftUI 可能给 opacity 或布局套上淡入/过渡。禁动画事务可以让切换保持硬切。

**它会停止子页内部 `UICollectionView` 动画吗？**
不会。UIKit diff、scroll offset、cell transform 或 `UIView.animate` 不受 SwiftUI transaction 完整约束，需要子页自己的 UIKit host 接收页面激活态并决定 `animated`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
