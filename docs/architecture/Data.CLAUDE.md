# Data/
成员清单
- Repositories/BookRepository.swift: 封装书籍列表/详情/书摘查询。
- Repositories/ContentRepository.swift: 封装书摘、书评、相关内容查看、编辑与硬删除事务。
- Repositories/NoteRepository.swift: 封装标签分组与笔记详情读写。
- Repositories/BackupServerRepository.swift: 封装备份服务器配置 CRUD 与连接测试。
- Repositories/BackupRepository.swift: 封装备份/恢复链路。
- Repositories/StatisticsRepository.swift: 封装热力图聚合查询与阅读日历月数据聚合。
- Repositories/ReadCalendarColorRepository.swift: 封装阅读日历封面主色提取、文本可读性计算、失败哈希回退与缓存。
- Repositories/TimelineRepository.swift: 封装时间线 6 路事件查询、排序分组与整月日历标记聚合。
- Repositories/RepositoryContainer.swift: 组装并暴露书籍、笔记、备份、统计、阅读日历取色、时间线仓储入口。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
