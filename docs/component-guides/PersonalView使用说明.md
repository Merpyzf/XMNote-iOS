# PersonalView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Personal/PersonalView.swift`
- 角色：我的页面核心壳层，负责分组化设置入口、顶部操作入口与页面节奏控制。
- 适用场景：作为 Tab 根页面或导航栈中的“我的”入口页。

## 快速接入
```swift
PersonalView(
    onAddBook: { /* 打开新增书籍 */ },
    onAddNote: { /* 打开新增笔记 */ },
    onOpenDebugCenter: { /* DEBUG 可选 */ }
)
.environment(AppState())
```

## 参数说明
- `onAddBook: () -> Void`
  - 顶部 `+` 菜单中的“新增书籍”动作回调。
- `onAddNote: () -> Void`
  - 顶部 `+` 菜单中的“新增笔记”动作回调。
- `onOpenDebugCenter: (() -> Void)?`
  - Debug 场景透传入口；线上可传 `nil`。

布局与视觉约束（本次更新）：
- 分组间距通过 `Layout.panelSpacing` 统一控制，默认 `Spacing.comfortable`。
- 行高使用 `Layout.rowMinHeight = 44`，避免相邻 Item 的纵向 padding 叠加。
- 行内图标与主文本统一 `Color.textPrimary`，减少视觉噪音。

## 示例
- 示例 1：作为 Tab 根页面接入。
```swift
NavigationStack {
    PersonalView(
        onAddBook: { router.presentAddBook() },
        onAddNote: { router.presentAddNote() }
    )
}
```

- 示例 2：仅复用页面视觉，不启用 Debug 入口。
```swift
PersonalView(onAddBook: {}, onAddNote: {}, onOpenDebugCenter: nil)
```

## 常见问题
### 1) 为什么不建议在页面中恢复 Section 标题？
当前分组已由卡片结构与图标语义表达。额外标题会增加纵向噪音，破坏页面呼吸感。

### 2) 行内间距应该调 `padding` 还是调 `rowMinHeight`？
优先调 `rowMinHeight`。该策略可避免相邻 Item 垂直 padding 叠加，保证节奏稳定。

### 3) 图标颜色可以改回主题色吗？
不建议。设置页图标应从属于文本层级，使用主题色会抢占视觉焦点。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
