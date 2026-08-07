# Book/
> L2 | 父级: Views/CLAUDE.md

书籍管理视图模块，承载页面壳层与页面私有展示组件；对应 ViewModel 位于 `xmnote/ViewModels/Book/`。

## 成员清单

- `BookContainerView.swift`: 书籍 Tab 容器与二级切换入口
- `BookGridView.swift`: 书籍网格展示与筛选
- `BookGridItemView.swift`: 单本书籍卡片渲染
- `BookDetailView.swift`: 原生四域单书工作台壳层，承接目录、书摘、相关与书评
- `ChapterManagerView.swift`: 五层书内目录管理、导入、星标、移动、排序与删除页面
- `Components/BookWorkspaceCollectionView.swift`: 单书工作台四域常驻 UIKit Collection 桥接与 diffable snapshot 应用
- `Components/BookWorkspaceNoteItem.swift`: 单书工作台章节头与富文本书摘卡片
- `Components/BookSearchChipButtonStyle.swift`: 书籍搜索页面私有胶囊按压样式
- `Components/BookSearchRecentQueriesSection.swift`: 书籍搜索最近查询区块
- `Components/BookSearchResultRow.swift`: 书籍搜索结果行
- `Components/BookSearchResultSkeletonRow.swift`: 书籍搜索骨架行
- `Components/BookSearchStatusCard.swift`: 书籍搜索空态与错误态卡片
- `Components/BookCollectionVisualComponents.swift`: 书单列表、详情与封面组合视觉组件
- `Components/BookshelfBookListChromeViews.swift`: 书架二级列表浏览与编辑 chrome
- `Components/BookshelfBookListCollectionCells.swift`: 书架二级列表 UIKit cell、区头与空态容器
- `Components/BookshelfBookListCollectionLayoutFactory.swift`: 书架二级列表 compositional layout 工厂
- `Components/BookshelfBookListCollectionModels.swift`: 书架二级列表配置、状态与 section 模型
- `Components/BookshelfBookListCollectionView.swift`: 书架二级列表 SwiftUI/UIKit collection 桥接
- `Components/BookshelfBookListItemViews.swift`: 书架二级列表网格与列表条目视图
- `Components/BookshelfBookListViewportStableCollectionView.swift`: 书架二级列表视口稳定 Collection 子类
- `Components/BookshelfInteractionState.swift`: 书架编辑 chrome、底部 inset 与搜索抽屉状态
- `CollectionListPlaceholderView.swift`: 书单空态占位

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
