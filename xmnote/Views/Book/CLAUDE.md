# Book/
> L2 | 父级: Views/CLAUDE.md

书籍管理视图模块，承载页面壳层与页面私有展示组件；对应 ViewModel 位于 `xmnote/ViewModels/Book/`。

## 成员清单

- `BookContainerView.swift`: 书籍 Tab 容器与二级切换入口
- `BookGridView.swift`: 书籍网格展示与筛选
- `BookGridItemView.swift`: 单本书籍卡片渲染
- `BookDetailView.swift`: 书籍工作台核心页面壳层，聚合共享书籍头部、目录/书摘/相关/书评四域与路由入口
- `Components/BookWorkspaceCollectionView.swift`: 书籍工作台页面私有原生分页、共享 Chrome、吸顶与视口稳定宿主
- `Components/BookWorkspaceNoteItem.swift`: 书籍工作台页面私有章节标题、书摘卡片与布局刻度
- `CollectionListPlaceholderView.swift`: 书单空态占位

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
