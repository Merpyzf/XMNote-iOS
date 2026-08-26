# XMTagLabel 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Business/Tag/XMTagLabel.swift`。
- 角色：统一纯展示领域标签的排版、文字颜色、语义背景、内边距与 4pt 连续圆角。
- 适用场景：书摘、内容详情、搜索结果、时间线等页面中用于描述内容归属的标签。
- 不适用场景：筛选、选择、状态、评分、指标、搜索历史以及可点击操作型 Capsule。

## 快速接入

```swift
XMTagLabel(tag.title)
```

需要保留关键词高亮或其他 `Text` 组合时使用内容槽位：

```swift
XMTagLabel {
    XMKeywordHighlighting.text(
        tag.title,
        query: query
    )
}
```

调用方只提供标签内容，不重复声明字体、前景色、背景、内边距或圆角。

## 参数说明

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `title` | `String` | 直接构造单行纯文本标签，使用 `Text(verbatim:)`，不把用户标签内容解释为本地化键。 |
| `content` | `@ViewBuilder () -> Content` | 提供需要高亮等组合能力的标签内容；外层仍统一施加标签排版和表层。 |

组件固定使用：

- `AppTypography.caption2`
- `Color.textSecondary`
- `Color.tagBackground`
- 水平 `Spacing.cozy`、垂直 `Spacing.compact`
- `CornerRadius.inlaySmall`（4pt）和 `.continuous`
- 单行显示

## 示例

### 示例 1：书摘标签

```swift
FlowLayout(spacing: Spacing.cozy) {
    ForEach(note.tags, id: \.self) { tag in
        XMTagLabel(tag)
    }
}
```

### 示例 2：搜索结果中的高亮标签

```swift
XMTagLabel {
    XMKeywordHighlighting.text(tag.title, query: searchText)
}
```

### 示例 3：不要用于操作型筛选

```swift
// 不合规：筛选项具有选中、点击和可访问性状态。
XMTagLabel("全部")
    .onTapGesture { selectedScope = .all }

// 正确：继续使用真实筛选控件或对应页面私有组件。
scopeSelector
```

## 常见问题

### 1. 可以调整圆角或背景色吗？

不可以。纯展示领域标签的视觉语义由组件统一维护。需要其他颜色或轮廓通常意味着该元素具有不同状态或业务角色，应使用对应组件，而不是扩展样式参数。

### 2. 为什么标签管理页面的卡片不使用 XMTagLabel？

标签管理项是可进入、可选择或可编辑的内容入口，承载数量和操作状态，不是正文中的纯展示标签。视觉相似不构成复用依据。

### 3. 为什么不使用 Capsule？

当前设计系统将纯展示领域标签定义为紧凑 4pt 连续圆角。Capsule 保留给具有操作、筛选、状态或独立设置入口语义的组件。

### 4. Dynamic Type 下如何处理？

组件使用语义字体并保持单行。页面应提供可换行的标签流布局；不要通过固定整体高度裁切标签，也不要在调用处缩小字体覆盖组件规则。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
