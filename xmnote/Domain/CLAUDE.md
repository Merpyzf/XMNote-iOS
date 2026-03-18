# Domain/
> L2 | 父级: /CLAUDE.md

仓储契约层与跨层领域模型。定义 Repository 协议与 ViewModel/Data 共享的数据结构。

## Models/

- `BookModels.swift`: BookItem、BookDetail、NoteExcerpt 书籍域展示模型
- `Tag.swift`: Tag、TagSection 标签域展示模型
- `NoteCategory.swift`: NoteCategory 枚举（书摘/相关/书评三分类）
- `ContentViewerModels.swift`: ContentViewerSourceContext、ContentViewerItemID、ContentViewerListItem、ContentViewerDetail 等通用内容查看领域模型
- `RepositoryModels.swift`: NoteDetailPayload、BackupServerFormInput 仓储 IO 模型
- `HeatmapModels.swift`: HeatmapDay（阅读/书摘/打卡次数+时长+阅读状态分段）与 HeatmapLevel、HeatmapStatisticsDataType、HeatmapBookState 热力图领域模型
- `ReadCalendarModels.swift`: ReadCalendarDay/ReadCalendarMonthData/ReadCalendarEventRun/ReadCalendarEventSegment/ReadCalendarWeekLayout + ReadCalendarSegmentColor（三态：pending/resolved/failed）阅读日历领域模型
- `TimelineModels.swift`: TimelineEvent、TimelineSection、TimelineEventCategory、TimelineDayMarker 等时间线领域模型
- `ReadingDashboardModels.swift`: BookReadingStatus、ReadingDashboardSnapshot、ReadingTrendMetric、ReadingDailyGoal、ReadingResumeBook、ReadingRecentBook、ReadingYearSummary 在读首页领域模型

## Repositories/

- `RepositoryProtocols.swift`: BookRepositoryProtocol、NoteRepositoryProtocol、ContentRepositoryProtocol、BackupServerRepositoryProtocol、BackupRepositoryProtocol、StatisticsRepositoryProtocol、ReadCalendarColorRepositoryProtocol、TimelineRepositoryProtocol、ReadingDashboardRepositoryProtocol 九个仓储契约

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
