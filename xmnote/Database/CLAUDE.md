# Database/
> L2 | 父级: /CLAUDE.md

GRDB 数据层，负责 SQLite 持久化、Schema 迁移与 Record 类型定义。当前以 Android Room v40 schema JSON 作为物理结构合同，保证整库备份/恢复场景下的双端识别能力。

## 目录结构

- `Core/`: 数据库入口、SwiftUI Environment 注入、迁移注册与数据库 owner 解析。
- `SchemaContract/`: Android Room v40 物理 Schema 合约、诊断工具与 `RoomSchemaV40.json` 原始契约。
- `Seed/`: 初始数据填充，包括默认用户、来源、阅读状态、书籍、章节、分类与 COS 配置。
- `RestoreCompatibility/`: 备份恢复前的 Schema 校验、staging 数据整理、默认根数据补齐、墓碑记录生成与外键违规读取。
- `Records/`: SQLite 表对应的 GRDB Record 定义，包含 35 个实体 Record 与 `BaseRecord`。

## Core/ 子目录

- `AppDatabase.swift`: DatabasePool 初始化、迁移执行与生命周期管理。
- `AppDatabaseKey.swift`: SwiftUI Environment 注入 Key，提供 `\.appDatabase` 访问。
- `DatabaseMigrator+Schema.swift`: 迁移入口，注册 Room v40 对齐的 Schema 创建与后续迁移。
- `DatabaseOwnerResolver.swift`: 解析当前数据库 owner，统一默认用户与备份恢复场景的归属判断。

## SchemaContract/ 子目录

- `RoomCanonicalSchemaV40.swift`: iOS 端创建 Android Room v40 等价物理 Schema 的唯一契约入口。
- `RoomSchemaDiagnostic.swift`: 对比当前 SQLite Schema 与 Room v40 JSON，输出表、索引、外键与 identityHash 差异。
- `RoomSchemaV40.json`: Android Room 导出的 v40 Schema 原始文件，用于双端数据库对齐校验。

## Seed/ 子目录

- `DatabaseSchema+Seed.swift`: 初始数据填充，保证默认根数据与 Android Room 侧一致。

## RestoreCompatibility/ 子目录

- `BackupSchemaValidator.swift`: 备份恢复前校验 staging 数据库 Schema，并触发受限兼容整理。
- `DefaultRootSeeder.swift`: 补齐备份数据缺失的默认根记录。
- `ForeignKeyViolationReader.swift`: 读取 SQLite 外键违规信息，为恢复兼容修复提供定位数据。
- `StagingIntegrityCanonicalizer.swift`: 在导入正式库前修正 staging 数据的引用完整性。
- `TombstoneFactory.swift`: 为软删除语义生成兼容的墓碑记录。

## Records/ 子目录（35 个实体 Record + BaseRecord）

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
