# Note/
> L2 | 父级: Views/CLAUDE.md

笔记管理视图模块，承载页面壳层与页面私有展示组件；对应 ViewModel 位于 `xmnote/ViewModels/Note/`。

## 成员清单

- `NoteContainerView.swift`: 笔记 Tab 容器与二级切换入口
- `NoteCollectionView.swift`: 笔记分类切换与内容分发
- `NoteTagsView.swift`: 标签分组网格展示
- `NoteDetailView.swift`: 笔记详情阅读与编辑
- `NoteReviewPlaceholderView.swift`: 书评空态占位
- `NoteReviewView.swift`: 书摘回顾分页卡组主界面
- `Components/NoteReviewCardView.swift`: 书摘回顾卡片页面私有内容视图
- `Components/NoteReviewPalette+UI.swift`: 书摘回顾卡片配色与文本对齐 UI 映射
- `Sheets/NoteReviewSettingsSheet.swift`: 书摘回顾设置 Sheet
- `Sheets/NoteReviewTagEditSheet.swift`: 书摘回顾标签编辑 Sheet

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
