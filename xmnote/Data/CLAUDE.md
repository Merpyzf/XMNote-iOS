# Data/
> L2 | 父级: /CLAUDE.md

仓储实现层与依赖注入容器。实现 Domain 层定义的 Repository 协议，组合本地数据源。

## Repositories/

- `BookRepository.swift`: BookRepositoryProtocol 实现，书籍列表/详情/书摘查询
- `ContentRepository.swift`: ContentRepositoryProtocol 实现，书摘/书评/相关内容的查看、编辑与 Android v45 `is_deleted` 软删除事务
- `AIRepository.swift`: AIRepositoryProtocol 实现，配置读取、单任务 Prompt 原子保存、统一请求预览/并发流式试运行/优化、流式/非流式生成与结果解析
- `BookContentSortQuery.swift`: 单书四域持久化排序规则读取与 SQL 片段映射
- `BookGroupManagementRepository.swift`: BookGroupManagementRepositoryProtocol 实现，分组增改删、关系维护与手动排序事务
- `BookReadingDetailRepository.swift`: BookReadingDetailRepositoryProtocol 实现，单书阅读详情观察与写入
- `ChapterManagementRepository.swift`: ChapterManagementRepositoryProtocol 实现，五层目录、移动、排序和批量导入事务
- `ReadCalendarRepository.swift`: ReadCalendarRepositoryProtocol 实现，月历与每日轨迹聚合读写
- `SourceManagementRepository.swift`: SourceManagementRepositoryProtocol 实现，来源增改删、迁移与排序事务
- `NoteImageUploadQuotaRepository.swift`: 书摘图片上传配额观察与消费事务
- `S3UploadRepository.swift`: 图片对象上传、票据与清理能力实现
- `GlobalSearchRepository.swift`: GlobalSearchRepositoryProtocol 实现，书籍/书摘/相关/书评四类本地全局搜索
- `NoteRepository.swift`: NoteRepositoryProtocol 实现，标签分组、书摘分页搜索范围与笔记详情读写
- `NoteReviewSettingStore.swift`: 书摘回顾设置本地存储与变更广播
- `TagManagementRepository.swift`: TagManagementRepositoryProtocol 实现，书摘/书籍标签管理读写与排序
- `ExternalAppIntegrationRepository.swift`: ExternalAppIntegrationRepositoryProtocol 实现，关联应用配置和书摘发送
- `ExternalAppIntegrationSettingStore.swift`: 关联应用配置本地存储
- `BackupServerRepository.swift`: BackupServerRepositoryProtocol 实现，备份服务器配置持久化与连通性
- `BackupRepository.swift`: BackupRepositoryProtocol 实现，统一编排本地/云端归档、iOS 偏好白名单与数据库恢复后设置应用
- `StatisticsRepository.swift`: StatisticsRepositoryProtocol 实现，热力图聚合查询 + 阅读日历月数据聚合（多事件源按日按书去重、读完计数、最早日期查询）
- `ReadCalendarColorRepository.swift`: ReadCalendarColorRepositoryProtocol 实现，阅读日历封面主色提取（dominant）、文本可读性计算、失败哈希回退与缓存
- `TimelineRepository.swift`: TimelineRepositoryProtocol 实现，时间线 6 路事件查询、合并排序分组与整月日历标记聚合
- `ReadingDashboardRepository.swift`: ReadingDashboardRepositoryProtocol 实现，在读首页仪表盘聚合读取与阅读目标写入
- `RepositoryContainer.swift`: App 级 Repository 依赖组装容器，通过 SwiftUI Environment 注入

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
