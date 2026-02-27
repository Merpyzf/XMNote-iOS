# UI 核心组件白名单

定义
- 非可复用但承载页面核心业务流程、关键交互入口、关键状态展示的组件。
- 白名单内组件必须同步登记到 `docs/architecture/术语对照表.md`，类别标记为 `UI-核心页面`。

收录规则
- 命中关键业务入口（如备份、详情、主容器切换）。
- 改动会影响核心任务完成路径。
- 仅页面中“核心组件”纳入，普通占位/样式辅助组件不纳入。

组件路径清单
- xmnote/Views/Book/BookContainerView.swift
- xmnote/Views/Book/BookGridView.swift
- xmnote/Views/Book/BookGridItemView.swift
- xmnote/Views/Book/BookDetailView.swift
- xmnote/Views/Note/NoteContainerView.swift
- xmnote/Views/Note/NoteCollectionView.swift
- xmnote/Views/Note/NoteTagsView.swift
- xmnote/Views/Note/NoteDetailView.swift
- xmnote/Views/Personal/Backup/DataBackupView.swift
- xmnote/Views/Personal/Backup/WebDAVServerListView.swift
- xmnote/Views/Personal/Backup/WebDAVServerFormView.swift
- xmnote/Views/Personal/Backup/BackupHistorySheet.swift
- xmnote/Views/Reading/ReadingContainerView.swift
- xmnote/Views/Personal/PersonalView.swift

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
