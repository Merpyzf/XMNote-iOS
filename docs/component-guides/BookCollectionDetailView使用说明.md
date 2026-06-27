# BookCollectionDetailView 使用说明

## 组件定位

- 源码路径：xmnote/Views/Book/BookCollectionDetailView.swift
- 角色：书单详情核心页面组件，承载书单 Header、成员书籍列表、添加书籍、占位书恢复、收藏理由/年度点评、年度说明、元信息编辑、移出书籍、排序、删除和分享图生成。

## 快速接入

```swift
BookCollectionDetailView(
    collectionID: collectionID,
    onOpenRoute: { route in
        // 转交外层 BookRoute 导航
    }
)
```

详情页会在内部创建 `BookCollectionDetailViewModel` 并启动观察流；外层只负责传入 `collectionID` 与书籍路由回调。

## 参数说明

- `collectionID`：目标书单 ID，必须来自有效 `collection` 记录。
- `onOpenRoute`：打开书籍详情、书籍编辑等外层路由的回调。

## 示例

### 1. 打开书单详情

```swift
NavigationLink(value: BookRoute.collectionDetail(collectionID: item.id)) {
    BookCollectionListCard(item: item, displayMode: .list)
}
```

### 2. 处理书单内书籍点击

```swift
BookCollectionDetailView(collectionID: id) { route in
    bookPath.append(route)
}
```

非占位书会进入书籍详情；占位书会执行恢复到书架的写操作。

## 常见问题

### 1) 为什么底部只放“添加书籍”？

添加书籍是手动书单详情的高频主操作。分享、编辑、删除、年度说明等对象级低频动作放在顶部更多菜单，避免底部主操作拥挤。

### 2) 年度书单哪些内容可编辑？

年度书单不允许手动添加、移出、排序或删除成员。可编辑的是年度本体说明，以及每本书在年度书单中的年度点评。

### 3) 批量导出书籍是否已经接入？

还没有。Android 详情页有批量导出书籍能力，iOS 当前只实现分享图；源码中保留 TODO，后续必须补齐真实导出。

### 4) 占位书恢复会不会丢失收藏理由？

不会。恢复只更新 `book` 的有效状态、书架排序和阅读状态，原 `collection_book` relation 保留。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
