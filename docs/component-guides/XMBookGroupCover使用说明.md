# XMBookGroupCover 使用说明

## 组件定位

- 源码路径：`xmnote/Views/Personal/Components/XMBookGroupCover.swift`。
- 归属：个人中心页面私有组件，不属于公共 `UIComponents`。
- 角色：用多个 `XMBookCover` 统一表达书籍分组，覆盖书架列表、聚合入口和分组管理。
- 边界：只消费有序封面 URL，不查询数据库，也不承载分组标题、数量或点击行为。

## 快速接入

```swift
XMBookGroupCover(
    covers: group.coverURLs,
    style: .adaptiveManagementCompact
)
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `covers` | 已按业务顺序排列的封面 URL；组件按样式截取需要数量。 |
| `style` | `.compactList`、`.collectionCaseCompact`、`.orderedGridCompact` 或 `.adaptiveManagementCompact`。 |

管理页优先使用 `.adaptiveManagementCompact`，它会针对 0、1、2、3、4+ 本书分别选择空托盘、单封面、叠放或网格布局。

## 示例

### 分组管理行

```swift
HStack {
    XMBookGroupCover(
        covers: item.coverURLs,
        style: .adaptiveManagementCompact
    )
    Text(item.name)
}
```

### 紧凑列表

```swift
XMBookGroupCover(covers: covers, style: .compactList)
```

## 常见问题

### 空分组需要页面提供占位图吗？

不需要。组件会显示中性的文件夹托盘空态。

### 可以传入未排序的封面吗？

不建议。封面位置具有顺序语义，Repository 或 ViewModel 应先按分组内书籍顺序生成 URL 数组。

### 为什么组件不可点击？

点击范围和无障碍标签属于分组行或卡片，封面自身被标记为装饰，避免产生重复焦点。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
