# UI 核心组件白名单

定义
- 非可复用但承载页面核心业务流程、关键交互入口、关键状态展示的组件。
- 白名单内组件必须同步登记到 `docs/architecture/术语对照表.md`，类别标记为 `UI-核心页面`。

收录规则
- 命中关键业务入口（如备份、详情、主容器切换）。
- 改动会影响核心任务完成路径。
- 仅页面中“核心组件”纳入，普通占位/样式辅助组件不纳入。
- 从公共目录迁回 Feature 的页面私有组件不会自动进入白名单；公共组件以 `scripts/design-system/component-catalog.json` 为完整清单。

组件路径清单
- xmnote/Views/Book/BookContainerView.swift
- xmnote/Views/Book/BookGridView.swift
- xmnote/Views/Book/BookGridItemView.swift
- xmnote/Views/Book/BookDetailView.swift
- xmnote/Views/Book/ChapterManagerView.swift
- xmnote/Views/Book/BookCollectionListView.swift
- xmnote/Views/Book/BookCollectionDetailView.swift
- xmnote/Views/Book/Sheets/BookCollectionCoverSearchSheet.swift
- xmnote/Views/Note/NoteContainerView.swift
- xmnote/Views/Note/NoteCollectionView.swift
- xmnote/Views/Note/NoteTagsView.swift
- xmnote/Views/Note/NoteDetailView.swift
- xmnote/Views/Note/NoteReviewView.swift
- xmnote/Views/Personal/Backup/DataBackupView.swift
- xmnote/Views/Personal/Backup/WebDAVServerListView.swift
- xmnote/Views/Personal/Backup/WebDAVServerFormView.swift
- xmnote/Views/Personal/Backup/Sheets/BackupHistorySheetView.swift
- xmnote/Views/Reading/ReadingContainerView.swift
- xmnote/Views/Reading/ReadingDashboardView.swift
- xmnote/Views/Reading/ReadingHeatmapWidgetView.swift
- xmnote/Views/Reading/ReadCalendar/ReadCalendarView.swift
- xmnote/Views/Reading/Timeline/ReadingTimelineView.swift
- xmnote/Views/Personal/PersonalView.swift
- xmnote/Views/Personal/AIPromptEditorView.swift
- xmnote/Views/Personal/BookGroupManagementView.swift
- xmnote/Views/Personal/SourceManagementView.swift

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
