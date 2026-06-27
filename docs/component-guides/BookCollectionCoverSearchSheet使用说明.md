# BookCollectionCoverSearchSheet 使用说明

## 组件定位

- 源码路径：xmnote/Views/Book/Sheets/BookCollectionCoverSearchSheet.swift
- 角色：书单内书籍元信息编辑的业务 Sheet，负责在线匹配有封面的书籍搜索结果，并把选中的封面链接回填到编辑表单。

## 快速接入

```swift
BookCollectionCoverSearchSheet(
    initialTitle: title,
    currentCoverURL: coverURL
) { selectedURL in
    coverURL = selectedURL
}
```

该 Sheet 不保存数据库，也不上传图片。它只返回选中的在线封面 URL。

## 参数说明

- `initialTitle`：初始搜索词，通常来自当前书籍标题。
- `currentCoverURL`：当前封面链接，用于在结果中标记当前封面。
- `onSelect`：用户选择封面后的回调，返回裁剪空白后的 URL 字符串。

## 示例

### 1. 在元信息编辑 Sheet 中打开

```swift
.sheet(isPresented: $showsCoverSearch) {
    BookCollectionCoverSearchSheet(
        initialTitle: trimmedTitle,
        currentCoverURL: trimmedCoverURL
    ) { selectedURL in
        coverURL = selectedURL
        selectedCover = nil
    }
}
```

### 2. 自定义搜索来源

当前 Sheet 使用 `BookSearchSource.productionCases`。如果未来需要更多来源，优先扩展书籍搜索来源模型，不在 Sheet 内写死私有来源数组。

## 常见问题

### 1) 为什么封面搜索不直接保存？

保存书籍元信息需要同时处理标题、作者、出版社、出版日期、封面和 relation 文本，统一由 `BookCollectionBookMetadataEditSheet` 提交给 ViewModel。封面搜索只负责选择候选。

### 2) 搜索结果为什么只显示有封面的条目？

这个 Sheet 的任务是匹配封面。ViewModel 会过滤空封面链接，避免用户选择没有实际封面的结果。

### 3) 网络错误如何反馈？

`BookCollectionCoverSearchViewModel` 把错误转成 `BookCollectionCoverSearchStatus.failure`，Sheet 展示内联状态卡片，不弹中心提示。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
