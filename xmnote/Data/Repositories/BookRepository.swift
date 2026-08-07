import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接
 * [OUTPUT]: 对外提供 BookRepository（BookRepositoryProtocol 的 GRDB 实现，含书架列表读写、单本评分、书架/书单显示设置、分组移入移出、书单加入、书单书籍元信息编辑、批量编辑、删除与重命名管理）
 * [POS]: Data 层书籍仓储实现，统一封装书架列表/详情/书摘数据读取、默认书架分组预览排序与默认书架排序置顶写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍仓储实现，负责书架、详情与书摘订阅查询。
struct BookRepository: BookRepositoryProtocol {
    private let databaseManager: DatabaseManager
    nonisolated private let displaySettingStore: BookshelfDisplaySettingStore
    nonisolated private let bookCollectionDisplaySettingStore: BookCollectionDisplaySettingStore

    /// 注入数据库管理器，供书架、详情和书摘查询复用同一数据源。
    init(
        databaseManager: DatabaseManager,
        displaySettingStore: BookshelfDisplaySettingStore = .shared,
        bookCollectionDisplaySettingStore: BookCollectionDisplaySettingStore = .shared
    ) {
        self.databaseManager = databaseManager
        self.displaySettingStore = displaySettingStore
        self.bookCollectionDisplaySettingStore = bookCollectionDisplaySettingStore
    }

    /// 为书架页提供可持续订阅的数据流，任意书籍或笔记变更后会自动刷新列表。
    func observeBooks() -> AsyncThrowingStream<[BookItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try BookReadQuery.fetchBooks(db)
        }
    }

    /// 为首页书架提供书籍与分组混排订阅，本轮只读默认书架，不触发任何排序或置顶写入。
    func observeBookshelf(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<[BookshelfItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            let rows = try BookshelfBookAggregateQuery.fetchAllRows(db)
            return try fetchBookshelf(
                db,
                rows: rows,
                setting: setting,
                searchKeyword: searchKeyword
            )
        }
    }

    /// 为首页书架提供多维度只读快照，本轮仅聚合展示数据，不触发任何数据库写入。
    func observeBookshelfSnapshot(
        settingsByDimension: [BookshelfDimension: BookshelfDisplaySetting],
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookshelfSnapshot(
                db,
                settingsByDimension: settingsByDimension,
                searchKeyword: searchKeyword
            )
        }
    }

    /// 为首页书架聚合维度提供可持续订阅的数据流。
    func observeBookshelfAggregateSnapshot(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfAggregateSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookshelfSnapshot(
                db,
                settingsByDimension: [
                    .default: BookshelfDisplaySetting.defaultValue(for: .default),
                    .status: setting,
                    .tag: setting,
                    .source: setting,
                    .rating: setting,
                    .author: setting,
                    .press: setting
                ],
                searchKeyword: searchKeyword
            ).aggregateSnapshot
        }
    }

    /// 为聚合二级列表提供可持续订阅的数据流。
    func observeBookshelfBookList(
        context: BookshelfListContext,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfBookListSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookshelfBookList(
                db,
                context: context,
                setting: setting,
                searchKeyword: searchKeyword
            )
        }
    }

    /// 按最终展示顺序提交书架排序，不更新时间戳，避免制造 Android 不会产生的同步事件。
    func updateBookshelfOrder(_ orderedItems: [BookshelfOrderItem]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateBookshelfOrder(db, orderedItems: orderedItems)
        }
    }

    /// 按最终展示顺序提交标签、来源或阅读状态排序。
    func updateBookshelfAggregateOrder(
        context: BookshelfAggregateOrderContext,
        orderedIDs: [Int64]
    ) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateBookshelfAggregateOrder(db, context: context, orderedIDs: orderedIDs)
        }
    }

    /// 按最终组内顺序提交默认分组二级列表排序，不更新时间戳。
    func updateBooksInGroupOrder(groupID: Int64, orderedBookIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateBooksInGroupOrder(db, groupID: groupID, orderedBookIDs: orderedBookIDs)
        }
    }

    /// 批量置顶默认分组内书籍，按 Android 组内最大 pin_order 追加。
    func pinBooksInGroup(groupID: Int64, bookIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try pinBooksInGroup(db, groupID: groupID, bookIDs: bookIDs)
        }
    }

    /// 批量取消默认分组内书籍置顶，不更新时间戳。
    func unpinBooksInGroup(bookIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            for bookID in bookIDs {
                try updateBookPin(db, bookID: bookID, pinned: false, pinOrder: 0)
            }
        }
    }

    /// 将默认分组内选中普通书籍移动到普通区最前，置顶区保持不变。
    func moveBooksInGroupToStart(
        _ bookIDs: [Int64],
        groupID: Int64,
        currentItems: [BookshelfBookListOrderItem]
    ) async throws {
        let orderedIDs = reorderedBookListItems(bookIDs, in: currentItems, placement: .start).map(\.id)
        try await updateBooksInGroupOrder(groupID: groupID, orderedBookIDs: orderedIDs)
    }

    /// 将默认分组内选中普通书籍移动到普通区最后，置顶区保持不变。
    func moveBooksInGroupToEnd(
        _ bookIDs: [Int64],
        groupID: Int64,
        currentItems: [BookshelfBookListOrderItem]
    ) async throws {
        let orderedIDs = reorderedBookListItems(bookIDs, in: currentItems, placement: .end).map(\.id)
        try await updateBooksInGroupOrder(groupID: groupID, orderedBookIDs: orderedIDs)
    }

    /// 读取二级列表批量编辑 Sheet 所需选项，并在单本选择时补齐当前值。
    func fetchBookshelfBatchEditOptions(bookIDs: [Int64]) async throws -> BookshelfBatchEditOptions {
        try await databaseManager.database.dbPool.read { db in
            try fetchBookshelfBatchEditOptions(db, bookIDs: bookIDs)
        }
    }

    /// 批量设置书籍标签：单本替换，多本追加缺失。
    func batchSetBooksTags(bookIDs: [Int64], tagIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try batchSetBooksTags(db, bookIDs: bookIDs, tagIDs: tagIDs)
        }
    }

    /// 批量更新书籍来源。
    func batchSetBooksSource(bookIDs: [Int64], sourceID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try batchSetBooksSource(db, bookIDs: bookIDs, sourceID: sourceID)
        }
    }

    /// 新建书籍分组，供批量移组 Sheet 在当前面板内直接创建并回填选中项。
    func createGroup(named name: String) async throws -> BookEditorNamedOption {
        try await databaseManager.database.dbPool.write { db in
            try createGroup(db, name: name)
        }
    }

    /// 新建书籍标签，供批量标签 Sheet 在当前面板内直接创建并回填选中项。
    func createTag(named name: String) async throws -> BookEditorNamedOption {
        try await databaseManager.database.dbPool.write { db in
            try createTag(db, name: name)
        }
    }

    /// 新建书籍来源，供批量来源 Sheet 在当前面板内直接创建并回填选中项。
    func createSource(named name: String) async throws -> BookshelfSourceOption {
        try await databaseManager.database.dbPool.write { db in
            try createSource(db, name: name)
        }
    }

    /// 批量设置阅读状态，读完状态同步评分与阅读进度。
    func batchSetBookReadStatus(bookIDs: [Int64], input: BookshelfBatchReadStatusInput) async throws {
        try await databaseManager.database.dbPool.write { db in
            try batchSetBookReadStatus(db, bookIDs: bookIDs, input: input)
        }
    }

    /// 读取二级列表移入分组候选项。
    func fetchBookshelfMoveTargetGroups(excludingGroupID: Int64?) async throws -> [BookshelfMoveGroupOption] {
        try await databaseManager.database.dbPool.read { db in
            try fetchMoveTargetGroups(db, excludingGroupID: excludingGroupID)
        }
    }

    /// 读取可作为“加入书单”目标的手动书单，排除年度书单。
    func fetchManualBookCollections() async throws -> [BookCollectionSummary] {
        try await databaseManager.database.dbPool.read { db in
            try fetchManualBookCollections(db)
        }
    }

    /// 持续监听书单列表快照，并按 collection 类型拆分手动书单与年度书单。
    func observeBookCollectionList() -> AsyncThrowingStream<BookCollectionListSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookCollectionListSnapshot(db)
        }
    }

    /// 持续监听指定书单详情，详情页打开期间 collection 或 relation 变化会自动刷新。
    func observeBookCollectionDetail(collectionID: Int64) -> AsyncThrowingStream<BookCollectionDetail?, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookCollectionDetail(db, collectionID: collectionID)
        }
    }

    /// 扫描有效书籍并按读完历史修复年度书单关系，用于 Android 历史数据迁移后的首轮读取补齐。
    func repairAnnualBookCollections() async throws {
        try await databaseManager.database.dbPool.write { db in
            try repairAnnualBookCollections(db)
        }
    }

    /// 新建手动书单，供加入书单 Sheet 在面板内直接创建并回填选中项。
    func createBookCollection(title: String) async throws -> BookCollectionSummary {
        try await databaseManager.database.dbPool.write { db in
            try createBookCollection(db, title: title)
        }
    }

    /// 新建手动书单并写入标题与简介。
    func createBookCollection(input: BookCollectionFormInput) async throws -> BookCollectionListItem {
        try await databaseManager.database.dbPool.write { db in
            let collectionID = try createBookCollection(db, input: input)
            guard let item = try fetchBookCollectionListItem(db, collectionID: collectionID) else {
                throw BookshelfBatchWriteError.invalidCollection
            }
            return item
        }
    }

    /// 编辑手动书单标题与简介。
    func updateBookCollection(collectionID: Int64, input: BookCollectionFormInput) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateBookCollection(db, collectionID: collectionID, input: input)
        }
    }

    /// 删除手动书单及其全部 relation。
    func deleteBookCollection(collectionID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteBookCollection(db, collectionID: collectionID)
        }
    }

    /// 写入手动书单最终排序。
    func updateManualBookCollectionOrder(_ collectionIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateManualBookCollectionOrder(db, collectionIDs: collectionIDs)
        }
    }

    /// 批量加入书单，已有有效关系不会重复插入。
    func addBooks(_ bookIDs: [Int64], toCollection collectionID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try addBooksToCollection(db, bookIDs: bookIDs, collectionID: collectionID)
        }
    }

    /// 将本地书或远端草稿加入手动书单；远端草稿按 Android 书单占位书语义落库。
    func addBookSelections(
        _ selections: [BookCollectionBookSelectionInput],
        toCollection collectionID: Int64
    ) async throws {
        try await databaseManager.database.dbPool.write { db in
            try addBookSelectionsToCollection(db, selections: selections, collectionID: collectionID)
        }
    }

    /// 将书单占位书恢复到书架，保留原有书单 relation 与 relation 文本。
    func restoreCollectionPlaceholderBook(bookID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try restoreCollectionPlaceholderBook(db, bookID: bookID)
        }
    }

    /// 从书单内移除指定 relation。
    func removeBooksFromCollection(collectionBookIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try removeBooksFromCollection(db, collectionBookIDs: collectionBookIDs)
        }
    }

    /// 写入书单内 relation 最终排序。
    func updateBooksInCollectionOrder(collectionID: Int64, relationIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateBooksInCollectionOrder(db, collectionID: collectionID, relationIDs: relationIDs)
        }
    }

    /// 编辑书单内推荐语。
    func updateCollectionBookRecommend(collectionBookID: Int64, recommend: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateCollectionBookRecommend(db, collectionBookID: collectionBookID, recommend: recommend)
        }
    }

    /// 编辑书单内单本书籍元信息与 relation 收藏理由，保持 Android 双表写入事务语义。
    func updateCollectionBookMetadata(_ input: BookCollectionBookMetadataEditInput) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateCollectionBookMetadata(db, input: input)
        }
    }

    /// 更新年度书单本体说明，不开放年度标题、成员和排序写入。
    func updateAnnualBookCollectionDescription(collectionID: Int64, description: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateAnnualBookCollectionDescription(db, collectionID: collectionID, description: description)
        }
    }

    /// 解析微信读书书单链接，返回导入预览。
    func parseWereadBookCollectionImport(link: String) async throws -> BookCollectionImportPreview {
        try await parseWereadBookCollectionImportPreview(link: link)
    }

    /// 保存微信读书导入预览，单事务创建书单与占位书关系。
    func saveWereadBookCollectionImport(_ preview: BookCollectionImportPreview) async throws -> BookCollectionListItem {
        try await databaseManager.database.dbPool.write { db in
            let collectionID = try saveWereadBookCollectionImport(db, preview: preview)
            guard let item = try fetchBookCollectionListItem(db, collectionID: collectionID) else {
                throw BookshelfBatchWriteError.invalidCollection
            }
            return item
        }
    }

    /// 读取当前书单导出与分享所需快照。
    func fetchBookCollectionExportSnapshot(collectionID: Int64) async throws -> BookCollectionDetail {
        try await databaseManager.database.dbPool.read { db in
            guard let detail = try fetchBookCollectionDetail(db, collectionID: collectionID) else {
                throw BookshelfBatchWriteError.invalidCollection
            }
            return detail
        }
    }

    /// 将书籍从分组移回默认书架，按 Android placement 语义写入默认排序值。
    func moveBooksOutOfGroup(bookIDs: [Int64], placement: GroupBooksPlacement) async throws {
        try await databaseManager.database.dbPool.write { db in
            try moveBooksOutOfGroup(db, bookIDs: bookIDs, placement: placement)
        }
    }

    /// 按选择顺序批量置顶 Book/Group，跳过 Android 同样会忽略的已置顶项。
    func pinBookshelfItems(_ ids: [BookshelfItemID]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try pinBookshelfItems(db, ids: ids)
        }
    }

    /// 取消单个 Book/Group 置顶状态，不更新时间戳。
    func unpinBookshelfItem(_ id: BookshelfItemID) async throws {
        try await databaseManager.database.dbPool.write { db in
            try unpinBookshelfItem(db, id: id)
        }
    }

    /// 将选中普通项移动到普通区最前，置顶区不参与移动。
    func moveBookshelfItemsToStart(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem]
    ) async throws {
        let orderedItems = reorderedBookshelfItems(ids, in: currentItems, placement: .start)
        try await updateBookshelfOrder(orderedItems)
    }

    /// 将选中普通项移动到普通区最后，置顶区不参与移动。
    func moveBookshelfItemsToEnd(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem]
    ) async throws {
        let orderedItems = reorderedBookshelfItems(ids, in: currentItems, placement: .end)
        try await updateBookshelfOrder(orderedItems)
    }

    /// 删除默认书架条目，Book 走软删除级联清理，Group 先安置组内书籍再软删除。
    func deleteBookshelfItems(
        _ ids: [BookshelfItemID],
        groupBooksPlacement: GroupBooksPlacement
    ) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteBookshelfItems(db, ids: ids, groupBooksPlacement: groupBooksPlacement)
        }
    }

    /// 将书籍移入目标分组，复刻 Android GroupRepository.moveBooksToGroup 语义。
    func moveBooks(_ bookIDs: [Int64], toGroup targetGroupID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try moveBooksToGroup(db, bookIDs: bookIDs, targetGroupID: targetGroupID)
        }
    }

    /// 软删除指定书籍及其 Android 对齐关联数据。
    func deleteBooks(_ bookIDs: [Int64]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteBooks(db, bookIDs: bookIDs)
        }
    }

    /// 删除指定分组，先将组内书籍移回默认书架。
    func deleteGroup(groupID: Int64, placement: GroupBooksPlacement) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteGroup(db, groupID: groupID, placement: placement)
        }
    }

    /// 重命名分组，更新时间戳以便后续同步层感知变更。
    func renameGroup(groupID: Int64, newName: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try renameGroup(db, groupID: groupID, newName: newName)
        }
    }

    /// 重命名书籍标签，执行 Android 同等重名校验。
    func renameTag(tagID: Int64, newName: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try renameTag(db, tagID: tagID, newName: newName)
        }
    }

    /// 删除书籍标签，并清理标签与书籍/笔记关系。
    func deleteTag(tagID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteTag(db, tagID: tagID)
        }
    }

    /// 重命名书籍来源，执行 Android 同等重名校验。
    func renameSource(sourceID: Int64, newName: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try renameSource(db, sourceID: sourceID, newName: newName)
        }
    }

    /// 删除书籍来源，并把书籍迁移到未知来源。
    func deleteSource(sourceID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteSource(db, sourceID: sourceID)
        }
    }

    /// 重命名作者资料并同步更新书籍 author 字段。
    func renameAuthor(oldName: String, newName: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try renameAuthor(db, oldName: oldName, newName: newName)
        }
    }

    /// 删除作者维度下的所有有效书籍，并按 Android 语义硬删除作者资料行。
    func deleteAuthor(name: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteAuthor(db, name: name)
        }
    }

    /// 重命名出版社资料并同步更新书籍 press 字段。
    func renamePress(oldName: String, newName: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try renamePress(db, oldName: oldName, newName: newName)
        }
    }

    /// 删除出版社维度下的所有有效书籍，并按 Android 语义硬删除出版社资料行。
    func deletePress(name: String) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deletePress(db, name: name)
        }
    }

    /// 从本地轻量设置读取各书架维度显示配置。
    func fetchBookshelfDisplaySettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting] {
        displaySettingStore.fetchSettings(scope: scope)
    }

    /// 保存单个维度的书架显示配置。
    func saveBookshelfDisplaySetting(
        _ setting: BookshelfDisplaySetting,
        for dimension: BookshelfDimension,
        scope: BookshelfDisplaySettingScope
    ) {
        displaySettingStore.save(setting, for: dimension, scope: scope)
    }

    /// 观察书架显示设置变化，供默认书架在二级分组排序偏好变更后重建只读快照。
    func observeBookshelfDisplaySettingChanges(
        scope: BookshelfDisplaySettingScope,
        dimension: BookshelfDimension
    ) -> AsyncStream<Void> {
        displaySettingStore.observeChanges(scope: scope, dimension: dimension)
    }

    /// 从本地轻量设置读取书单首页显示配置。
    func fetchBookCollectionDisplaySetting() -> BookCollectionDisplaySetting {
        bookCollectionDisplaySettingStore.fetchSetting()
    }

    /// 保存书单首页显示配置。
    func saveBookCollectionDisplaySetting(_ setting: BookCollectionDisplaySetting) {
        bookCollectionDisplaySettingStore.save(setting)
    }

    /// 为书籍详情页提供单书订阅流，用于展示基础信息、阅读状态和笔记统计。
    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try BookReadQuery.fetchBook(db, bookId: bookId)
        }
    }

    /// 为书籍详情页提供书摘订阅流，保障新增/删除书摘后列表实时更新。
    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try BookReadQuery.fetchNotes(db, bookId: bookId)
        }
    }

    /// 更新单本有效书籍评分；参数必须是 0...50 范围内的半星刻度，写入后详情与书评观察流会自动刷新。
    func updateBookRating(bookId: Int64, score: Int64) async throws {
        guard (0...50).contains(score), score.isMultiple(of: 5) else {
            throw BookRatingWriteError.invalidScore
        }
        let updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
            try BookReadStatusMutation.updateBookRating(
                db,
                bookID: bookId,
                ratingScore: score,
                updatedAt: updatedAt
            )
            guard db.changesCount > 0 else {
                throw BookRatingWriteError.bookUnavailable
            }
        }
    }

    /// 读取本地书籍选择结果，支持标题/作者/ISBN 关键字筛选。
    func fetchPickerBooks(matching query: String) async throws -> [BookPickerBook] {
        try await databaseManager.database.dbPool.read { db in
            try BookReadQuery.fetchPickerBooks(db, matching: query)
        }
    }

    /// 解析单本本地书籍，供创建成功后的选择流回填。
    func fetchPickerBook(bookId: Int64) async throws -> BookPickerBook? {
        try await databaseManager.database.dbPool.read { db in
            try BookReadQuery.fetchPickerBook(db, bookId: bookId)
        }
    }
}

/// 单本评分写入的可行动错误，避免无效刻度或失效书籍被静默忽略。
private nonisolated enum BookRatingWriteError: LocalizedError {
    case invalidScore
    case bookUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidScore:
            return "评分必须在 0 到 5 星之间，并以半星为步进"
        case .bookUnavailable:
            return "书籍不存在、已被删除，或暂时无法评分"
        }
    }
}
