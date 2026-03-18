# Content/
> L2 | 父级: Views/CLAUDE.md

书摘、书评、相关内容查看与编辑视图模块，承接全屏 viewer、单页详情页与最小编辑页；对应 ViewModel 位于 `xmnote/ViewModels/Content/`。

## 成员清单

- `ContentDetailSupport.swift`: 查看页共享辅助类型与标题/卡片基础视图
- `ContentViewerView.swift`: 通用内容查看页壳层（混合 feed viewer）
- `ContentViewerContentView.swift`: 通用内容分页内容壳层（自建 horizontal paging + 单页纵向滚动）
- `ContentViewerDetailBodies.swift`: 书摘/书评/相关内容共享正文 body 组件
- `NoteViewerView.swift`: 书摘查看页壳层
- `NoteViewerContentView.swift`: 书摘分页内容壳层（自建 horizontal paging + 单页纵向滚动）
- `ReviewDetailView.swift`: 书评单页详情页
- `ReviewEditorView.swift`: 书评最小编辑页
- `RelevantDetailView.swift`: 相关内容单页详情页
- `RelevantEditorView.swift`: 相关内容最小编辑页

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
