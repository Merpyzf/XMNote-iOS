# Domain/
> L2 | 父级: /CLAUDE.md

仓储契约层与跨层领域模型。定义 Repository 协议与 ViewModel/Data 共享的数据结构。

## Models/

- `BookModels.swift`: BookItem、BookDetail、NoteExcerpt 书籍域展示模型
- `Tag.swift`: Tag、TagSection 标签域展示模型
- `NoteCategory.swift`: NoteCategory 枚举（书摘/相关/书评三分类）
- `GlobalSearchModels.swift`: 全局搜索分类、筛选范围、结果目标、统一结果与搜索快照模型
- `ContentViewerModels.swift`: ContentViewerSourceContext、ContentViewerItemID、ContentViewerListItem、ContentViewerDetail 等通用内容查看领域模型
- `NoteReviewModels.swift`: NoteReviewSettings、NoteReviewCardItem、NoteReviewTagOption 等书摘回顾领域模型
- `TagManagementModels.swift`: TagManagementScope、TagManagementItem、TagManagementSnapshot 等标签管理领域模型
- `ExternalAppIntegrationModels.swift`: ExternalAppDestination、ExternalAppIntegrationSettings 与发送载荷/结果模型
- `RepositoryModels.swift`: NoteDetailPayload、BackupServerFormInput 仓储 IO 模型
- `HeatmapModels.swift`: HeatmapDay（阅读/书摘/打卡次数+时长+阅读状态分段）与 HeatmapLevel、HeatmapStatisticsDataType、HeatmapBookState 热力图领域模型
- `ReadCalendarModels.swift`: ReadCalendarDay/ReadCalendarMonthData/ReadCalendarEventRun/ReadCalendarEventSegment/ReadCalendarWeekLayout + ReadCalendarSegmentColor（三态：pending/resolved/failed）阅读日历领域模型
- `TimelineModels.swift`: TimelineEvent、TimelineSection、TimelineEventCategory、TimelineDayMarker 等时间线领域模型
- `ReadingDashboardModels.swift`: BookReadingStatus、ReadingDashboardSnapshot、ReadingTrendMetric、ReadingDailyGoal、ReadingResumeBook、ReadingRecentBook、ReadingYearSummary 在读首页领域模型
- `AIModels.swift`: AI 供应商配置、生成请求、流式事件与标签候选领域模型
- `AIPromptEditingModels.swift`: 提示词字段、受控变量、校验问题、试运行书摘/目标/流式事件与唯一请求构建器
- `BookContentWorkspaceModels.swift`: 单书目录/书摘/相关/书评四域、持久化排序与展示快照输入模型
- `BookGroupManagementModels.swift`: 书籍分组管理快照、条目和写入输入模型
- `BookReadingDetailModels.swift`: 阅读详情记录、汇总与编辑草稿模型
- `ChapterBatchImportModels.swift`: 章节文本解析、预览和批量导入结果模型
- `ChapterManagementModels.swift`: 五层章节树、可见节点、移动目标与结构写入模型
- `NoteBatchModels.swift`: 书摘批量选择、合并与批量操作模型
- `NoteImageUploadQuotaModels.swift`: 图片配额快照、消费结果与失败语义
- `ReadCalendarShareModels.swift`: 阅读日历分享卡内容和临时文件模型
- `SourceManagementModels.swift`: 用户/默认来源范围、快照和排序输入模型

## Repositories/

- `RepositoryProtocols.swift`: Book、Note、Content、AI、分组、来源、计时器、图片上传等仓储契约集合
- `BookReadingDetailRepositoryProtocol.swift`: 单书阅读详情观察与写入契约
- `ChapterManagementRepositoryProtocol.swift`: 章节树观察、结构写入与导入契约
- `ReadCalendarRepositoryProtocol.swift`: 月历、每日轨迹、设置与分享数据契约

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
