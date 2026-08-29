# Content/
> L2 | 父级: Views/CLAUDE.md

书摘、书评、相关内容查看与编辑视图模块，承接全屏 viewer、单页详情页与最小编辑页；对应 ViewModel 位于 `xmnote/ViewModels/Content/`。

## 成员清单

- `ContentDetailSupport.swift`: 查看页共享辅助类型与标题/卡片基础视图
- `ContentViewerSharedSupport.swift`: 通用 Viewer 展示语义、能力提示与页面私有辅助弹层
- `ContentViewerView.swift`: 通用内容查看页壳层（混合 feed viewer）
- `ContentViewerContentView.swift`: 通用内容分页内容壳层（自建 horizontal paging + 单页纵向滚动）
- `ContentViewerDetailBodies.swift`: 书摘/书评/相关内容共享正文 body 组件
- `NoteViewerView.swift`: 书摘查看页壳层
- `NoteViewerContentView.swift`: 书摘分页内容壳层（自建 horizontal paging + 单页纵向滚动）
- `ReviewDetailView.swift`: 书评单页详情页
- `ReviewEditorView.swift`: 书评最小编辑页
- `RelevantDetailView.swift`: 相关内容单页详情页
- `RelevantEditorView.swift`: 相关内容最小编辑页
- `Components/AIMarkdownResultView.swift`: AI Markdown 流式渲染、跨区块文本选择与表格交互的页面私有组件
- `Sheets/AIInteractionSheets.swift`: AI 释义与自动标签业务 Sheet，承接流式内容、空结果、保留部分结果的失败反馈与专属恢复路径
- `Sheets/RelatedBookRelationEditorSheet.swift`: 阅读日历与单书工作台复用的相关书籍关系编辑业务 Sheet

Viewer 无内容与无可用内容失败使用 `XMContentStateView`；已有正文时的局部错误卡由页面适配器委托给 `XMInlineStatusBanner`，不得覆盖可信内容。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
