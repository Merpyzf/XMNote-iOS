import Foundation

/**
 * [INPUT]: 依赖 Models 与 Services 层的数据类型定义，包含三联登录恢复快照
 * [OUTPUT]: 对外提供 Book/Note/Content/GlobalSearch/Backup/S3/AI/图片额度/标签选择布局偏好/TagManagement/BookGroupManagement/SourceManagement/ExternalAppIntegration/Statistics/ReadCalendar/封面主题/Timeline/ReadingDashboard/ReadingTimer、回顾分页目录与轻量布局清单及书籍搜索录入协议
 * [POS]: Domain 层仓储契约，定义 Presentation 获取本地/网络数据的唯一入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
*/

/// 书籍标签关系的显式变更模式，避免由选择数量隐式推断替换、追加或移除语义。
enum BookTagMutationMode: String, Hashable, Sendable {
    case replace
    case add
    case remove
}

/// 书籍封面样例数据访问契约，供调试预览读取真实书籍封面。
protocol BookCoverSampleRepositoryProtocol {
    /// 持续监听书架列表变化，供书籍首页实时刷新。
    func observeBooks() -> AsyncThrowingStream<[BookItem], Error>
}

/// 书架管理数据访问契约，定义首页、二级列表和聚合管理的观察与写入入口。
protocol BookshelfRepositoryProtocol {
    /// 持续监听默认书架混排列表，供首页展示书籍与分组。
    func observeBookshelf(setting: BookshelfDisplaySetting, searchKeyword: String?) -> AsyncThrowingStream<[BookshelfItem], Error>
    /// 持续监听首页书架只读快照，按维度设置分别排序与分区，供不同浏览维度共享同一数据来源。
    func observeBookshelfSnapshot(settingsByDimension: [BookshelfDimension: BookshelfDisplaySetting], searchKeyword: String?) -> AsyncThrowingStream<BookshelfSnapshot, Error>
    /// 持续监听非默认维度聚合入口，供 UIKit 聚合列表独立刷新。
    func observeBookshelfAggregateSnapshot(setting: BookshelfDisplaySetting, searchKeyword: String?) -> AsyncThrowingStream<BookshelfAggregateSnapshot, Error>
    /// 持续监听二级书籍列表，避免路由携带静态书籍数组导致返回后数据陈旧。
    func observeBookshelfBookList(context: BookshelfListContext, setting: BookshelfDisplaySetting, searchKeyword: String?) -> AsyncThrowingStream<BookshelfBookListSnapshot, Error>
    /// 按最终书架顺序写入 Book/Group 的 order 字段，严格复刻 Android 手动排序落库语义。
    func updateBookshelfOrder(_ orderedItems: [BookshelfOrderItem]) async throws
    /// 按最终聚合顺序写入标签、来源或阅读状态的 order 字段。
    func updateBookshelfAggregateOrder(context: BookshelfAggregateOrderContext, orderedIDs: [Int64]) async throws
    /// 按默认分组二级列表最终顺序写入组内书籍的 book_order 字段。
    func updateBooksInGroupOrder(groupID: Int64, orderedBookIDs: [Int64]) async throws
    /// 批量置顶默认分组内的书籍，按组内最大 pin_order 追加。
    func pinBooksInGroup(groupID: Int64, bookIDs: [Int64]) async throws
    /// 批量取消默认分组内书籍的置顶状态。
    func unpinBooksInGroup(bookIDs: [Int64]) async throws
    /// 将默认分组内选中的非置顶书籍移动到普通区最前。
    func moveBooksInGroupToStart(_ bookIDs: [Int64], groupID: Int64, currentItems: [BookshelfBookListOrderItem]) async throws
    /// 将默认分组内选中的非置顶书籍移动到普通区最后。
    func moveBooksInGroupToEnd(_ bookIDs: [Int64], groupID: Int64, currentItems: [BookshelfBookListOrderItem]) async throws
    /// 读取二级列表批量编辑所需选项；单本选择时同时返回该书当前标签、来源、阅读状态、状态时间与评分。
    func fetchBookshelfBatchEditOptions(bookIDs: [Int64]) async throws -> BookshelfBatchEditOptions
    /// 按显式模式批量变更书籍标签，禁止由选择数量推断业务语义。
    func mutateBooksTags(bookIDs: [Int64], tagIDs: [Int64], mode: BookTagMutationMode) async throws
    /// 批量设置书籍来源，按 Android DAO 语义仅通过 id 定位目标书籍。
    func batchSetBooksSource(bookIDs: [Int64], sourceID: Int64) async throws
    /// 新建书籍分组，供批量移组 Sheet 面板内直接创建并返回新选项。
    func createGroup(named name: String) async throws -> BookEditorNamedOption
    /// 新建书籍标签，供批量标签 Sheet 面板内直接创建并返回新选项。
    func createTag(named name: String) async throws -> BookEditorNamedOption
    /// 新建书籍来源，供批量来源 Sheet 面板内直接创建并返回新选项。
    func createSource(named name: String) async throws -> BookshelfSourceOption
    /// 批量设置书籍阅读状态；读完状态会同步评分与阅读进度到终点。
    func batchSetBookReadStatus(bookIDs: [Int64], input: BookshelfBatchReadStatusInput) async throws
    /// 读取可作为移入目标的有效分组，排除当前分组后供批量移组 Sheet 展示封面与数量。
    func fetchBookshelfMoveTargetGroups(excludingGroupID: Int64?) async throws -> [BookshelfMoveGroupOption]
    /// 读取未删除、非年度的手动书单，供批量加入书单 Sheet 展示。
    func fetchManualBookCollections() async throws -> [BookCollectionSummary]
    /// 持续监听手动书单与年度书单列表快照，供书单 Tab 实时展示。
    func observeBookCollectionList() -> AsyncThrowingStream<BookCollectionListSnapshot, Error>
    /// 持续监听指定书单详情，供书单详情页展示 collection 与 collection_book 关系。
    func observeBookCollectionDetail(collectionID: Int64) -> AsyncThrowingStream<BookCollectionDetail?, Error>
    /// 按当前读完历史修复年度书单关系，供年度书单入口在读取前补齐 Android 历史迁移副作用。
    func repairAnnualBookCollections() async throws
    /// 新建手动书单，创建后可立即作为加入书单目标。
    func createBookCollection(title: String) async throws -> BookCollectionSummary
    /// 按 Android saveCollection 语义新建手动书单，写入标题与简介。
    func createBookCollection(input: BookCollectionFormInput) async throws -> BookCollectionListItem
    /// 编辑手动书单标题与简介；年度书单不允许通过此入口编辑。
    func updateBookCollection(collectionID: Int64, input: BookCollectionFormInput) async throws
    /// 删除手动书单及其关联关系；年度书单不允许通过此入口删除。
    func deleteBookCollection(collectionID: Int64) async throws
    /// 按最终列表顺序写入手动书单 order 字段。
    func updateManualBookCollectionOrder(_ collectionIDs: [Int64]) async throws
    /// 批量加入书单；已有有效关系保持不变，只为缺失关系插入记录。
    func addBooks(_ bookIDs: [Int64], toCollection collectionID: Int64) async throws
    /// 将本地书或在线/导入草稿统一加入当前手动书单；草稿会按 Android 语义保存为占位书。
    func addBookSelections(_ selections: [BookCollectionBookSelectionInput], toCollection collectionID: Int64) async throws
    /// 将书单中的占位书恢复为书架有效书籍，保留原书单 relation。
    func restoreCollectionPlaceholderBook(bookID: Int64) async throws
    /// 从书单内物理删除指定关系；移除最后引用时由书籍仓储清理业务占位书。
    func removeBooksFromCollection(collectionBookIDs: [Int64]) async throws
    /// 按书单内最终顺序写入 relation order 字段。
    func updateBooksInCollectionOrder(collectionID: Int64, relationIDs: [Int64]) async throws
    /// 编辑书单内推荐语，保留同一 relation 并更新 relation 时间戳。
    func updateCollectionBookRecommend(collectionBookID: Int64, recommend: String) async throws
    /// 编辑书单内单本书籍元信息与收藏理由，支持有效书和占位书，手动/年度书单均可使用。
    func updateCollectionBookMetadata(_ input: BookCollectionBookMetadataEditInput) async throws
    /// 编辑年度书单本体说明；不允许修改标题、年份、成员或排序。
    func updateAnnualBookCollectionDescription(collectionID: Int64, description: String) async throws
    /// 解析微信读书书单链接，返回保存前预览，不写入数据库。
    func parseWereadBookCollectionImport(link: String) async throws -> BookCollectionImportPreview
    /// 保存微信读书导入预览，在单个事务中创建书单、占位书与 relation 推荐语。
    func saveWereadBookCollectionImport(_ preview: BookCollectionImportPreview) async throws -> BookCollectionListItem
    /// 读取当前书单一次性快照，供导出与分享生成锁定范围。
    func fetchBookCollectionExportSnapshot(collectionID: Int64) async throws -> BookCollectionDetail
    /// 将指定书籍从当前分组移出到默认书架，并按位置语义写入默认书架排序值。
    func moveBooksOutOfGroup(bookIDs: [Int64], placement: GroupBooksPlacement) async throws
    /// 批量置顶默认书架顶层 Book/Group，按传入选择顺序追加 pin_order。
    func pinBookshelfItems(_ ids: [BookshelfItemID]) async throws
    /// 取消单个默认书架顶层 Book/Group 的置顶状态。
    func unpinBookshelfItem(_ id: BookshelfItemID) async throws
    /// 将非置顶选中项移动到普通区最前，置顶区保持不变。
    func moveBookshelfItemsToStart(_ ids: [BookshelfItemID], in currentItems: [BookshelfOrderItem]) async throws
    /// 将非置顶选中项移动到普通区最后，置顶区保持不变。
    func moveBookshelfItemsToEnd(_ ids: [BookshelfItemID], in currentItems: [BookshelfOrderItem]) async throws
    /// 删除默认书架顶层 Book/Group，分组删除时按传入位置安置组内书籍。
    func deleteBookshelfItems(_ ids: [BookshelfItemID], groupBooksPlacement: GroupBooksPlacement) async throws
    /// 将指定书籍从用户操作时的原分组移动到目标分组，取消置顶并重建唯一有效分组关系。
    func moveBooks(_ bookIDs: [Int64], fromGroup currentGroupID: Int64, toGroup targetGroupID: Int64) async throws
    /// 物理删除指定书籍及其关联数据；仍被书单/相关关系引用时保留最小业务占位书。
    func deleteBooks(_ bookIDs: [Int64]) async throws
    /// 删除分组并按位置语义把组内书籍安置回默认书架。
    func deleteGroup(groupID: Int64, placement: GroupBooksPlacement) async throws
    /// 重命名书籍分组。
    func renameGroup(groupID: Int64, newName: String) async throws
    /// 重命名书籍标签。
    func renameTag(tagID: Int64, newName: String) async throws
    /// 删除书籍标签并清理标签与书籍/笔记的关系。
    func deleteTag(tagID: Int64) async throws
    /// 重命名书籍来源。
    func renameSource(sourceID: Int64, newName: String) async throws
    /// 删除书籍来源，并将存量书籍迁移到未知来源。
    func deleteSource(sourceID: Int64) async throws
    /// 重命名作者，并同步更新使用旧作者名的书籍。
    func renameAuthor(oldName: String, newName: String) async throws
    /// 批量修改多个作者维度下的有效书籍作者字段，不写作者资料表。
    func batchModifyBooksAuthor(sourceNames: [String], newName: String) async throws
    /// 删除作者维度下的书籍，并按 Android 作者管理语义移除作者记录。
    func deleteAuthor(name: String) async throws
    /// 重命名出版社，并同步更新使用旧出版社名的书籍。
    func renamePress(oldName: String, newName: String) async throws
    /// 批量修改多个出版社维度下的有效书籍出版社字段，不写出版社资料表。
    func batchModifyBooksPress(sourceNames: [String], newName: String) async throws
    /// 删除出版社维度下的书籍，并按 Android 出版社管理语义移除出版社记录。
    func deletePress(name: String) async throws
    /// 读取按维度和作用域持久化的书架显示设置。
    func fetchBookshelfDisplaySettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting]
    /// 保存单个维度在指定作用域下的书架显示设置。
    func saveBookshelfDisplaySetting(_ setting: BookshelfDisplaySetting, for dimension: BookshelfDimension, scope: BookshelfDisplaySettingScope)
    /// 观察指定书架显示设置变更；调用方取消迭代后底层观察任务会随流终止，避免页面释放后继续触发刷新。
    func observeBookshelfDisplaySettingChanges(scope: BookshelfDisplaySettingScope, dimension: BookshelfDimension) -> AsyncStream<Void>
    /// 读取书单首页显示设置。
    func fetchBookCollectionDisplaySetting() -> BookCollectionDisplaySetting
    /// 保存书单首页显示设置。
    func saveBookCollectionDisplaySetting(_ setting: BookCollectionDisplaySetting)
}

/// 单本书内容工作台数据访问契约，定义书籍资料与四个内容域的观察入口。
protocol BookDetailRepositoryProtocol {
    /// 持续监听指定书籍详情变化，供详情页实时更新。
    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error>
    /// 持续监听指定书籍下的书摘列表变化。
    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error>
    /// 按 0...50 半星步进更新单本有效书籍评分，并同步 Android 毫秒更新时间。
    func updateBookRating(bookId: Int64, score: Int64) async throws
    /// 持续监听指定书籍下的相关分类变化。
    func observeBookRelatedCategories(bookId: Int64) -> AsyncThrowingStream<[BookRelatedCategory], Error>
    /// 持续监听指定书籍下的相关内容变化。
    func observeBookRelated(bookId: Int64) -> AsyncThrowingStream<[BookRelatedExcerpt], Error>
    /// 持续监听指定书籍下的书评变化。
    func observeBookReviews(bookId: Int64) -> AsyncThrowingStream<[BookReviewExcerpt], Error>
}

/// 本地选书数据访问契约，定义通用选书器需要的最小书籍查询能力。
protocol BookPickerRepositoryProtocol {
    /// 按关键词读取本地可选书籍列表，供通用书籍选择流实时筛选。
    func fetchPickerBooks(matching query: String) async throws -> [BookPickerBook]
    /// 按 bookId 解析单本本地书籍，供创建成功后的选择流回填。
    func fetchPickerBook(bookId: Int64) async throws -> BookPickerBook?
}

/// 书籍模块完整本地仓储契约，由更窄的书架、详情、选书与封面样例能力组合而成。
protocol BookRepositoryProtocol:
    BookCoverSampleRepositoryProtocol,
    BookshelfRepositoryProtocol,
    BookDetailRepositoryProtocol,
    BookPickerRepositoryProtocol {
}

/// 书籍搜索仓储契约，统一封装在线来源搜索、豆瓣详情补抓与最近搜索持久化。
protocol BookSearchRepositoryProtocol {
    /// 按来源搜索远端书籍列表；空关键字视为业务错误。
    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult]
    /// 将搜索结果补齐为录入页种子；豆瓣等轻量结果需要在这里抓详情。
    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed
    /// 读取最近搜索词，供搜索页初始态展示。
    func fetchRecentQueries() -> [String]
    /// 写入最近搜索词，按最近使用顺序去重保留。
    func saveRecentQuery(_ query: String)
    /// 删除单条最近搜索词。
    func removeRecentQuery(_ query: String)
    /// 清空全部最近搜索词。
    func clearRecentQueries()
    /// 读取添加书籍搜索设置。
    func fetchSearchSettings() -> BookSearchSettings
    /// 保存添加书籍搜索设置。
    func saveSearchSettings(_ settings: BookSearchSettings)
}

/// 书籍录入仓储契约，统一封装录入选项、偏好读取与新增保存事务。
protocol BookEditorRepositoryProtocol {
    /// 拉取录入页所需的来源、分组、标签与偏好配置。
    func fetchOptions() async throws -> BookEditorOptions
    /// 基于搜索种子与录入偏好生成首屏草稿。
    func makeDraft(from seed: BookEditorSeed?) -> BookEditorDraft
    /// 保存录入偏好，用于下次手动创建或搜索结果补空。
    func savePreference(_ preference: BookEntryPreference)
    /// 按 Android 判重与事务规则保存新书。
    func saveBook(_ draft: BookEditorDraft) async throws -> Int64
    /// 读取既有书籍并转换为录入页可编辑草稿。
    func fetchEditableBook(bookId: Int64) async throws -> BookEditorDraft
    /// 读取仍被有效关系引用的占位书；只建立元数据编辑草稿，不把它恢复到书架。
    func fetchEditableRelatedPlaceholder(bookId: Int64) async throws -> BookEditorDraft
    /// 按当前模式保存书籍草稿。
    func saveBookDraft(_ draft: BookEditorDraft, mode: BookEditorMode) async throws -> Int64
}

/// OCR 调试仓储契约，统一封装百度 OCR 偏好持久化、鉴权缓存与识别请求。
protocol OCRRepositoryProtocol {
    /// 读取 OCR 调试页当前偏好（AK/SK、语言、精度与文案优化开关）。
    func fetchPreferences() -> OCRPreferences
    /// 覆盖写入 OCR 调试页偏好。
    func savePreferences(_ preferences: OCRPreferences)
    /// 清除 SDK 内部鉴权缓存，便于测试凭据切换与异常恢复链路。
    func clearAuthorizationCache()
    /// 对裁切后的图片执行百度 OCR，并返回已做 Android 对齐文本后处理的结果。
    func recognizeText(request: OCRRecognitionRequest) async throws -> OCRRecognitionResult
}

/// 笔记模块数据访问契约，覆盖标签分组、书摘回顾与笔记详情读写。
protocol NoteRepositoryProtocol {
    /// 持续监听标签分组及其笔记摘要，供笔记页分区渲染。
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error>
    /// 持续监听四个默认分组与用户书摘标签聚合，明确排除书籍标签。
    func observeNoteHomeSnapshot() -> AsyncThrowingStream<NoteHomeSnapshot, Error>
    /// 持续监听当前范围、搜索和排序下的一页书摘，列表变化后保留同一请求语义刷新。
    func observeNoteExcerptList(request: NoteExcerptPageRequest) -> AsyncThrowingStream<NoteExcerptListSnapshot, Error>
    /// 持续监听指定书籍章节范围的一页书摘；includeDescendants 由 Repository 递归解析章节树。
    func observeChapterNoteList(request: ChapterNotePageRequest) -> AsyncThrowingStream<NoteExcerptListSnapshot, Error>
    /// 持续监听星标章节分组，按章节树计算含后代书摘数量。
    func observeStarredChapterGroups(request: StarredChapterRequest) -> AsyncThrowingStream<[StarredChapterGroup], Error>
    /// 设置章节星标状态；无效章节或系统根章节抛出业务错误。
    func setChapterStarred(chapterID: Int64, isStarred: Bool) async throws
    /// 持续监听全局相关分类，按精确标题跨书聚合并排除隐藏分类。
    func observeRelatedCategories(request: RelatedCategoryRequest) -> AsyncThrowingStream<RelatedCategorySnapshot, Error>
    /// 持续监听指定相关分类作用域内的混排内容页。
    func observeRelatedContentList(request: RelatedContentPageRequest) -> AsyncThrowingStream<RelatedContentListSnapshot, Error>
    /// 删除首页同名聚合分类；系统默认分类只清空内容并保留分类根，自定义分类跨书软删除定义、内容和附图。
    func deleteRelatedCategory(scope: RelatedCategoryScope) async throws
    /// 持续监听全量书评页，搜索和排序由请求集中描述。
    func observeBookReviewList(request: BookReviewPageRequest) -> AsyncThrowingStream<BookReviewListSnapshot, Error>
    /// 读取书摘回顾设置，供回顾页首屏恢复用户偏好。
    func fetchNoteReviewSettings() -> NoteReviewSettings
    /// 保存书摘回顾设置，供设置 Sheet 即时持久化偏好。
    func saveNoteReviewSettings(_ settings: NoteReviewSettings)
    /// 观察书摘回顾设置变更，供多入口设置修改后同步刷新。
    func observeNoteReviewSettingChanges() -> AsyncStream<Void>
    /// 观察书摘、书籍、章节、标签关系与附图变化，供保活的回顾卡组同步外部编辑结果。
    func observeNoteReviewDataChanges() -> AsyncThrowingStream<Void, Error>
    /// 上传回顾背景图并返回远端地址，供回顾设置保存图片背景。
    func uploadNoteReviewBackground(localURL: URL) async throws -> S3UploadResult
    /// 下载回顾背景图数据，供分享图渲染复用当前图片背景。
    func fetchNoteReviewBackgroundData(remoteURL: URL) async throws -> Data
    /// 按当前回顾设置读取一页书摘卡片，统一承接顺序分页与随机排除语义。
    func fetchNoteReviewPage(request: NoteReviewPageRequest) async throws -> [NoteReviewCardItem]
    /// 按卡堆完全相同的筛选条件读取轻量书摘身份序列；随机顺序由调用会话在内存中生成。
    func fetchNoteReviewIDs(settings: NoteReviewSettings) async throws -> [Int64]
    /// 异步构建/验证无正文目录；调用任务取消后停止后续批次，cacheID 标识可恢复的同一会话派生文件。
    func openNoteReviewDirectory(request: NoteReviewDirectoryRequest, cacheID: UUID,
                                 schedule: @escaping NoteReviewDirectoryReadScheduling,
                                 progress: @escaping @Sendable (NoteReviewDirectoryPreparation) async -> Void) async throws -> any NoteReviewDirectory
    /// 按输入身份顺序异步读取纸流测高所需的轻量正文、标题与更新时间；仓储保证单条 SQL 最多包含 128 个 ID，调用方拥有取消与过期结果判定。
    func fetchNoteReviewOverviewLayoutSources(noteIDs: [Int64]) async throws -> [NoteReviewOverviewLayoutSource]
    /// 按书摘主键读取单个只读操作上下文，供当日记录菜单复用标签、微信读书、分享和外部发送能力。
    func fetchNoteReviewItem(noteID: Int64) async throws -> NoteReviewCardItem?
    /// 批量读取书摘只读操作上下文，避免重度阅读日期逐条访问数据库。
    func fetchNoteReviewItems(noteIDs: [Int64]) async throws -> [NoteReviewCardItem]
    /// 读取回顾设置可选标签，供标签筛选 Sheet 展示。
    func fetchNoteReviewTagOptions() async throws -> [NoteReviewTagOption]
    /// 读取当前回顾卡片的标签编辑快照，供操作菜单进入标签 Sheet。
    func fetchNoteReviewTagEditSnapshot(noteID: Int64) async throws -> NoteReviewTagEditSnapshot
    /// 替换当前回顾卡片的书摘标签，并返回数据库确认后的最新选中标签。
    func replaceNoteReviewTags(noteID: Int64, tags: [NoteEditorTagOption]) async throws -> [NoteEditorTagOption]
    /// 物理增删单条书摘与指定自定义标签的关系，供爱心快捷操作复用标签体系。
    func setNoteTagMembership(noteID: Int64, tagID: Int64, isPresent: Bool) async throws
    /// 按已选书籍 ID 读取回显信息，供设置页展示与 BookPicker 预选。
    func fetchNoteReviewSelectedBooks(bookIDs: [Int64]) async throws -> [BookPickerBook]
    /// 按笔记 ID 拉取可编辑详情（正文/想法 HTML 与元信息）。
    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload?
    /// 保存笔记正文与想法 HTML，提交后触发下游观察流更新。
    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws
    /// 拉取书摘编辑页首屏所需草稿、恢复草稿与书/章/标签选项。
    func fetchNoteEditorBootstrap(mode: NoteEditorMode, seed: NoteEditorSeed?) async throws -> NoteEditorBootstrap
    /// 当切换书籍时，重新拉取当前书籍下的章节选项。
    func fetchNoteEditorChapters(bookId: Int64) async throws -> [NoteEditorChapterOption]
    /// 新建书摘标签；需遵循 Android 的长度与重名校验。
    func createNoteTag(named name: String) async throws -> NoteEditorTagOption
    /// 将选中的本地图片暂存到编辑目录，供自动保存与后续上传复用。
    func stageNoteEditorImage(data: Data, preferredFileExtension: String) async throws -> NoteEditorImageItem
    /// 上传单张暂存附图，返回携带远端 URL 的最新条目。
    func uploadStagedNoteEditorImage(_ item: NoteEditorImageItem) async throws -> NoteEditorImageItem
    /// 删除单张暂存附图，避免残留无效缓存文件。
    func removeStagedNoteEditorImage(_ item: NoteEditorImageItem) async
    /// 保存当前编辑草稿，用于自动恢复。
    func saveNoteEditorDraft(_ draft: NoteEditorDraft)
    /// 读取指定书籍与书摘组合下的自动保存草稿。
    func fetchNoteEditorDraft(bookId: Int64, noteId: Int64) -> NoteEditorDraft?
    /// 删除指定书籍与书摘组合下的自动保存草稿，并清理本地暂存图。
    func deleteNoteEditorDraft(bookId: Int64, noteId: Int64)
    /// 按 Android 事务语义保存新建/编辑后的书摘。
    func saveNoteEditor(_ draft: NoteEditorDraft) async throws -> Int64
    /// 读取批量编辑所需书摘、可选书籍与标签；并发删除的 ID 通过 unavailableNoteIDs 返回。
    func fetchNoteBatchEditBootstrap(noteIDs: [Int64]) async throws -> NoteBatchEditBootstrap
    /// 在单一事务内软删除附图、标签关系与选中书摘，并物理清理 Android 定义的导入 Hash。
    func deleteNotes(noteIDs: [Int64]) async throws
    /// 将原书摘移动到目标书籍，并按祖先标题路径在目标书中复用或重建章节。
    func moveNotes(noteIDs: [Int64], toBookID bookID: Int64) async throws
    /// 将同一本书内的原书摘移动到目标章节，不复制书摘或其子记录。
    func moveNotes(noteIDs: [Int64], toChapterID chapterID: Int64) async throws
    /// 在章节选择现场新建手动章节；parentID=0 表示根章节。
    func createChapter(bookID: Int64, parentID: Int64, title: String) async throws -> NoteEditorChapterOption
    /// 对每条选中书摘事务替换全部标签关系；旧关系软删除，空 tagIDs 表示清空标签。
    func replaceTagsForNotes(noteIDs: [Int64], tagIDs: [Int64]) async throws
    /// 按正文/想法各自的排序与换行规则生成合并预览草稿。
    func fetchNoteMergeDraft(request: NoteMergePreviewRequest) async throws -> NoteMergeDraft
    /// 在单一事务内软删除全部来源书摘并创建合并结果，返回新书摘主键。
    func mergeNotes(_ draft: NoteMergeDraft) async throws -> Int64
}

/// 通用标签选择布局偏好契约，隔离视图与具体持久化实现。
protocol TagSelectionLayoutPreferenceRepositoryProtocol {
    /// 读取全局标签选择布局；无有效偏好时由实现回退列表。
    func fetchLayoutMode() -> TagSelectionLayoutMode
    /// 保存全局标签选择布局，供全部复用场景和后续启动恢复。
    func saveLayoutMode(_ layoutMode: TagSelectionLayoutMode)
}

/// 标签管理仓储契约，统一封装标签管理页与业务标签选择器共用的书摘/书籍标签读写语义。
protocol TagManagementRepositoryProtocol {
    /// 持续观察书摘与书籍标签管理快照，供分段数量与当前列表同步刷新。
    func observeTagManagementSnapshot() -> AsyncThrowingStream<TagManagementSnapshot, Error>
    /// 新建指定范围的标签，按 Android 标签管理语义写入默认字段。
    func createTag(named name: String, scope: TagManagementScope) async throws
    /// 编辑指定标签名称，按 Android TagManage 的 @Update 全列语义提交。
    func updateTag(tagID: Int64, name: String, scope: TagManagementScope) async throws
    /// 在单一事务内物理删除指定范围下的标签及其关系；任一项失败时整批回滚。
    func deleteTags(tagIDs: [Int64], scope: TagManagementScope) async throws
    /// 按当前展示顺序写入 tag_order，并更新 updated_date。
    func updateTagOrder(tagIDs: [Int64], scope: TagManagementScope) async throws
}

/// 书籍分组管理仓储契约，统一封装“我的 > 书籍分组”的分组读写语义。
protocol BookGroupManagementRepositoryProtocol {
    /// 持续观察书籍分组管理快照，供列表数量、封面预览与操作状态同步刷新。
    func observeBookGroupManagementSnapshot() -> AsyncThrowingStream<BookGroupManagementSnapshot, Error>
    /// 新建书籍分组，按 Android GroupManage 语义写入默认字段。
    func createGroup(named name: String) async throws
    /// 编辑指定分组名称，按 Android GroupDao.updateName 语义提交。
    func updateGroup(groupID: Int64, name: String) async throws
    /// 在单一事务内删除指定分组；含书分组先按用户选择把书籍移回默认书架开头或末尾，任一项失败时整批回滚。
    func deleteGroups(groupIDs: [Int64], placement: GroupBooksPlacement) async throws
    /// 按当前展示顺序写入 group_order，并更新 updated_date。
    func updateGroupOrder(groupIDs: [Int64]) async throws
}

/// 书籍来源管理仓储契约，统一封装“我的 > 书籍来源”的来源读写语义。
protocol SourceManagementRepositoryProtocol {
    /// 持续观察我的来源与默认来源管理快照，供分段数量与当前列表同步刷新。
    func observeSourceManagementSnapshot() -> AsyncThrowingStream<SourceManagementSnapshot, Error>
    /// 新建我的来源，按 Android 来源管理语义写入默认字段。
    func createSource(named name: String) async throws
    /// 编辑指定我的来源名称，按 Android SourceRepository.update 的 @Update 全列语义提交。
    func updateSource(sourceID: Int64, name: String) async throws
    /// 删除指定我的来源；删除前将关联书籍迁移到未知来源。
    func deleteSources(sourceIDs: [Int64]) async throws
    /// 按当前展示顺序写入 source_order，并更新 updated_date。
    func updateSourceOrder(sourceIDs: [Int64], scope: SourceManagementScope) async throws
}

/// 通用内容查看仓储契约，统一封装书摘/书评/相关内容的查看、编辑与删除入口。
protocol ContentRepositoryProtocol {
    /// 持续监听指定来源下的分页内容列表。
    func observeViewerItems(source: ContentViewerSourceContext) -> AsyncThrowingStream<[ContentViewerListItem], Error>
    /// 持续监听指定书籍的书评、相关内容与可新建分类，供书籍详情笔记域工作区同步刷新。
    func observeBookContentWorkspace(bookID: Int64) -> AsyncThrowingStream<BookContentWorkspaceSnapshot, Error>
    /// 原子写入指定书籍与内容类型的排序规则；同一本书的三个类型互不覆盖。
    func updateBookContentSortRule(
        bookID: Int64,
        type: BookContentSortType,
        rule: BookContentSortRule
    ) async throws
    /// 在受保护的系统“书籍”分类下建立两本有效本地书之间的相关关系，禁止自关联与重复关系。
    func addRelatedBook(sourceBookID: Int64, relatedBookID: Int64) async throws
    /// 将在线候选保存为 is_deleted=1 引用占位书并建立相关关系，不把候选强制加入书架。
    func addRelatedBookPlaceholder(sourceBookID: Int64, seed: BookEditorSeed) async throws
    /// 将相关书籍占位记录恢复为有效书架书，使其可进入完整详情与编辑链路。
    func restoreRelatedBookPlaceholder(bookID: Int64) async throws
    /// 新建当前书籍私有或全部书籍共享的相关分类，并按 Android 可见范围判重。
    func createBookRelatedCategory(bookID: Int64, title: String, scope: BookContentCategoryScope) async throws
    /// 重命名当前书可管理的私有或全局自定义分类；六个固定默认分类始终只读。
    func renameBookRelatedCategory(bookID: Int64, categoryID: Int64, title: String) async throws
    /// 软删除当前书可管理的私有或全局自定义分类、其内容与附图，保留同步删除状态。
    func deleteBookRelatedCategory(bookID: Int64, categoryID: Int64) async throws
    /// 切换六个固定默认分类的隐藏状态；隐藏设置会影响所有书籍。
    func setDefaultBookRelatedCategoryHidden(categoryID: Int64, isHidden: Bool) async throws
    /// 按当前书管理列表的最终顺序更新 order；全局分类顺序变化会跨书生效。
    func updateBookRelatedCategoryOrder(bookID: Int64, categoryIDs: [Int64]) async throws
    /// 按统一 itemID 拉取查看页完整详情。
    func fetchViewerDetail(itemID: ContentViewerItemID) async throws -> ContentViewerDetail?
    /// 读取书评编辑草稿。
    func fetchReviewEditorDraft(reviewId: Int64) async throws -> ReviewEditorDraft?
    /// 按新建/编辑模式读取书评草稿；新建草稿校验所属书籍并使用空图片集。
    func fetchReviewEditorDraft(mode: ReviewEditorMode) async throws -> ReviewEditorDraft?
    /// 保存书评编辑草稿。
    func saveReviewEditorDraft(_ draft: ReviewEditorDraft) async throws
    /// 按新建/编辑模式保存书评并返回真实主键。
    func saveReviewEditorDraft(_ draft: ReviewEditorDraft, mode: ReviewEditorMode) async throws -> Int64
    /// 读取书籍与书评主键精确匹配的自动保存草稿。
    func fetchReviewEditorAutoSaveDraft(sourceBookId: Int64, reviewId: Int64) -> ReviewEditorAutoSaveDraft?
    /// 写入书评自动保存草稿；编码失败会作为仓储错误返回。
    func saveReviewEditorAutoSaveDraft(_ draft: ReviewEditorAutoSaveDraft) throws
    /// 删除精确身份下的书评自动保存草稿，不触碰任何远端图片。
    func deleteReviewEditorAutoSaveDraft(sourceBookId: Int64, reviewId: Int64)
    /// 读取相关内容编辑草稿。
    func fetchRelevantEditorDraft(contentId: Int64) async throws -> RelevantEditorDraft?
    /// 按新建/编辑模式读取相关内容草稿；新建草稿校验书籍与分类关系。
    func fetchRelevantEditorDraft(mode: RelevantEditorMode) async throws -> RelevantEditorDraft?
    /// 保存相关内容编辑草稿。
    func saveRelevantEditorDraft(_ draft: RelevantEditorDraft) async throws
    /// 读取相关书籍关系及目标书信息，供当日记录菜单编辑关联。
    func fetchRelatedBookRelationDraft(relationID: Int64) async throws -> RelatedBookRelationDraft?
    /// 以单事务保存相关书籍关系，并按 Android 语义固定写入“书籍”分类。
    func saveRelatedBookRelationDraft(_ draft: RelatedBookRelationDraft) async throws
    /// 按新建/编辑模式保存相关内容并返回真实主键。
    func saveRelevantEditorDraft(_ draft: RelevantEditorDraft, mode: RelevantEditorMode) async throws -> Int64
    /// 读取书籍、分类与内容主键精确匹配的自动保存草稿。
    func fetchRelevantEditorAutoSaveDraft(
        sourceBookId: Int64,
        categoryId: Int64,
        contentId: Int64
    ) -> RelevantEditorAutoSaveDraft?
    /// 写入相关内容自动保存草稿；编码失败会作为仓储错误返回。
    func saveRelevantEditorAutoSaveDraft(_ draft: RelevantEditorAutoSaveDraft) throws
    /// 删除精确身份下的相关内容自动保存草稿，不触碰任何远端图片。
    func deleteRelevantEditorAutoSaveDraft(sourceBookId: Int64, categoryId: Int64, contentId: Int64)
    /// 按 Android 语义软删除普通相关内容或相关书籍关系及其附图。
    func deleteRelatedRelation(relationID: Int64) async throws
    /// 删除指定内容，按 Android 当前约定软删除主记录与子记录；书摘导入哈希按 Android 物理清理。
    func delete(itemID: ContentViewerItemID) async throws
}

/// 全局搜索仓储契约，统一封装书籍、书摘、相关与书评四类本地检索。
protocol GlobalSearchRepositoryProtocol {
    /// 按关键词执行一次全局本地搜索；空关键词返回空快照，不触发 Toast 式错误。
    func search(keyword: String) async throws -> GlobalSearchSnapshot
    /// 读取最近全局搜索词，供搜索根页展示真实历史。
    func fetchRecentQueries() -> [String]
    /// 写入最近全局搜索词，按最近使用顺序去重保留。
    func saveRecentQuery(_ query: String)
    /// 删除单条最近全局搜索词。
    func removeRecentQuery(_ query: String)
    /// 清空全部最近全局搜索词。
    func clearRecentQueries()
}

/// 关联应用集成仓储契约，统一封装三方配置读取、保存、已配置目标计算与书摘发送。
protocol ExternalAppIntegrationRepositoryProtocol {
    /// 读取当前关联应用配置；纯本地同步读取，不触发数据库或网络访问。
    func fetchSettings() -> ExternalAppIntegrationSettings
    /// 保存关联应用配置；空值表示清空配置，非空 URL 会在写入前做 Android 对齐格式校验。
    func saveSettings(_ settings: ExternalAppIntegrationSettings) throws
    /// 基于当前配置计算已启用目标，供发送菜单或设置页状态展示。
    func configuredDestinations() -> [ExternalAppDestination]
    /// 观察关联应用配置变化，供保活页面同步发送入口可用性。
    func observeConfigurationChanges() -> AsyncStream<Void>
    /// 按书摘 ID 读取数据库载荷并发送到指定目标；数据库读取与网络请求均在 Repository 内完成，调用任务取消后不再回写调用方状态。
    func send(noteID: Int64, to destination: ExternalAppDestination) async throws -> ExternalAppIntegrationSendResult
}

/// AI 仓储契约，统一封装完整本机配置快照、单任务提示词、OpenAI-compatible 请求与自动标签写回。
nonisolated protocol AIRepositoryProtocol: Sendable {
    /// 读取配置与各供应商密钥存在状态；明文密钥不会离开 Repository/Service 边界。
    func fetchConfiguration() async throws -> AIConfigurationSnapshot
    /// 保存非敏感配置，并可选更新当前供应商密钥；`apiKey=nil` 表示保留已有密钥。
    func saveConfiguration(_ configuration: AIConfiguration, apiKey: String?) async throws
    /// 原子更新一个任务的 System/User 组合，不提交设置页尚未保存的模型、开关或密钥草稿。
    func savePromptTemplate(_ template: AIPromptTemplate, for kind: AIPromptKind) async throws
    /// 使用正式请求构建器生成离线预览，不读取凭据或发起网络请求。
    func makePromptPreview(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        sample: AIPromptSampleContext
    ) throws -> AIPromptRequestPreview
    /// 用相同模型、参数和上下文流式试运行当前草稿；对照时并发输出当前与应用原始提示词事件。
    func streamPromptTrial(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        sample: AIPromptSampleContext,
        comparesDefault: Bool
    ) -> AsyncThrowingStream<AIPromptTrialEvent, Error>
    /// 根据自然语言期望优化当前字段；不读取或上传任何书摘正文。
    func optimizePrompt(
        kind: AIPromptKind,
        field: AIPromptEditorField,
        currentText: String,
        instruction: String
    ) async throws -> String
    /// 删除指定供应商密钥，不改变另一供应商配置。
    func deleteAPIKey(for provider: AIProvider) async throws
    /// 对单条书摘执行 SSE 流式解读，元素为截至当前的完整累积文本；取消消费流会取消网络请求。
    func streamNoteExplanation(noteID: Int64) -> AsyncThrowingStream<String, Error>
    /// 对 Viewer 中选中的文本执行 SSE 流式释义；取消消费流会取消网络请求。
    func streamTextLookup(input: AITextLookupInput) -> AsyncThrowingStream<String, Error>
    /// 流式生成 AI 标签：先发送累计正文快照，结束后再解析并发送 0...3 个最终候选；取消消费会取消网络请求。
    func streamTagSuggestions(
        noteID: Int64
    ) -> AsyncThrowingStream<AIAutoTagGenerationEvent, Error>
    /// 将已选建议与书摘现有标签取并集，创建缺失标签后提交关系。
    func applyAutoTags(noteID: Int64, suggestions: [AIAutoTagSuggestion]) async throws
}

/// 备份服务器配置契约，覆盖服务器列表、当前选择、增删改与连通性校验。
protocol BackupServerRepositoryProtocol {
    /// 拉取全部备份服务器配置，供列表页展示。
    func fetchServers() async throws -> [BackupServerRecord]
    /// 读取当前选中的备份服务器；未选择时返回 nil。
    func fetchCurrentServer() async throws -> BackupServerRecord?
    /// 新增或更新备份服务器配置（地址、账号、密码等）。
    func saveServer(_ input: BackupServerFormInput, editingServer: BackupServerRecord?) async throws
    /// 删除指定备份服务器配置。
    func delete(_ server: BackupServerRecord) async throws
    /// 将指定服务器设为当前备份目标。
    func select(_ server: BackupServerRecord) async throws
    /// 校验 WebDAV 连接可用性，失败时抛出网络或认证错误。
    func testConnection(_ input: BackupServerFormInput) async throws
}

/// 数据备份契约，覆盖备份执行、历史读取与恢复流程。
protocol BackupRepositoryProtocol {
    /// 读取云备份页面状态快照，聚合当前 provider、WebDAV 配置、阿里云账号信息与最近备份时间。
    func fetchCloudBackupPageState() async throws -> CloudBackupPageState
    /// 读取最近一次本地导出成功时间；无记录时返回 nil。
    func fetchLastLocalBackupDate() async -> Date?
    /// 刷新当前 provider 对应的最近一次云备份时间。
    func fetchLatestCloudBackupDate() async throws -> Date?
    /// 持久化当前选中的云备份 provider。
    func selectCloudBackupProvider(_ provider: CloudBackupProvider) async throws
    /// 发起阿里云盘授权流程。
    func authorizeAliyunDrive() async throws
    /// 清除阿里云盘授权状态。
    func revokeAliyunDriveAuthorization() async
    /// 生成本地导出所需的临时备份包，并返回交给系统文件选择器的票据。
    func prepareLocalExport() async throws -> LocalBackupExportTicket
    /// 本地导出流程结束后清理临时文件，并按结果刷新最近导出时间。
    func finalizeLocalExport(_ ticket: LocalBackupExportTicket, succeeded: Bool) async
    /// 将用户从“文件”中选择的备份复制到沙盒，并返回后续恢复所需票据。
    func prepareLocalImport(from url: URL) async throws -> LocalBackupImportTicket
    /// 使用本地导入票据执行恢复流程，并通过回调上报阶段进度。
    func restoreLocalBackup(
        using ticket: LocalBackupImportTicket,
        progress: (@Sendable (RestoreProgress) -> Void)?
    ) async throws -> BackupRestoreResult
    /// 放弃本地导入票据时清理复制到沙盒的临时文件。
    func discardLocalImport(_ ticket: LocalBackupImportTicket) async
    /// 执行一次完整备份流程，并通过回调上报阶段进度。
    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws
    /// 获取远端备份历史列表，供恢复入口展示可选备份。
    func fetchBackupHistory() async throws -> [BackupFileInfo]
    /// 使用指定备份执行恢复流程，并通过回调上报阶段进度。
    func restore(
        _ backup: BackupFileInfo,
        progress: (@Sendable (RestoreProgress) -> Void)?
    ) async throws -> BackupRestoreResult
}

/// S3 配置契约，覆盖默认配置映射、自定义配置 CRUD、启用切换与联通性校验。
protocol S3ConfigRepositoryProtocol {
    /// 拉取全部可用 S3 配置，供设置页或测试入口展示。
    func fetchConfigs() async throws -> [S3Config]
    /// 读取当前启用的 S3 配置；未配置时返回 nil。
    func fetchCurrentConfig() async throws -> S3Config?
    /// 新增或更新自定义 S3 配置。
    func saveConfig(_ input: S3ConfigFormInput, editingConfig: S3Config?) async throws -> S3Config
    /// 删除指定 S3 配置。
    func delete(_ config: S3Config) async throws
    /// 将指定 S3 配置设为当前启用配置。
    func select(_ config: S3Config) async throws
    /// 校验给定配置是否具备上传与删除测试对象的能力。
    func testConnection(_ input: S3ConfigFormInput) async throws
}

/// 应用后端配置契约，集中封装任意配置 key 的远端查询与本地缓存。
nonisolated protocol AppBackendConfigRepositoryProtocol: Sendable {
    /// 返回指定配置 key 的当前值；刷新失败时允许返回最近一次成功缓存，无缓存则返回 nil。
    func queryValue(key: String) async -> String?
}

/// 图片上传每日额度仓储契约，集中处理动态上限、默认图床判断、跨编辑器预占与成功保存计数。
nonisolated protocol NoteImageUploadQuotaRepositoryProtocol: Sendable {
    /// 将当前草稿实际新图数与预占对齐；`isPersistedDraft` 同时确认 owner，供启动整理安全删除未落草稿的孤儿票据。
    func reconcileReservation(
        id: String,
        owner: NoteImageUploadReservationOwner,
        draftNewImageCount: Int,
        isPersistedDraft: Bool
    ) async -> NoteImageUploadQuotaState
    /// 在共享 Actor 内按 owner 原子申请本次新增数量；申请先保持未确认，编辑器写下自动草稿后再 reconcile 确认。
    func reserveImages(
        id: String,
        owner: NoteImageUploadReservationOwner,
        currentDraftNewImageCount: Int,
        requestedCount: Int
    ) async -> NoteImageUploadReservationResult
    /// 用户明确丢弃草稿时释放当天预占；保留草稿退出不会调用此方法。
    func releaseReservation(id: String) async
    /// 仅在业务主内容成功后转换真实存在的 ticket；同一 ID 重复提交必须幂等。
    func commitReservation(id: String, savedImageCount: Int) async
}

/// S3 上传契约，覆盖当前配置下的文件上传、联通性校验、删除与取消。
protocol S3UploadRepositoryProtocol: AnyObject {
    /// 将相册图片数据写入仓储管理的暂存缓存目录，返回可用于预览、上传和草稿恢复的文件 URL。
    func stageImageData(_ data: Data, preferredFileExtension: String) async throws -> URL
    /// 清理仓储管理的暂存缓存文件；既有远端对象不会被删除。
    func discardStagedFile(at localURL: URL) async
    /// 校验 URL 是否仍指向仓储管理目录中的有效暂存文件，供自动草稿恢复前过滤失效缓存。
    func isStagedFileAvailable(at localURL: URL) async -> Bool
    /// 使用当前启用配置上传本地文件并返回对象键与远端地址。
    func uploadFile(localURL: URL, prefix: String, progress: (@Sendable (Double) -> Void)?) async throws -> S3UploadResult
    /// 使用调用方提供的稳定对象键上传；仅用于来源内容摘要已经确定的幂等导入。
    func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> S3UploadResult
    /// 校验当前启用配置是否可访问 S3 兼容网关。
    func testCurrentConfiguration() async throws
    /// 删除指定对象键或完整 URL 对应的远端对象。
    func deleteObject(path: String) async throws
    /// 取消当前正在执行的上传请求。
    func cancelCurrentUpload()
}

extension S3UploadRepositoryProtocol {
    /// 测试替身未关心对象键时沿用普通上传；生产实现覆盖此方法以保持稳定对象键。
    func uploadFile(
        localURL: URL,
        objectKey: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> S3UploadResult {
        try await uploadFile(localURL: localURL, prefix: objectKey, progress: progress)
    }
}

/// 阅读日历事件条封面取色仓储
protocol ReadCalendarColorRepositoryProtocol {
    /// 返回最终可渲染颜色：
    /// - resolved: 封面主色提取成功
    /// - failed: 提取失败，已回退哈希色
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> ReadCalendarSegmentColor

    /// 强制重算颜色；不支持强制语义的替身实现可回落到普通读取。
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String,
        forceRefresh: Bool
    ) async -> ReadCalendarSegmentColor

    /// 返回同一次封面量化得到的背景代表色、图表强调色与可读前景色，供沉浸式书籍页面消费。
    func resolveCoverThemeColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> BookCoverThemeColor
}

extension ReadCalendarColorRepositoryProtocol {
    /// 默认兼容既有仓储替身；生产仓储覆写该方法以真正跳过颜色结果缓存。
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String,
        forceRefresh _: Bool
    ) async -> ReadCalendarSegmentColor {
        await resolveEventColor(
            bookId: bookId,
            bookName: bookName,
            coverURL: coverURL
        )
    }

    /// 为既有替身提供兼容实现；生产仓储会覆写并返回完整的代表色与强调色。
    func resolveCoverThemeColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> BookCoverThemeColor {
        let eventColor = await resolveEventColor(
            bookId: bookId,
            bookName: bookName,
            coverURL: coverURL
        )
        return BookCoverThemeColor(
            state: eventColor.state,
            representativeRGBAHex: eventColor.backgroundRGBAHex,
            backgroundRGBAHex: eventColor.backgroundRGBAHex,
            accentRGBAHex: eventColor.backgroundRGBAHex,
            onRepresentativeRGBAHex: eventColor.textRGBAHex
        )
    }
}

/// 统计数据仓储（热力图、阅读统计）
/// 对齐 Android StatisticsRepository.getChartData(year=0)
protocol StatisticsRepositoryProtocol {
    /// 按统计类型与年份获取热力图数据
    /// - Parameters:
    ///   - year: 0 表示全部年份；>0 表示指定自然年
    ///   - dataType: 统计维度（书摘/阅读/全部/打卡）
    /// - Returns: (数据字典, 起始日期, 结束日期)
    ///   - 起始日期为 nil 表示无可用数据
    ///   - 结束日期用于控制图表显示范围（例如指定年份时为该年 12/31）
    func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?)

    /// 获取热力图全量数据（从最早记录到今天）
    /// 返回值：(数据字典, 最早记录日期)；最早日期为 nil 表示无任何阅读记录
    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?)

    /// 获取阅读日历最早可展示日期
    /// - Parameter excludedEventTypes: 需排除的事件类型集合
    /// - Returns: 最早存在阅读行为的日期（startOfDay），无数据则返回 nil
    func fetchReadCalendarEarliestDate(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> Date?

    /// 按月获取阅读日历数据（书籍事件 + 读完标记）
    /// - Parameters:
    ///   - monthStart: 目标月份任意日期（实现内会归一到该月 1 日）
    ///   - excludedEventTypes: 需排除的事件类型集合
    /// - Returns: 月数据（仅包含有活动或读完记录的日期键）
    func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData

    /// 按自然年获取阅读时长 Top 书籍（精确聚合）
    /// - Parameters:
    ///   - year: 自然年（如 2026）
    ///   - excludedEventTypes: 需排除的事件类型集合
    ///   - limit: 返回条数上限
    /// - Returns: 年度阅读时长 Top 书籍（按 readSeconds 降序）
    func fetchReadCalendarYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook]
}

extension StatisticsRepositoryProtocol {
    /// 便捷方法：按“全部年份 + 全部统计维度”返回热力图数据。
    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let result = try await fetchHeatmapData(year: 0, dataType: .all)
        return (result.days, result.earliestDate)
    }

    /// 便捷方法：不排除事件类型时读取阅读日历最早可展示日期。
    func fetchReadCalendarEarliestDate() async throws -> Date? {
        try await fetchReadCalendarEarliestDate(excludedEventTypes: [])
    }

    /// 便捷方法：不排除事件类型时读取指定月份阅读日历数据。
    func fetchReadCalendarMonthData(monthStart: Date) async throws -> ReadCalendarMonthData {
        try await fetchReadCalendarMonthData(monthStart: monthStart, excludedEventTypes: [])
    }

    /// 便捷方法：不排除事件类型时读取年度阅读时长榜。
    func fetchReadCalendarYearTopBooks(year: Int, limit: Int = 10) async throws -> [ReadCalendarMonthlyDurationBook] {
        try await fetchReadCalendarYearTopBooks(
            year: year,
            excludedEventTypes: [],
            limit: limit
        )
    }
}

/// 时间线事件仓储契约，覆盖按时间范围的事件列表查询与日历标记聚合。
protocol TimelineRepositoryProtocol {
    /// 查询指定毫秒时间戳范围内的事件列表，按时间降序排列并按日分组。
    /// - Parameters:
    ///   - startTimestamp: 起始毫秒时间戳（含）
    ///   - endTimestamp: 结束毫秒时间戳（含）
    ///   - category: 事件分类过滤（.all 查全部）
    func fetchTimelineEvents(
        startTimestamp: Int64,
        endTimestamp: Int64,
        category: TimelineEventCategory
    ) async throws -> [TimelineSection]

    /// 聚合指定月份的日历标记（每日活跃状态与阅读进度），供日历 cell 渲染。
    /// - Parameters:
    ///   - monthStart: 目标月份首日
    ///   - category: 事件分类过滤（.all 查全部）
    func fetchCalendarMarkers(
        for monthStart: Date,
        category: TimelineEventCategory
    ) async throws -> [Date: TimelineDayMarker]
}

/// 在读首页仪表盘仓储契约，集中封装首页聚合读取与目标写入。
protocol ReadingDashboardRepositoryProtocol {
    /// 持续观察首页聚合快照；数据库变更或目标调整后会自动刷新。
    func observeDashboard(referenceDate: Date) -> AsyncThrowingStream<ReadingDashboardSnapshot, Error>

    /// 更新指定日期对应的每日阅读目标（秒）。
    func updateDailyReadingGoal(seconds: Int, for date: Date) async throws

    /// 更新指定年份对应的年度阅读目标（本）。
    func updateYearlyReadGoal(count: Int, forYear year: Int) async throws
}

/// 微信读书扫码授权导入仓储契约，统一授权校验、远端抓取、目标书匹配与增量落库。
@MainActor
protocol WereadImportRepositoryProtocol {
    /// MainActor 完成来源补全后提交同目标事务，取消继续向下传播。
    func commitPreviewGroup(_ group: NoteImportCommitGroup) async throws -> NoteImportCommitGroupResult
    /// 为共享预览生成完整来源快照，保留微信读书专用时间和章节语义。
    func makePreviewDrafts(_ books: [WereadImportBook]) -> [NoteImportDraftBook]
    /// 在会员门禁后提交已冻结预览，保留逐书事务和进度回调。
    func commitPreviewImport(books: [NoteImportCommitBook], progress: @escaping (Int, Int) -> Void) async throws
    func fetchPreferences() -> WereadImportPreferences
    func savePreferences(_ preferences: WereadImportPreferences)
    func restoreAuthorization() async -> WereadAuthorization?
    func validateAuthorization(cookieHeader: String) async throws -> WereadAuthorization
    func clearAuthorization() async
    func fetchImportBookIDs(authorization: WereadAuthorization, preferences: WereadImportPreferences) async throws -> [String]
    func fetchImportBooks(
        authorization: WereadAuthorization,
        preferences: WereadImportPreferences,
        progress: @escaping (Int, Int) -> Void,
        warning: @escaping (String) -> Void
    ) async throws -> [WereadImportBook]
    func fetchImportBooks(
        authorization: WereadAuthorization,
        bookIDs: [String],
        importsReadingTime: Bool,
        progress: @escaping (Int, Int) -> Void,
        warning: @escaping (String) -> Void
    ) async throws -> [WereadImportBook]
    func fetchImportBooks(
        authorization: WereadAuthorization,
        bookIDs: [String],
        importsReadingTime: Bool,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [WereadImportBook]
    func matchLocalBooks(_ books: [WereadImportBook]) async throws -> [WereadImportBook]
    func commitImport(
        books: [WereadImportBook],
        progress: @escaping (Int, Int) -> Void
    ) async throws
    func fetchBackfillPrompt() async throws -> WereadBackfillPrompt
    func performBackfill(
        authorization: WereadAuthorization,
        progress: @escaping (WereadBackfillProgress) -> Void
    ) async throws -> WereadBackfillResult
}

/// 全来源书摘导入仓储契约；Parser、API 和特殊入口统一通过 Draft 进入此写入边界。
@MainActor
protocol NoteImportRepositoryProtocol {
    /// 按来源入口恢复额外筛选，不恢复搜索或阅读状态。
    func fetchPreviewPreferences(sourceKey: String) -> NoteImportFilter
    /// 通过仓储持久化最近偏好，不创建命名方案。
    func savePreviewPreferences(_ filter: NoteImportFilter, sourceKey: String) throws
    /// 异步只读评估本地快照，取消后不得应用旧结果。
    func assessImportDuration(targetID: Int64?, drafts: [NoteImportDraftBook]) async throws -> NoteImportDurationAssessment
    /// 异步提交一个目标的全部来源，失败整体回滚，取消仅影响未开始的事务。
    func commitImportGroup(_ group: NoteImportCommitGroup) async throws -> NoteImportCommitGroupResult
    /// 读取命名筛选方案；不恢复上次生效的条件或书籍选择。
    /// 区分来源 ID 匹配和名称候选；MainActor 编排，取消后页面忽略过期结果。
    func previewTargetMatch(for draft: NoteImportDraftBook) async throws -> NoteImportTargetMatch
    func fetchPreviewBookMetadata(id: Int64) async throws -> NoteImportBookMetadata
    func fetchPreviewEditorOptions() async throws -> BookEditorOptions
    /// 从系统文件选择器授予的 security-scoped URL 流式复制 Kindle 文件；32 MiB、4 MiB 空间预留和取消语义与 Android OTG 对齐。
    func loadKindleClippingsFile(from url: URL) async throws -> Data
    /// 通过仓储读取并解析汉王分享页正文；网络取消由调用任务向 URLSession 传播。
    func fetchHanWangShareContent(from sharedURL: String) async throws -> String
    /// 在 MainActor 编排三联凭证恢复；Keychain 访问在专属 actor 执行，页面取消后丢弃快照。
    func loadLifeWeekLoginState() async -> LifeWeekLoginState
    /// 在 MainActor 编排记住偏好更新，专属 actor 串行删除密码并提交偏好；失败保留先前状态。
    func setLifeWeekRemembersPassword(_ enabled: Bool) async throws
    /// 在 MainActor 编排认证与抓取，认证后回报可恢复的存储问题；父任务取消沿请求链传播。
    func fetchLifeWeekBooks(
        phoneNumber: String,
        password: String,
        onAuthenticated: @MainActor @Sendable (String?) -> Void
    ) async throws -> [NoteImportDraftBook]
    func matchLocalBook(for draft: NoteImportDraftBook) async throws -> BookPickerBook?
    /// 按 Android `BookDao.queryByIdSuspend` 语义判断显式导入目标是否存在；软删除记录仍是可解析目标。
    func hasImportTargetBook(id: Int64) async throws -> Bool
    /// 为未匹配本地书籍且非三联来源的新书请求文渠候选；远端失败不得阻断导入。
    func enrichImportBookInfoIfNeeded(
        _ books: [NoteImportCommitBook]
    ) async -> [NoteImportCommitBook]
    func commitImport(
        books: [NoteImportCommitBook],
        progress: @escaping (Int, Int) -> Void
    ) async throws
}

/// 阅读计时仓储契约，统一封装实时计时、结束保存、补录和恢复所需的数据读写。
protocol ReadingTimerRepositoryProtocol {
    /// 读取单本书的计时上下文，供入口、计时页和补录页初始化。
    func fetchBookContext(bookId: Int64) async throws -> ReadingTimerBookContext
    /// 读取全局最新未完成计时，覆盖运行、暂停和停止待保存，供启动恢复和新建互斥检查。
    func fetchActiveSession() async throws -> ReadingTimerSession?
    /// 按记录 ID 读取单段阅读计时。
    func fetchSession(recordId: Int64) async throws -> ReadingTimerSession?
    /// 创建新的运行中计时记录，并把书籍状态推进为在读；`countdownSeconds = 0` 表示正计时。
    func createSession(bookId: Int64, startAt: Date, countdownSeconds: Int64) async throws -> ReadingTimerSession
    /// 持久化运行中快照，用于暂停、继续、停止和后台校准。
    func updateSessionSnapshot(_ input: ReadingTimerSnapshotInput) async throws -> ReadingTimerSession
    /// 继续停止待保存的计时，保留原始开始时间，并把停止间隔累计为暂停时长。
    func resumeStoppedSession(recordId: Int64, resumedAt: Date) async throws -> ReadingTimerSession
    /// 保存停止后的阅读记录，使其进入既有统计消费口径。
    func finishSession(_ input: ReadingTimerFinishInput) async throws -> ReadingTimerSession
    /// 放弃未完成计时，使用软删除避免进入统计并保持同步兼容。
    func discardSession(recordId: Int64) async throws
    /// 保存一条补录阅读记录，支持日期时长与精确起止两种模式。
    func saveSupplement(_ input: ReadingTimerSupplementInput) async throws -> Int64
}
