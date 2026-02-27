# Database/
> L2 | 父级: /CLAUDE.md

GRDB 数据层，负责 SQLite 持久化、Schema 迁移与 Record 类型定义。与 Android Room 完全兼容。

## 顶层成员

- `AppDatabase.swift`: DatabasePool 初始化、迁移执行、生命周期管理
- `AppDatabaseKey.swift`: SwiftUI Environment 注入 Key，提供 `\.appDatabase` 访问
- `DatabaseMigrator+Schema.swift`: 迁移入口，v38 全量 Schema 创建
- `DatabaseSchema+Core.swift`: 核心表 Schema（book/note/tag/author 等）
- `DatabaseSchema+Relation.swift`: 关联表 Schema（tag_note/tag_book/group_book 等）
- `DatabaseSchema+Content.swift`: 内容表 Schema（review/chapter/image 等）
- `DatabaseSchema+Reading.swift`: 阅读表 Schema（read_time_record/read_plan 等）
- `DatabaseSchema+Config.swift`: 配置表 Schema（setting/widget_config/cos_config 等）
- `DatabaseSchema+Seed.swift`: 初始数据填充（默认阅读状态、默认分组等）

## Records/ 子目录（37 个 Record）

每个 Record 对应一张 SQLite 表，遵循 `Codable + FetchableRecord + PersistableRecord` 协议。

- `BaseRecord.swift`: 公共字段协议（created_date/updated_date/last_sync_date/is_deleted）
- `BookRecord.swift`: 书籍表
- `NoteRecord.swift`: 笔记表
- `TagRecord.swift`: 标签表
- `AuthorRecord.swift`: 作者表
- `BackupServerRecord.swift`: 备份服务器配置表
- `BookReadStatusRecordRecord.swift`: 书籍阅读状态记录表
- `CategoryRecord.swift`: 分类表
- `CategoryContentRecord.swift`: 分类内容关联表
- `CategoryImageRecord.swift`: 分类图片表
- `ChapterRecord.swift`: 章节表
- `CheckInRecordRecord.swift`: 打卡记录表
- `CollectionRecord.swift`: 书单表
- `CollectionBookRecord.swift`: 书单-书籍关联表
- `CosConfigRecord.swift`: COS 配置表
- `CoverMosaicRecord.swift`: 封面马赛克表
- `GroupRecord.swift`: 分组表
- `GroupBookRecord.swift`: 分组-书籍关联表
- `ImageRecord.swift`: 图片表
- `PressRecord.swift`: 出版社表
- `ReadPlanRecord.swift`: 阅读计划表
- `ReadStatusRecord.swift`: 阅读状态表
- `ReadTargetRecord.swift`: 阅读目标表
- `ReadTimeRecordRecord.swift`: 阅读时间记录表
- `ReminderEventRecord.swift`: 提醒事件表
- `ReviewRecord.swift`: 书评表
- `ReviewImageRecord.swift`: 书评图片表
- `SettingRecord.swift`: 设置表
- `SortRecord.swift`: 排序表
- `SourceRecord.swift`: 来源表
- `TagBookRecord.swift`: 标签-书籍关联表
- `TagNoteRecord.swift`: 标签-笔记关联表
- `UserRecord.swift`: 用户表
- `WhiteNoiseRecord.swift`: 白噪音表
- `WidgetConfigRecord.swift`: 小组件配置表
- `AttachImageRecord.swift`: 附件图片表

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
