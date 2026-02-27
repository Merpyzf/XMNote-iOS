# Data/
> L2 | 父级: /CLAUDE.md

仓储实现层与依赖注入容器。实现 Domain 层定义的 Repository 协议，组合本地数据源。

## Repositories/

- `BookRepository.swift`: BookRepositoryProtocol 实现，书籍列表/详情/书摘查询
- `NoteRepository.swift`: NoteRepositoryProtocol 实现，标签分组与笔记详情读写
- `BackupServerRepository.swift`: BackupServerRepositoryProtocol 实现，备份服务器配置持久化与连通性
- `BackupRepository.swift`: BackupRepositoryProtocol 实现，备份/历史/恢复流程编排
- `StatisticsRepository.swift`: StatisticsRepositoryProtocol 实现，热力图三源聚合查询（阅读时长/笔记数/打卡次数+打卡时长）
- `RepositoryContainer.swift`: App 级 Repository 依赖组装容器，通过 SwiftUI Environment 注入

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
