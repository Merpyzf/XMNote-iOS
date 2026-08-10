# Book/
> L2 | 父级: ViewModels/CLAUDE.md

书籍模块 ViewModel 与单书工作台展示派生层目录。

## 成员清单

- `BookDetailViewModel.swift`: 单书详情、四域内容观察、评分和相关/书评写入状态源
- `BookWorkspacePresentationStore.swift`: 可取消、revision 防竞态的四域展示快照与展开状态仓
- `BookEditorViewModel.swift`: 书籍编辑草稿、元数据和保存状态编排
- `BookReadingDetailViewModel.swift`: 单书阅读记录详情与编辑状态编排
- `ChapterManagerViewModel.swift`: 五层目录展开、搜索、移动、排序、删除和撤销状态编排
- `ChapterBatchImportViewModel.swift`: 章节批量解析、预览与提交状态编排
- `ChapterRemoteSyncViewModel.swift`: 远端目录差异读取与同步状态编排

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
