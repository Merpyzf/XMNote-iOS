# BookGroupManagementView 使用说明

## 组件定位

- 源码路径：`xmnote/Views/Personal/BookGroupManagementView.swift`。
- 角色：“我的 > 书籍分组”的新增、搜索、重命名、手动排序、多选删除和组内书籍入口。
- 边界：ViewModel 管理页面状态，Repository 负责与 Android 对齐的事务和软删除条件。

## 快速接入

```swift
BookGroupManagementView { route in
    navigationCoordinator.pushBook(route)
}
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `onOpenBookRoute` | 进入组内书籍列表时交给外层书籍导航 owner 的回调。 |

## 示例

```swift
case .groupManagement:
    BookGroupManagementView(onOpenBookRoute: openBookRoute)
```

页面的普通、选择、排序三种模式互斥；进入编辑模式会关闭搜索，写入期间禁用重复操作。

## 常见问题

### 为什么分组封面不在页面里拼装？

页面统一使用 `XMBookGroupCover`，由组件按封面数量选择布局，避免不同入口产生不同的组合规则。

### 手动排序成功需要 Toast 吗？

不需要。列表顺序变化就是成功反馈；失败时 ViewModel 回滚并通过可感知消息解释。

### 删除分组会删除书籍吗？

不会。Repository 只处理分组及关系，书籍实体继续保留。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
