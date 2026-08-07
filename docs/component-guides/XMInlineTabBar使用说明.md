# XMInlineTabBar 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Tabs/XMInlineTabBar.swift`。
- 角色：内容区内 2 至 5 个互斥子页面的左对齐切换器。
- 边界：只写回 selection 并移动选中胶囊，不负责切换内容的生命周期、分页手势或持久化。

## 快速接入

```swift
XMInlineTabBar(
    items: BookWorkspaceSection.allCases.map {
        XMInlineTabItem(id: $0, title: $0.title)
    },
    selection: $selectedSection,
    accessibilityLabel: "单书内容分类"
)
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `items` | 2 至 5 个具有稳定 `Hashable` ID 的 `XMInlineTabItem`。 |
| `selection` | 当前业务选中项；必须存在于 `items`。 |
| `accessibilityLabel` | 整组切换器的无障碍名称。 |
| `accessibilityTitle` | 单项可选无障碍文案，省略时使用可见标题。 |

## 示例

### 四域工作台

```swift
let items = [
    XMInlineTabItem(id: Section.catalog, title: "目录"),
    XMInlineTabItem(id: Section.notes, title: "书摘"),
    XMInlineTabItem(id: Section.related, title: "相关"),
    XMInlineTabItem(id: Section.reviews, title: "书评")
]

XMInlineTabBar(items: items, selection: $selection)
```

业务内容切换应在 selection 更新后无动画硬切；组件内部只为胶囊连续移动使用 `.snappy`，Reduce Motion 下即时落位。

## 常见问题

### 它和 TopSwitcher、XMScopeSelector 有什么区别？

`TopSwitcher` 属于首页顶部导航，`XMScopeSelector` 用于同一数据集的范围筛选；`XMInlineTabBar` 表达当前页面内容区内并列的子页面。

### 为什么不支持 6 个以上入口？

超过 5 个时信息架构已经不适合轻量 Inline Tab，应重新分组或使用列表/菜单导航。

### selection 不在 items 中会怎样？

Debug 构建会触发断言，生产构建不渲染，避免展示一个无法解释的选中状态。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
