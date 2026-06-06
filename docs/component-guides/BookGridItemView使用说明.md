# BookGridItemView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Book/BookGridItemView.swift`
- 角色：书架网格中的单本书籍卡片，负责封面、角标、书名、作者和排序辅助信息展示。
- 归属：`xmnote/Views/Book/` 下的 UI-核心页面组件，不抽入 `UIComponents`。

## 快速接入
~~~swift
BookGridItemView(
    book: book,
    showsNoteCount: true,
    isPinned: item.pinned,
    isEditing: viewModel.isEditing,
    isSelected: viewModel.selectedIDs.contains(item.id),
    titleDisplayMode: displaySetting.titleDisplayMode,
    searchKeyword: viewModel.searchKeyword,
    sortAuxiliaryText: book.sortAuxiliaryText(for: sortCriteria)
)
~~~

## 参数说明
| 参数 | 说明 |
| --- | --- |
| `book` | 书籍展示模型，包含封面、书名、作者、阅读状态、评分、进度等展示字段。 |
| `showsNoteCount` | 是否显示书摘数量角标，默认书架和二级列表按显示设置传入。 |
| `isPinned` | 是否显示置顶角标。 |
| `isEditing` | 编辑态下展示选择状态，不在组件内修改选择集合。 |
| `isSelected` | 当前卡片是否被选中。 |
| `titleDisplayMode` | 书名显示模式，使用书架显示设置传入。 |
| `searchKeyword` | 搜索高亮关键字。 |
| `sortAuxiliaryText` | 排序上下文辅助文案；由容器层根据当前排序条件生成，可为空。 |

接入时保持“容器层负责状态、组件层负责渲染”的边界。组件不读取 Repository，也不自行判断当前排序条件。

## 示例
### 默认书架网格

~~~swift
BookGridItemView(
    book: book,
    showsNoteCount: showsNoteCount,
    isPinned: item.pinned,
    isEditing: isEditing,
    isSelected: isSelected,
    titleDisplayMode: titleDisplayMode,
    searchKeyword: searchKeyword,
    sortAuxiliaryText: item.bookListItem?.sortAuxiliaryText(for: sortCriteria)
)
~~~

### 二级列表网格

~~~swift
BookGridItemView(
    book: book,
    showsNoteCount: displaySetting.showsNoteCount,
    isPinned: book.isPinned,
    isEditing: viewModel.isEditing,
    isSelected: viewModel.selectedBookIDs.contains(book.id),
    titleDisplayMode: displaySetting.titleDisplayMode,
    searchKeyword: viewModel.searchKeyword,
    sortAuxiliaryText: book.sortAuxiliaryText(for: viewModel.sortCriteria)
)
~~~

## 排序辅助信息

`sortAuxiliaryText` 用于对齐 Android 网格排序上下文展示。容器层应只在以下排序下传入非空文案：

- 出版时间
- 阅读时长
- 读完时间
- 阅读进度
- 创建时间
- 修改时间
- 评分

辅助信息必须是一行短文案，使用组件内的书架辅助文字层级渲染，避免挤压封面、书名和作者。无障碍标签应由容器层把同一文案合入卡片 accessibility label。

## 常见问题
### 1) 这个组件是否可抽到 UIComponents？
不建议。该组件属于核心页面壳层/页面核心业务组件，默认保留在 xmnote/Views。

### 2) 是否允许在组件内直接访问 Repository？
遵循现有架构：通过页面层或 ViewModel 注入，不在纯展示子组件中直连数据层。

### 3) 为什么排序文案不在组件内计算？
排序条件属于列表容器上下文。把文案生成放在 `BookshelfBookListItem.sortAuxiliaryText(for:)`，默认书架和二级列表能共享同一业务表达，组件只负责稳定渲染。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
