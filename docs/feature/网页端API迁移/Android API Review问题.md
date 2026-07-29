# Android Web API Review 问题

> 审查对象固定为 Android 提交 `9aca6bbbf41bdc5f341da9ad1874d2cf71d54b29` 与 Pixel 4 已安装的 5.6.0 APK。
> 本文只记录 Android 实现问题，不修改 Android 代码。iOS 为保证基线一致，默认复刻已确认的 Android 行为，并在代码与本文中标记 TODO。

## 当前进度

| 项目 | 进度 |
| --- | ---: |
| 已完成 Android Web / App 业务闭环 Review | 160 / 160 |
| 已发现并有代码或 Pixel 4 运行时证据的问题 | 89 |
| 已在 iOS 复刻并标记 TODO | 89 |

“已发现”不等于对应接口已完成 Review。只有 Web Controller、Service、Repository/DAO、App 对应业务和运行时边界均核对后，Todo 才会标记完成。

## 已确认问题

### ANDROID-WEB-089：AI 配置更新把解析器、混淆类名和空对象崩溃细节回传客户端

- 关联接口：`WEB-API-002 PUT /api/v1/ai/config`。
- 源码机制：`AIController.kt:86-123` 捕获全部 `Exception` 后直接把 `e.message` 拼入 `配置更新失败`，没有把 JSON 语法错误转换为稳定的参数错误。
- Pixel 4 证据：正式 APK 对 `{` 返回 `java.io.EOFException`；对数组和字符串返回 `java.lang.IllegalStateException` 与 Gson 排障链接；对尾随逗号返回混淆后的 `com.google.gson.stream.Wwwwwwwwwwwwwwwwwwwwwwwwwwwwww` 类名；对空体或 `null` 返回包含完整 DTO 包名和 getter 签名的空对象崩溃文案。上述请求均在设置写入前失败。
- 影响：普通客户端输入错误暴露第三方解析器、R8 混淆结果、内部 DTO 包名和方法签名，且错误合同会随构建工具和 Gson 版本漂移。
- App 参考：原生 `AIConfigurationViewModel` 通过类型化表单更新设置，不会把 JSON 解析器或 JVM 崩溃细节展示给用户。
- iOS 决策：冻结基线阶段由 `DesktopWebGsonJSONFailureMessage.caughtAIConfigExceptionDescription` 与 `DesktopWebAIRoutes` 复刻正式 APK 已取证文案，并标记 `TODO(ANDROID-WEB-089)`；不把该异常实现反向修复到 Android。

### ANDROID-WEB-088：原始字符串 JSON 解析异常被错误归类为服务器故障并泄漏 Gson 内部文案

- 关联接口：`WEB-API-037` 至 `WEB-API-039`、`WEB-API-041` 至 `WEB-API-046`、`WEB-API-049`、`WEB-API-050`、`WEB-API-057`、`WEB-API-058`、`WEB-API-060` 至 `WEB-API-062`、`WEB-API-065`、`WEB-API-071`、`WEB-API-075`、`WEB-API-076`、`WEB-API-078` 至 `WEB-API-082`、`WEB-API-091` 至 `WEB-API-093`、`WEB-API-095`、`WEB-API-097`、`WEB-API-102`、`WEB-API-103`、`WEB-API-105`、`WEB-API-106`、`WEB-API-109`、`WEB-API-113`、`WEB-API-115`、`WEB-API-116`、`WEB-API-153`、`WEB-API-154`、`WEB-API-156`、`WEB-API-157`、`WEB-API-159`，共 43 条。
- 源码机制：这些 Controller 均以 `@RequestBody body: String` 接收原始内容，再在方法体内调用 `JsonParser` / Gson 转为 DTO。语法异常发生在 Controller 内部，且多数方法没有捕获 `JsonSyntaxException`，最终落入全局异常处理器。
- Pixel 4 证据：对上述 43 条正式 APK 路由发送单字节 `{`，全部返回 HTTP 200、`code=50001`、`msg="End of input at line 1 column 2 path $."`，且没有 `Content-Type` 与 `Cache-Control`。同一冻结源码的独立测试 App 结果一致，排除 R8 特有差异；双端隔离数据库主文件与 WAL 在批次调用前后哈希均未变化。
- 边界证据：正式 APK 对 `{"a":` 返回 `End of input at line 1 column 6 path $.a`；对尾随逗号、数组和非对象字符串分别泄漏 Gson 的 `malformed-json` / `unexpected-json-structure` 文案与排障链接。空体和 `null` 还可能继续泄漏 Kotlin 非空参数异常。
- 影响：客户端输入错误被伪装为服务器内部故障，响应暴露第三方解析器版本和内部路径信息；不同 JSON 错误还形成不稳定的英文文案合同。
- App 参考：原生 App 通过类型化表单和 Repository 调用业务，不经过 Web 原始字符串解析与全局 HTTP 异常处理器。
- iOS 决策：`DesktopWebAndroidRawJSONFailureMiddleware` 在授权与会员门禁之后缓冲这 43 条 JSON 请求；合法对象继续交给 Route，已确认的 Gson 语法与顶层类型失败返回相同 `50001`、文案及 Header，并标记 `TODO(ANDROID-WEB-088)`。空体、`null` 与更深层类型不匹配继续作为后续边界矩阵逐项取证，不以宽松归一化掩盖。

### ANDROID-WEB-087：正式 APK 的具体 DTO 请求体处理器全部在进入 Controller 前崩溃

- 关联接口：`WEB-API-012`、`WEB-API-014`、`WEB-API-015`、`WEB-API-017` 至 `WEB-API-023`、`WEB-API-029` 至 `WEB-API-031`、`WEB-API-053`、`WEB-API-054`、`WEB-API-083`、`WEB-API-086`、`WEB-API-087`、`WEB-API-124`、`WEB-API-125`、`WEB-API-128`、`WEB-API-129`、`WEB-API-131`、`WEB-API-140`、`WEB-API-142`、`WEB-API-144`，共 26 条。
- 源码机制：上述接口均以具体 DTO 声明 `@RequestBody`。AndServer 生成的 Handler 会创建匿名 `TypeReference<DTO>`，通过 `getGenericSuperclass()` 取得 DTO 类型后再调用 `GsonMessageConverter.convert`；以 `String` 声明请求体的接口直接读取 body 字符串，不进入该反射路径。
- APK 证据：Pixel 4 当前安装 APK 的 SHA-256 为 `c7d4d9af282faaa68c6910ea04e62477ae21c6b474d047e7bd5872f37dd6e882`。DEX 中 `TypeReference` 构造器固定把 `getGenericSuperclass()` 强转为 `ParameterizedType`，但生成 Handler 的匿名子类 `Signature` 只保留了原始 `TypeReference`，没有 DTO 类型参数，因此构造匿名类时即抛出 `ClassCastException`。
- 运行时证据：正式 APK 对 `PUT /api/v1/settings/web`、`PUT /api/v1/settings/export` 和只读 `POST /api/v1/bookshelf/items/query` 均返回 HTTP 200、`code=50001`、`msg="java.lang.Class cannot be cast to java.lang.reflect.ParameterizedType"`；设置接口调用前后的脱敏响应哈希一致，证明 Controller 与持久化写入均未执行。相同提交的未混淆隔离测试包可正常解析 DTO，说明差异来自正式构建产物；以原始字符串接收请求体的 `POST /api/v1/books/0/chapters/import-preview` 能进入 Controller 并返回正常业务错误 `40002`。
- 影响：26 条接口在 Android 5.6.0 正式 APK 中无论请求内容是否合法都无法执行业务逻辑，其中包含创建/编辑书籍、书架批量操作、阅读记录、导出、来源和统计目标等核心能力；网页会收到全局异常而不是 Controller 约定的成功或参数错误。
- App 参考：原生 App 直接调用 Presenter/Repository，不经过 AndServer 生成 Handler 和反射请求体转换，因此不受此问题影响。
- iOS 决策：`DesktopWebFrozenAPKRequestBodyFailureMiddleware` 在访问授权和会员写保护之后、请求体解码之前，对 26 条接口返回同一 `50001` 包络，并标记 `TODO(ANDROID-WEB-087)`。核心写接口在 iOS 生产环境尚无会员源时仍优先返回 `40009`；测试注入高级版后复刻正式 APK 的 `50001`。底层 Route/Port 成功路径测试继续保留，供 Android 修复正式构建后解除兼容守卫。

### ANDROID-WEB-086：根章节响应暴露内部占位章节标题

- 关联接口：`WEB-API-068 GET /api/v1/books/{bookId}/notes`、`WEB-API-072 GET /api/v1/notes`。
- 证据：`WebNoteDao.batchQueryChaptersWithParent` 通过 `LEFT JOIN chapter parent ON parent.id = child.parent_id` 投影 `parent.title`；V44 数据库保留 `id=0`、标题为 `empty empty` 的内部占位章节。Pixel 4 隔离包查询根章节书摘时，响应中的 `chapter.parentTitle` 因此为 `"empty empty"`。
- 影响：Web 公共 JSON 暴露了数据库内部哨兵记录的实现细节，客户端可能把占位文本当作真实父章节标题展示。
- App 参考：原生 App 使用章节层级和路径模型展示目录，不会把 `id=0` 的占位标题作为根章节父标题呈现。
- iOS 决策：为保持 Android 5.6.0 可观察行为，书内及全局书摘投影均查询有效父章节并保留该占位标题；`DesktopWebNoteRepository.activeParentTitles` 已标记 TODO。未来双端应把根章节父标题统一为 `null` 或空值。

### ANDROID-WEB-085：JSON 业务响应未声明 Content-Type

- 关联接口：全部使用统一 `ApiResponse` 包络的 JSON 接口；Pixel 4 首批运行时证据覆盖 `WEB-API-004`、`WEB-API-006` 至 `WEB-API-010` 等 45 条只读根路径。
- 证据：Pixel 4 隔离 `.uitest` 包通过 8090 返回完整 JSON 与 `Cache-Control: private`，但响应头没有 `Content-Type`；同批次 45/45 请求均复现。Android Web 由 AndServer 将 Controller 返回对象写入响应，没有补充 JSON 媒体类型。
- 影响：普通 `response.json()` 仍可工作，但依赖媒体类型判断响应格式的通用客户端会把 JSON 当作未知二进制；网页端的原始响应错误探测也会因缺少该 Header 跳过 JSON 业务错误检查。
- App 参考：该问题仅属于 Android Web HTTP 适配层，原生 App Repository/页面不存在对应媒体类型合同。
- iOS 决策：本迁移先保留 Android 5.6.0 的 Header 缺失行为；`DesktopWebAPIContract.swift` 已标记 TODO。未来若 Android 修复，需要双端同时恢复 `application/json` 并更新基线。

### ANDROID-WEB-001：AI 配置查询返回明文 API Key

- 关联接口：`WEB-API-001 GET /api/v1/ai/config`
- 证据：`AIController.kt:43-80` 直接将 `getDeepSeekAPIKey()` 和 `getSiliconFlowAPIKey()` 放入成功响应。
- 影响：局域网客户端可读取完整第三方密钥；用户关闭访问码时风险更高。
- App 参考：待该接口正式 Review 时核对 App 设置页是否会回显完整密钥。
- iOS 决策：本迁移基线仍复刻 Android 响应；实现处标记 TODO，不在本任务单方改变合同。

### ANDROID-WEB-002：导出设置查询返回多个明文凭据

- 关联接口：`WEB-API-122 GET /api/v1/settings/export`
- 证据：`SettingsController.kt:41-46` 返回 `NoteExportWebService.getSettings()`；`NoteExportWebService.kt:92-114` 读出语雀、Notion、思源和 Obsidian 凭据；`ExportDto.kt:8-28` 将它们定义为响应字段。
- 影响：局域网客户端可获取 `yuqueToken`、`notionToken`、`siyuanToken` 和 `obsidianApiKey` 原文。
- App 参考：`NoteExportSettingActivity.kt:46-106` 与 `NoteExportPresenter.kt:80-94` 读取和更新同一组 `SpSettingHelper` 键；App 会使用这些凭据，但不会通过局域网响应统一回传全部原文。
- iOS 决策：本迁移基线仍复刻 Android 响应；`DesktopWebAPIAdapter.swift:72` 已标记 `TODO(ANDROID-WEB-002)`，并依赖访问码边界降低暴露面。

### ANDROID-WEB-003：分页大小没有实用上限

- 关联接口：所有通过 `ParamValidator.validatePagination` 处理 `pageSize` 的列表接口；当前已确认包含 `WEB-API-006`、`WEB-API-009`、`WEB-API-010`、`WEB-API-025`、`WEB-API-026`、`WEB-API-055`、`WEB-API-056`，其余 ID 随逐接口 Review 回填。
- 证据：`ParamValidator.kt:9-24` 将 `MAX_PAGE_SIZE` 设为 `Int.MAX_VALUE`，因此正整数 `pageSize` 基本不会被限制。
- 影响：客户端可请求过大结果集，带来数据库、序列化和内存压力。
- App 参考：App 页面通常以受控批次加载，不会直接暴露任意 `pageSize`；具体业务路径待逐接口核对。
- iOS 决策：为保持可观察行为一致，默认复刻该边界；在每个命中的 iOS 实现处标记 TODO。

### ANDROID-WEB-004：Web 删除标签会无事务地物理删除两类关联

- 关联接口：`WEB-API-155 DELETE /api/v1/tags/{id}`。
- 证据：`TagService.kt:104-113` 先软删除 `tag`，再依次删除 `tag_note` 与 `tag_book`；`WebTagDao.kt:73-77` 使用无 `is_deleted` 过滤的物理 `DELETE`，三个 DAO 调用没有共同事务。
- App 参考：`TagRepository.kt:72-86` 在 `noteDb.runInTransaction` 中只按标签类型处理对应关系表，再软删除标签；App 路径不会跨类型物理抹除两张关系表。
- 可复现输入：为一个标签同时准备 `tag_note`、`tag_book` 及已软删除关联后调用删除接口。
- 实际结果：标签主记录保留 tombstone，但两张关系表中该 `tag_id` 的全部行永久消失；任一步失败可能留下部分完成状态。
- 风险：破坏同步 tombstone、删除不具原子性，并会清除与标签声明类型无关的关系数据。
- iOS 决策：`DesktopWebCatalogRepository.deleteTag` 按相同顺序分三次写入并物理删除两类关联，已标记 `TODO(ANDROID-WEB-004)`；隔离数据库单测固定该异常基线。

### ANDROID-WEB-005：Web 标签能力缺少用户数据隔离

- 关联接口：`WEB-API-020`、`WEB-API-021`、`WEB-API-152` 至 `WEB-API-156`。
- 证据：`WebTagDao.kt:13-30,59-69` 的列表、详情、判重和写入 SQL 均没有 `user_id` 条件；`TagService.kt:57-64` 创建标签时固定 `userId = 1L`；`WebBookDao.kt:1008-1055` 的批量标签存在性与关系查询同样不限制标签 owner，`BookService.kt:1232-1360` 据此允许批量关联其他 owner 的标签。
- App 参考：`TagRepository.kt:139-163,206-209` 列表查询先从设置读取当前 userId 并传给 `TagDao.queryTags`；Web 路径绕过了这一 owner 边界。
- 可复现输入：数据库中同时存在 user 1 与 user 2 的标签，通过 Web 执行列表、重命名、删除、排序，或将 user 2 标签批量设置到当前书籍。
- 实际结果：列表可见其他用户标签；重名检查横跨用户；按 ID 可编辑、删除或排序其他用户标签；新标签始终归 user 1；批量设置与精确替换也会接受其他 owner 的有效标签。
- 风险：本地多 owner/恢复数据场景会发生越权读取和写入，且新数据可能落到错误 owner。
- iOS 决策：`DesktopWebCatalogRepository` 与 `DesktopWebBookRepository+Batch.swift` 原样保留无 owner 过滤及固定 user 1 的行为，并标记 `TODO(ANDROID-WEB-005)`；测试显式覆盖跨 owner 可见、可写及批量关联。

### ANDROID-WEB-006：Web 分组接口缺少用户数据隔离

- 关联接口：`WEB-API-025` 至 `WEB-API-031`、`WEB-API-055` 至 `WEB-API-062`。
- 证据：`WebBookDao.kt:542-555,675-727` 的分组列表、计数和组内书籍查询均没有 `user_id` 条件；`WebGroupDao.kt:11-39` 的详情、顺序、置顶和删除写入同样不校验 owner；`GroupService.kt:27-34` 创建时固定 `userId = 1L`。
- App 参考：`GroupRepository.kt:32-49` 的创建由 `GroupModelMapper` 使用 App 当前业务用户构造实体；列表走 App DAO；`GroupRepository.kt:195-213` 的改名与排序虽然按 ID 写入，但调用入口使用当前用户已加载的分组模型。
- 可复现输入：同时准备 user 1 与 user 2 的有效分组，并通过 Web 分别执行列表、改名、删除、置顶和排序；或在当前 owner 不是 1 时创建分组。
- 实际结果：Web 可列出并修改其他 owner 的分组；新分组始终归 user 1；通过其他 owner 的 group ID 还可读取和重排其书籍。
- 风险：恢复数据或多 owner 数据并存时发生越权读取与写入，新数据也可能归属错误 owner。
- iOS 决策：`DesktopWebGroupRepository.swift:101,176` 与 `DesktopWebBookRepository+Bookshelf.swift` 保留无 owner 过滤及固定 user 1 行为并标记 `TODO(ANDROID-WEB-006)`；隔离数据库测试锁定跨 owner 可见、可写与顺序计算。

### ANDROID-WEB-007：删除分组无共同事务且会移除书籍的全部分组关系

- 关联接口：`WEB-API-059 DELETE /api/v1/groups/{id}`。
- 证据：`GroupService.kt:67-90` 逐本调用 `WebBookRepository.moveOutFromGroup` 后再软删除目标分组关系与主记录，外层没有事务；`WebBookDao.kt:982-984` 的迁出 SQL 按 `book_id` 软删除全部有效 `group_book`，不只删除当前 `group_id`。
- App 参考：`GroupRepository.kt:140-169` 的 App 迁出路径也按书籍移除关系，但其批量 Rx 路径在 `noteDb.runInTransaction` 内完成；`GroupRepository.kt:188-190` 另有按 `groupId + bookId` 删除单条关系的能力。
- 可复现输入：书籍同时保留两个有效分组关系，其中一个是待删除分组；让迁出流程中任一后续数据库写入失败。
- 实际结果：删除一个分组时，该书籍的其他有效分组关系也被软删除；多书籍迁移与分组删除之间可能只完成一部分。
- 风险：产生超出目标分组范围的数据变更，并在异常时留下不可原子恢复的中间状态。
- iOS 决策：`DesktopWebGroupRepository.swift:256-289` 按相同顺序执行独立写入并移除书籍全部有效分组关系，标记 `TODO(ANDROID-WEB-007)`；隔离数据库测试固定多关系与逐次时间戳结果。

### ANDROID-WEB-008：书籍接口缺少用户数据隔离

- 关联接口：当前已确认 `WEB-API-004` 至 `WEB-API-012`、`WEB-API-014` 至 `WEB-API-023`、`WEB-API-025` 至 `WEB-API-031`；其余 Book API 随逐接口 Review 扩展范围。
- 证据：`WebBookDao.kt:150-373,436-447,619-671,731-787,888-890` 的统计、详情、最近行为、列表、置顶、未分组、恢复和置顶写入均没有 `user_id` 条件；删除接口又直接进入 App `BookRepository.deleteBook(bookId)`，完整链路只按 book ID 定位。
- App 参考：`BookDao.kt:221-237,309-318,537-691` 与 `BookRepository.kt:1095-1149,1506-1557,1773-1889` 同样未在多数单书/全书路径统一校验 owner，因此这是 Web 与 App 共有的数据隔离缺口，而非 Web 单独引入的差异。
- 可复现输入：数据库中同时保留 user 1 与 user 2 的有效书籍，并通过任一关联接口查询统计、详情、最近行为、置顶或未分组列表。
- 实际结果：其他 owner 的书籍会进入统计或响应；详情接口仅凭 ID 即可读取完整书籍及关联聚合。
- 风险：多账号数据、跨账号恢复或残留 owner 数据并存时发生越权读取、删除、置顶或恢复。
- iOS 决策：`DesktopWebBookRepository` 及其扩展原样保留无 owner 过滤行为，并标记 `TODO(ANDROID-WEB-008)`；隔离数据库测试固定跨 owner 查询与写入边界。

### ANDROID-WEB-009：未分组查询会把已删除分组的残留关系继续视为有效归属

- 关联接口：`WEB-API-010 GET /api/v1/books/ungrouped`。
- 证据：`WebBookDao.kt:649-671` 的 `NOT EXISTS` 只检查 `group_book.is_deleted = 0`，不关联并过滤目标 `group.is_deleted`。
- App 参考：`BookDao.kt:251-264` 的未分组查询通过 `group LEFT JOIN group_book`，明确要求 `group.is_deleted = 0`，因此指向已删除分组的关系不会阻止书籍出现在 App 未分组列表。
- 可复现输入：准备一本非置顶有效书籍、一个已软删除分组，以及二者之间仍为有效状态的 `group_book` 关系。
- 实际结果：Web 未分组接口排除该书；分组列表又不会展示已删除分组，导致书籍在 Web 的两种归属视图中同时不可见。
- 风险：非事务删除失败、旧备份或脏数据恢复后形成“幽灵归属”，用户无法从 Web 列表找到书籍。
- iOS 决策：`DesktopWebBookRepository.ungroupedBooks` 仍只检查关系 tombstone，并标记 `TODO(ANDROID-WEB-009)`；单测固定“已删除分组 + 有效关系仍被排除”的异常基线。

### ANDROID-WEB-010：AND 标签筛选保留重复 ID，导致合法书籍被全部排除

- 关联接口：`WEB-API-006 GET /api/v1/books`。
- 证据：`BookController.kt:69-71` 将 `tagIds` 逐项转为 Long 后直接保留，不去重；`WebBookRepository.kt:457-468` 又使用 `COUNT(DISTINCT tb.tag_id) = filter.tagIds.size` 判断 AND 条件。
- App 参考：App 书架由受控标签对象/选择索引产生筛选输入，不直接接收外部逗号分隔 ID；`DefaultBookListFragment.kt:445-451` 的多选结果来自单个标签选择器，因此正常 App 路径不会构造重复 ID。
- 可复现输入：一本书具有关联标签 7，请求 `tagIds=7,7&tagMode=and`。
- 实际结果：子查询的 distinct 数量为 1，请求列表长度为 2，等式永远不成立；书籍被错误排除。
- 风险：同一逻辑标签被客户端重复传入时，AND 筛选从幂等集合语义退化为恒不匹配。
- iOS 决策：路由解析与仓储计数均原样保留重复 ID，`DesktopWebBookRepository+List.swift` 标记 `TODO(ANDROID-WEB-010)`；单测固定该异常合同。

### ANDROID-WEB-011：关联筛选与写入不校验目标主记录是否有效

- 关联接口：`WEB-API-006`、`WEB-API-012`、`WEB-API-014`、`WEB-API-015`、`WEB-API-018`、`WEB-API-019`、`WEB-API-022`、`WEB-API-056`。
- 证据：`WebBookRepository.kt:446-479` 的组合筛选只检查 `group_book.is_deleted = 0` / `tag_book.is_deleted = 0`，不连接 `group` 或 `tag` 主表；`WebBookDao.kt:559-572,888-890` 的组内查询与置顶作用域也不验证分组主记录；`BookService.kt:1141-1151,1187-1221,1442-1479,1507-1597` 直接使用请求中的来源、标签或分组 ID，批量迁组虽有事务仍不读取目标分组主记录。
- App 参考：App 的分组和标签入口通常先读取有效主记录后再传入 ID；`GroupBooksViewModel.kt:123-151` 从已进入的分组上下文加载书籍。该 UI 前置条件不能保护 Web 客户端直接提交 tombstone ID。
- 可复现输入：保留一本有效书和一条有效关联，同时将目标 `source`、`group` 或 `tag` 主记录软删除；再按该 ID 筛选、置顶、更新来源/标签，或批量迁入该分组。
- 实际结果：已删除目标 ID 仍能筛出关联书籍；已删除分组的组内列表仍返回书籍并参与置顶序号；单书或批量更新可写入已删除来源/标签，批量迁组也可创建指向已删除分组的有效关系。
- 风险：删除中断、旧备份或脏关系会让 Web 暴露不可见分类中的数据，并使筛选结果与可用分组/标签列表矛盾。
- iOS 决策：主列表、组内列表、单书与批量写入均复刻不校验关联目标主记录的行为，在 `DesktopWebBookRepository+List.swift`、`DesktopWebBookRepository+Writes.swift`、`DesktopWebBookRepository+Mutation.swift`、`DesktopWebBookRepository+Batch.swift` 和 `DesktopWebGroupRepository.swift` 标记 `TODO(ANDROID-WEB-011)`；隔离数据库测试覆盖已删除目标、置顶作用域、来源覆盖与原始关系写入。

### ANDROID-WEB-012：组内名称分区丢弃空书名，但 total 仍包含它们

- 关联接口：`WEB-API-006 GET /api/v1/books?groupId=...&sectionBy=name`。
- 证据：`BookService.kt:653-674` 用未删减的 `context.baseBooks.size` 返回 total；`BookService.kt:879-902` 构造名称分区时先过滤 `name.isNotBlank()`。
- App 参考：`SubBookListFormatHelper.kt:441-470` 同样在名称分区中排除空书名；`GroupBooksViewModel.kt:133-151` 又以原始列表数量显示工具栏总数，因此 App 也存在相同的可见数量偏差。
- 可复现输入：指定分组内包含一本非置顶、名称为空或全空白的有效书，请求 `sectionBy=name`。
- 实际结果：该书不出现在任何 section 中，但响应 `total` 仍将其计入；若为空名书已置顶，则仍会进入“置顶”分区。
- 风险：客户端无法通过 section 内容复算 total，且页面可能显示无法定位的书籍数量。
- iOS 决策：`DesktopWebBookRepository+List.swift` 对非置顶空名书执行相同过滤并保留原始 total，标记 `TODO(ANDROID-WEB-012)`；单测固定普通空名与置顶例外。

### ANDROID-WEB-013：删除书籍会重写多类既有 tombstone 的更新时间

- 关联接口：`WEB-API-011 DELETE /api/v1/books/{id}`。
- 证据：`BookService.kt:1067-1074` 直接复用 App `BookRepository.deleteBook`；`BookRepository.kt:803-847` 在单一事务中按 17 步清理关联；`TagBookDao.kt:36-45`、`TagNoteDao.kt:28-29`、`NoteDao.kt:35-36`、`BookReadStatusRecordDao.kt:35-36` 与 `SortDao.kt:26-27` 的 SQL 没有 `is_deleted = 0` 条件，且各 DAO 默认重新读取 `System.currentTimeMillis()`。
- App 参考：Web 与 App 共用同一 `BookRepository.deleteBook`，因此这是双端共同的删除语义，不是 Web 独立实现。
- 可复现输入：为目标书籍准备已经软删除且 `updated_date` 较早的 `tag_book`、`tag_note`、`note`、阅读状态或排序记录，再删除该书。
- 实际结果：这些 tombstone 仍保持删除状态，但 `updated_date` 被刷新；相反，`group_book`、`read_time_record` 和 `check_in_record` 因 DAO 带有效状态过滤而不会刷新既有 tombstone。
- 风险：重复删除关联数据会伪造新的变更时间，可能触发不必要同步并掩盖原始删除时间；不同关联表的 tombstone 语义也不一致。
- iOS 决策：`DesktopWebBookRepository+Writes.swift` 在一个 GRDB 事务中保留 17 步顺序、每步独立时钟与各表原始过滤条件，并标记 `TODO(ANDROID-WEB-013)`；单测固定重写/不重写矩阵和晚期失败全量回滚。

### ANDROID-WEB-014：Web 恢复书架与阅读状态历史不在同一事务

- 关联接口：`WEB-API-016 PUT /api/v1/books/{id}/add-to-bookshelf`。
- 证据：`BookService.kt:1029-1063` 先调用 `WebBookRepository.restoreToBookshelf` 提交书籍恢复，再单独调用 `insertReadStatusRecord`；两次 suspend DAO 调用没有共同事务。
- App 参考：`BookRepository.kt:1468-1503` 的 `addBookToRead` 将恢复 `book` 与插入 `book_read_status_record` 包在同一个 `noteDb.runInTransaction` 中。
- 可复现输入：准备一条软删除书籍，并让第二步 `book_read_status_record` 插入因触发器、约束或存储异常失败。
- 实际结果：接口失败，但书籍已经恢复为有效且变为“在读”，阅读状态历史却没有对应记录。
- 风险：响应失败与数据库状态不一致，重试又会因书籍已有效而直接返回，从而永久缺失状态历史。
- iOS 决策：为保持 Android Web 可观察基线，`DesktopWebBookRepository+Writes.swift` 故意分两次提交并标记 `TODO(ANDROID-WEB-014)`；隔离数据库单测用第二步失败固定部分完成结果。

### ANDROID-WEB-015：顶层书籍与分组置顶分别计算最大序号

- 关联接口：`WEB-API-012 PUT /api/v1/books/{id}/pin`、`WEB-API-060 PUT /api/v1/groups/{id}/pin`。
- 证据：`WebBookRepository.kt:871-882` 在无有效 groupId 时只查询 `WebBookDao.queryMaxPinOrder()`；`GroupService.kt:102-108` 又只查询 `WebGroupRepository.queryMaxPinOrder()`。两条路径都忽略另一种顶层项目。
- App 参考：`BookRepository.kt:3504-3541` 的顶层 `pin` 同时读取 `bookDao.queryMaxPinOrder()` 与 `groupDao.queryMaxPinOrder()`，取二者最大值后再追加。
- 可复现输入：先让置顶书籍最大序号为 99、置顶分组最大序号为 9，再通过 Web 置顶一个新分组；反向场景同理。
- 实际结果：新分组获得 10 而不是 100；书籍与分组共享展示区域时可能出现重复或倒退的 `pin_order`，无法形成单调的全局置顶序列。
- 风险：混合置顶后的顺序与操作先后不一致，重复序号还会使最终展示依赖次级排序或数据库返回顺序。
- iOS 决策：`DesktopWebBookRepository+Writes.swift` 与 `DesktopWebGroupRepository.swift` 分别保留各自类型的最大值计算，并标记 `TODO(ANDROID-WEB-015)`；单测固定“忽略另一类型”和 Kotlin `Int` 溢出行为。

### ANDROID-WEB-016：Web 单书与批量局部更新跨多个独立提交

- 关联接口：`WEB-API-015 PUT /api/v1/books/{id}`、`WEB-API-019 POST /api/v1/books/batch-update`。
- 证据：`BookService.kt:1185-1227,1489-1603` 依次调用 `WebBookRepository.updateBook`、状态历史/年度书单同步、标签或分组关系写入，两个方法都没有 `DatabaseProvider.db.withTransaction`；批量更新的不同书籍和每个 DAO 调用同样各自提交。
- App 参考：`BookRepository.kt:861-897` 将阅读状态、书籍主表、分组归一化和标签替换全部放在同一个 `noteDb.runInTransaction` 中。
- 可复现输入：单书更新书名和标签，或批量更新阅读状态/来源，同时让较晚的分组或标签关系写入触发约束失败。
- 实际结果：接口最终失败，但书籍主表、状态副作用、先前书籍或先前关系已经提交；失败点之后的修改没有执行。
- 风险：客户端按失败结果重试时面对已变化的中间状态，可能重复创建关系或无法还原原分组，且 Web 与 App 的原子性语义相反。
- iOS 决策：`DesktopWebBookRepository+Mutation.swift` 与 `DesktopWebBookRepository+Batch.swift` 按 Android Web 的调用顺序故意分开提交并标记 `TODO(ANDROID-WEB-016)`；隔离数据库测试固定单书晚期失败与批量较晚标签失败的部分完成状态。

### ANDROID-WEB-017：创建书籍接受负分组 ID，并据此计算错误的顶层排序

- 关联接口：`WEB-API-014 POST /api/v1/books`。
- 证据：`BookService.kt:1392-1393` 将任意非空 `groupId` 传给 `calcNewBookOrder`；该方法对非零 ID 查询目标组边界。`BookService.kt:1472-1479` 却只在 `groupId > 0` 时创建关系。
- App 参考：`BookRepository.kt:409-431` 的 group 参数来自有效 `Group` 对象；未分组时明确传入 0，不存在外部负 ID 输入。
- 可复现输入：创建书籍时传入 `groupId=-7`，并采用新增到末尾设置。
- 实际结果：服务按不存在的 -7 分组得到空边界并生成 `book_order=1`，随后不创建任何分组关系；该书实际成为顶层书籍，但排序没有基于现有顶层书籍与分组计算。
- 风险：顶层书架产生重复、倒退或跳跃排序值，展示顺序与用户新增位置偏好不一致。
- iOS 决策：`DesktopWebBookRepository+Mutation.swift` 保留“负 ID 参与组内排序、但不建关系”的异常合同并标记 `TODO(ANDROID-WEB-017)`；单测固定 `book_order=1` 且无有效分组关系。

### ANDROID-WEB-018：更新阅读位置时书签修改时间不会写入数据库

- 关联接口：`WEB-API-015 PUT /api/v1/books/{id}`。
- 证据：`BookService.kt:100-119` 的 `applyUpdatePositionFields` 在收到 `readPosition` 时把 `bookMarkModifiedTime` 设为当前时间；随后调用的 `WebBookDao.kt:955-976` 更新列集合却没有 `book_mark_modified_time`。
- App 参考：`BookRepository.kt:861-897` 最终通过 `bookDao.updateSync(book.toEntity())` 更新完整实体，正常 App 编辑路径不会丢失内存中的书签时间。
- 可复现输入：准备 `book_mark_modified_time=77` 的电子书，通过 Web 更新 `readPosition`，不触发其他会单独写该列的接口。
- 实际结果：响应中的阅读位置已经变化，但数据库 `book_mark_modified_time` 仍为 77；最近阅读聚合也不会把本次 Web 操作视为新的书签行为。
- 风险：最近阅读排序、最后修改时间和跨端同步遗漏本次进度变更，用户看到的书籍活跃顺序与实际操作不一致。
- iOS 决策：`DesktopWebBookRepository+Mutation.swift` 的精确更新 SQL 故意遗漏该列并标记 `TODO(ANDROID-WEB-018)`；单测固定阅读位置推进而书签时间保持旧值。

### ANDROID-WEB-019：批量移出分组的单书四步写入没有事务

- 关联接口：`WEB-API-023 POST /api/v1/books/batch-move-out`。
- 证据：`BookService.kt:1154-1162` 按请求顺序逐本调用 `WebBookRepository.moveOutFromGroup`；`WebBookRepository.kt:1173-1183` 又依次执行取消置顶、计算顶层边界、软删除全部分组关系和更新书籍排序，外层及单书内部均没有 `DatabaseProvider.db.withTransaction`。
- App 参考：`GroupRepository.kt:140-168` 的 App 移出路径也分步执行，但会先软删除关系、再读取顶层边界并更新排序；两者都缺少共同事务，Web 还采用“关系仍存在时先算边界”的不同顺序。
- 可复现输入：准备一批组内书籍，在第一本或较晚一本的 `group_book` 软删除或 `book_order` 更新处注入约束/触发器失败。
- 实际结果：接口失败前已处理的书籍保持全部修改；当前失败书籍还可能只完成取消置顶或关系软删除，留下仍在分组但已取消置顶，或已移出却沿用旧排序的中间状态。
- 风险：响应失败与数据库状态不一致，重试时顶层边界已改变，最终顺序可能与首次请求意图不同；批量越靠后失败，部分完成范围越大。
- iOS 决策：`DesktopWebBookRepository+Batch.swift` 故意按四个独立阶段提交并标记 `TODO(ANDROID-WEB-019)`；隔离数据库测试固定头尾遍历顺序及较晚书籍失败后的部分提交状态。

### ANDROID-WEB-020：书架原始重排可修改不属于当前 manifest 的任意记录

- 关联接口：`WEB-API-031 PUT /api/v1/bookshelf/order`。
- 证据：`BookshelfService.kt` 的 `reorder` 直接遍历请求中的原始引用；`WebBookDao.kt` 对书籍和分组顺序的更新 SQL 只按 ID 定位，没有校验记录是否有效、是否位于顶层、是否属于当前 owner，也不要求引用出现在当前书架 manifest。
- App 参考：`BookRepository.kt:694-751` 的 App 书架排序从当前页面已经加载的 `IBookData` 集合生成顺序，正常交互无法提交列表外的任意数据库 ID。
- 可复现输入：请求中分别传入已删除书籍、仍在分组内的书籍、占位书籍 ID 0、其他 owner 的书籍或分组，以及重复引用。
- 实际结果：已识别类型会按请求索引更新目标行；未知类型被忽略；重复引用最后一次写入生效。目标不需要存在于当前 manifest。
- 风险：外部客户端可改写隐藏记录、占位记录或其他 owner 数据的排序与修改时间，造成恢复后顺序漂移及数据隔离破坏。
- iOS 决策：`DesktopWebBookRepository+Bookshelf.swift` 原样保留无过滤重排并标记 `TODO(ANDROID-WEB-020)`；隔离数据库测试覆盖列表外记录、重复引用、未知类型和事务回滚。

### ANDROID-WEB-021：items/query 未校验 manifest，暴露占位与组内书籍

- 关联接口：`WEB-API-029 POST /api/v1/bookshelf/items/query`。
- 证据：`BookshelfService.kt` 的 `buildBookshelfItems` 直接把请求中的 book ID 交给 `WebBookDao.queryBooksByIds`；该查询只要求 `id IN (...)` 与 `is_deleted = 0`，没有排除 ID 0，也没有校验书籍是否位于顶层或引用是否来自当前 manifest。
- App 参考：`BookRepository.kt:1095-1149,1773-1969` 的详情与书架聚合由 App 已加载的书架/分组上下文驱动，正常书架 UI 不接收客户端构造的任意混合引用。
- 可复现输入：在请求引用中加入有效占位书籍 ID 0、仅位于分组内的书籍、重复引用和不存在的 ID。
- 实际结果：ID 0 与组内书籍会返回完整书籍 DTO；重复引用按原顺序重复返回；不存在的引用被跳过。
- 风险：接口越过书架 manifest 边界暴露哨兵记录及当前视图范围外的数据，并扩大无 owner 过滤问题的可利用面。
- iOS 决策：`DesktopWebBookRepository+Bookshelf.swift` 原样保留直接 ID 查询并标记 `TODO(ANDROID-WEB-021)`；隔离数据库测试固定占位书籍、组内书籍、重复和缺失引用合同。

### ANDROID-WEB-022：日历连续阅读标记恒为 false

- 关联接口：`WEB-API-032 GET /api/v1/calendar/month`、`WEB-API-033 GET /api/v1/calendar/day`。
- 证据：`ReadCalendarRepository.getDaysOfMonth` 创建 `CalendarBook` 时沿用 `isContinuation=false` 默认值；只有 `getDayEvents` 会结合相邻日期更新连续标记，但 `CalendarWebService` 的月历与日详情都只调用 `getDaysOfMonth`，没有进入该路径，日详情 DTO 还再次显式写入 `false`。
- App 参考：App 日历布局经 `ReadCalendarRepository.getDayEvents` 处理跨日连续事件，因此相邻日期的阅读区间可以获得连续语义。
- 可复现输入：同一本书在连续两天分别产生阅读事件，再分别请求当月和第二天详情。
- 实际结果：两个响应中的对应书籍 `isContinuation` 都为 `false`，该公开字段无法表达连续阅读。
- 风险：Web 客户端若依赖该字段连接跨日事件，会始终把连续区间渲染成独立事件，和 App 日历展示不一致。
- iOS 决策：`DesktopWebCalendarRepository.swift` 原样保留恒为 `false` 并标记 `TODO(ANDROID-WEB-022)`；隔离数据库测试固定跨日事件仍不连续的合同。

### ANDROID-WEB-023：月历已读数量可包含已删除或缺失书籍

- 关联接口：`WEB-API-032 GET /api/v1/calendar/month`。
- 证据：`BookRepository.getReadDoneBookCountOfDay` 最终调用 DAO 直接统计时间范围内 `book_read_status_record` 且只排除 `book_id=0`，没有连接有效书籍；同一月历响应的书籍事件与日详情已读书籍路径则会连接并过滤未删除 `book`。
- App 参考：App 使用同一底层已读数量统计，因此计数问题并非 Web 独有；但日历事件和详情仍只展示有效书籍。
- 可复现输入：某日保留一条有效完成记录，并将关联书籍软删除或让记录指向不存在的书籍。
- 实际结果：该日 `readDoneBookCount` 增加，但 `books` 与日详情中没有对应书籍。
- 风险：月历徽标数量与可展开明细不一致，用户无法解释多出的完成数。
- iOS 决策：`DesktopWebCalendarRepository.swift` 原样按状态记录计数并标记 `TODO(ANDROID-WEB-023)`；隔离数据库测试固定“计数存在、书籍不展示”的合同。

### ANDROID-WEB-024：批量删除会让不存在或已删除章节的书摘解除关联

- 关联接口：`WEB-API-041 POST /api/v1/chapters/batch-delete`。
- 证据：`ChapterService.kt:357-368` 只用 `findById` 收集仍有效的章节实体，却继续把原始 `request.ids` 交给 `collectDeleteChapterIds`；`ChapterService.kt:725-737` 的辅助方法把这些原始根 ID 原样纳入结果，随后 `WebNoteRepository.removeChapterOfNotes` 会对全部结果清空 `note.chapter_id`。
- App 参考：`ChapterRepository.kt:556-573` 的 App 批量删除先从当前章节树收集真实目标，再在事务中解除书摘关联并软删除章节，正常 UI 不会把不存在的客户端 ID 作为删除根节点。
- 可复现输入：准备一条仍指向已软删除章节 ID 的书摘，或人为令书摘引用不存在的正 ID，再把该 ID 放入批量删除请求。
- 实际结果：接口返回成功，章节没有可删除记录，但书摘的 `chapter_id` 仍被清零、`updated_date` 被更新。
- 风险：一个看似幂等的无效删除请求会修改仍有效的书摘，且无法从响应判断发生了额外数据损失。
- iOS 决策：`DesktopWebChapterRepository+Writes.swift` 原样把请求根 ID 纳入解绑范围并标记 `TODO(ANDROID-WEB-024)`；隔离数据库测试固定已删除章节仍会解除书摘关联的合同。

### ANDROID-WEB-025：章节多步骤写入缺少共同事务

- 关联接口：`WEB-API-038 PUT /api/v1/chapters/{id}`、`WEB-API-042 PUT /api/v1/books/{bookId}/chapters/order`、`WEB-API-043 PUT /api/v1/chapters/{parentId}/children/order`、`WEB-API-044 PUT /api/v1/chapters/move-to-parent`、`WEB-API-045 PUT /api/v1/chapters/move-out`、`WEB-API-046 POST /api/v1/books/{bookId}/chapters/batch`。
- 证据：`ChapterService.kt:286-297` 先改标题再刷新整树 metadata；`ChapterService.kt:372-425`、`465-543` 逐条更新排序、父级或插入章节，移动后再单独刷新 metadata；这些路径均未使用 `DatabaseProvider.db.withTransaction`，每次 Repository 调用独立提交。
- App 参考：`ChapterRepository.kt:637-710,665-689,770-875` 的移动与组织变更路径使用 `noteDb.runInTransaction`；目录导入也在 `ChapterRepository.kt:132-153` 的事务内写完整棵树。
- 可复现输入：在标题已更新后让 metadata 刷新失败，或在重排、移动、批量创建的较晚条目注入约束/触发器失败。
- 实际结果：接口失败，但此前标题、父级、顺序或已插入章节继续保留；移动场景还可能出现结构已经变化而 `chapter_level/source_path` 仍为旧值。
- 风险：客户端重试无法恢复首次意图，章节树可能处于结构和派生 metadata 不一致的中间状态。
- iOS 决策：`DesktopWebChapterRepository+Writes.swift` 按 Android 的独立提交边界复刻并标记 `TODO(ANDROID-WEB-025)`；隔离数据库测试固定较晚失败后的部分提交状态。

### ANDROID-WEB-026：部分章节写接口未校验所属书籍仍有效

- 关联接口：`WEB-API-038`、`WEB-API-040`、`WEB-API-041`、`WEB-API-043`、`WEB-API-044`、`WEB-API-045`。
- 证据：`ChapterService.kt:286-307,344-370,398-498` 只通过 `WebChapterRepository.findById/queryByIds` 校验章节仍有效，没有调用 `requireActiveBook`；相对地，创建、置顶、顶级排序、在线目录和导入路径会显式校验有效书籍。
- App 参考：App 的章节入口通常从当前有效书籍页面进入，但 `ChapterRepository` 自身也没有对所有按 ID 写入统一增加有效书籍检查，因此 Web 把内部按 ID 能力直接暴露后放大了这一边界缺口。
- 可复现输入：软删除一本书但保留其有效章节，再对章节执行改名、删除、子级排序、移入父级或移出操作。
- 实际结果：请求仍成功并修改章节、书摘关联或树 metadata；批量删除还可混合处理有效书籍与已删除书籍下的章节。
- 风险：已删除书籍的隐藏内容仍可被局域网客户端改写，恢复书籍后看到的章节树可能已发生不可预期变化。
- iOS 决策：`DesktopWebChapterRepository+Writes.swift` 保留这些接口只校验章节、不校验有效书籍的合同并标记 `TODO(ANDROID-WEB-026)`；隔离数据库测试固定已删除书籍下章节仍可改名的行为。

### ANDROID-WEB-027：目录导入只选择深层节点时整棵祖先子树被跳过

- 关联接口：`WEB-API-050 POST /api/v1/books/{bookId}/chapters/import-commit`。
- 证据：`ChapterService.kt:185-213` 在每个节点先调用 `isNodeSelected` 决定是否递归；`ChapterService.kt:716-719` 只检查当前 key 和直接子节点 key，不递归检查更深后代。
- App 参考：`ChapterRemoteSyncSheetViewModel` 按勾选项形成导入列表，`ChapterRepository.kt:132-153` 会在事务中递归保存传入树；App 业务不会用这个仅检查一层的 Web 选择辅助方法。
- 可复现输入：目录包含根、子、孙三级，只把孙节点 key 放入 `selectedKeys`。
- 实际结果：根节点被判断为未选择，根及全部后代一并计入 `skipped`，孙节点没有创建；如果同时选择直接子节点，才会进入递归并继续创建未显式选择的祖先与后代。
- 风险：用户明确选择的深层章节静默丢失，返回的跳过数量看似合理却无法说明选择为何未生效。
- iOS 决策：`DesktopWebChapterRepository+Import.swift` 原样只检查当前节点和直接子节点并标记 `TODO(ANDROID-WEB-027)`；隔离数据库测试固定“仅选择孙节点时全部跳过”的合同。

### ANDROID-WEB-028：按书摘 ID 的接口可读取或修改已删除书籍中的隐藏数据

- 关联接口：`WEB-API-074`、`WEB-API-076` 至 `WEB-API-082`。
- 证据：`NoteService.kt:290-294,468-478,569-755,761-887` 的详情、删除、批量移动/打标/迁书和合并均先按 note ID 读取；除更新时的目标书籍与迁书目标外，不校验原书籍有效性。`WebNoteDao.kt:73-79` 的 `findById/queryByIds` 也只过滤 `note.is_deleted`，不关联 `book`。
- App 参考：App 书摘列表通常从有效书籍页面进入，但 `NoteRepository.kt:1396-1402,1797-1819,2040-2075` 的底层删除、合并和移动同样主要按 note ID/对象执行；UI 前置条件不能保护直接暴露的 Web ID 接口。
- 可复现输入：软删除一本书但保留其中的有效书摘，再按 ID 请求详情、删除、清空章节、设置标签、迁入另一有效书籍，或合并该书中的多条书摘。
- 实际结果：详情仍返回隐藏书摘；单删、批删、打标和章节移动继续修改其图谱；更新可把隐藏书摘迁出，合并可在已删除书籍下创建新的有效书摘。
- 风险：删除态数据不再是隔离边界，局域网客户端可观察或改写 App 正常入口不可见的数据，恢复书籍后出现意外变更。
- iOS 决策：`DesktopWebNoteRepository.swift` 与 `DesktopWebNoteRepository+Writes.swift` 保留按 note 主键读取和写入的合同并标记 `TODO(ANDROID-WEB-028)`；隔离数据库测试固定已删除书籍下详情可读、删除可写。

### ANDROID-WEB-029：创建和更新会把重复标签 ID 误判为标签不存在

- 关联接口：`WEB-API-075 POST /api/v1/notes`、`WEB-API-076 PUT /api/v1/notes/{id}`。
- 证据：`NoteService.kt:408-412,494-498` 把请求原始 `tagIds` 直接交给校验；`WebNoteRepository.kt:1106-1110` 将 SQL 命中数与原始数组长度比较，而 `WebNoteDao.kt:113-115` 的 `IN (:tagIds)` 对重复值只会命中一条主记录。
- App 参考：`NoteRepository.kt:1155-1158,1191-1213` 和 `TagRepository.kt:312-324` 的 App 写入来自受控标签对象集合，正常 UI 不会构造重复选择；Web 把外部数组直接暴露后才出现集合语义退化。
- 可复现输入：有效标签 411 存在，创建或更新请求传入 `tagIds: [411, 411]`。
- 实际结果：数据库计数为 1、请求长度为 2，接口返回“部分标签不存在”，合法标签组合被拒绝。
- 风险：客户端重试或合并数组产生重复项时出现非幂等失败，且错误信息误导为数据缺失。
- iOS 决策：`DesktopWebNoteRepository+Writes.swift` 按原始长度比较并标记 `TODO(ANDROID-WEB-029)`；隔离数据库测试固定重复 ID 返回参数错误。

### ANDROID-WEB-030：书摘写响应中的图片 ID 是数组下标而非数据库主键

- 关联接口：`WEB-API-075`、`WEB-API-076`、`WEB-API-082`。
- 证据：`NoteService.kt:1129-1143` 的 `buildNoteResultDto` 直接用 `imageUrls.mapIndexed` 构造 `WebAttachImageDto(index, url)`；而详情和列表在 `NoteService.kt:326-327` 通过 `WebNoteDao.kt:42-50` 返回真实 `attach_image.id`。
- App 参考：`NoteRepository.kt:1159-1163,1214-1222` 写入图片后不对外构造 Web DTO；App 后续读取使用持久化实体 ID，没有“本次数组下标就是图片 ID”的合同。
- 可复现输入：创建带两张图片的书摘，记录 POST 响应，再请求该书摘详情。
- 实际结果：写响应图片 ID 固定为 `0,1`；详情响应改为数据库自增主键，通常不是 `0,1`。
- 风险：客户端若缓存写响应中的 ID，随后的刷新会看到同一资源身份突变，无法可靠做增量更新或定位。
- iOS 决策：`DesktopWebNoteRepository+Writes.swift` 的写响应继续生成数组下标并标记 `TODO(ANDROID-WEB-030)`；路由与仓储测试分别锁定响应结构和写后真实主键差异。

### ANDROID-WEB-031：两类书摘批量写入没有共同事务

- 关联接口：`WEB-API-079 POST /api/v1/notes/batch-move-chapter`、`WEB-API-080 POST /api/v1/notes/batch-set-tags`。
- 证据：`NoteService.kt:642-650` 逐条更新章节；`NoteService.kt:689-701` 逐条替换标签再更新 note 时间，均未进入 `DatabaseProvider.db.withTransaction`。其中 `WebNoteRepository.kt:1122-1148` 的标签替换自身也分为软删除关系和逐条插入多个 DAO 调用。
- App 参考：`NoteRepository.kt:2040-2049` 的 App 批量移动章节使用 `runInTransaction`；`TagRepository.kt:294-306` 的 App 批量标签路径同样没有事务，因此前者是 Web/App 差异，后者是双方共有问题。
- 可复现输入：批量移动时让较晚 note 更新失败；或批量替换标签时让关系删除后、某个关系插入或 note 更新时间更新失败。
- 实际结果：接口失败但此前书摘已移动；标签路径甚至可能留下“旧关系已删除、只插入部分新关系、note 更新时间未更新”的单条中间状态。
- 风险：失败响应不代表无副作用，客户端重试可能覆盖部分结果，标签图谱和主记录时间戳也可能不一致。
- iOS 决策：`DesktopWebNoteRepository+Writes.swift` 保留独立提交边界并标记 `TODO(ANDROID-WEB-031)`；隔离数据库测试覆盖批量成功、缺失 ID 规则与关系替换结果，故障注入将在双端隔离对比阶段继续核验。

### ANDROID-WEB-032：合并草稿绕过位置校验与富文本规范化

- 关联接口：`WEB-API-082 POST /api/v1/notes/batch-merge`。
- 证据：`NoteService.kt:825-859` 将 `merged.content/idea/position/positionUnit` 直接放入新 `NoteEntity`，只校验非空、章节和标签；没有调用创建/更新使用的 `canonicalizeRichHtmlHighlightColors` 与 `validateNotePosition`。
- App 参考：`NotesMergePresenter.kt:254-271` 的合并对象来自受控编辑页面并交给 `NoteRepository.mergeNotes`；Web 允许任意客户端直接提交草稿字段，扩大了底层未校验边界。
- 可复现输入：合并两条书摘，并在 `merged` 中传入未规范化 `<mark>`、超出总页数的 `position` 与未知 `positionUnit`。
- 实际结果：合并成功，新书摘原样保存富文本、非法位置和未知单位；同样内容通过创建或更新接口会被规范化或拒绝。
- 风险：同一业务对象因入口不同形成不同持久化格式，并可能破坏阅读进度展示、排序和后续编辑。
- iOS 决策：`DesktopWebNoteRepository+Writes.swift` 原样绕过两项处理并标记 `TODO(ANDROID-WEB-032)`；隔离数据库测试固定未规范化 mark、`999999` 位置与单位 `99` 被接受。

### ANDROID-WEB-033：空字符串图片 URL 可绕过空内容校验并写入数据库

- 关联接口：`WEB-API-075`、`WEB-API-076`。
- 证据：`NoteService.kt:1056-1067` 的 `validateNoteContent` 只判断 `imageUrls` 数组是否非空，不检查元素；`WebNoteRepository.kt:1136-1148` 又会把每个字符串原样插入 `attach_image`。
- App 参考：`NoteRepository.kt:1159-1163,1214-1222` 接收由图片选择/导入流程产生的附图对象，正常 UI 不会把空 URL 作为唯一书摘内容；Web 请求缺少这一上游保证。
- 可复现输入：创建或更新请求令 content、idea 均为空，并传入 `imageUrls: [""]`。
- 实际结果：内容校验通过，数据库产生 `image_url=''` 的有效附图行，接口把书摘视为非空。
- 风险：生成无法展示、无法定位来源的幽灵附件，并允许业务上空白书摘持久化。
- iOS 决策：`DesktopWebNoteRepository+Writes.swift` 保留非空数组判断和空 URL 插入并标记 `TODO(ANDROID-WEB-033)`；隔离数据库测试固定该行存在。

### ANDROID-WEB-034：已删除标签在书摘筛选、计数和展示中的语义互相矛盾

- 关联接口：`WEB-API-068`、`WEB-API-069`、`WEB-API-072`、`WEB-API-073`。
- 证据：`WebNoteDao.kt:31-40` 的展示标签会过滤 `tag.is_deleted=0`；`WebNoteRepository.kt:574-590` 的书内“有/无标签”内存筛选使用该展示集合。正标签 ID 筛选和全局特殊筛选在 `WebNoteRepository.kt:194-224,277-307,899-950` 只检查 `tag_note.is_deleted=0`；筛选项默认计数在 `WebNoteDao.kt:122-140,187-213` 同样只看关系，而自定义项在 `WebNoteDao.kt:163-176,241-254` 又过滤标签主记录。
- App 参考：`TagRepository.kt:43-163` 与 App 标签选择入口只展示有效标签；正常 UI 无法选择已删除标签 ID，但历史有效关系仍可能来自删除中断、恢复或同步数据。
- 可复现输入：给有效书摘保留一条有效 `tag_note`，再把对应 tag 主记录软删除。
- 实际结果：书内“无标签”列表会包含该书摘，但筛选项计数把它计入“有标签”；直接用已删除 tag ID 仍能筛中；全局“有标签”也会命中，而响应的 tags 数组为空。
- 风险：筛选徽标、列表结果和响应内容无法互相解释，用户点击“有标签”后可能看到没有任何标签的书摘。
- iOS 决策：`DesktopWebNoteRepository.swift` 同时保留展示集合与原始关系集合并标记 `TODO(ANDROID-WEB-034)`；隔离数据库测试固定书内列表/计数、正 ID 和全局筛选的分叉。

### ANDROID-WEB-035：合并排序数组中的重复 ID 会重复拼接内容与图片

- 关联接口：`WEB-API-082 POST /api/v1/notes/batch-merge`。
- 证据：`NoteService.kt:779-809` 用 `sortNotesForMerge` 的结果拼接文本和图片；`NoteService.kt:1025-1034` 对 `orderedIds` 每个元素都直接映射 note，`used` 只用于排除尾部补项，没有拒绝或去重排序数组本身。
- App 参考：`NotesMergePresenter.kt:152-271` 的排序来自当前已选择书摘列表，每条书摘对象唯一；Web 直接接受外部 ID 数组，缺少 App 入口的唯一性保证。
- 可复现输入：选择书摘 821、822，并传入 `contentOrderedIds: [822, 821, 822]`。
- 实际结果：默认合并内容会包含 822 两次，822 的图片也按相同顺序重复写入；原书摘只删除一次。
- 风险：一个排序参数会静默复制用户内容和附件，且响应没有提示重复来源。
- iOS 决策：`DesktopWebNoteRepository+Writes.swift` 保留重复映射并标记 `TODO(ANDROID-WEB-035)`；隔离数据库测试固定图片顺序为 `two, one, two`。

### ANDROID-WEB-036：按书评 ID 的接口可读取或修改已删除书籍中的隐藏数据

- 关联接口：`WEB-API-114`、`WEB-API-116`、`WEB-API-117`。
- 证据：`ReviewService.kt:107-110,153-155,192-198` 只调用 `WebReviewRepository.findById`；`WebReviewDao.kt:33-35` 仅校验 review 自身未删除，没有关联 book 或检查 book 删除态。
- App 参考：`ReviewRepository.kt:50-89` 的底层更新、删除和详情同样按 review ID 工作；App 正常从有效书籍页面进入，但该 UI 前置条件不能保护直接暴露的 Web ID 接口。
- 可复现输入：软删除一本书但保留其中一条有效书评，再按书评 ID 请求详情、更新或删除。
- 实际结果：详情仍返回隐藏书评，更新和删除也成功修改其内容、图片或删除态。
- 风险：已从书架隐藏的数据仍可被局域网客户端枚举和改写，删除书籍边界不能形成访问隔离。
- iOS 决策：`DesktopWebReviewRepository.swift` 与 `DesktopWebReviewRepository+Writes.swift` 保留按 review ID 定位的行为并标记 `TODO(ANDROID-WEB-036)`；隔离数据库测试覆盖详情、更新与删除。

### ANDROID-WEB-037：书评创建和更新原样接受空图片 URL

- 关联接口：`WEB-API-115`、`WEB-API-116`。
- 证据：`ReviewService.kt:115-143,157-181` 只校验标题与正文，随后把 `imageUrls` 原样交给 `WebReviewRepository.replaceReviewImages`；`WebReviewRepository.kt:186-197` 对每个字符串直接插入 `review_image`，不剔除空白值。
- App 参考：`ReviewRepository.kt:32-65` 接收由 App 图片选择流程产生的 `ReviewImage`，正常 UI 不会主动构造空 URL；Web 请求缺少这一上游保证。
- 可复现输入：创建或更新一条标题非空的书评，同时传入 `imageUrls: [""]`。
- 实际结果：请求成功，数据库新增 `image=''` 的有效 `review_image` 行。
- 风险：生成无法展示和无法追溯来源的幽灵附件，并让图片数量与可见内容不一致。
- iOS 决策：`DesktopWebReviewRepository+Writes.swift` 原样保存空字符串并标记 `TODO(ANDROID-WEB-037)`；隔离数据库测试固定该记录存在。

### ANDROID-WEB-038：书评写响应中的图片 ID 是数组下标而非数据库主键

- 关联接口：`WEB-API-115`、`WEB-API-116`。
- 证据：`ReviewService.kt:204-216` 通过 `mapIndexed` 把 `0...n` 写入 `WebAttachImageDto.id`；详情与列表则由 `WebReviewDao.kt:22-31` 返回真实 `review_image.id`。
- App 参考：`ReviewRepository.kt:32-65,80-89` 写入后由 DAO 主键和关系实体持有真实图片 ID，App 不把数组位置伪装成持久化标识。
- 可复现输入：创建带两张图片的书评，记录 POST 响应，再查询该书评详情。
- 实际结果：写响应图片 ID 为 0、1；详情响应改为数据库自增主键，客户端看到同一图片的标识变化。
- 风险：前端若缓存写响应或以 ID 做差量更新，会把数组位置误当稳定实体标识。
- iOS 决策：`DesktopWebReviewRepository+Writes.swift` 保留写响应重编号并标记 `TODO(ANDROID-WEB-038)`；路由与 Repository 测试分别锁定写响应和详情差异。

### ANDROID-WEB-039：书评草稿的书籍存在性校验不一致

- 关联接口：`WEB-API-108`、`WEB-API-110`。
- 证据：`ReviewDraftService.kt:13-20,64-85` 中 GET 和 DELETE 只执行正数 ID 校验，PUT 才调用 `ensureBookExists` 检查有效 book。
- App 参考：`ReviewEditPresenter.kt:51-110` 的草稿读写依赖已打开的书评编辑页面，bookId 来自有效页面上下文；Web 直接接收外部 ID，没有同等前置条件。
- 可复现输入：使用不存在或已软删除的正数 bookId，先预置对应 SharedPreferences 草稿，再分别调用 GET、DELETE 与 PUT。
- 实际结果：GET 可读、DELETE 可删，PUT 则返回“书籍不存在”。
- 风险：同一草稿资源在三个方法上的生命周期边界矛盾，陈旧草稿可被远程枚举或清理却无法更新。
- iOS 决策：`DesktopWebReviewRepository.swift` 保留 GET/DELETE 不校验、PUT 校验的分叉并标记 `TODO(ANDROID-WEB-039)`；测试固定三种方法的不同结果。

### ANDROID-WEB-040：书评草稿先提交上传票据再保存偏好，失败时无法回滚

- 关联接口：`WEB-API-109 PUT /api/v1/reviews/drafts`。
- 证据：`ReviewDraftService.kt:48-61` 先调用 `NoteImageUploadRiskControlService.commitUploadedTickets`，再进入 `WebReviewDraftRepository.saveDraft`；`WebReviewDraftRepository.kt:19-44` 最终写 SharedPreferences，两类存储没有共同事务。
- App 参考：`ReviewEditPresenter.kt:76-89` 的本地自动保存只写草稿，不承担 Web 上传票据提交；因此 App 路径不存在这组跨存储原子性要求。
- 可复现输入：提交含有效上传票据的草稿，并在票据提交后让 SharedPreferences 保存失败或进程终止。
- 实际结果：上传票据已被消费，但草稿及其图片引用未保存，重试可能无法重新绑定同一票据。
- 风险：附件资源与草稿状态永久分叉，用户可能丢失刚上传的图片引用。
- iOS 决策：`DesktopWebReviewRepository.swift` 保留“票据回调先于偏好保存”的调用顺序并标记 `TODO(ANDROID-WEB-040)`；失败注入测试验证回调已发生而草稿未落盘。

### ANDROID-WEB-041：书评 `word_count` 排序与响应字数使用不同文本口径

- 关联接口：`WEB-API-107`、`WEB-API-111`。
- 证据：`WebReviewRepository.kt:147-159` 使用 SQLite `LENGTH(title) + LENGTH(content)` 对原始 HTML 排序；`ReviewService.kt:204-216` 与 DTO 转换使用 `wordCount` 生成响应字数，会按可见文本处理富文本。
- App 参考：App 展示字数使用 `StringExtensions.wordCount` 的可见内容语义；原始 HTML 长度不是用户可见的书评长度。
- 可复现输入：准备一条可见文字很短但 HTML 标签很长的书评，以及一条纯文本较长的书评，按 `word_count asc` 查询。
- 实际结果：排序次序按 HTML 原文长度决定，却在响应中显示与该次序不一致的可见字数。
- 风险：用户选择按字数排序后看到明显倒序，且客户端无法用响应字段解释服务端顺序。
- iOS 决策：`DesktopWebReviewRepository.swift` 保留原始 HTML SQL 长度排序和可见 UTF-16 字数响应并标记 `TODO(ANDROID-WEB-041)`；隔离数据库测试固定反直觉顺序。

### ANDROID-WEB-042：删除书评图片与主记录是两个独立提交

- 关联接口：`WEB-API-117 DELETE /api/v1/reviews/{id}`。
- 证据：`ReviewService.kt:192-198` 调用 `WebReviewRepository.softDelete`；`WebReviewRepository.kt:180-184` 先更新图片、再更新书评主表，没有 `withTransaction` 包裹。
- App 参考：`ReviewRepository.kt:70-77` 在单一 `noteDb.runInTransaction` 中删除主记录和图片。
- 可复现输入：让图片软删除成功，再通过触发器或数据库故障使 review 主表更新失败。
- 实际结果：接口失败，但图片已全部软删除，书评仍有效且再次查询不再包含图片。
- 风险：失败响应仍造成不可见的数据损失，重试无法恢复已删除的图片关联。
- iOS 决策：`DesktopWebReviewRepository+Writes.swift` 按相同顺序执行两个独立写入并标记 `TODO(ANDROID-WEB-042)`；故障注入测试固定主表失败后图片提交仍保留。

### ANDROID-WEB-043：计时完成接口允许矛盾或无效的时间字段

- 关联接口：`WEB-API-083 POST /api/v1/read-time/sessions`。
- 证据：`ReadTimeWebService.kt:19-41` 只在 `elapsedSeconds` 超过 8 小时时检查 `confirmedLongDuration`，随后原样保存请求的 `startTime`、`endTime`、`elapsedSeconds`、`countdownSeconds` 与 `pausedDurationMillis`；没有校验负数、起止顺序、未来时间或字段间的一致性。
- App 参考：`ReadTimingPresenter.kt:158-224` 从当前时间建立运行中的计时记录，并由 App 计时状态维护起止时间和时长的一致性；`ReadTimeRecordPresenter.kt:125-163` 保存的是 App 已构造的完整记录，不接受同等自由度的外部字段组合。
- 可复现输入：设置 `confirmedLongDuration=true`，同时提交负的阅读/倒计时/暂停时长、未来的开始时间和早于开始时间的结束时间。
- 实际结果：接口成功，并持久化一条状态为已完成但时间字段互相矛盾的阅读记录。
- 风险：阅读统计、时间线排序和后续编辑会基于不可解释的数据计算，且客户端无法根据成功响应判断记录已损坏。
- iOS 决策：`DesktopWebReadingRecordRepository.swift` 原样保存这些字段并标记 `TODO(ANDROID-WEB-043)`；隔离数据库单测固定该异常合同。

### ANDROID-WEB-044：阅读记录详情、更新和删除可直接操作未完成计时

- 关联接口：`WEB-API-085`、`WEB-API-087`、`WEB-API-088`。
- 证据：`ReadingRecordWebService.kt:38-41,52-75,92-95` 的 `getOwnedRecord` 只检查 `bookId` 与 `isDeleted`，没有要求 `status = FINISHED`；而列表路径通过 `ReadTimeRecordDao.kt:107-108` 只返回已完成记录。
- App 参考：`ReadTimingPresenter.kt:158-224` 与 `ReadTimingService.kt` 持有运行中/暂停中的计时会话；`ReadTimeRecordPresenter.kt:54-163,189-200` 的编辑与删除来自阅读记录页面上下文，不承担直接终止活动计时的职责。
- 可复现输入：准备一条 `RUNNING` 或 `PAUSE` 状态的有效计时记录，分别请求详情、更新或删除。
- 实际结果：详情可直接读取；更新会把记录强制改为 `FINISHED`；删除会把活动记录软删除。
- 风险：局域网客户端可绕过计时会话 owner，导致 App 中正在进行的计时被提前结束、覆盖或失踪。
- iOS 决策：`DesktopWebReadingRecordRepository.swift` 保留该状态边界并标记 `TODO(ANDROID-WEB-044)`；测试覆盖运行中记录的读取、强制完成与删除。

### ANDROID-WEB-045：更新相同进度但省略单位时会重新解释历史进度

- 关联接口：`WEB-API-087 PUT /api/v1/books/{bookId}/reading-records/{recordId}`。
- 证据：`ReadingRecordWebService.kt:199-217,232-239` 仅在“请求进度与旧值相同且请求单位也与旧单位相同”时保留已记录单位；请求省略 `recordedPositionUnit` 而旧记录存在单位时，会回退到书籍当前 `positionUnit` 重新规范化同一个数值。
- App 参考：`ReadTimeRecordPresenter.kt:75-96,125-150` 编辑时携带完整 `ReadTimeRecord`，不存在把省略字段解释为使用书籍当前单位的 Patch 合同。
- 可复现输入：旧记录 `position=50`、`recordedPositionUnit=2`，书籍当前 `positionUnit=0`；更新时继续提交 `position=50` 但省略 `recordedPositionUnit`。
- 实际结果：历史记录的单位被改成 0；若原数值超过新单位允许范围，还会在未改变进度值的情况下报错。
- 风险：局部更新会静默改变历史阅读位置的含义，或让原本合法的相同值更新突然失败。
- iOS 决策：`DesktopWebReadingRecordRepository.swift` 复刻同一保留条件和回退顺序并标记 `TODO(ANDROID-WEB-045)`；单测固定单位覆盖与拒绝边界。

### ANDROID-WEB-046：模糊阅读“日期”按精确毫秒与当前时刻比较

- 关联接口：`WEB-API-086`、`WEB-API-087`。
- 证据：`ReadingRecordWebService.kt:166-174` 直接判断 `fuzzyReadDate > System.currentTimeMillis()`，但错误文案表达的是“阅读日期不能晚于今天”。
- App 参考：`ReadTimeRecordActivity.kt:218,348-349,596-604` 通过日期选择器和当前时间默认值构造模糊阅读日期，页面意图是选择日历日；Web 客户端则可直接提交任意毫秒时间戳。
- 可复现输入：提交与设备同一自然日、但比当前时刻晚数分钟的 `fuzzyReadDate`。
- 实际结果：接口以“晚于今天”为由拒绝同一天的时间戳。
- 风险：同日数据会因时钟、时区或客户端生成时机产生边界性失败，错误文案也无法准确解释限制。
- iOS 决策：`DesktopWebReadingRecordRepository.swift` 继续按精确当前毫秒比较并标记 `TODO(ANDROID-WEB-046)`；测试固定同日未来时刻被拒绝的行为。

### ANDROID-WEB-047：“全局类别”实际跨全部书籍返回，默认顺序也跨作用域计算

- 关联接口：`WEB-API-089`、`WEB-API-091`。
- 证据：`WebRelatedDao.kt:27-37` 的 `queryGlobalCategories` 仅过滤 `is_deleted=0`，没有要求 `book_id=0`；`RelatedService.kt:34-41,68-76` 直接用该结果展示全局类别并计算新全局类别的最大 order。
- App 参考：`RelevantRepository.kt` 与 `RelatedNoteCategoriesViewModel.kt` 在书籍上下文中以 `book_id=0 OR 当前书籍` 组织类别；类别管理并没有“全局页显示所有其他书籍私有类别”的业务意图。
- 可复现输入：为书籍 A、书籍 B 和全局作用域分别建立有效类别，再读取全局类别或创建未指定 order 的全局类别。
- 实际结果：响应包含 A、B 的私有类别；新全局类别的 order 取所有作用域最大值加一。
- 风险：局域网客户端可看到其他书籍类别，且全局排序被无关书籍影响。
- iOS 决策：`DesktopWebRelatedRepository.swift` 与 `DesktopWebRelatedRepository+Writes.swift` 原样复刻并标记 `TODO(ANDROID-WEB-047)`；隔离数据库测试锁定跨作用域列表和 order。

### ANDROID-WEB-048：类别切换作用域只改 `book_id`，不验证目标书籍或既有内容

- 关联接口：`WEB-API-092 PUT /api/v1/related-categories/{id}`。
- 证据：`RelatedService.kt:96-145` 解析新 scope 后直接更新 `CategoryEntity.bookId`；没有读取目标 book，也没有迁移或检查该类别下 `category_content.book_id`。
- App 参考：`CategoryManagerPresenter.kt` 与相关内容页面的类别操作依赖当前有效书籍上下文，不暴露可把类别任意迁往不存在书籍的外部 Patch。
- 可复现输入：把含书籍 A 内容的自定义类别改为不存在书籍 ID，或改到书籍 B。
- 实际结果：类别更新成功，既有内容仍归属 A，类别与内容作用域分叉。
- 风险：列表、计数和编辑校验采用不同 owner 后会出现内容失踪或不可编辑。
- iOS 决策：`DesktopWebRelatedRepository+Writes.swift` 保留直接改作用域的合同并标记 `TODO(ANDROID-WEB-048)`；测试覆盖无效目标与不迁移内容。

### ANDROID-WEB-049：删除自定义类别会跨作用域物理删除所有同名类别且可部分提交

- 关联接口：`WEB-API-094 DELETE /api/v1/related-categories/{id}`。
- 证据：`RelatedService.kt:161-180` 先按标题查询全部有效类别，再逐个调用 `deleteNotesOfCategory` 与 `deleteCategoryById`；`WebRelatedDao.kt:42-43,66-67,135-136` 均为物理删除，循环没有共同事务，也未先处理 `category_image`。系统默认类别则保留类别、只物理删除内容。
- App 参考：`RelevantRepository.kt` 的正常类别管理以当前类别 ID 和当前书籍为边界，不应把其他书籍的同名类别视为同一资源。
- 可复现输入：在两本书中建立同名自定义类别，其中一个类别内容带图片或让第二个类别删除触发失败，然后删除第一个类别。
- 实际结果：操作向其他作用域扩散；前序类别可能已经永久删除，后序失败无法回滚；默认类别又呈现另一套删除语义。
- 风险：一次请求可跨书误删，且失败响应仍会永久改变部分数据。
- iOS 决策：`DesktopWebRelatedRepository+Writes.swift` 复刻同名扩散、物理删除和独立提交并标记 `TODO(ANDROID-WEB-049)`；故障注入测试固定部分提交。

### ANDROID-WEB-050：类别重排逐行独立提交并产生不同更新时间

- 关联接口：`WEB-API-095 POST /api/v1/books/{bookId}/related-categories/reorder`。
- 证据：`RelatedService.kt:394-417` 校验完整集合后逐项设置 order、逐次调用 `WebRelatedRepository.updateCategory`，每轮重新读取系统时间，未使用事务。
- App 参考：`CategoryManagerPresenter.kt` 的拖动排序属于单一用户动作，业务上应整体成功或整体失败。
- 可复现输入：提交完整合法顺序，并让中间某一行更新通过触发器失败。
- 实际结果：失败前的类别已持久化新 order，后续保持旧值；各行 updateDate 也可能不同。
- 风险：失败后的排序集合不再满足唯一连续顺序，重试前 UI 与数据库状态分叉。
- iOS 决策：`DesktopWebRelatedRepository+Writes.swift` 保留逐行提交并标记 `TODO(ANDROID-WEB-050)`；测试用触发器锁定前序提交。

### ANDROID-WEB-051：相关内容多条路径不校验来源书籍、类别及 owner 生命周期

- 关联接口：`WEB-API-091`、`WEB-API-098` 至 `WEB-API-103`、`WEB-API-106`。
- 证据：`WebRelatedDao.kt:90-106` 的详情/按 ID 查询只过滤内容 tombstone；`WebRelatedRepository` 的书内 RawQuery 不连接有效 book/category；`RelatedService.kt:258-286,306-349` 创建只校验类别作用域且内容书查询包含已删除书籍，来源 `bookId` 本身不验证；转换时又通过 `queryBooksByIdsIncludingDeleted` 返回内容书。
- App 参考：`RelevantEditPresenter.kt`、`RelevantListViewModel.kt` 和 `RelevantRepository.kt` 从已打开的有效书籍/类别页面构建操作上下文，正常路径不会直接接受任意外部 owner ID。
- 可复现输入：软删除来源书籍或类别后按原 bookId 列表/详情；创建时使用不存在来源书籍或已删除内容书。
- 实际结果：部分列表和详情继续暴露孤儿内容；创建可落在无效来源书籍，且可引用已删除内容书。
- 风险：Web 可制造或读取 App 页面无法稳定管理的数据，owner 隔离与生命周期边界失效。
- iOS 决策：`DesktopWebRelatedRepository.swift` 与 `DesktopWebRelatedRepository+Writes.swift` 复刻这些路径差异并标记 `TODO(ANDROID-WEB-051)`；测试覆盖已删父级、无效来源和已删内容书。

### ANDROID-WEB-052：空的“全部相关内容”返回 `pageSize=0`

- 关联接口：`WEB-API-099 GET /api/v1/books/{bookId}/related-notes/all`。
- 证据：`RelatedService.kt:220-244` 令 `total = dtoList.size`，随后直接构造 `Pagination(1, total, total, ...)`；空列表因此得到 pageSize 0。
- App 参考：该接口是 Web 专用全量传输形态；App 列表不暴露 PageResult。其他 Web 分页入口均把 pageSize 规范为正数。
- 可复现输入：查询没有相关内容的有效书籍。
- 实际结果：返回 `pagination.page=1,pageSize=0,total=0,totalPages=0`。
- 风险：通用分页客户端若以 pageSize 做除法或下一页判断，会触发异常分支。
- iOS 决策：`DesktopWebRelatedRepository.swift` 保留零 pageSize 并标记 `TODO(ANDROID-WEB-052)`；路由与 Repository 测试固定空集合外形。

### ANDROID-WEB-053：相关内容删除与图片删除分开提交，并重写既有图片墓碑

- 关联接口：`WEB-API-104`、`WEB-API-105`。
- 证据：`RelatedService.kt:352-380` 先软删除内容，随后另行更新图片；`WebRelatedDao.kt:108-156` 的图片 SQL 没有 `is_deleted=0` 条件。批量路径只要任一内容命中，就对请求中全部 ID 更新图片。
- App 参考：`RelevantRepository.kt` 的内容与图片生命周期由单一业务动作维护；正常 App 删除不应在失败后只留下图片墓碑变化。
- 可复现输入：让内容软删除成功后图片 SQL 失败；或批量请求同时包含有效、已删除和不存在 ID，并为已删除 ID 预置图片墓碑。
- 实际结果：第一种情况接口失败但主记录已删除；第二种情况会重写未命中内容下既有图片的 updated_date。
- 风险：失败不可回滚，且批量请求会修改超出实际命中集合的审计时间。
- iOS 决策：`DesktopWebRelatedRepository+Writes.swift` 保留两个提交及全请求 ID 图片更新并标记 `TODO(ANDROID-WEB-053)`；测试固定故障与墓碑重写。

### ANDROID-WEB-054：更新未改变 `categoryId` 时跳过类别有效性校验

- 关联接口：`WEB-API-103 PUT /api/v1/related-notes/{id}`。
- 证据：`RelatedService.kt:306-318` 只有目标 categoryId 与旧值不同时才调用 `findCategoryById` 并检查书籍归属；保持原 ID 时，即使类别已删除或已迁往其他书籍也继续更新。
- App 参考：`RelevantEditPresenter.kt` 的编辑上下文来自当前类别列表；类别生命周期变化后正常页面会刷新，而 Web Patch 可长期持有旧 ID。
- 可复现输入：先删除或迁移一条内容的类别，再更新内容但省略 categoryId 或提交原值。
- 实际结果：更新成功，内容继续引用已删除或错误书籍作用域的类别。
- 风险：编辑操作会固化已损坏关系，后续展示和批量迁移结果不可预测。
- iOS 决策：`DesktopWebRelatedRepository+Writes.swift` 保留“仅变化时校验”并标记 `TODO(ANDROID-WEB-054)`；测试锁定陈旧类别仍可更新。

### ANDROID-WEB-055：内存书籍分页乘法溢出后把负数传给 `drop` 或回绕到中间页

- 关联接口：`WEB-API-056 GET /api/v1/groups/{id}/books`、`WEB-API-118 GET /api/v1/search`、`WEB-API-119 GET /api/v1/search/aggregate` 的 `book` 域。
- 证据：`BookService.kt:635-648` 与 `SearchService.kt:174-177` 都使用 Kotlin `Int` 计算 `(page - 1) * pageSize`，未做溢出检查，随后直接调用 `drop(offset)`；Controller 允许 `page` 与 `pageSize` 达到 `Int.MAX_VALUE`。
- App 参考：`GroupBooksViewModel.kt:123-290` 和 `SearchPresenter.kt:74-143` 的 App 页面从受控滚动状态产生分页，不暴露客户端可提交的 Int 极值，因此不会走到同一乘法输入边界。
- 可复现输入：请求 `/api/v1/groups/11/books?page=3&pageSize=2147483647`，或搜索接口提交 `type=book&page=3&pageSize=2147483647&keyword=`；另用 `page=2147483646&pageSize=2147483647` 可观察正数回绕。
- 实际结果：首组参数按 32 位有符号整数回绕为 `-2`，组内书籍和单域搜索因 `drop(-2)` 失败；聚合搜索把 book 域降级为空页并把异常消息写入 `errors.book`。正数回绕时则会从与请求页码无关的中间偏移返回数据。
- 风险：合法 Int 参数可稳定触发业务失败或返回错误页，并造成内存分页与 SQL 分页域的行为分叉。
- iOS 决策：`DesktopWebGroupRepository.groupBookOffset` 与 `DesktopWebSearchRepository.arrayOffset` 原样复刻 Int32 回绕、负数失败和正数中间页，均标记 `TODO(ANDROID-WEB-055)`；Repository 测试和 Group 78 / 78 双端用例锁定当前合同。

### ANDROID-WEB-056：书籍搜索在分页前无上限加载并投影全部匹配记录

- 关联接口：`WEB-API-118`、`WEB-API-119` 的 `book` 域。
- 证据：`SearchService.kt:17,144-177` 固定以 `Int.MAX_VALUE` 查询书架，再对全部书籍执行 `BookService.convertToDto`；相关内容书同样全部读取和完整投影，合并去重后才执行内存分页。
- App 参考：`SearchPresenter.kt:120-143` 的 App 全局搜索也一次加载所选域，但输入来自单个前台搜索动作；Web 接口可被局域网客户端并发、重复调用，且额外投影混合来源的完整 Web DTO。
- 可复现输入：准备大量书籍及相关内容书，反复请求 `type=book&pageSize=1`。
- 实际结果：虽然响应只返回 1 条，数据库仍读取全部匹配书籍，并完成标签、分组、来源等完整投影后再丢弃绝大多数结果。
- 风险：响应规模与计算/内存成本脱钩，可导致前台 Web 服务延迟和内存峰值随书库总量增长。
- iOS 决策：为维持结果总数、混合顺序与去重合同，`DesktopWebSearchRepository.searchBooks` 暂时保留全量物化并标记 `TODO(ANDROID-WEB-056)`；本任务只记录，不改变 Android 基线。

### ANDROID-WEB-057：`tagId` 只过滤书架来源，不过滤相关内容书来源

- 关联接口：`WEB-API-118`、`WEB-API-119` 的 `book` 域。
- 证据：`SearchService.kt:139-152` 只把 `tagId` 写入 `WebBookRepository.BookFilter`；`SearchService.kt:162` 随后调用的 `WebRelevantRepository.searchContentBooks(keyword)` 没有标签参数，合并步骤也不再校验标签。
- App 参考：`SearchPresenter.kt:74-143` 的 App 全局搜索没有标签参数；因此 App 不存在“带标签的四域搜索”合同可为这项不对称提供业务依据。
- 可复现输入：让书籍 A 带目标标签，让未带标签的书籍 B 仅作为相关内容的 `contentBook`；请求 `type=book&keyword=<同时匹配 A/B>&tagId=<目标标签>`。
- 实际结果：响应同时返回 A 与 B；A 标记为 `bookshelf`，B 标记为 `related_content_book`，标签条件只约束前半区。
- 风险：客户端把 `tagId` 理解为搜索结果过滤条件时会得到越界结果，分页总数也包含未命中标签的书籍。
- iOS 决策：`DesktopWebSearchRepository.searchBooks` 保留半区过滤并标记 `TODO(ANDROID-WEB-057)`；隔离数据库测试锁定未带标签的相关内容书仍被合入。

### ANDROID-WEB-058：全部时间的书摘标签统计会计入已删除书摘的残留关系

- 关联接口：`WEB-API-150 GET /api/v1/statistics/chart/note-tag`。
- 证据：`StatisticsRepository.kt:1547-1567` 在 `isAll` 分支调用 `TagDao.queryNoteCountOfTag`，只统计有效 `tag_note`，没有连接 `note` 校验其 `is_deleted`；范围分支使用另一条会连接书摘时间的查询。
- App 参考：App 的书摘列表和标签筛选以有效书摘为业务对象，软删除书摘不会继续展示。
- 可复现输入：软删除一条仍保留有效 `tag_note` 的书摘，分别请求全部时间与指定月份的 note-tag 图表。
- 实际结果：全部时间统计包含该关系，指定月份统计不包含，同一数据因范围形态不同得到不同计数。
- 风险：历史删除越多，全部时间标签分布偏差越大，并与书摘总数不一致。
- iOS 决策：`DesktopWebStatisticsRepository+Charts.swift` 保留两条查询的不对称并标记 `TODO(ANDROID-WEB-058)`；测试固定 all/range 分叉。

### ANDROID-WEB-059：月参数由宽松 Calendar 静默归一化但响应回显原值

- 关联接口：`WEB-API-132 GET /api/v1/statistics/monthly-reading`。
- 证据：`StatisticsController.kt:21-31` 只处理 0 默认值；`DateUtil.kt:589-605` 与 `StatisticsWebService.kt:561-594` 使用默认 lenient 的 `Calendar.set(year, month-1, ...)`，未限制 1...12，同时 DTO 仍回显请求的 year/month。
- App 参考：App 的统计月份来自受控年月选择器，不接受任意整数月份。
- 可复现输入：请求 `year=2026&month=13`。
- 实际结果：数据库范围实际变为 2027 年 1 月，响应却显示 `year=2026,month=13,label=2026年13月`。
- 风险：响应元数据与所统计的真实自然月分叉，缓存或导出会把数据归到错误月份。
- iOS 决策：`DesktopWebStatisticsRepository.monthlyReading` 原样宽松归一化并标记 `TODO(ANDROID-WEB-059)`；边界测试锁定 month=13。

### ANDROID-WEB-060：历史周的“当前连续阅读”仍锚定真实今天

- 关联接口：`WEB-API-133 GET /api/v1/statistics/weekly-reading`。
- 证据：`StatisticsWebService.kt:597-663` 用请求周生成查询终点，却在 620、648-653 行从 `LocalDate.now()` 向前检查 activeDates；历史周的 activeDates 不含今天时通常立即得到 0。
- App 参考：App 首页的连续阅读是面向当前时刻的全局指标；历史周图表若展示 streak，应以所选周终点解释，不能混用两个时间锚点。
- 可复现输入：选择一个每天都有阅读、但早于当前周的历史周。
- 实际结果：七天数据均为已阅读，`currentStreak` 仍为 0。
- 风险：字段名称和筛选范围暗示周内连续天数，但返回与所选周无关的当前快照。
- iOS 决策：`DesktopWebStatisticsRepository.weeklyReading` 保留今天锚点并标记 `TODO(ANDROID-WEB-060)`；测试覆盖历史周语义。

### ANDROID-WEB-061：读取每日目标会创建数据库记录

- 关联接口：`WEB-API-143 GET /api/v1/statistics/daily-reading-target`。
- 证据：`StatisticsWebService.kt:508-558` 的 GET 调用 `ensureTodayReadingTimeTarget`，当日无记录时从 SharedPreferences 取默认值并直接插入 `read_target`。
- App 参考：`ReadTargetRepository.kt:82-101` 的 App 读取路径也有同类初始化副作用，这是现有业务设计而非纯查询。
- 可复现输入：清空当天 type=READING_TIME 目标后连续调用 GET。
- 实际结果：第一次 GET 新增一行；后续 GET 读取该行，数据库状态因只读 HTTP 请求变化。
- 风险：预取、探活和重试都会写库，破坏 GET 幂等假设，也会影响备份差异。
- iOS 决策：`DesktopWebStatisticsRepository.dailyReadingTarget` 原样插入并标记 `TODO(ANDROID-WEB-061)`；测试同时断言响应和新增行。

### ANDROID-WEB-062：年度目标写入不校验年份和目标范围

- 关联接口：`WEB-API-140 PUT /api/v1/statistics/read-target`。
- 证据：`StatisticsWebService.kt:451-466` 直接按请求 year/target 查询并插入或更新，没有像年度庆祝接口那样校验 year，也没有限制 target 非负。
- App 参考：`ReadingPresenter.kt:135-155` 的 App 输入来自目标设置 UI，不会正常生成负数或无效年份。
- 可复现输入：提交 `{"year":-1,"target":-2}`。
- 实际结果：接口成功并在 `read_target` 中持久化负年份、负目标。
- 风险：年度范围、完成率和后续图表可能被异常目标污染。
- iOS 决策：`DesktopWebStatisticsRepository.setReadTarget` 保留无校验写入并标记 `TODO(ANDROID-WEB-062)`；测试锁定负值成功合同。

### ANDROID-WEB-063：范围状态分布按当前书籍快照而非历史状态计算

- 关联接口：`WEB-API-136 GET /api/v1/statistics/overview`。
- 证据：`StatisticsWebService.kt:277-304` 调用 `getBookStatusPieChartDataSuspend`；`StatisticsRepository.kt:1362-1396` 在范围模式按 `book.read_status_changed_date` 筛选后读取书籍当前 `read_status_id`，不从 `book_read_status_record` 还原该时间段的事件状态。
- App 参考：App 当前状态饼图使用同一 Repository，因此共享此实现；但 Web overview 的 year/month/week 参数会让客户端合理期待历史切片。
- 可复现输入：书籍在所选月份读完，之后改为搁置，再查询该月份 overview。
- 实际结果：该月份状态分布显示“搁置”，而不是当月发生的“读完”。
- 风险：历史报表会随今天的再次改状态而回写式变化，无法作为稳定时间序列。
- iOS 决策：`DesktopWebStatisticsRepository+Overview.swift` 按当前快照复刻并标记 `TODO(ANDROID-WEB-063)`。

### ANDROID-WEB-064：概览完读字数经过显示文本往返后丢失精度

- 关联接口：`WEB-API-136 GET /api/v1/statistics/overview`。
- 证据：`StatisticsRepository.kt:1817-1854` 先将总字数格式化为一位小数的“万字/千字”文本；`StatisticsWebService.kt:210-211,1098-1104` 再解析该文本为 Long。
- App 参考：App 只展示格式化文本，不需要把显示值还原为精确业务数；Web DTO 却声明 `totalWordCount` 为数值。
- 可复现输入：完读书籍字数合计 12,345。
- 实际结果：overview 返回 12,000，而不是 12,345。
- 风险：数值 API 永久损失最多约 500 字精度，且与 word-count 图表原始合计不一致。
- iOS 决策：`DesktopWebStatisticsRepository+Overview.swift` 保留格式化再反解析并标记 `TODO(ANDROID-WEB-064)`；测试固定 12,345→12,000。

### ANDROID-WEB-065：图表桶由首尾是否同月决定，周范围输出整月或全年空桶

- 关联接口：`WEB-API-145` 至 `WEB-API-151`。
- 证据：`StatisticsRepository.kt:974-1078,1094-1184,1207-1347,1866-1981` 仅用 `startMonth == endMonth` 选择日桶，否则选择月桶；同月周初始化整月所有日期，跨月周初始化全年 1...12 月，未按请求周的 7 天构桶。
- App 参考：App 统计图表复用这些 Repository 方法，但界面筛选维度与 Web 的显式 weekStart 合同不同。
- 可复现输入：分别选择同月内一周和跨月一周请求任一图表接口。
- 实际结果：同月周返回 28~31 个日桶；跨月周返回 12 个月桶，绝大多数与请求范围无关且为 0。
- 风险：客户端无法根据 weekStart 得到稳定七日序列，单位也会在周边界突然从“日”变为“月”。
- iOS 决策：`DesktopWebStatisticsRepository+Charts.swift` 保留桶形并标记 `TODO(ANDROID-WEB-065)`；图表测试锁定两类外形。

### ANDROID-WEB-066：周范围与阅读节律用固定 24 小时推进自然日

- 关联接口：`WEB-API-133`、`WEB-API-134`。
- 证据：`StatisticsWebService.kt:609,641` 以 `24*3600*1000` 计算周日和 streak 起点；`StatisticsWebService.kt:735-796` 的节律分段同样用固定 dayMillis 推进本地日。
- App 参考：App 当前默认中国时区没有 DST，因此日常路径不暴露；在支持夏令时的系统时区中，本地自然日可能为 23 或 25 小时。
- 可复现输入：将系统时区设为存在 DST 的区域，并让范围跨越切换日。
- 实际结果：周终点或节律时段相对本地午夜偏移一小时，记录可能落入错误日/时段。
- 风险：设备时区变化后产生不可见的统计边界差异。
- iOS 决策：为匹配冻结 Android，`DesktopWebStatisticsRepository.swift` 保留固定毫秒推进并标记 `TODO(ANDROID-WEB-066)`；本任务不修正 Android。

### ANDROID-WEB-067：已删除打卡仍扩张热力图起点和年份范围

- 关联接口：`WEB-API-135 GET /api/v1/statistics/heatmap`。
- 证据：`CheckInRecordDao.kt:75-79` 的最早打卡查询没有 `is_deleted=0`，而 81-82 行的实际打卡数据查询会过滤删除；`StatisticsRepository.kt:365-369,1404-1458` 分别把该最早值用于热力图起点和 yearRange。
- App 参考：热力图实际点位只消费有效打卡，删除记录不应继续作为可见统计范围的 owner。
- 可复现输入：只保留一条 2025 年已软删除打卡，其余有效数据均在 2026 年。
- 实际结果：响应从 2025 年开始且 yearRange 包含 2025，但该日期打卡热度为 0。
- 风险：删除旧数据后仍产生大段空年份，响应体和前端渲染成本持续增大。
- iOS 决策：`DesktopWebStatisticsRepository+Heatmap.swift` 原样保留起点泄漏并标记 `TODO(ANDROID-WEB-067)`；测试锁定“扩范围但不贡献热度”。

### ANDROID-WEB-068：热力图响应依赖未进入数据库备份的设备私有偏好

- 关联接口：`WEB-API-135 GET /api/v1/statistics/heatmap`。
- 证据：`StatisticsRepository.kt:385,425,473,513,560,605` 仅在 `SpSettingHelper.getHeatChartReadingStatusMarkVisibility()` 为 true 时填充 bookStates；`SpSettingHelper.kt:2187-2196` 将该值保存在 SharedPreferences，默认 true。
- App 参考：`HeatChartSettingActivity.kt:248,329,384` 允许用户独立修改这个设备偏好；它不属于 V44 数据库备份。
- 可复现输入：两台设备恢复同一数据库，一台关闭“阅读状态标记”，另一台保持默认，再请求同一年度热力图。
- 实际结果：除 bookStates 外数据一致，但关闭偏好的设备始终返回全 false。
- 风险：仅同步数据库无法形成双端一致性前提，设备设置会制造隐式合同差异。
- iOS 决策：按 Pixel 4 实际运行时已冻结的 true 输出，并在 `DesktopWebStatisticsRepository+Heatmap.swift` 标记 `TODO(ANDROID-WEB-068)`；该非数据库偏好已纳入 43 / 43 统计接口对比证据。

### ANDROID-WEB-069：年度热力图遗漏最后一秒内的 999 毫秒

- 关联接口：`WEB-API-135 GET /api/v1/statistics/heatmap`。
- 证据：`StatisticsRepository.kt:399-407,484-492,573-588` 使用 `SimpleDateFormat` 解析 `${year}-12-31 23:59:59` 作为闭区间终点，毫秒固定为 000。
- App 参考：数据库时间字段以毫秒存储；其他年度范围通常通过 `DateUtil.getEndTimeMillisecondsOfYear` 结束于 23:59:59.999。
- 可复现输入：在 12 月 31 日 23:59:59.500 写入有效书摘、打卡或状态记录，再请求该年度热力图。
- 实际结果：记录被年度查询排除，下一年度也不会包含，形成 999ms 数据盲区。
- 风险：低概率但确定性丢失年度边界事件。
- iOS 决策：`DesktopWebStatisticsRepository+Heatmap.swift` 将终点收缩到 23:59:59.000 并标记 `TODO(ANDROID-WEB-069)`；边界测试锁定遗漏行为。

### ANDROID-WEB-090：普通年度统计范围继承请求时刻的毫秒字段

- 影响接口：年度维度的阅读节律、统计概览及七类统计图表，以及上一年度环比范围。
- 证据：`DateUtil.getStartTimeMillisecondsOfYear/getEndTimeMillisecondsOfYear` 通过 `Calendar.set(year, month, day, hour, minute, second)` 设置字段，但没有清零 `Calendar.MILLISECOND`；`StatisticsWebService.getTimeRange` 和年度环比直接消费这两个边界。
- App 参考：月范围 helper 会显式设置起点 `MILLISECOND=0`、终点 `MILLISECOND=999`，证明年度 helper 的残留毫秒不是业务设计。
- 可复现输入：在某年 1 月 1 日 00:00:00.000 放置一条完成阅读记录，再在当前时刻毫秒部分非 0 时请求该年度统计。
- 实际结果：年初记录通常被排除；年末 23:59:59 内可包含的毫秒区间还会随请求时刻变化。同一数据库的年度结果因此可能随调用毫秒发生边界抖动。
- 风险：年度总阅读时长、首月趋势和年度环比可能遗漏边界记录，而且响应不是严格确定性的。
- iOS 决策：为冻结 Pixel 4 当前可观察合同，`DesktopWebStatisticsRepository.yearRange` 同样保留当前毫秒余数并标记 `TODO(ANDROID-WEB-090)`；测试锁定年初/年末边界，本任务不修改 Android。

### ANDROID-WEB-091：AndServer 查询参数绑定泄露解析文本，并按首键异常拼接重复值

- 影响接口：`WEB-API-032 GET /api/v1/calendar/month`、`WEB-API-033 GET /api/v1/calendar/day`、`WEB-API-055 GET /api/v1/groups`、`WEB-API-056 GET /api/v1/groups/{id}/books`、`WEB-API-084 GET /api/v1/books/{bookId}/reading-records`、`WEB-API-152 GET /api/v1/tags`。
- 证据：生成的 Controller Handler 都通过 `StandardRequest.getParameter` 取值；AndServer 2.1.11 的 `Uri.parametersToQuery` 在重新序列化第一个参数名的多个值时漏写 `&`，因此只有“请求中第一个有效参数名”的重复值会被拼成 `1page=2` 或 `namesortBy=custom`，后续参数名则由 `getFirst` 取第一个值。数字绑定失败继续向外暴露原始 Java `For input string` 文本。
- App 参考：App 的 `ReadCalendarRepository` 和 `TagRepository.queryTags` 接收内部已类型化的时间戳或标签类型，不暴露 URL 参数解析，也不存在重复键合同。
- 可复现输入：请求 `type=2147483648`、`month=9223372036854775808`、未转义的 `+1`、同名键 `page=1&page=2`，以及交换 Group 或 ReadingRecord 的 `sortBy/sortOrder` 与重复排序参数的出现顺序；先传无值键再传有效值时，无值键会被忽略。
- 实际结果：客户端收到 Java 实现细节；重复参数的结果依赖该参数名是否为请求中的首个有效键，同一组 `sortBy/sortOrder` 仅改变查询顺序就可能改变最终排序。
- 风险：查询参数合同依赖 AndServer 内部解析细节，错误文本不稳定且会泄露服务端技术实现。
- iOS 决策：`DesktopWebAndroidFormQuery` 统一复刻 Int32/Int64/String、表单加号、百分号解码、空值、无值键和首键重复值缺陷，供 Tag、Calendar、Group 与 ReadingRecord 路由共用；Package 边界测试、Tag 16 / 16、Calendar 32 / 32、Group 78 / 78 与 ReadingRecord 36 / 36 双端运行用例锁定当前合同，本任务不修改 Android。

### ANDROID-WEB-092：月历从原始请求日期开始生成日期，可能跨入下个月

- 影响接口：`WEB-API-032 GET /api/v1/calendar/month`。
- 证据：`ReadCalendarRepository.getDaysOfMonth` 会先用 `DateUtil.getStartTimeMillisecondsOfMonth/getEndTimeMillisecondsOfMonth` 生成自然月事件查询范围，但随后把 `Calendar.timeInMillis` 重新设为未经归一化的原始 `monthStartMillis`，并从该日期连续循环当月天数；传入月中日期时不会把游标重置到 1 日。Java `Calendar.add(DAY_OF_MONTH, 1)` 在 `Long.MAX_VALUE` 后还会回绕到负时间戳。
- App 参考：`ReadCalendarComposeViewModel` 从已归一化的选中月份/月首时间调用 Repository，因此正常 App 页面不会传入任意月中日期；Web Controller 则公开接受任意 `Long`，暴露了底层前提。
- 可复现输入：请求 `month` 为 2024-07-03 的毫秒值，或分别传 `Long.MAX_VALUE`、`Long.MIN_VALUE`。
- 实际结果：响应顶部仍声明 2024 年 7 月、`daysInMonth=31`，但 `days` 实际覆盖 7 月 3 日至 8 月 2 日；后两日的 `readDoneBookCount` 也会按跨月日期查询。极端最大值的第二个日期会回绕到最小时间戳一侧。
- 风险：客户端提交非月首时间戳时会隐藏月初数据、混入下月数据，并产生标题与明细自相矛盾的响应；极端输入还带来跨时间轴回绕。
- iOS 决策：`DesktopWebCalendarRepository` 保留“自然月事件查询 + 原始日期游标”的不一致语义，并实现 Java GregorianCalendar 的极端时间戳回绕兼容，标记 `TODO(ANDROID-WEB-092)`；Repository 边界测试与 32 / 32 双端 HTTP 用例固定当前合同，本任务不修改 Android。

### ANDROID-WEB-093：组 ID 为 0 时路径参数退化为“不筛选”，返回全部有效书籍

- 影响接口：`WEB-API-056 GET /api/v1/groups/{id}/books`。
- 证据：`BookService.kt:460-473` 把路径 `groupId` 原样写入 `WebBookRepository.BookFilter`；`WebBookRepository.kt:447-454` 仅在 `filter.groupId != 0L` 时添加 `group_book` 条件。Controller 与 Service 都没有先验证分组存在性，因此路径中的 0 触发了列表筛选器的内部哨兵语义。
- App 参考：`GroupBooksViewModel.kt:123-151` 从用户已打开的真实分组模型加载组内书籍，不会把 0 当作可导航分组 ID；App 的“全部书籍”另有明确书架入口。
- 可复现输入：请求 `/api/v1/groups/0/books`，并与 `/api/v1/groups/999999999/books` 对比。
- 实际结果：不存在的普通分组返回空页，而 ID 0 返回数据库中全部有效、非零 ID 书籍；冻结 V44 数据中实测为 381 本。
- 风险：一个语义为“组内资源”的路径会意外暴露全书架数据，权限、缓存和客户端空状态判断都可能被绕过。
- iOS 决策：`DesktopWebGroupRepository.baseBooks(inGroup:)` 保留 ID 0 的全量查询并标记 `TODO(ANDROID-WEB-093)`；Repository 边界测试和 Group 78 / 78 双端运行用例固定当前异常基线，本任务不修改 Android。

### ANDROID-WEB-070：封面代理的 DNS 校验与真实连接之间存在重绑定窗口

- 关联接口：`WEB-API-024 GET /api/v1/book-covers/proxy/{bookId}`。
- 证据：`BookCoverProxyService.kt:419-453` 先用 `InetAddress.getAllByName` 校验目标地址，`337` 行随后由 OkHttp 独立解析并连接；校验结果没有固定到实际 socket。
- App 参考：App 的封面加载由 Coil/OkHttp 直接消费受信数据，不向局域网客户端开放任意可控 URL 的服务端代理边界。
- 可复现输入：让受攻击域名在校验时解析到公网地址，在 OkHttp 建连时切换到回环或局域网地址。
- 实际结果：第二次 DNS 解析可能绕过第一次私网地址拦截。
- 风险：形成 SSRF 的 DNS rebinding 时间检查/使用分离窗口。
- iOS 决策：为保持当前合同继续校验每次跳转，但在 `DesktopWebBookCoverService.download` 标记 `TODO(ANDROID-WEB-070)`；本任务不把 Android 安全缺陷扩展为新业务语义。

### ANDROID-WEB-071：封面过大错误被 Controller 折叠为 502

- 关联接口：`WEB-API-024 GET /api/v1/book-covers/proxy/{bookId}`。
- 证据：`BookCoverProxyService.kt:385-398` 抛出内部状态 413；`BookCoverController.kt:45-51` 只映射 403、404、415，其余全部返回 502。
- App 参考：App 图片加载失败通过图片管线状态反馈，不存在 HTTP 状态码映射。
- 可复现输入：让远端封面响应有效图片类型，但 `Content-Length` 或实际字节超过代理上限。
- 实际结果：客户端收到 HTTP 502，而不是服务层已经识别的 413。
- 风险：客户端无法区分“资源过大”和“上游网关失败”，重试策略会失真。
- iOS 决策：Package 路由保留可观察的 502 映射并在 `DesktopWebExternalBookRoutes` 标记 `TODO(ANDROID-WEB-071)`。

### ANDROID-WEB-072：同一导入任务可被并发提交两次

- 关联接口：`WEB-API-065 POST /api/v1/import/tasks/{taskId}/commit`。
- 证据：`ImportTaskService.kt:95-105` 只在写库前锁定并检查状态；`123-125` 的数据库导入在锁外执行；`136-141` 完成后才再次锁定写成 `COMMITTED`。
- App 参考：App 导入由单一前台流程驱动，`NoteRepository.importNotesToDbSuspend` 本身不负责 Web 任务幂等。
- 可复现输入：对同一个 `SUCCEEDED` taskId 同时发送两次 commit。
- 实际结果：两个请求都能通过初始检查并分别执行导入，最后都写成已提交。
- 风险：重复创建书籍、书摘和阅读记录，且响应看似均成功。
- iOS 决策：按合同保留 actor 可重入行为并在 `DesktopWebImportService` 标记 `TODO(ANDROID-WEB-072)`；测试只在隔离数据库覆盖，生产仍由会员只读门禁保护。

### ANDROID-WEB-073：ZIP 解压缺少路径穿越和总量限制

- 关联接口：`WEB-API-063 POST /api/v1/import/tasks`。
- 证据：`ZipHelper.kt:65-87` 直接使用 `File(destDir + separator + entryName)` 写入条目，没有 canonical path 校验、条目数限制或解压后总字节限制；`ImportTaskService.kt:225-248` 对上传 ZIP 直接调用该 helper。
- App 参考：App 导入同样复用文件解析能力，但不是局域网 HTTP 上传攻击面。
- 可复现输入：上传包含 `../outside`、绝对路径或高压缩比巨量条目的 ZIP。
- 实际结果：条目可逃出目标目录，或持续消耗磁盘/内存直至失败。
- 风险：形成 Zip Slip 与压缩炸弹攻击面。
- iOS 决策：`DesktopWebImportService.validateArchiveBeforeTaskCreation` 不复制任意路径落盘行为，并标记 `TODO(ANDROID-WEB-073)`；这是安全边界，不影响合法文件响应合同。

### ANDROID-WEB-074：上传全局锁覆盖远端网络请求

- 关联接口：`WEB-API-157` 至 `WEB-API-160`。
- 证据：`NoteImageUploadRiskControlService.kt:250-269` 的 `withStore` 使用单一 `synchronized(lock)`；`87-139` 在该闭包内校验并等待 COS 上传，清理路径也可在锁内请求远端删除。
- App 参考：App 的 `RxCosHelper` 上传不会持有覆盖所有用户操作的 Web 风控全局锁。
- 可复现输入：让一次 COS 上传或删除长时间阻塞，同时请求预留、释放或上传封面。
- 实际结果：全部上传相关接口串行等待该网络请求。
- 风险：单个慢请求会放大为整个网页图片能力的阻塞和超时。
- iOS 决策：`DesktopWebUploadService` 只在状态读写阶段持有 actor 隔离，网络在锁外执行，并标记 `TODO(ANDROID-WEB-074)`；不复制不可观测的内部阻塞实现。

### ANDROID-WEB-075：过期票据和远端清理只由后续请求驱动

- 关联接口：`WEB-API-157` 至 `WEB-API-160`。
- 证据：`NoteImageUploadRiskControlService.kt:45-46,97-98,146-147,243-245` 只在上传相关入口调用 `cleanupStore`；没有定时器或进程启动恢复调度。
- App 参考：App COS 上传没有这套 Web 票据生命周期。
- 可复现输入：上传一张图片后不提交，随后不再调用任何上传接口。
- 实际结果：票据虽然逻辑过期，但远端对象和持久化记录会一直保留到下一次相关请求。
- 风险：长期不使用网页上传时，孤儿对象与状态存储无法及时收敛。
- iOS 决策：当前同样按请求触发清理，并在 `DesktopWebUploadService.drainCleanupTasks` 标记 `TODO(ANDROID-WEB-075)`。

### ANDROID-WEB-076：上传接口的“凭证已过期”专用分支不可达

- 关联接口：`WEB-API-158 POST /api/v1/note-images/upload`。
- 证据：`NoteImageUploadRiskControlService.kt:97-113` 先执行 `cleanupStore`，它在 `272-280` 将到期票据迁为终态；随后 `requireTicket` 会先因状态不再是 reserved 抛出通用“已失效”，`107-113` 的专用过期提示无法到达。
- App 参考：App 直接上传图片，不暴露票据过期文案。
- 可复现输入：预留票据，等待 TTL 过期后调用上传。
- 实际结果：返回通用失效错误，而不是代码中声明的“上传凭证已过期，请重新选择图片”。
- 风险：死分支掩盖真实状态机顺序，维护者可能错误依赖专用错误合同。
- iOS 决策：保留通用失效响应并在 `DesktopWebUploadService.requireTicket` 标记 `TODO(ANDROID-WEB-076)`；边界测试锁定实际可观察结果。

### ANDROID-WEB-077：非 PNG 图片仍使用 `.png` 对象键

- 关联接口：`WEB-API-158`、`WEB-API-160`。
- 证据：`ImageValidationService` 接受 JPEG、PNG、GIF、WebP；`CosHelper.java:83-88` 却统一拼接 `AppConstant.IMG_SUFFIX`，冻结版本该后缀为 `png`。
- App 参考：App 也复用 `RxCosHelper`，因此共享扩展名与实际内容不一致的历史行为。
- 可复现输入：上传合法 JPEG、GIF 或 WebP。
- 实际结果：COS URL 以 `.png` 结尾，实际字节和检测 MIME 仍是原格式。
- 风险：依赖扩展名的 CDN、下载器或内容审计会误判格式。
- iOS 决策：iOS 使用检测到的真实扩展名，不复制存储格式错误，并在 `DesktopWebUploadService.writeTemporary` 标记 `TODO(ANDROID-WEB-077)`；双端对比对随机对象键按合同归一化。

### ANDROID-WEB-078：票据存储损坏时静默清空全部状态

- 关联接口：`WEB-API-157` 至 `WEB-API-159`。
- 证据：`NoteImageUploadTicketStore.kt:65-71` 对任何 Gson 解析失败直接返回空 store，没有备份、告警或恢复 cleanupTasks。
- App 参考：App 没有持久化 Web 票据状态。
- 可复现输入：将 SharedPreferences 中票据 JSON 截断后调用任一票据接口。
- 实际结果：全部票据、限流记录和待清理对象索引消失，接口从空状态继续运行。
- 风险：已上传但未提交的远端对象失去清理索引，且额度/限流状态被重置。
- iOS 决策：按基线从空 store 恢复，并在 `DesktopWebUploadService.loadStore` 标记 `TODO(ANDROID-WEB-078)`。

### ANDROID-WEB-079：远端上传成功与票据持久化之间存在孤儿对象窗口

- 关联接口：`WEB-API-158`、`WEB-API-160`。
- 证据：`NoteImageUploadRiskControlService.kt:116-135` 先完成远端上传，再更新内存票据；直到 `withStore` 返回后的 `263` 行才异步 `SharedPreferences.apply()` 持久化。
- App 参考：App 直接上传同样可能产生未引用对象，但没有承诺 Web 票据清理状态机。
- 可复现输入：COS 返回成功后、票据 JSON 写入磁盘前终止进程。
- 实际结果：远端对象已存在，本地却没有 objectKey 或 cleanup task。
- 风险：对象永久泄漏且无法由后续请求自动发现。
- iOS 决策：保留远端成功后提交本地状态的必要顺序，并在 `DesktopWebUploadService` 标记 `TODO(ANDROID-WEB-079)`；失败补偿测试覆盖可恢复路径，进程强杀窗口单独记录。

### ANDROID-WEB-080：待清理任务没有冻结原上传 COS 配置

- 关联接口：`WEB-API-157` 至 `WEB-API-160`。
- 证据：`NoteImageUploadTicketStore.kt:48-60` 的 cleanup task 只保存 ticketId 与 objectKey；`NoteImageCleanupCoordinator.kt:43-89` 删除时重新读取当前 COS 配置。
- App 参考：`CosConfigPresenter` 允许用户切换自定义 COS，上传后配置并非恒定。
- 可复现输入：使用 COS A 上传并生成待清理任务，切换到 COS B 后触发清理。
- 实际结果：删除会向 COS B 发送 COS A 的 objectKey，通常失败，也可能误删同名对象。
- 风险：跨配置误操作与孤儿对象并存。
- iOS 决策：当前数据形状继续只保存 objectKey，并在 `DesktopWebUploadService.CleanupTask` 标记 `TODO(ANDROID-WEB-080)`；生产写入保持禁用。

### ANDROID-WEB-081：AI 关闭开关不约束透明代理入口

- 关联接口：`WEB-API-003 POST /api/v1/ai/chat/completions`。
- 证据：`AIController.kt:132-151` 只读取 provider 和 API Key，不调用 `getLLMIsEnable()`；同文件配置 GET 会返回该开关。
- App 参考：`App.kt:225-246` 与 `PersonalContainerFragment.kt:396` 会先检查开关，再暴露或初始化 AI 能力。
- 可复现输入：把 `isEnabled` 设为 false，但保留有效 API Key，随后直接调用代理接口。
- 实际结果：请求仍会被转发到上游并消耗额度。
- 风险：UI 表达“关闭”但服务端能力仍开启，局域网客户端可绕过 App 功能门禁。
- iOS 决策：按 Android 可观察行为不检查开关，并在 `DesktopWebAIService.chatCompletions` 标记 `TODO(ANDROID-WEB-081)`。

### ANDROID-WEB-082：SSE 代理错误文案转义不完整

- 关联接口：`WEB-API-003 POST /api/v1/ai/chat/completions`。
- 证据：`AIController.kt:198-203` 只把双引号替换为 `\\\"`，没有转义反斜杠、换行或控制字符，随后直接拼入 SSE JSON。
- App 参考：App 的 LLM Client 直接解析上游响应，不手工拼接这段 Web SSE 错误 JSON。
- 可复现输入：让流读取异常的 message 包含反斜杠或换行。
- 实际结果：生成的 `data:` 事件可能不是合法 JSON，换行还会破坏 SSE 事件边界。
- 风险：前端无法稳定解析代理错误，可能表现为流无故中断。
- iOS 决策：暂按冻结实现只转义双引号，并在 `DesktopWebAIService` 标记 `TODO(ANDROID-WEB-082)`。

### ANDROID-WEB-083：本地导出任务目录没有回收

- 关联接口：`WEB-API-053 POST /api/v1/export/notes/local`。
- 证据：`NoteExportWebService.kt:833-846` 每次在 cache 下创建 `web-note-export/task_*`；`ExportController.kt:45-63` 仅以 `FileInputStream` 返回文件，没有完成回调或 finally 删除，生成中途失败也没有清理 taskDir。
- App 参考：App 导出由界面流程持有目标 Uri/缓存生命周期，不复用该 Web task 目录。
- 可复现输入：连续执行本地导出，或在多个文件生成过程中制造一次失败。
- 实际结果：每次任务的单文件、ZIP 与中间文件持续留在缓存目录。
- 风险：长期使用网页导出会无界增长缓存占用。
- iOS 决策：`DesktopWebExportService.exportNotesLocally` 直接返回内存 Data，不复制泄漏，并标记 `TODO(ANDROID-WEB-083)`。

### ANDROID-WEB-084：导入制品只在后续请求中清理，任务登记前失败会永久遗漏

- 关联接口：`WEB-API-063` 至 `WEB-API-066`。
- 证据：`ImportTaskService.kt:60,86,92,156` 只在导入 API 入口调用 `cleanupExpiredTasks`；`508-528` 没有调度器。`225-248` 可先创建并解压目录，若随后校验/解析在任务放入 map 前失败，该目录也没有 owner 可供清理。
- App 参考：App 导入文件由单一页面流程管理，不依赖 Web task map 的 TTL。
- 可复现输入：上传能解压但解析失败的 ZIP，或创建成功后 30 分钟内不再调用任何导入接口。
- 实际结果：失败制品或过期任务目录保留到未来某次请求；任务登记前失败的目录不会被 map 清理发现。
- 风险：无界缓存增长，并可能长期保留用户导入原文。
- iOS 决策：iOS 任务以内存 Data 持有，不复制磁盘泄漏，并在 `DesktopWebImportService.cleanupExpiredTasks` 标记 `TODO(ANDROID-WEB-084)`。

### ANDROID-WEB-094：正式 APK 与同源码测试包的业务错误 Content-Type 不一致

- 关联接口：`WEB-API-064 GET /api/v1/import/tasks/{taskId}`、`WEB-API-157 POST /api/v1/note-images/upload-tickets`、`WEB-API-158 POST /api/v1/note-images/upload`，并可能影响同一 Upload Controller 的其他业务异常。
- 证据：正式 Pixel 4 Android 5.6.0 APK 查询不存在或已删除的导入任务、拒绝超过 20 张的票据预留、拒绝已释放票据上传时均返回业务错误 JSON，但响应不包含 `Content-Type`；保留相同 Controller、Service 和 DTO 的独立 application ID 测试包对相同错误返回 `Content-Type: application/json;charset=UTF-8`。两者的 HTTP 状态、响应体和其他合同字段一致，差异位于构建产物或运行时响应适配层。
- App 参考：App 导入流程直接观察 Presenter/Repository 状态，不暴露 HTTP Header，因此没有可对照的 App 行为。
- 可复现输入：分别向正式 APK 与同源码测试包请求一个不存在的 taskId，或预留并释放图片票据后再上传、请求预留 21 张图片。
- 实际结果：相同源码路径在两个 Android 构建产物中产生不同的错误响应 Header；若只使用测试包收敛，会把正式 APK 不存在的 Header 错误写入 iOS 合同。
- 风险：测试替身不能完整代表被冻结的正式 APK，客户端对错误响应媒体类型的判断可能随构建产物变化。
- iOS 决策：以正式 APK 为最终合同，业务错误响应不补 `Content-Type`；测试包仅用于无法安全访问正式数据库的合法成功链路。`DesktopWebImportRoutes` 与 `DesktopWebUploadRoutes` 标记 `TODO(ANDROID-WEB-094)`，并由正式 APK 错误用例单独锁定 Header。

### ANDROID-WEB-095：在线搜书结果经共享 Book setter 丢失发布日期的“日”精度

- 关联接口：`WEB-API-013 GET /api/v1/books/search/online`。
- 证据：`OnlineSearchService.kt:38-52` 先经 `BookDtoMapper` 把文曲结果转换为 App `Book`，再读取 `book.pubDate` 生成 Web DTO；`BookDtoMapper.kt:21` 先把 RFC3339 截为 `yyyy-MM-dd`，但 `Book.kt:38-50` 的 `pubDate` setter 随后又用 `yyyy-MM-dd` 解析并固定格式化成 `yyyy-MM`。正式 APK 字节码与源码一致。
- App 参考：同一 `Book` setter 服务于 App 录入搜索，因此 App 也会把可解析的完整日期压缩到月份；源码已用 `FIXME` 标记该共享实现待优化。
- 可复现输入：文曲返回 `2018-11-20T00:00:00Z`，再调用在线搜书接口。
- 实际结果：Web 响应返回 `2018-11`；不可解析字符串保持原值。该行为与上游提供的日期精度不一致。
- 风险：网页端无法展示或保存上游已经提供的准确出版日，且转换原因隐藏在通用 App 模型 setter 中。
- iOS 决策：为保持正式 APK 合同，`DesktopWebOnlineBookService.androidDate` 仍压缩为 `yyyy-MM` 并标记 `TODO(ANDROID-WEB-095)`；不把这项 Android 异常扩散到 iOS App 的通用书籍模型。

## 待确认现象

- Android 8090 服务在部分 `curl` 请求中会在完整响应体之后出现 `Recv failure: Connection reset by peer`。当前仅作为传输层待复现现象，不认定为 API 业务问题，也不纳入 iOS 复刻合同。

## 已完成 Review 批次

### 设置与能力（7 / 7）

- 覆盖接口：`WEB-API-067`、`WEB-API-120` 至 `WEB-API-125`。
- Web 入口证据：`SettingsController.kt:24-74`、`NativeActionController.kt:14-18`。
- 真实 owner：网页设置、访问码和导出设置均由 `SpSettingHelper` 的 SharedPreferences 持有；会员状态由 `SpSecuritySettingHelper` 持有；本批接口不经过 Repository、DAO 或数据库。
- App 对照：录入偏好见 `BookEntryPreferenceSheet.kt:100-109,178-197`；访问码见 `DesktopClientViewModel.kt:111-161`；导出设置见 `NoteExportSettingActivity.kt:46-106` 与 `NoteExportPresenter.kt:80-94`；会员判断与升级入口见 `PremiumHelper.kt:54-83,128-139`、`PersonalContainerFragment.kt:440-445`、`VipUpgradeActivity.kt:404-408`。
- 结论：除 `ANDROID-WEB-002` 已记录的明文凭据外，本批未发现新的 Android 业务异常。iOS 已复刻默认值、局部 Patch、归一化、显式录入偏好重置、会员只读能力和原生升级动作结果；其中 `WEB-API-067` 的已开通高级版拒绝分支已由正式 Pixel 4 APK 与固定 iOS 模拟器验证为严格一致，其余设置接口的收敛证据见《API一致性基线》。

### 来源与标签（11 / 11）

- 覆盖接口：`WEB-API-126` 至 `WEB-API-131`、`WEB-API-152` 至 `WEB-API-156`。
- Web 入口证据：`SourceController.kt:22-66`、`SourceService.kt:18-129`、`WebSourceDao.kt:15-49`；`TagController.kt:23-63`、`TagService.kt:18-126`、`WebTagDao.kt:13-77`。
- 真实 owner：来源由 `WebSourceRepository/WebSourceDao` 直接读写 `source` 与关联 `book`；标签由 `WebTagRepository/WebTagDao` 直接读写 `tag`、`tag_note`、`tag_book`。二者都未复用 App Repository。
- App 对照：来源路径见 `SourceRepository.kt:27-117` 与 `BookSourceViewModel.kt:80-144`；标签路径见 `TagRepository.kt:43-163,206-209`。
- 结论：来源 6 条接口与 App 的名称判重、可见性、关联书籍回退及排序意图基本一致，Web 额外保护预置来源不被删除。标签 5 条接口确认存在 `ANDROID-WEB-004`、`ANDROID-WEB-005` 与查询参数异常 `ANDROID-WEB-091`，iOS 已原样复刻并用隔离数据库测试锁定；标签读取 16 / 16 HTTP 场景严格一致且数据库零变化，5 条接口运行态双端对比均已收敛为 `exact`。

### 分组（8 / 8）

- 覆盖接口：`WEB-API-055` 至 `WEB-API-062`。
- Web 入口证据：`GroupController.kt:27-108`、`GroupService.kt:18-139`、`BookService.kt:437-650,1162-1178`、`WebGroupDao.kt:11-42`、`WebBookDao.kt:514-526,675-727,766-787,890-953,982-992`。
- 真实 owner：分组列表和组内书籍由 `WebBookRepository/WebBookDao` 聚合；分组增删改、置顶和排序由 `WebGroupRepository/WebGroupDao` 直接写入；删除和组内书籍排序还会调用 `WebBookRepository`。Web 路径未复用 App `GroupRepository`。
- App 对照：分组列表与创建见 `GroupRepository.kt:32-49`；分组删除/迁出见 `GroupRepository.kt:101-169`；改名和排序见 `GroupRepository.kt:195-213`；带书籍的分组读取见 `GroupRepository.kt:217-245`；顶层混合置顶见 `BookRepository.kt:3504-3541`。
- 结论：已复刻分页、首关系计数、组内完整 `WebBookDto` 聚合、全部排序规则、名称处理、置顶、重排与删除副作用。两条读取接口覆盖默认/极值分页、路径边界、全部排序、重复查询键和 ID 0 哨兵共 78 个场景，HTTP 状态、合同 Header 与原始 JSON 响应为 78 / 78 严格一致；稳定态数据库增量比较为 39 张表、0 个变化单元、0 个不一致。确认存在 `ANDROID-WEB-003`、`ANDROID-WEB-006`、`ANDROID-WEB-007`、`ANDROID-WEB-011`、`ANDROID-WEB-015`、`ANDROID-WEB-055`、`ANDROID-WEB-091` 与 `ANDROID-WEB-093`；8 条接口运行态双端对比均已收敛为 `exact`。

### 书籍（20 / 20）

- 覆盖接口：`WEB-API-004` 至 `WEB-API-023`。
- Web 入口证据：`BookController.kt:31-249`、`BookService.kt:55-265,274-1363,1368-1980`、`WebBookRepository.kt:33-930,938-1220`、`WebBookDao.kt:150-373,436-447,540-787,888-1156`；单本与批量删除直接复用 `BookRepository.kt:803-847`。
- 真实 owner：读取、创建、更新、置顶、恢复书架及六类批量关系写入由 `BookService` 调用 `WebBookRepository/WebBookDao`；单本与批量删除调用 App `BookRepository` 的逐书 17 步事务。标签整批替换和迁入分组各自使用整批事务，批量更新、置顶与移出则保留独立提交边界。
- App 对照：创建/更新见 `BookRepository.kt:409-458,861-897`；书籍详情与全量聚合见 `BookRepository.kt:1095-1149,1773-1969`；最近书摘/最近阅读见 `BookRepository.kt:1506-1557` 与 `BookDao.kt:537-691`；书架与组内排序/分区见 `BookListFormatHelper.kt:24-412`、`SubBookListFormatHelper.kt:21-501`、`DefaultBookListViewModel.kt:106-305`、`GroupBooksViewModel.kt:123-290`；删除、恢复、标签、置顶与迁组分别见 `BookRepository.kt:803-847,1466-1503,3293-3353,3504-3560`、`GroupRepository.kt:71-95,140-168`。
- 结论：已复刻七条本地读取、在线搜索、创建/更新、17 步删除、置顶、恢复书架，以及批量删除、置顶、局部更新、标签 append/replace、精确替换、整批迁组和非事务移出。确认存在 `ANDROID-WEB-008` 至 `ANDROID-WEB-019` 与 `ANDROID-WEB-095`；分页、跨 owner 标签/分组、关联目标校验和混合置顶还分别命中既有问题。七条本地读取覆盖 108 个场景且数据库 0 变化；在线搜索覆盖正式文曲成功合同、fuzzywuzzy 排序和共享 Book setter 的月份截断；删除/恢复覆盖 5 个有效、幂等、缺失和重复场景，数据库比较为 39 张共有表、18 个变化单元、7 个归一化时钟单元与 0 个不一致；其余 10 条 DTO 写路由以合法载荷复现正式 APK 的 `ANDROID-WEB-087`，10 / 10 与 iOS 正式兼容层严格一致且 iOS 业务表 0 变化。20 条 Book 接口均已收敛为 `exact`。

### 书架混排（7 / 7）

- 覆盖接口：`WEB-API-025` 至 `WEB-API-031`。
- Web 入口证据：`BookshelfController.kt:21-134`、`BookshelfService.kt`、`WebBookRepository.kt` 与 `WebBookDao.kt` 的书架 manifest、混排展开、分组预览、批量查询和排序读写路径。
- 真实 owner：七条接口均由 `BookshelfService` 组织，数据通过 `WebBookRepository/WebBookDao` 读取或写入 `book`、`group` 与 `group_book`；未复用 App 的书架 ViewModel 或 Repository 排序入口。
- App 对照：顶层混排与排序见 `BookRepository.kt:694-751`；完整书籍聚合见 `BookRepository.kt:1095-1149,1773-1969`；书架与分组格式化见 `BookListFormatHelper.kt:24-412`、`SubBookListFormatHelper.kt:21-501`。
- 结论：已复刻 manual manifest、分页展开、排序视图、置顶分组元数据、按引用批量查询、相对移动及原始重排，包含默认参数、未知类型跳过、重复引用、缺失锚点回退与事务边界。确认存在 `ANDROID-WEB-020`、`ANDROID-WEB-021`，并命中既有分页及 book/group owner 隔离问题。四条读取接口覆盖分页、关键词、全部排序、布尔值、重复键、布局与 manifest 共 76 个场景，HTTP 状态、合同 Header 与原始 JSON 响应为 76 / 76 严格一致；双端同源数据库调用前后四份快照 SHA-256 完全相同，39 张表均为 0 个变化单元。三条 DTO 路由的正式 APK 故障由 `ANDROID-WEB-087` 冻结报告锁定；保留泛型签名的独立 Android 测试包与 iOS DEBUG 一致性进程补充验证成功语义，查询、移动、重排为 3 / 3 HTTP 严格一致，数据库比较覆盖 39 张共有表、719 个变化单元与 367 个归一化时钟单元，0 个不一致。`WEB-API-025...031` 均已收敛为 `exact`。

### 日历（2 / 2）

- 覆盖接口：`WEB-API-032`、`WEB-API-033`。
- Web 入口证据：`CalendarController.kt:14-30`、`CalendarWebService.kt`、`WebCalendarDto.kt`、`ReadCalendarRepository.kt:1153-1246,1757-1800,1834-2000`。
- 真实 owner：两条接口都由 `CalendarWebService` 组织，复用 App `ReadCalendarRepository` 聚合书摘、想法、回顾、精确/模糊阅读时长、已读和打卡事件；展示开关与每日书籍上限来自 `SpSettingHelper`。
- App 对照：日历数据聚合与连续事件布局见 `ReadCalendarRepository.kt` 和 `ReadCalendarComposeViewModel.kt`；Web 与 App 共享绝大多数查询，但 Web 没有调用 App 的连续事件处理路径。
- 结论：已复刻自然月全部日期、周一起始索引、事件来源顺序、单日书籍去重/上限、跨日时长切分、已读书籍补入和汇总规则，并按冻结运行时保留月中游标与极端时间戳回绕。确认存在 `ANDROID-WEB-022`、`ANDROID-WEB-023`、`ANDROID-WEB-091`、`ANDROID-WEB-092`；正常、闰年、纪元、月中跨月、Long 极值、缺失/空值/非法/重复/加号参数共 32 / 32 HTTP 场景严格一致，双端数据库比较为 39 张共有表、0 个变化单元，两条接口均已收敛为 `exact`。

### 章节与目录（17 / 17）

- 覆盖接口：`WEB-API-034` 至 `WEB-API-050`。
- Web 入口证据：`ChapterController.kt:31-188`、`ChapterService.kt:38-750`、`WebChapterRepository.kt`、`WebChapterDao.kt`、`ChapterTreeHelper.kt` 与 `OnlineSearchService.kt:14-108`。
- 真实 owner：章节树、收藏、增删改、排序、移动和目录导入由 `ChapterService` 组织，经 `WebChapterRepository/WebChapterDao` 读写 `chapter`，并通过 `WebNoteRepository` 维护书摘关联；在线候选与目录调用文曲外部服务。仅导入提交具有整棵目录事务，其余多步骤写入按 Repository 调用分别提交。
- App 对照：章节增删改、组织、移动及目录保存见 `ChapterRepository.kt`；章节管理入口见 `ChapterManagerViewModel.kt`、`ChapterListViewModel.kt`；远程目录选择见 `ChapterRemoteSyncSheetViewModel.kt`。
- 结论：已复刻树构建、孤儿根节点、路径与笔记计数、最后使用、收藏分组、增删改、排序/移动、批量创建、文曲候选排序与目录规范化，以及五层目录预览/提交。确认存在 `ANDROID-WEB-024` 至 `ANDROID-WEB-027`；本地 15 条接口的运行态证据沿用章节读写批次，在线候选与目录通过正式 APK 2 / 2、独立测试包 2 / 2 和 39 张共有表数据库零变化验证，17 条接口均已收敛为 `exact`。

### 书摘（15 / 15）

- 覆盖接口：`WEB-API-068` 至 `WEB-API-082`。
- Web 入口证据：`NoteController.kt:29-243`、`NoteService.kt:46-1157`、`WebNoteRepository.kt`、`WebNoteDao.kt`、`SortRepository.kt:24-160`。
- 真实 owner：书内/全局列表、标签筛选、详情和全部写入由 `NoteService` 组织，经 `WebNoteRepository/WebNoteDao` 访问 note、tag_note、attach_image；排序设置复用 App `SortRepository`；创建、更新和合并还通过 `WebBookRepository/WebChapterRepository` 维护进度与章节路径。除明确的事务块外，不复用 App `NoteRepository`。
- App 对照：创建/更新见 `NoteRepository.kt:1124-1225`；删除/合并见 `NoteRepository.kt:1233-1241,1396-1402,1797-1819`；移动书籍/章节见 `NoteRepository.kt:2040-2075`；批量标签见 `TagRepository.kt:294-324`；页面调用见 `NotesViewModel.kt:293-579` 与 `NotesMergePresenter.kt:152-271`。
- 结论：已复刻书内章节树排序、全局 SQLite LIKE/随机排除、筛选项统计、排序规则、详情、富文本规范化、阅读进度同步、软删除图谱、批量移动/标签/迁书和合并。确认存在 `ANDROID-WEB-028` 至 `ANDROID-WEB-035`，同时命中既有分页、book/tag owner 隔离问题；读取与写入的成功、失败、边界及数据库副作用证据均已收敛，对应 15 条接口全部为 `exact`。

### 书评（11 / 11）

- 覆盖接口：`WEB-API-107` 至 `WEB-API-117`。
- Web 入口证据：`ReviewController.kt:26-190`、`ReviewService.kt:28-235`、`ReviewDraftService.kt:11-86`、`WebReviewRepository.kt`、`WebReviewDraftRepository.kt`、`WebReviewDao.kt`。
- 真实 owner：全局/书内列表、详情和书评写入由 `ReviewService` 组织，经 `WebReviewRepository/WebReviewDao` 访问 review、review_image 与 book；排序设置复用 App `SortRepository`；草稿由 `WebReviewDraftRepository` 写入 `SpSettingHelper`，上传票据另由风险控制服务提交。
- App 对照：书评增删改查见 `ReviewRepository.kt:26-95`；草稿恢复、自动保存、删除及提交见 `ReviewEditPresenter.kt:51-182`；App 的书评数据库写入使用事务，而 Web 删除与草稿跨存储路径保留独立提交。
- 结论：已复刻全局/书内分页、随机排除、SQL 字数排序、排序规则、详情、富文本规范化、草稿、图片和软删除行为。确认存在 `ANDROID-WEB-036` 至 `ANDROID-WEB-042`，同时命中既有分页和 book owner 隔离问题；读取、草稿、排序与 CRUD 的成功、失败、边界及数据库副作用证据均已收敛，对应 11 条接口全部为 `exact`。

### 阅读计时与阅读记录（6 / 6）

- 覆盖接口：`WEB-API-083` 至 `WEB-API-088`。
- Web 入口证据：`ReadTimeController.kt:15-20`、`ReadTimeWebService.kt:13-48`、`ReadingRecordController.kt:21-71`、`ReadingRecordWebService.kt:18-302`。
- 真实 owner：计时完成由 `ReadTimingRepository` 写入 `read_time_record` 并按条件推进书籍位置；阅读记录列表、详情、创建、更新和删除由 `TimingRecordRepository` 与 `ReadTimeRecordDao` 读写，同步影响 `book.current_position` 与单位。Web 服务复用 App Repository，但自行定义外部请求校验与记录状态边界。
- App 对照：计时创建和完成见 `ReadTimingPresenter.kt:158-224`、`ReadTimingRepository.kt:40-99`；阅读记录加载、编辑、保存和删除见 `ReadTimeRecordPresenter.kt:54-214`。
- 结论：已复刻长时确认、原始计时字段保存、精确/模糊记录、列表排序、进度单位规范化、书籍位置推进、软删除及更新时戳。列表/详情的正常、空值、重复查询键、路径 Long 边界、未完成记录和不存在记录共 36 / 36 HTTP 场景严格一致，稳定态数据库比较为 39 张共有表、0 个变化单元、0 个不一致；删除成功、删除后不可见及重复删除的 4 / 4 串行场景严格一致，数据库 2 个变化单元中仅 1 个设备时钟字段按规则归一化，0 个遗漏或单边副作用。三个 DTO 写接口按冻结 APK 的 `ANDROID-WEB-087` 故障精确一致。确认存在 `ANDROID-WEB-043` 至 `ANDROID-WEB-046`、查询绑定问题 `ANDROID-WEB-091`，并继续命中 `ANDROID-WEB-008` 的书籍 owner 隔离问题；6 条接口运行态双端对比均已收敛为 `exact`。

### 相关内容与类别（18 / 18）

- 覆盖接口：`WEB-API-089` 至 `WEB-API-106`。
- Web 入口证据：`RelatedController.kt:30-290`、`RelatedService.kt:34-417`、`WebRelatedRepository.kt`、`WebRelevantRepository.kt`、`WebRelatedDao.kt:18-185`、`SortRepository.kt`。
- 真实 owner：类别、书内列表、详情和全部写入由 `RelatedService` 组织，经 `WebRelatedRepository/WebRelatedDao` 读写 category、category_content、category_image；全局列表由 `WebRelevantRepository` 动态查询；排序设置复用 App `SortRepository`。创建/更新事务只包主记录、图片与上传票据，删除和重排保留独立提交。
- App 对照：相关内容读写见 `RelevantRepository.kt`；类别管理与列表见 `CategoryManagerPresenter.kt`、`RelatedNoteCategoriesViewModel.kt`、`RelevantListViewModel.kt`；编辑/详情见 `RelevantEditPresenter.kt`、`RelevantViewPresenter.kt`。
- 结论：已复刻全局/书内类别、显示开关、排序、书内/全局内容、完整详情、富文本与图片、内容书、批量删除和迁类。确认存在 `ANDROID-WEB-047` 至 `ANDROID-WEB-054`，并继续命中 `ANDROID-WEB-008` 的 owner 隔离问题；读取与写入的成功、失败、边界及数据库副作用证据均已收敛，对应 18 条接口全部为 `exact`。

### 搜索（2 / 2）

- 覆盖接口：`WEB-API-118`、`WEB-API-119`。
- Web 入口证据：`SearchController.kt:15-43`、`SearchService.kt:15-185`、`WebBookRepository/WebBookDao`、`WebNoteRepository/WebNoteDao`、`WebReviewRepository/WebReviewDao`、`WebRelevantRepository/WebRelevantDao` 与 `WebRelatedDao`。
- 真实 owner：`SearchService` 分派四个 Web Repository；书籍域先读取全部书架并与相关内容书合并后手工分页，其他三域由各 DAO 直接分页；聚合接口严格按 book→note→relevant→review 顺序执行并逐域吞掉异常。
- App 对照：`SearchPresenter.kt:74-143` 通过 App 的 `BookRepository`、`NoteRepository`、`RelevantRepository`、`ReviewRepository` 搜索并用 `Maybe.zip` 合并；App 会拒绝空关键词，且不暴露 Web 分页或 `bookId/tagId` 参数。
- 结论：已复刻 type 校验、分页归一化、四域 DTO、SQLite LIKE、软删除关联差异、书籍混合来源去重、特殊书摘标签、逐域聚合降级。确认存在 `ANDROID-WEB-055` 至 `ANDROID-WEB-057`，并继续命中 `ANDROID-WEB-008` 与 `ANDROID-WEB-034`；单域与四域聚合的成功、失败、边界及数据库零副作用证据均已收敛，对应 2 条接口全部为 `exact`。

### 统计（20 / 20）

- 覆盖接口：`WEB-API-132` 至 `WEB-API-151`。
- Web 入口证据：`StatisticsController.kt:21-215`、`StatisticsWebService.kt:90-1105`、`StatisticsRepository.kt:65-1983`、`TimingRecordRepository.kt`、`ReadTargetDao`、`ReadTimeRecordDao`、`CheckInRecordDao`、`BookReadStatusRecordDao`、`BookDao`、`NoteDao`、`TagDao` 与 `SourceDao`。
- 真实 owner：月/周/节律由 `TimingRecordRepository` 聚合阅读记录；热力图、概览、年度书单和七类图表由 `StatisticsRepository` 组合多 DAO；年度/每日目标由 `read_target` 与 SharedPreferences 共同持有。Web Service 还承担范围解析、显示文本反解析、图表 DTO 和默认值。
- App 对照：统计首页见 `StatisticsViewModel.kt:16-94` 与 `StatisticsPresenter.kt:21-94`；每日/年度目标见 `ReadingPresenter.kt:45-155`、`ReadTargetRepository.kt:22-135`；热力图见 `HeatChartPresenter.kt:23-150` 与 `HeatChartFragment.kt:34-175`。
- 结论：已复刻精确记录跨日拆分、模糊记录归日、六段阅读节律、热力图、概览对比、年度书单、三类目标和七类图表。确认新增 `ANDROID-WEB-058` 至 `ANDROID-WEB-069`、`ANDROID-WEB-090`，同时命中既有书籍 owner 隔离问题。Pixel 4 的热力图非数据库偏好已经过实际运行冻结；20 个接口的 43 个读取/错误边界用例及 3 个冻结 APK DTO 写接口均已严格一致，数据库比较为零变化，运行态双端对比已收敛为 `exact`。

### AI、在线搜索、封面、导入导出与上传（17 / 17）

- 覆盖接口：`WEB-API-001` 至 `WEB-API-003`、`WEB-API-013`、`WEB-API-024`、`WEB-API-051` 至 `WEB-API-054`、`WEB-API-063` 至 `WEB-API-066`、`WEB-API-157` 至 `WEB-API-160`。
- Web 入口证据：`AIController.kt:43-291`、`BookController.kt:174-183`、`OnlineSearchService.kt:14-108`、`BookCoverController.kt:23-58`、`BookCoverProxyService.kt:33-636`、`ExportController.kt:23-79`、`NoteExportWebService.kt`、`ImportController.kt:22-61`、`ImportTaskService.kt:52-530`、`UploadController.kt:21-66`、`NoteImageUploadRiskControlService.kt`、`ImageService.kt`、`ImageValidationService.kt` 与 `NoteImageCleanupCoordinator.kt`。
- 真实 owner：AI Controller 直接读写 `SpSettingHelper` 并使用 `HttpsURLConnection`；在线搜索直接调用 `ServiceHelper/WenQuService` 与 `BookDtoMapper`；封面代理用 `WebBookRepository` 查书后由 Coil/OkHttp 缓存和下载；导出组合 App 的 Book/Note/Review/Relevant/BookTag 及四类远端 Repository；导入组合解析器、`BookRepository`、`NoteRepository` 和 `MatchBookInfoHelper`；上传票据保存在 SharedPreferences，COS 能力由 `RxCosHelper/CosHelper` 提供。
- App 对照：AI 配置与启动门禁见 `AIConfigurationViewModel.kt:26-123`、`App.kt:225-275`；在线搜书见 `BookSearchPresenter.kt`、`BookSearchSheetViewModel.kt` 与 `MatchBookInfoHelper.java`；导出见 `NoteExportPresenter.kt` 与 `NoteExportActivity.kt`；导入见 `ImportPresenter.kt`、`ImportBookListPresenter.kt`、`ImportNoteListPresenter.kt`、`NoteRepository.importNotesToDbSuspend`；图片上传与配置见 `AttachImagesView.kt`、`EditOrAddBookPresenter.kt`、`CosConfigPresenter.kt` 与 `RxCosHelper.kt`。
- 结论：17 条接口均已完成 iOS 实现和单元测试，包含 AI 配置局部更新/透明代理、文曲结果映射和模糊排序、封面签名/缓存/Range 边界、三类本地与四类远端导出、导入任务生命周期和文曲补全，以及上传票据/额度/限流/清理状态机。确认新增 `ANDROID-WEB-070` 至 `ANDROID-WEB-084`、`ANDROID-WEB-094` 与 `ANDROID-WEB-095`；安全或资源泄漏类问题按文档说明采用边界等价而非复制危险实现。AI 配置 `WEB-API-001/002`、透明代理 `WEB-API-003`、在线搜书 `WEB-API-013`、封面代理 `WEB-API-024`、导出 `WEB-API-051...054`、导入 `WEB-API-063...066` 与上传完整工作流 `WEB-API-157...160` 均已完成正式合同、成功/失败链路和数据库副作用收敛。

## 后续记录模板

每个新问题必须包含：问题 ID、关联 API ID、Android Web 代码证据、Android App 参考证据、可复现输入、实际结果、风险、iOS 复刻决策和 TODO 落点。
