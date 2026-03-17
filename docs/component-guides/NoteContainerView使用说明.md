# NoteContainerView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Note/NoteContainerView.swift`
- 角色：笔记模块容器壳层，负责“笔记/回顾”二级切换、顶部操作入口与 `NoteViewModel` 生命周期托管。
- 适用场景：主页 Tab 的笔记入口。

## 快速接入
```swift
NoteContainerView(
    onAddBook: { /* 新增书籍 */ },
    onAddNote: { /* 新增笔记 */ }
)
.environment(repositoryContainer)
```

## 参数说明
- `onAddBook: () -> Void`
  - 顶部 `+` 菜单中的新增书籍动作回调。
- `onAddNote: () -> Void`
  - 顶部 `+` 菜单中的新增笔记动作回调。
- `onOpenDebugCenter: (() -> Void)?`
  - Debug 入口透传，可选。

顶部交互约束（本次更新）：
- 右上辅助按钮通过 `TopBarActionIcon(containerSize: 36)` 与 `+` 按钮保持一致尺寸。
- `selectedSubTab == .notes` 时显示排序图标，`review` 时显示设置图标。

## 示例
- 示例 1：作为主页容器直接接入。
```swift
NavigationStack {
    NoteContainerView(
        onAddBook: { appRouter.presentAddBook() },
        onAddNote: { appRouter.presentAddNote() }
    )
    .environment(repositoryContainer)
}
```

- 示例 2：仅复用容器，不开启 Debug 入口。
```swift
NoteContainerView(onAddBook: {}, onAddNote: {}, onOpenDebugCenter: nil)
```

## 常见问题
### 1) 为什么要固定 `containerSize: 36`？
用于与顶部 `+` 按钮形成统一视觉节奏，避免双按钮并排时出现大小不一致。

### 2) 可以把顶部按钮换成页面私有实现吗？
不建议。应复用 `TopBarActionIcon`，保证跨页面顶部操作视觉一致。

### 3) 这个组件是否允许直接访问数据库？
不允许。数据访问必须经 Repository，容器仅注入并消费 ViewModel。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
