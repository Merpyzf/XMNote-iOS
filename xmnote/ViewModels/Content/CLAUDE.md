# Content/
> L2 | 父级: ViewModels/CLAUDE.md

书摘、书评、相关内容查看与编辑的 ViewModel 目录，承接全屏 viewer、单页详情与最小编辑链路的状态编排。

## 成员清单

- `ContentViewerViewModel.swift`: 通用内容查看状态中枢（混合 feed 分页、详情缓存、预取与删除回退）
- `NoteViewerViewModel.swift`: 书摘查看状态中枢（note-only feed 分页、详情缓存、预取与删除回退）
- `ReviewDetailViewModel.swift`: 书评单页详情状态中枢（加载、刷新与删除）
- `ReviewEditorViewModel.swift`: 书评最小编辑页状态中枢（草稿加载、富文本回填与保存）
- `RelevantDetailViewModel.swift`: 相关内容单页详情状态中枢（加载、刷新与删除）
- `RelevantEditorViewModel.swift`: 相关内容最小编辑页状态中枢（草稿加载、链接编辑与保存）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
