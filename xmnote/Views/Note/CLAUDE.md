# Note/
> L2 | 父级: Views/CLAUDE.md

笔记管理视图模块，承载页面壳层与页面私有展示组件；对应 ViewModel 位于 `xmnote/ViewModels/Note/`。

## 成员清单

- `NoteContainerView.swift`: 笔记 Tab 容器与二级切换入口
- `NoteCollectionView.swift`: 笔记分类切换与内容分发
- `NoteTagsView.swift`: 标签分组网格展示
- `NoteDetailView.swift`: 笔记详情阅读与编辑
- `NoteExcerptListView.swift`: 书摘二级列表（底部系统搜索、上下文菜单、分享/删除与批量操作）
- `NoteReviewView.swift`: 书摘回顾分页卡组主界面
- `Components/NoteReviewCardView.swift`: 书摘回顾卡片页面私有内容视图
- `Components/NoteReviewPalette+UI.swift`: 书摘回顾卡片配色与文本对齐 UI 映射
- `Components/NoteCollapsibleSearchPage.swift`: 书摘页面折叠搜索与滚动 chrome 组件组
- `Components/NoteExcerptListComponents.swift`: 书摘列表行、分组与状态组件
- `Components/NoteHomeCategoryViews.swift`: 星标章节与笔记分类入口组件
- `Components/NoteIndexGridItem.swift`: 笔记索引网格布局与条目
- `Components/NotePullDownSearchBar.swift`: 下拉搜索输入组件
- `Components/NoteReviewRefreshDeckHost.swift`: 书摘回顾刷新和卡组内容宿主
- `Components/NoteScrollBoundaryCoordinator.swift`: 书摘列表滚动边界与下拉手势协调器
- `Sheets/NoteReviewSettingsSheet.swift`: 书摘回顾设置 Sheet
- `Sheets/NoteReviewTagEditSheet.swift`: 书摘回顾标签编辑 Sheet

笔记首页、书摘列表、回顾和批量 Sheet 的通用空态、无结果与失败视觉统一复用 `StatePresentation` 组件族。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
