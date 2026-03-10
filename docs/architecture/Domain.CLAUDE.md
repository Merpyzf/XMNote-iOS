# Domain/
成员清单
- Models/BookModels.swift: 定义 BookItem、BookDetail、NoteExcerpt 书籍域展示模型。
- Models/Tag.swift: 定义 Tag、TagSection 标签域展示模型。
- Models/NoteCategory.swift: 定义笔记分类枚举（书摘/相关/书评）。
- Models/RepositoryModels.swift: 定义 NoteDetailPayload、BackupServerFormInput 仓储 IO 模型。
- Models/HeatmapModels.swift: 定义 HeatmapDay、HeatmapLevel、HeatmapStatisticsDataType、HeatmapBookState 热力图领域模型。
- Models/ReadCalendarModels.swift: 定义 ReadCalendarDay、ReadCalendarMonthData、ReadCalendarEventRun、ReadCalendarEventSegment、ReadCalendarWeekLayout、ReadCalendarSegmentColor 阅读日历领域模型。
- Models/TimelineModels.swift: 定义 TimelineEvent、TimelineSection、TimelineEventCategory、TimelineDayMarker 等时间线领域模型。
- Repositories/RepositoryProtocols.swift: 定义 Book、Note、BackupServer、Backup、Statistics、ReadCalendarColor、Timeline 七类仓储契约。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
