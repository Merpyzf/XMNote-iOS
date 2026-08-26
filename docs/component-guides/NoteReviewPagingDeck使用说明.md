# NoteReviewPagingDeck 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Note/Components/NoteReviewPaging/NoteReviewPagingDeck.swift`
- 配套模型：`xmnote/Views/Note/Components/NoteReviewPaging/NoteReviewPagingModels.swift`
- 归属：书摘回顾流程页面私有组件，不属于公共 `UIComponents`。
- 角色：书摘回顾专用分页卡组组件，基于 BigUIPaging `PageView` 提供双向切卡、后卡补位、内容 handoff、分页预加载和可访问性隔离。
- 边界：只负责卡组交互和动效，不读取业务数据，不决定卡片正文排版。

## 快速接入
```swift
NoteReviewPagingDeck(
    items: viewModel.items,
    selection: $viewModel.selectedItemID,
    hasMoreItems: viewModel.hasMoreItems,
    configuration: .iOSReviewDefault,
    onCardAppeared: { item, index in
        viewModel.handleCardAppeared(item, index: index)
    },
    onNeedsMoreItems: {
        Task { await viewModel.loadMoreIfNeeded() }
    },
    onTap: { item, _ in
        openContentViewer(for: item)
    }
) { item, context in
    NoteReviewCardView(item: item, settings: viewModel.settings)
} emptyContent: {
    Color.clear
}
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `items` | `[Item]` | 无 | 稳定可识别的卡片数据列表。 |
| `selection` | `Binding<Item.ID?>` | 无 | 外部当前选中卡片 ID。无效或为空时会规整到第一张。 |
| `hasMoreItems` | `Bool` | 无 | 是否仍可分页加载，影响尾部循环与预加载行为。 |
| `configuration` | `NoteReviewPagingDeckConfiguration` | `.iOSReviewDefault` | 控制动效规格、卡组 inset、预加载距离、循环和点击能力。 |
| `onCardAppeared` | `(Item, Int) -> Void` | 空闭包 | 当前卡片变化后回调，用于同步 ViewModel 当前位置。 |
| `onNeedsMoreItems` | `() -> Void` | 空闭包 | 接近尾部时触发，用于业务层分页加载。 |
| `onTap` | `(Item, Int) -> Void` | 空闭包 | 点击当前卡片时触发。 |
| `content` | `(Item, NoteReviewPagingDeckCardContext) -> CardContent` | 无 | 卡片内容构建闭包。 |
| `emptyContent` | `() -> EmptyContent` | 无 | 空数据占位内容。 |

## 示例

### 示例 1：回顾页主卡组
```swift
var configuration = NoteReviewPagingDeckConfiguration.iOSReviewDefault
configuration.cardInsets = NoteReviewPagingLayoutSpec.iOSReviewDefault.cardInsets

NoteReviewPagingDeck(
    items: items,
    selection: $selectedItemID,
    hasMoreItems: hasMoreItems,
    configuration: configuration
) { item, _ in
    NoteReviewCardView(item: item, settings: settings)
        .padding(.horizontal, NoteReviewPagingLayoutSpec.iOSReviewDefault.cardHorizontalPadding)
} emptyContent: {
    XMCompactStateView(
        role: .empty,
        title: "暂无可回顾书摘",
        systemImage: "text.quote"
    )
}
```

### 示例 2：Debug 页验证动效
```swift
NoteReviewPagingDeck(
    items: sampleItems,
    selection: $selection,
    hasMoreItems: false,
    configuration: .iOSReviewDefault
) { item, context in
    DebugReviewCard(item: item, isSelected: context.isSelectedCard)
} emptyContent: {
    Color.clear
}
```

## 常见问题

### 1. 为什么后层卡片内容仍然绘制？
后层卡使用 `.preview` content visibility，正文和 footer 透明度保持可见，但 `isReadable = false`。这能保证卡片切换到 handoff 附近时目标卡不是空白纸面，同时不会让后层卡参与点击或 VoiceOver 读取。

### 2. 为什么 selection 不在手势提交瞬间立刻写回？
如果提前写回，BigUIPaging 页面集合会立即按新 selection 重建，动画尾段可能直接切到新静止态。当前实现会先完成可视动画，再分阶段写回 selection、更新 selectedIndex、清理 visualSession。

### 3. 后层卡为什么不能靠隐藏文本解决露字？
需求要求底卡仍渲染内容。露字问题由 `NoteReviewPagingMotionSpec` 的旋转后 AABB 约束解决，限制侧边和底部实际露出量，保证静止态只露出纸面边缘。

### 4. 业务页可以直接修改 `zIndex` 吗？
不建议。卡组层级由 `NoteReviewPagingMotionSpec.layerPlans(...)` 统一计算，业务卡片只负责内容渲染。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
