# Android Web 增量对齐任务

> Review 日期：2026-07-29
>
> 文档性质：增量任务清单，不替代既有 160 接口历史 Todo 与一致性基线
>
> 本轮范围：只做静态 Review 和任务标识；不修改生产代码、测试、接口清单或数据库文件，不运行构建与测试

## 1. 结论摘要

本次重新从 Android Controller、Service、Repository/DAO、schema 与迁移代码提取事实，没有直接采信旧清单中的完成状态。

| 项目 | Review 结论 |
| --- | --- |
| Android 正式基线 | `43724fb2658008d00954625a06a360cf25e1fecc` |
| Android 未提交改动 | 仅进入候选区，不计入正式任务 |
| iOS Review 基线 | `b456a13b57b42e2857799910003febf06dc49b15` + 当前 `web` 分支工作区 |
| Android Controller | 21 个 |
| Android API | 162 个：`73 GET / 43 POST / 34 PUT / 12 DELETE` |
| Android 最近修复问题 | 67 个，影响现有机器清单中的 105 个唯一接口 |
| 正式实现待办 | 6 项 |
| 正式复验待办 | 5 项 |
| 无需 iOS 任务 | 2 个 Android 专属问题 |
| 候选任务 | 3 项，均等待 Android 提交冻结 |
| 本文任务复选框 | 14 个：11 个正式任务 + 3 个候选任务 |

正式任务中，当前已确认的高风险缺口是：

1. iOS 缺少 Notion 连接状态查询、原生连接入口及其设置/远端导出分支。
2. Android 已将最终数据库合同冻结在 v45，iOS 当前仍是开发阶段的 v45 + v46 中间结构，并缺少 `note_import_hash`。
3. iOS 尚未实现导入章节身份保护、书摘 Hash 懒回填，以及移动、合并、删除过程中的 Hash 生命周期。
4. iOS 分组置顶仍只读取分组最大 `pin_order`，没有纳入顶层书籍共享序列。
5. iOS 设置写入和 AI 配置持久化失败的错误码、稳定文案与 Android 当前合同仍不一致。
6. 机器清单虽然已有 162 条，但证据 revision 与旧 160 接口文档均已漂移，需要在实现完成后统一刷新。

## 2. Review 边界与事实来源

### 2.1 正式事实

- Android 接口统计来自对正式基线提交下 `web/src/main/java/com/merpyzf/web/controller` 的独立扫描：分别统计 `GetMapping`、`PostMapping`、`PutMapping`、`DeleteMapping`，结果为 162 条。
- Android 67 个已修复问题来自 `docs/feature/Android Web API R8 Full Mode Review结论.md:15-30` 及其逐项核实表；其中只有 `ANDROID-WEB-087`、`ANDROID-WEB-094` 是 R8 Full Mode 专属问题。
- 105 个受影响接口由 67 个问题 ID 与 iOS 当前 `endpoint-manifest.json` 每条 endpoint 的 `issueIds` 重新做集合关联得到；它是按既有逐接口标注计算的唯一接口数，不能把各任务分组数量直接相加。`ANDROID-WEB-088` 另有 43 条 `crossCuttingIssueCoverage` 合同矩阵，由 `WEB-DELTA-011` 单独全量复验，不反向改写本轮约定的 105 条逐接口统计。
- Android v45 最终数据库结构以正式基线中的 `DBConfig.java`、`MIGRATION_44_45.kt` 和 Room `45.json` 为准，不以 iOS 当前命名为 v45/v46 的开发中间结构为准。

### 2.2 已知基线漂移

| 载体 | 当前记录 | 与正式基线的差异 |
| --- | --- | --- |
| `API迁移Todo.md:3-15` | Android `9aca6bbb...`；160 API；72 GET / 42 POST | 少 2 个 Notion API，revision 过旧 |
| `API一致性基线.md:5-24` | 160 / 160；Android `9aca6bbb...` | 结论只对旧 APK 与旧 Controller 成立 |
| `endpoint-manifest.json:3-16` | 162 API；Android `fe5cde39...` | 数量已更新，但不是本次正式基线 `43724fb...` |
| `endpoint-manifest.json:35-57` | 2 个 Notion API 为 `deferred-p0`，3 条共享分支延期 | 正确暴露了缺口，但还没有 iOS 实现与新基线运行证据 |

本轮保持上述三个既有载体原样。只有完成本文正式实现与复验任务后，才由 `WEB-DELTA-006` 一次性刷新它们，避免再次出现“文档先宣告 exact、实现和证据仍在变化”的状态。

## 3. 正式实现待办

### [ ] WEB-DELTA-001：补齐 Notion 连接查询、原生连接入口与导出分支

- **优先级 / 类型**：P0 / 实现待办
- **评估**：功能优化；Android 已形成可观察的 OAuth 连接闭环，iOS 缺失属于功能未迁移，不是平台有意差异。
- **受影响 API / 数据库**：
  - `GET /api/v1/export/platforms/notion/connection`
  - `POST /api/v1/native/actions/open-notion-connection`
  - `GET /api/v1/settings/export`
  - `PUT /api/v1/settings/export`
  - `POST /api/v1/export/notes/remote`
  - `notion_page_sync`、`notion_block_sync`、`notion_sync_operation`
- **Android 证据**：
  - `web/src/main/java/com/merpyzf/web/controller/ExportController.kt:27-35@43724fb` 注册连接状态查询。
  - `web/src/main/java/com/merpyzf/web/controller/NativeActionController.kt:24-34@43724fb` 注册原生连接入口。
  - `web/src/main/java/com/merpyzf/web/dto/NotionConnectionDto.kt:3-20@43724fb` 定义请求、受理结果和连接状态字段。
  - `web/src/main/java/com/merpyzf/web/service/NotionConnectionWebService.kt:31-96@43724fb` 是连接尝试、状态读取与 mode 归一化 owner。
- **iOS 证据**：
  - `Packages/XMNoteWeb/Sources/XMNoteWeb/Routing/DesktopWebExportRoutes.swift:11-17` 只有 4 条旧导出路由。
  - `Packages/XMNoteWeb/Sources/XMNoteWeb/Routing/DesktopWebSettingsRoutes.swift:10-19` 只有高级版原生动作与设置路由。
  - `Packages/XMNoteWeb/Sources/XMNoteWeb/API/DesktopWebAPIContract.swift:132-165` 只有通用原生动作结果，没有 Notion 请求、结果、状态 DTO 或端口。
  - `xmnote/Infra/DesktopWeb/DesktopWebExportService.swift:239-247` 仍从 `notionToken`、`notionPageId` 走旧 Integration Token 分支。
- **真实 owner / 写入点 / 触发时机**：
  - Android owner 是 `NotionConnectionWebService`、OAuth token/attempt store 与 `NoteExportWebService`；连接入口触发时创建 attempt，状态查询读取 token 与 attempt，远端导出触发 Notion 同步写入。
  - iOS 应由 XMNoteWeb 路由端口进入 `DesktopWebAPIAdapter`，再由 Repository/Service 持有凭据、连接状态和远端副作用；路由层不得直接访问数据库或导航状态。
- **差异说明**：iOS 不只是少两条 route；当前设置 DTO、依赖注入、原生动作、OAuth 状态轮询和远端导出前置条件均未形成正式 Android 合同。
- **依赖关系**：数据库写入依赖 `WEB-DELTA-002`；完成后由 `WEB-DELTA-006` 更新机器清单和基线。
- **完成标准**：
  1. 两条新增 API 的 method/path、请求默认值、字段可空性、`code/msg/data`、错误码与 Android 正式基线一致。
  2. `connect/reconnect/manage` 三种 mode、attempt 生命周期、过期/取消/失败状态均可验证。
  3. 设置读取/更新与远端导出的 Notion 分支改用正式连接合同，不再把旧 token/page ID 分支误当成已对齐实现。
  4. 原生 UI 拉起失败时有与 iOS 生命周期相符的可恢复路径；可观察 HTTP 合同仍与 Android 一致。
  5. 差分用例覆盖“未连接、连接中、已连接、失效、用户取消、导出成功/部分失败”。
- **Android 反向优化建议**：把 attempt 状态值和错误码沉淀为显式公共合同，避免 Web DTO、Activity 与通知回退分支各自维护字符串。

### [ ] WEB-DELTA-002：将 iOS 数据库收敛到 Android 最终 v45 物理合同

- **优先级 / 类型**：P0 / 实现待办
- **评估**：功能优化；数据库结构不一致会破坏 Android ↔ iOS 备份恢复和 Web 导入去重，必须按 Android 正式结构收敛。
- **受影响 API / 数据库**：所有数据库型 Web API；直接涉及 Notion 导出、章节导入、书摘创建/更新/移动/合并/删除。重点表为 `notion_page_sync`、`notion_block_sync`、`notion_sync_operation`、`note_import_hash`。
- **Android 证据**：
  - `common/src/main/java/com/merpyzf/common/constant/DBConfig.java:9-15@43724fb` 明确 `DB_VERSION = 45`。
  - `data/src/main/java/com/merpyzf/data/db/migrate/MIGRATION_44_45.kt:7-13@43724fb` 声明 v44 后唯一迁移，并把 Notion 最终结构与 `note_import_hash` 一次创建。
  - 同文件 `:18-50` 的 `notion_page_sync` 没有 `scope`，唯一键是 `(connection_key, data_source_id, book_id)`，并直接包含 `metadata_fingerprint`、`content_fingerprint`、`remote_last_edited_time`、`last_exported_title`。
  - 同文件 `:55-109` 的 Block/Operation 外键均为 `ON DELETE CASCADE`；`:112-126` 创建 `note_import_hash`，主键为 `(book_id, content_hash)`，并为 `note_id` 建索引。
- **iOS 证据**：
  - `xmnote/Database/Core/AppDatabase.swift:21-28` 把当前版本指向 `RoomCanonicalSchemaV46`。
  - `xmnote/Database/Core/DatabaseMigrator+Schema.swift:11-22,51-57,94-99` 把开发中的 Notion 结构拆成 v45 与 v46 两次迁移。
  - `xmnote/Database/SchemaContract/RoomCanonicalSchemaV45.swift:11-57` 含 Android 当前已不存在的 `scope` 字段与四列唯一索引。
  - `xmnote/Database/SchemaContract/RoomCanonicalSchemaV46.swift:11-58` 只追加 `source_fingerprint`、远端编辑时间和标题，仍没有 Android 最终的两类 fingerprint。
  - `xmnote/Database/SchemaContract/RoomCanonicalSchemaCompatibility.swift:13-25,42-49` 仍把 v46 当作最高可恢复版本。
  - iOS v45/v46 schema、migration、Record 和 SQL 中均不存在 `note_import_hash`。
- **真实 owner / 写入点 / 触发时机**：
  - Android schema owner 是 `NoteDatabase` + `MIGRATION_44_45`；App 首次打开 v44 库时执行迁移。
  - iOS owner 是 `AppDatabase.migrator`、`RoomCanonicalSchemaCompatibility` 与 Room schema 资源；数据库打开、Android 备份恢复 staging 校验时触发。
- **差异说明**：同名 v45 实际不是同一结构，iOS v46 也不是 Android 正式版本。继续沿用会导致 `user_version`、Room identity hash、表列、索引和恢复闸门同时失真。
- **数据库核对清单**：

| 维度 | Android 正式事实 | iOS 后续完成要求 |
| --- | --- | --- |
| schema | 最终版本 45；四张新增表 | 最终物理表、列顺序、非空/default、PK/index 与 Android `45.json` 一致 |
| migration | 只保留 `44 → 45` 正式迁移 | 不再把开发中 v45/v46 当成 Android 正式序列；先给出已有 iOS 开发库的安全处置方案 |
| seed | 新表无 seed；既有 seed 不变 | 不为四张新表自造 seed，不改变既有 seed 顺序 |
| 外键/级联 | Notion 子表级联；`note_import_hash` 无外键 | 精确复刻，不额外加外键或级联 |
| 事务 | Room migration 原子执行；业务 Hash 生命周期由 Service `withTransaction` 收口 | 迁移失败不得留下半结构；业务事务见 `WEB-DELTA-003` |
| 冲突策略 | Hash 插入为 `IGNORE` | GRDB 使用等价冲突策略，不以 replace 改写既有 `note_id` |
| 读写 SQL | Hash 按 `note_id` 查询/删除，唯一性按 `book_id + content_hash` | SQL 条件、分批边界、`is_deleted` 语义与 Android 一致 |

- **依赖关系**：阻塞 `WEB-DELTA-001`、`WEB-DELTA-003`；完成后由 `WEB-DELTA-006` 刷新 schema digest 与基线。
- **完成标准**：
  1. 新库、v44 升级库、Android v45 恢复库的 `user_version`、Room identity hash、表/索引/外键完全一致。
  2. 物理 schema 对比必须使用 Android 正式 `45.json`，不能只比较 Swift 枚举常量。
  3. 对当前 iOS 开发 v45/v46 库先给出可回滚的数据迁移或明确的开发库重建方案，不静默降级或覆盖。
  4. migration、seed、外键、事务、冲突策略和关键 SQL 均有独立可验证证据。
- **Android 反向优化建议**：在正式交付产物中固定 `45.json` 的 digest 与一份最小 v44 fixture，供另一端直接做物理结构和迁移结果校验。

### [ ] WEB-DELTA-003：补齐导入章节身份与书摘 Hash 生命周期

- **优先级 / 类型**：P0 / 实现待办
- **评估**：功能优化；缺少稳定身份与去重 Hash 会导致再次导入重复章节/书摘，并在移动、合并后失去去重能力。
- **受影响 API / 数据库**：
  - 章节：`WEB-API-038`、`040-046`、`050`
  - 导入任务：`WEB-API-063`、`064`、`065`
  - 书摘：`WEB-API-075-082`
  - 数据库：`chapter.source_type/source_uid`、`note_import_hash`
- **Android 证据**：
  - `data/src/main/java/com/merpyzf/data/dao/web/WebChapterDao.kt:82-83@43724fb` 提供导入身份更新 SQL。
  - `web/src/main/java/com/merpyzf/web/repository/WebChapterRepository.kt:79-92@43724fb` 收集并保护已导入章节身份。
  - `web/src/main/java/com/merpyzf/web/service/ChapterService.kt:298,359,381,413,451,501,534@43724fb` 在章节改名、移动、删除、排序等写入前触发身份保护。
  - `data/src/main/java/com/merpyzf/data/dao/web/WebNoteDao.kt:75-88@43724fb` 定义 Hash 查询、`IGNORE` 插入与删除。
  - `web/src/main/java/com/merpyzf/web/repository/WebNoteRepository.kt:1084-1142@43724fb` 负责懒回填、跨书移动、合并转移和批量插入。
  - `web/src/main/java/com/merpyzf/web/service/NoteService.kt:537-543,754-759,877-887,937-949@43724fb` 在移动、合并、软删除事务中维护 Hash。
- **iOS 证据**：
  - `xmnote/Data/Repositories/DesktopWebChapterRepository+Import.swift:360-399` 导入章节把 `sourceUid` 写为空字符串。
  - `xmnote/Data/Repositories/DesktopWebChapterRepository+Writes.swift:427` 的写路径同样创建空 `sourceUid`，没有 Android 的身份保护调用。
  - `xmnote/Data/Repositories/DesktopWebNoteRepository+Writes.swift:337-350` 合并只处理 note/tag/image；`:680-723` 跨书创建章节仍写 `sourceType = 0`、`sourceUid = ""`。
  - iOS 当前数据库和 Repository 没有 `note_import_hash` Record、查询、写入或生命周期方法。
- **真实 owner / 写入点 / 触发时机**：
  - Android owner 是 `ChapterService`/`NoteService`，Repository/DAO 是真实写入点；在章节结构变更、书摘移动、合并、删除和下次导入去重时触发。
  - iOS 应由 `DesktopWebChapterRepository`、`DesktopWebNoteRepository` 通过 `AppDatabase` 事务写入，不能放到路由或 ViewModel。
- **差异说明**：iOS 当前只对标题与层级做匹配；章节一旦被 Web 修改就可能丢失导入来源身份。书摘完全没有跨导入周期的 Hash 事实源。
- **依赖关系**：依赖 `WEB-DELTA-002` 创建最终表；完成后进入 `WEB-DELTA-008` 章节/书摘复验和 `WEB-DELTA-006` 基线刷新。
- **完成标准**：
  1. 章节所有可能改变树身份的写入口都在同一事务内先保护 `source_type/source_uid`。
  2. 存量书摘在相关书籍下次导入时懒回填 Hash，不要求一次性全库扫描。
  3. 同书移动保留/补齐 Hash；跨书移动把 Hash 主键作用域切到目标书；合并把所有来源 Hash 转移到新 note；普通删除清除 Hash。
  4. Hash 算法、空内容处理、换行归一化、图片摘要边界与 Android 一致。
  5. 冲突使用 `IGNORE`，不得因重复导入把既有 Hash 所属 note 静默替换。
- **Android 反向优化建议**：把章节 identity 与 note hash 生命周期矩阵放进共享迁移说明，避免未来 App 写路径新增动作时漏接保护逻辑。

### [ ] WEB-DELTA-004：修正分组置顶的顶层共享序列

- **优先级 / 类型**：P1 / 实现待办
- **评估**：功能优化；Android 已把顶层书籍与分组收敛到同一混排序列，iOS 分组路径仍保留旧缺陷。
- **受影响 API / 数据库**：
  - `PUT /api/v1/groups/{id}/pin`（`WEB-API-060`）
  - 回归覆盖 `PUT /api/v1/books/{id}/pin`（`WEB-API-012`）与批量置顶（`WEB-API-018`）
  - `book.pinned/pin_order`、`group.pinned/pin_order`
- **Android 证据**：
  - `web/src/main/java/com/merpyzf/web/service/GroupService.kt:101-117@43724fb` 分组置顶调用共享最大值。
  - `web/src/main/java/com/merpyzf/web/repository/WebBookRepository.kt:881-886,894-906@43724fb` 同时读取书籍、分组最大 `pin_order`。
- **iOS 证据**：
  - `xmnote/Data/Repositories/DesktopWebGroupRepository.swift:293-310` 只执行 `SELECT MAX(pin_order) FROM group`，并保留 `NOTE(ANDROID-WEB-015)`。
  - `xmnote/Data/Repositories/DesktopWebBookRepository+Writes.swift:335-381` 的顶层书籍路径已正确比较 book/group 两类最大值。
- **真实 owner / 写入点 / 触发时机**：owner 是两端 Group/Book Repository；用户从 Web 置顶一个顶层分组或书籍时读取共享最大值并写入目标行。
- **差异说明**：只有 iOS 分组入口仍未使用已存在的共享算法，会生成与书籍重复或倒退的 `pin_order`。
- **依赖关系**：无数据库版本依赖；完成后进入 `WEB-DELTA-007` 书架域复验。
- **完成标准**：
  1. 顶层分组置顶读取有效置顶书籍与有效置顶分组的共同最大值。
  2. 分组内书籍置顶仍只在目标分组作用域计算，不误用顶层共享序列。
  3. 幂等置顶、取消置顶、Kotlin `Int` 溢出语义与 Android 一致。
  4. 用交错 book/group 数据验证返回值、数据库值和书架 manifest 顺序。
- **Android 反向优化建议**：将共享最大值提升为书架排序域的单一方法，避免 GroupService 反向依赖 WebBookRepository。

### [ ] WEB-DELTA-005：收敛设置与 AI 配置写入失败合同

- **优先级 / 类型**：P1 / 实现待办
- **评估**：功能优化；当前 iOS 会泄漏本地异常详情或落入通用服务器错误，Android 已使用稳定业务错误。
- **受影响 API / 数据库**：
  - `PUT /api/v1/settings/web`
  - `PUT /api/v1/settings/export`
  - `PUT /api/v1/ai/config`
  - UserDefaults/设置 Repository；无 SQLite schema 变化
- **Android 证据**：
  - `web/src/main/java/com/merpyzf/web/controller/SettingsController.kt:55-74@43724fb` 固定返回 `40001 / 设置更新失败` 或 `40001 / 导出设置更新失败`。
  - `web/src/main/java/com/merpyzf/web/controller/AIController.kt:89-124@43724fb` 解析后捕获持久化异常并返回 `40001 / 配置更新失败`。
- **iOS 证据**：
  - `Packages/XMNoteWeb/Sources/XMNoteWeb/Routing/DesktopWebSettingsRoutes.swift:41-64` 返回 code `400`，并拼接 `error.localizedDescription`。
  - `Packages/XMNoteWeb/Sources/XMNoteWeb/Routing/DesktopWebAIRoutes.swift:24-36` 没有把端口持久化失败归一到 `40001 / 配置更新失败`。
  - `Packages/XMNoteWeb/Sources/XMNoteWeb/API/DesktopWebAPIContract.swift:276-308` 已能稳定生成 Android JSON 包络，差异在 route 错误选择而不是编码器。
- **真实 owner / 写入点 / 触发时机**：route 只负责合同映射；真实写入 owner 是 `DesktopWebSettingsRepository`、`DesktopWebAIService` 的设置存储。用户提交合法 JSON、底层持久化失败时触发。
- **差异说明**：非法 JSON 入口已静态对齐，但“合法请求 + 写入失败”仍返回不同 code/message，并可能暴露 iOS 内部错误文本。
- **依赖关系**：与候选 DeepSeek/PDF 合同分离；正式修复只对齐 `43724fb`，完成后由 `WEB-DELTA-011` 复验错误合同。
- **完成标准**：
  1. 三条 API 的合法写入失败均返回 Android 当前固定 code/message，不拼接底层异常。
  2. 空体、畸形 JSON、顶层类型错误仍由统一严格解码合同处理。
  3. 成功路径不改变现有局部 patch 与持久化副作用。
- **Android 反向优化建议**：把三类稳定写错误提取为统一错误常量，避免 Controller 文案再次漂移。

### [ ] WEB-DELTA-006：刷新 162 接口机器清单与正式一致性基线

- **优先级 / 类型**：P1 / 实现待办（基线治理）
- **评估**：功能优化；这不是生产行为改动，但不刷新会继续让 `exact` 指向旧 Android 事实。
- **受影响 API / 数据库**：全部 162 个 API；不直接写业务数据库。需要同步 `endpoint-manifest.json`、`API迁移Todo.md`、`API一致性基线.md` 及相应差分证据。
- **Android 证据**：
  - 正式 Controller 扫描结果为 162：`73 GET / 43 POST / 34 PUT / 12 DELETE`。
  - `ExportController.kt:27-35@43724fb` 与 `NativeActionController.kt:24-34@43724fb` 是相对旧 160 清单新增的两条路由。
- **iOS 证据**：
  - `API迁移Todo.md:3-15` 和 `API一致性基线.md:5-24` 仍冻结 160 条、`9aca6bbb...`。
  - `endpoint-manifest.json:3-16` 虽为 162 条，但 sourceRevision 是 `fe5cde39...`。
- **真实 owner / 写入点 / 触发时机**：owner 是 parity manifest 与差分证据生成流程；只在正式实现任务和复验任务完成后写入，不能在中途提前标记 `exact`。
- **差异说明**：当前存在“三套正确性”：旧人工文档 160、机器清单 162、正式目标 revision 43724fb。数量相同不等于证据基线相同。
- **依赖关系**：依赖 `WEB-DELTA-001` 至 `WEB-DELTA-005`、`WEB-DELTA-007` 至 `WEB-DELTA-011` 全部完成；候选任务不阻塞。
- **完成标准**：
  1. 从 `43724fb` 重新生成 21 Controller、162 API、HTTP 方法统计与源码行号。
  2. 每个 `exact` 均绑定新 Android revision、产物信息和双端运行证据；未取得证据的条目保持 pending/deferred。
  3. 两条 Notion API 与三条共享分支不再使用过期 `deferred-p0` 状态。
  4. 67 个修复项及 105 个受影响接口的复验结果可从机器清单反查。
  5. 三个载体的数量、revision、状态统计一致，且不混入任何 Android 未提交候选合同。
- **Android 反向优化建议**：提供由 Controller 生成的稳定路由 manifest，并把提交 SHA、Controller digest 和 APK digest 作为同一份产物元数据输出。

## 4. 正式复验待办

以下项目的 iOS 当前代码静态上已收敛到 Android 修复后的方向，但现有 `exact` 证据仍绑定旧 Android revision，因此不能直接宣告完成。

### [ ] WEB-DELTA-007：复验标签、分组、书籍、书架与日历行为

- **优先级 / 类型**：P1 / 复验待办
- **覆盖 Android 修复项（15）**：`004`、`007`、`009`、`010`、`011`、`014`、`016`、`017`、`018`、`019`、`020`、`021`、`022`、`092`、`093`
- **受影响 API / 数据库**：`WEB-API-006`、`010`、`012`、`014-016`、`018-019`、`022-023`、`029`、`031-033`、`056`、`059`、`155`；涉及 tag/group/book、各关系表、阅读状态历史与 bookshelf 排序。
- **Android 证据**：`TagService.kt:111@43724fb`、`GroupService.kt:72-123@43724fb`、`BookService.kt:451,1130-1600@43724fb`、`WebBookRepository.kt:876-906@43724fb`、`CalendarWebService.kt:93@43724fb`。
- **iOS 证据**：`DesktopWebCatalogRepository.swift:320`、`DesktopWebGroupRepository.swift:256-325`、`DesktopWebBookRepository+Batch.swift:13-330`、`DesktopWebBookRepository+Bookshelf.swift:51-210,627-690`、`DesktopWebBookRepository+Mutation.swift:13-230`、`DesktopWebCalendarRepository.swift:111-260`。
- **真实 owner / 写入点 / 触发时机**：两端 Service/Repository 是 owner，DAO/GRDB SQL 是写入点；标签/分组删除、书籍创建/更新/恢复/批量移动/重排、月/日历查询时触发。
- **差异说明**：当前未发现除 `WEB-DELTA-004` 外的新静态差异；风险在事务回滚、无效父资源、重复 ID、日期边界和 manifest 作用域仍只有旧证据。
- **依赖关系**：先完成 `WEB-DELTA-004`；结果交给 `WEB-DELTA-006`。
- **完成标准**：在同一冻结数据集上逐项对比响应、事务边界、关系 tombstone、排序值、时间戳和失败回滚；15 个问题 ID 每个至少有一条新 revision 差分证据。

### [ ] WEB-DELTA-008：复验章节、书摘与搜索行为

- **优先级 / 类型**：P1 / 复验待办
- **覆盖 Android 修复项（12）**：`024`、`025`、`026`、`027`、`028`、`029`、`030`、`031`、`032`、`033`、`034`、`035`
- **受影响 API / 数据库**：`WEB-API-038`、`040-046`、`050`、`068-069`、`072-082`、`118-119`；涉及 chapter/note/tag_note/attach_image 及导入身份、Hash。
- **Android 证据**：`ChapterService.kt:164,351-570@43724fb`、`WebChapterRepository.kt:56-105@43724fb`、`NoteService.kt:391-950@43724fb`、`WebNoteRepository.kt:95-240,983-1142@43724fb`。
- **iOS 证据**：`DesktopWebChapterRepository+Import.swift:77-399`、`DesktopWebChapterRepository+Writes.swift:13-620`、`DesktopWebNoteRepository.swift:95-720`、`DesktopWebNoteRepository+Writes.swift:13-790`、`DesktopWebSearchRepository.swift:120-520`。
- **真实 owner / 写入点 / 触发时机**：Chapter/Note Repository 是 owner，GRDB 事务与关系表 SQL 是写入点；章节删除/移动/导入、书摘 CRUD/批量/合并和搜索时触发。
- **差异说明**：当前主要新增实现缺口已拆到 `WEB-DELTA-002/003`；其余 12 项静态方向一致，但没有绑定 `43724fb` 的响应与数据库副作用证据。
- **依赖关系**：先完成 `WEB-DELTA-002`、`WEB-DELTA-003`；结果交给 `WEB-DELTA-006`。
- **完成标准**：覆盖父书有效性、事务回滚、重复标签、图片真实 ID、富文本/位置校验、删除标签语义和重复合并顺序；同时验证身份/Hash 不被这些写入破坏。

### [ ] WEB-DELTA-009：复验书评、阅读记录、相关内容与混合搜索

- **优先级 / 类型**：P1 / 复验待办
- **覆盖 Android 修复项（19）**：`036`、`037`、`038`、`039`、`040`、`041`、`042`、`043`、`044`、`045`、`046`、`048`、`050`、`051`、`052`、`053`、`054`、`055`、`057`
- **受影响 API / 数据库**：`WEB-API-056`、`083`、`085-088`、`091-092`、`095`、`098-111`、`114-119`；涉及 review/review_image、reading_record、related_category/related_note/图片关系和来源书过滤。
- **Android 证据**：`ReviewService.kt:88-220@43724fb`、`ReadingRecordWebService.kt:45-140@43724fb`、`RelatedService.kt:100-470@43724fb`、`WebRelatedRepository.kt:81-187@43724fb`。
- **iOS 证据**：`DesktopWebReviewRepository.swift:30-410`、`DesktopWebReviewRepository+Writes.swift:13-180`、`DesktopWebReadingRecordRepository.swift:30-420`、`DesktopWebRelatedRepository.swift:80-430`、`DesktopWebRelatedRepository+Writes.swift:13-500`。
- **真实 owner / 写入点 / 触发时机**：Review/ReadingRecord/Related Repository 是 owner，各主表与图片/类别关系 SQL 是写入点；草稿、CRUD、批量删除/换类、分页和搜索时触发。
- **差异说明**：静态代码已采用修复后的主资源校验、事务、图片 ID、空分页与溢出策略；仍需证明失败路径和边界数据与当前 Android 一致。
- **依赖关系**：无 schema 新增依赖；结果交给 `WEB-DELTA-006`。
- **完成标准**：19 个问题 ID 逐项覆盖隐藏数据、空 URL、草稿一致性、word count、未完成计时、时间单位、类别 owner/生命周期、分页溢出与来源过滤。

### [ ] WEB-DELTA-010：复验统计时间边界与聚合精度

- **优先级 / 类型**：P1 / 复验待办
- **覆盖 Android 修复项（8）**：`059`、`060`、`062`、`064`、`065`、`067`、`069`、`090`
- **受影响 API / 数据库**：`WEB-API-132-137`、`140`、`145-151`；涉及 read_done、reading_record、note/tag 统计、read_target 与本地日期范围。
- **Android 证据**：`StatisticsWebService.kt:90-700@43724fb` 及对应统计 DAO 的范围 SQL。
- **iOS 证据**：`DesktopWebStatisticsRepository.swift:178-520`、`DesktopWebStatisticsRepository+Overview.swift:74-340`、`DesktopWebStatisticsRepository+Heatmap.swift:31-230`、`DesktopWebStatisticsRepository+Charts.swift:20-280`。
- **真实 owner / 写入点 / 触发时机**：Statistics Repository/DAO 是 owner；绝大多数为只读聚合，年度目标写入由 read_target 相关 SQL 负责；月、周、年与图表查询时触发。
- **差异说明**：静态实现已修复宽松月份、真实今天锚点、显示文本精度、图表桶、删除打卡范围和年度最后 999ms 等问题，但旧运行证据不足。
- **依赖关系**：结果交给 `WEB-DELTA-006`。
- **完成标准**：使用月边界、跨年、请求时刻带毫秒、空数据、删除数据、极大字数和时区日期 fixture，逐项对比范围端点、桶数量、精度与返回年份/月。

### [ ] WEB-DELTA-011：复验 HTTP/异常、导入、上传、导出与 AI 边界

- **优先级 / 类型**：P1 / 复验待办
- **覆盖 Android 修复项（9）**：`071`、`072`、`073`、`076`、`081`、`082`、`083`、`085`、`088`
- **受影响 API / 数据库**：
  - 直接接口：`WEB-API-003`、`024`、`053`、`063`、`065`、`158`
  - `ANDROID-WEB-088` 的 43 条 JSON 请求：`WEB-API-037-039`、`041-046`、`049-050`、`057-058`、`060-062`、`065`、`071`、`075-076`、`078-082`、`091-093`、`095`、`097`、`102-103`、`105-106`、`109`、`113`、`115-116`、`153-154`、`156-157`、`159`
  - 全部 JSON 包络接口的 Content-Type
  - 导入 task actor 状态、上传 ticket store；无 schema 新增
- **Android 证据**：`GsonMessageConverter.kt:29-61@43724fb`、`GlobalExceptionResolver.kt:21-72@43724fb`、`ImportTaskService.kt:61-130@43724fb`、`NoteExportWebService.kt:198,853@43724fb`、`AIController.kt:131-230@43724fb`。
- **iOS 证据**：
  - `DesktopWebAPIContract.swift:276-308` 固定 JSON Content-Type 与包络。
  - `DesktopWebImportService.swift:51-125,449-485` 有提交互斥、路径穿越与解压总量保护。
  - `DesktopWebExportService.swift:94-130,1023-1049` 在内存返回并用 `defer` 清理 ZIP 临时文件。
  - `DesktopWebUploadService.swift:251-303` 已使过期凭证专用分支可达。
  - `DesktopWebAIService.swift:86-175` 已约束关闭开关并用 JSON 序列化生成 SSE 错误。
- **真实 owner / 写入点 / 触发时机**：HTTP middleware/route 负责通用合同；Import/Upload/Export/AI Service 负责状态与外部副作用；畸形请求、并发提交、恶意压缩包、凭证过期、AI 关闭和流中断时触发。
- **差异说明**：静态代码已沿修复方向实现，但 43 条 JSON 请求、二进制响应、SSE 与并发状态机需要当前 Android 产物级证据；`WEB-DELTA-005` 的合法写入失败缺口必须先修。
- **依赖关系**：先完成 `WEB-DELTA-005`；结果交给 `WEB-DELTA-006`。
- **完成标准**：逐项验证 HTTP status、Content-Type、CORS、稳定 code/message、空体/畸形/顶层类型、并发提交、ZIP 限制、文件回收、ticket 过期、AI 禁用与 SSE 转义/终止。

## 5. 67 个 Android 已修复问题的完整归类

下表中每个问题 ID 恰好出现一次。实现与复验分组共 65 个，另外 2 个为 Android 专属 R8 问题；合计 67。

| 分类 | 归属 | 数量 | Android 问题 ID |
| --- | --- | ---: | --- |
| 实现待办 | `WEB-DELTA-004` | 1 | `015` |
| 实现待办 | `WEB-DELTA-005` | 1 | `089` |
| 复验待办 | `WEB-DELTA-007` | 15 | `004`、`007`、`009`、`010`、`011`、`014`、`016`、`017`、`018`、`019`、`020`、`021`、`022`、`092`、`093` |
| 复验待办 | `WEB-DELTA-008` | 12 | `024`、`025`、`026`、`027`、`028`、`029`、`030`、`031`、`032`、`033`、`034`、`035` |
| 复验待办 | `WEB-DELTA-009` | 19 | `036`、`037`、`038`、`039`、`040`、`041`、`042`、`043`、`044`、`045`、`046`、`048`、`050`、`051`、`052`、`053`、`054`、`055`、`057` |
| 复验待办 | `WEB-DELTA-010` | 8 | `059`、`060`、`062`、`064`、`065`、`067`、`069`、`090` |
| 复验待办 | `WEB-DELTA-011` | 9 | `071`、`072`、`073`、`076`、`081`、`082`、`083`、`085`、`088` |
| 无需任务 | Android R8 专属 | 2 | `087`、`094` |

### 无需任务说明

| 问题 | Android 事实 | iOS 事实 | 结论 |
| --- | --- | --- | --- |
| `ANDROID-WEB-087` | AndServer `TypeWrapper<DTO>` 泛型签名被 R8 Full Mode 移除；由 `web/consumer-rules.pro` 修复 | iOS 使用 Hummingbird/Swift Codable，不存在 AndServer、JVM 泛型签名或 R8 | 无需 iOS 实现；只需在 `WEB-DELTA-006` 中移除旧 Android 失败产物对 `exact` 证据的污染 |
| `ANDROID-WEB-094` | Apache HttpCore `ResponseContent` 被 R8 优化后导致正式包响应 Header 漂移；Android 已定向 keep 并统一 `JsonBody` | `DesktopWebAPIResponse` 显式写 `application/json;charset=UTF-8`，不经过 Apache HttpCore/R8 | 无需 iOS 实现；通用 Content-Type 仍由 `WEB-DELTA-011` 对当前产物复验 |

## 6. Android 未提交候选任务

候选任务全部排除在 11 个正式任务、67 个修复项与 105 个受影响接口的正式统计之外。状态统一为：**等待 Android 提交冻结**。

### [ ] WEB-CANDIDATE-001：DeepSeek V4 模型迁移与请求规范化

- **优先级 / 类型 / 状态**：候选 P1 / 候选实现 / 等待 Android 提交冻结
- **受影响 API / 数据库**：`GET/PUT /api/v1/ai/config`、`POST /api/v1/ai/chat/completions`；UserDefaults/SharedPreferences，无 SQLite schema 变化。
- **Android 候选证据**：
  - `common/.../AppConstant.java:784-823` 新增 `deepseek-v4-flash`、`deepseek-v4-pro`，把旧 `deepseek-chat` 归一到 flash。
  - `common/.../SpSettingHelper.kt:4153` 开始校验并归一模型。
  - 未跟踪文件 `web/.../AIChatRequestPolicy.kt:17-46` 对 DeepSeek 请求校验模型，并在未显式提供时补 `thinking: {"type":"disabled"}`；非 DeepSeek provider 原样透传。
- **iOS 证据**：`DesktopWebAIService.swift:36-56` 仍只声明 `deepseek-chat`；`:110-116` 把请求 body 原样转发，没有模型归一或 thinking 默认策略。
- **真实 owner / 写入点 / 触发时机**：AI 设置 owner 保存模型；Chat Request Policy 在每次 DeepSeek 代理请求发出前规范化 body。
- **差异说明**：候选合同仍可能调整，不能提前把模型名、拒绝规则或默认 thinking 写入正式 iOS。
- **依赖关系**：Android 先提交并给出最终 revision；随后重新比较 GET/PUT DTO、旧值迁移、DeepSeek/SiliconFlow 分支。
- **完成标准**：冻结后确认模型枚举、旧值迁移、非法值错误、显式 thinking 保留、默认 thinking、非 DeepSeek 透传，再决定是否转为正式 `WEB-DELTA`。

### [ ] WEB-CANDIDATE-002：PDF 设置字段与单书合并 PDF 行为

- **优先级 / 类型 / 状态**：候选 P1 / 候选实现 / 等待 Android 提交冻结
- **受影响 API / 数据库**：`GET/PUT /api/v1/settings/export`、`POST /api/v1/export/notes/local`；设置候选字段 `pdfContentMode`、`pdfFontMode`，无 SQLite schema 变化。
- **Android 候选证据**：
  - `web/.../dto/ExportDto.kt:8-49` 在设置响应和 patch 中加入两个字段。
  - `web/.../NoteExportWebService.kt:102-145` 读取、校验并保存字段。
  - 同文件 `:935-944` 允许合并 PDF 在单书、多内容时直接返回单个 PDF；当前 dirty 工作区还替换了 PDF generator 与导航结构。
- **iOS 证据**：
  - `DesktopWebExternalContract.swift:112-138` 的导出请求没有 PDF 展示/字体字段。
  - `DesktopWebExportService.swift:94-130` 单书选择多类内容时仍生成 ZIP。
  - iOS 设置与导出源码中不存在 `pdfContentMode`、`pdfFontMode`。
- **真实 owner / 写入点 / 触发时机**：设置 Repository 保存两个偏好；本地 PDF 导出时生成单书合并文档、章节导航和字体策略。
- **差异说明**：字段枚举值、默认值、字体回退与合并 PDF 文件名仍处于 Android 未提交状态。
- **依赖关系**：等待 Android PDF 实现与测试一并冻结；不能混入正式设置错误合同 `WEB-DELTA-005`。
- **完成标准**：冻结后取得字段枚举/default、错误文案、单/多书返回媒体类型、文件名、内容顺序、书签/目录和字体回退的完整合同。

### [ ] WEB-CANDIDATE-003：重新审查尚在调整的 Notion 同步/导出依赖行为

- **优先级 / 类型 / 状态**：候选 P1 / 候选复审 / 等待 Android 提交冻结
- **受影响 API / 数据库**：`GET/PUT /api/v1/settings/export`、`POST /api/v1/export/notes/remote`；`notion_page_sync`、`notion_block_sync`、`notion_sync_operation` 与 Notion 远端页面/Block。
- **Android 候选证据**：
  - dirty 工作区正在修改 `NotionGenerator`、多类 fingerprint、`NotionSyncDao`、`NotionLibrarySyncRepository`、`NotionRepository` 和 `NoteExportWebService`。
  - `NotionLibrarySyncRepository.kt:56-172,427-945` 当前候选代码同时调整 metadata/content 同步、恢复操作、Block 更新和失败状态。
- **iOS 证据**：`DesktopWebExportService.swift:239-247,301-320` 仍是旧 token + database/page 的直接远端创建逻辑；当前 iOS Notion Record/schema 也对应过期开发中结构。
- **真实 owner / 写入点 / 触发时机**：Android 候选 owner 是 Notion Repository/Sync DAO/Generator；远端导出时先写远端，再更新本地 page/block/operation 状态，失败时进入恢复路径。
- **差异说明**：正式 `WEB-DELTA-001/002` 只对齐 `43724fb` 已提交合同；dirty 工作区的依赖顺序、fingerprint 和恢复规则不得提前并入。
- **依赖关系**：等待 Android 提交冻结，再以新提交对 `43724fb` 做独立 diff；若改变 API 或数据库正式合同，新增正式 delta，不回写本候选统计。
- **完成标准**：冻结后重新提取 schema、迁移、事务、冲突策略、本地/远端写入顺序、失败恢复和幂等规则，并明确它是替代还是增量于正式基线。

## 7. 后续执行顺序

1. 先完成 `WEB-DELTA-002`，冻结可恢复的 Android v45 物理数据库合同。
2. 并行推进 `WEB-DELTA-001` 与 `WEB-DELTA-003`，分别补 Notion 连接闭环和导入身份/Hash。
3. 完成 `WEB-DELTA-004`、`WEB-DELTA-005` 两个局部行为缺口。
4. 执行 `WEB-DELTA-007` 至 `WEB-DELTA-011` 的新基线差分复验。
5. 最后执行 `WEB-DELTA-006`，一次性刷新 162 接口机器清单、历史 Todo 与一致性基线。
6. 候选任务只在 Android 提交冻结后转正，不阻塞上述正式链路。

## 8. 本文静态验收规则

- Android Controller 数量必须为 21，API 必须为 162，方法统计必须为 `73/43/34/12`。
- 正式任务编号必须唯一且连续为 `WEB-DELTA-001` 至 `WEB-DELTA-011`。
- 候选任务编号必须唯一且连续为 `WEB-CANDIDATE-001` 至 `WEB-CANDIDATE-003`。
- 任务复选框必须为 14 个；正式 11 个、候选 3 个。
- 67 个 Android 已修复问题必须在第 5 节恰好出现一次：实现 2、复验 63、无需任务 2。
- Android 未提交事实只能出现在第 6 节，不得进入正式任务完成统计。
- 正式任务必须同时包含双端路径与行号、owner、写入点、触发时机、依赖和可验证完成标准。
- 数据库任务必须同时核对 schema、migration、seed、外键/级联、事务、冲突策略与读写 SQL。
- 本轮不执行 iOS/Android 单元测试或构建；运行时和产物证据属于后续任务的完成标准。
