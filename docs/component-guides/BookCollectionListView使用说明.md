# BookCollectionListView 使用说明

## 组件定位

- 源码路径：xmnote/Views/Book/BookCollectionListView.swift
- 角色：书单首页核心页面组件，承载手动书单/年度书单列表、显示模式、书单创建编辑删除、排序、微信读书导入入口和导入成功后的详情跳转。

## 快速接入

```swift
BookCollectionListView(
    viewModel: viewModel,
    editMode: $collectionEditMode,
    importRouter: importRouter,
    onOpenCollection: { collectionID in
        onOpenBookRoute(.collectionDetail(collectionID: collectionID))
    }
)
```

接入时由上层 `BookContainerView` 创建并持有 `BookCollectionListViewModel`，避免列表页重复启动观察任务。

## 参数说明

- `viewModel`：书单列表状态 owner，负责观察列表快照、创建/编辑/删除/排序、导入解析与反馈。
- `editMode`：列表排序模式绑定，仅手动书单可进入排序。
- `importRouter`：外部微信读书导入请求入口，消费 App URL 或 Share Extension handoff。
- `onOpenCollection`：打开指定书单详情的路由回调。

## 示例

### 1. 作为书籍首页二级页

```swift
BookCollectionListView(
    viewModel: collectionViewModel,
    editMode: $collectionEditMode,
    importRouter: importRouter,
    onOpenCollection: { id in
        onOpenBookRoute(.collectionDetail(collectionID: id))
    }
)
```

### 2. 消费系统分享导入

```swift
.onChange(of: bookCollectionImportRouter.pendingImport) { _, request in
    guard let request else { return }
    selectedTab = .books
    selectedSubTab = .collections
}
```

列表页会在出现时根据请求来源执行预览导入或直接导入。

## 常见问题

### 1) 为什么列表页不直接访问数据库？

书单数据必须经 Repository。列表页只消费 `BookCollectionListViewModel` 暴露的状态和动作，真实读写由 `BookRepository+Collections` 完成。

### 2) 年度书单为什么不能排序？

年度书单成员由读完记录自动同步，排序按读完时间倒序；允许用户排序会破坏 Android 年度书单业务语义。

### 3) 微信读书导入失败时是否会写入半成品？

不会。链接解析阶段只生成内存预览；只有用户确认或系统分享直接保存路径成功走完 Repository 事务后才写入数据库。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
