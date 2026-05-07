import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接
 * [OUTPUT]: 对外提供 BookRepository（BookRepositoryProtocol 的 GRDB 实现，含书架列表读写、分组移入移出、批量编辑、删除与重命名管理）
 * [POS]: Data 层书籍仓储实现，统一封装书架列表/详情/书摘数据读取与默认书架排序置顶写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍仓储实现，负责书架、详情与书摘订阅查询。
struct BookRepository: BookRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let displaySettingStore: BookshelfDisplaySettingStore

    /// 注入数据库管理器，供书架、详情和书摘查询复用同一数据源。
    init(
        databaseManager: DatabaseManager,
        displaySettingStore: BookshelfDisplaySettingStore = .shared
    ) {
        self.databaseManager = databaseManager
        self.displaySettingStore = displaySettingStore
    }

    /// 为书架页提供可持续订阅的数据流，任意书籍或笔记变更后会自动刷新列表。
    func observeBooks() -> AsyncThrowingStream<[BookItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBooks(db)
        }
    }

    /// 为首页书架提供书籍与分组混排订阅，本轮只读默认书架，不触发任何排序或置顶写入。
    func observeBookshelf(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<[BookshelfItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookshelf(db, setting: setting, searchKeyword: searchKeyword)
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

    /// 批量设置阅读状态，读完状态同步评分与阅读进度。
    func batchSetBookReadStatus(bookIDs: [Int64], input: BookshelfBatchReadStatusInput) async throws {
        try await databaseManager.database.dbPool.write { db in
            try batchSetBookReadStatus(db, bookIDs: bookIDs, input: input)
        }
    }

    /// 读取二级列表移入分组候选项。
    func fetchBookshelfMoveTargetGroups(excludingGroupID: Int64?) async throws -> [BookEditorNamedOption] {
        try await databaseManager.database.dbPool.read { db in
            try fetchMoveTargetGroups(db, excludingGroupID: excludingGroupID)
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

    /// 为书籍详情页提供单书订阅流，用于展示基础信息、阅读状态和笔记统计。
    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBook(db, bookId: bookId)
        }
    }

    /// 为书籍详情页提供书摘订阅流，保障新增/删除书摘后列表实时更新。
    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchNotes(db, bookId: bookId)
        }
    }

    /// 读取本地书籍选择结果，支持标题/作者/ISBN 关键字筛选。
    func fetchPickerBooks(matching query: String) async throws -> [BookPickerBook] {
        try await databaseManager.database.dbPool.read { db in
            try fetchPickerBooks(db, matching: query)
        }
    }

    /// 解析单本本地书籍，供创建成功后的选择流回填。
    func fetchPickerBook(bookId: Int64) async throws -> BookPickerBook? {
        try await databaseManager.database.dbPool.read { db in
            try fetchPickerBook(db, bookId: bookId)
        }
    }
}

/// 书架显示设置的本地轻量持久化入口，保持 ViewModel 只经 Repository 获取本地数据。
struct BookshelfDisplaySettingStore {
    static let shared = BookshelfDisplaySettingStore()

    private let defaults: UserDefaults
    private let mainKey = "bookshelf.display.settings.v1"
    private let bookListKey = "bookshelf.book-list.display.settings.v1"

    /// 注入 UserDefaults，默认使用标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取全部维度设置；缺失或解码失败时回退到各作用域默认值。
    func fetchSettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting] {
        let fallback = Self.defaultSettings(scope: scope)
        guard let data = defaults.data(forKey: key(for: scope)),
              let decoded = try? JSONDecoder().decode([BookshelfDimension: BookshelfDisplaySetting].self, from: data) else {
            return fallback
        }
        return fallback.merging(decoded) { _, stored in stored }
    }

    /// 保存指定维度设置。
    func save(_ setting: BookshelfDisplaySetting, for dimension: BookshelfDimension, scope: BookshelfDisplaySettingScope) {
        var settings = fetchSettings(scope: scope)
        settings[dimension] = setting
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(for: scope))
    }

    private func key(for scope: BookshelfDisplaySettingScope) -> String {
        switch scope {
        case .main:
            return mainKey
        case .bookList:
            return bookListKey
        }
    }

    private static func defaultSettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting] {
        Dictionary(uniqueKeysWithValues: BookshelfDimension.allCases.map {
            switch scope {
            case .main:
                return ($0, BookshelfDisplaySetting.defaultValue(for: $0))
            case .bookList:
                return ($0, BookshelfDisplaySetting.defaultBookListValue(for: $0))
            }
        })
    }
}

nonisolated private struct IndexedBookshelfItem {
    let item: BookshelfItem
    let sourceIndex: Int
}

nonisolated private struct BookshelfGroupBookPreview {
    let id: Int64
    let name: String
    let author: String
    let readStatusName: String
    let sourceName: String
    let cover: String
    let noteCount: Int
    let createdDate: Int64
    let modifiedDate: Int64
    let publishDate: Int64
    let score: Int64
    let readDoneDate: Int64
    let totalReadingTime: Int64
    let readingProgress: Double?
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
}

nonisolated private struct BookshelfGroupBuilder {
    let id: Int64
    let name: String
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
    let createdDate: Int64
    private(set) var books: [BookshelfGroupBookPreview]

    mutating func append(_ book: BookshelfGroupBookPreview) {
        guard !books.contains(where: { $0.id == book.id }) else { return }
        books.append(book)
    }

    func makeItem(searchKeyword: String = "") -> BookshelfItem? {
        let sortedBooks = sortBooksByAndroidCustomOrder(books)
        let normalizedKeyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGroupMatched = normalizedKeyword.isEmpty || name.localizedCaseInsensitiveContains(normalizedKeyword)
        let visibleBooks = isGroupMatched ? sortedBooks : sortedBooks.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedKeyword)
                || $0.author.localizedCaseInsensitiveContains(normalizedKeyword)
                || $0.readStatusName.localizedCaseInsensitiveContains(normalizedKeyword)
                || $0.sourceName.localizedCaseInsensitiveContains(normalizedKeyword)
        }
        guard !visibleBooks.isEmpty else { return nil }
        let payload = BookshelfGroupPayload(
            id: id,
            name: name,
            bookCount: visibleBooks.count,
            representativeCovers: visibleBooks.prefix(6).map(\.cover),
            books: visibleBooks.map { $0.listItem }
        )
        return BookshelfItem(
            id: .group(id),
            pinned: pinned,
            pinOrder: pinOrder,
            sortOrder: sortOrder,
            sortMetadata: BookshelfItemSortMetadata(
                createdDate: createdDate,
                modifiedDate: books.map(\.modifiedDate).max() ?? createdDate,
                publishDate: 0,
                noteCount: visibleBooks.reduce(0) { $0 + $1.noteCount },
                rating: visibleBooks.map(\.score).max() ?? 0,
                readDoneDate: visibleBooks.map(\.readDoneDate).max() ?? 0,
                totalReadingTime: visibleBooks.reduce(0) { $0 + $1.totalReadingTime },
                readingProgress: nil,
                bookCount: visibleBooks.count
            ),
            content: .group(payload)
        )
    }

    private func sortBooksByAndroidCustomOrder(_ books: [BookshelfGroupBookPreview]) -> [BookshelfGroupBookPreview] {
        let pinnedBooks = books.filter(\.pinned).sorted { lhs, rhs in
            if lhs.pinOrder != rhs.pinOrder {
                return lhs.pinOrder > rhs.pinOrder
            }
            return lhs.id < rhs.id
        }
        let notPinnedBooks = books.filter { !$0.pinned }.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.id < rhs.id
        }
        return pinnedBooks + notPinnedBooks
    }
}

private extension BookshelfGroupBookPreview {
    nonisolated var listItem: BookshelfBookListItem {
        BookshelfBookListItem(
            id: id,
            title: name,
            author: author,
            cover: cover,
            noteCount: noteCount,
            pinned: pinned
        )
    }
}

private extension String {
    nonisolated var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum BookshelfBatchWriteError: LocalizedError {
    case emptySelection
    case invalidGroup
    case invalidTag
    case invalidSource
    case invalidReadStatus
    case ratingRequired
    case invalidName(String)
    case duplicateName(String)
    case protectedDefaultSource

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "请先选择书籍"
        case .invalidGroup:
            return "分组已不存在，请刷新后重试"
        case .invalidTag:
            return "标签已不存在，请刷新后重试"
        case .invalidSource:
            return "来源已不存在，请刷新后重试"
        case .invalidReadStatus:
            return "阅读状态已不存在，请刷新后重试"
        case .ratingRequired:
            return "标记读完时需要选择评分"
        case .invalidName(let target):
            return "\(target)名称不能为空"
        case .duplicateName(let message):
            return message
        case .protectedDefaultSource:
            return "未知来源不能删除"
        }
    }
}

nonisolated private struct BookshelfBookAggregateRow {
    let payload: BookshelfBookPayload
    let press: String
    let readStatusOrder: Int64
    let sourceOrder: Int64
    let sourceIsHidden: Bool
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
    let createdDate: Int64
    let modifiedDate: Int64
    let publishDate: Int64
    let readDoneDate: Int64
    let totalReadingTime: Int64
    let readingProgress: Double?
}

nonisolated private struct BookshelfTagInfo: Hashable {
    let id: Int64
    let name: String
    let order: Int64
}

nonisolated private struct BookshelfStatusKey: Hashable {
    let id: Int64
    let title: String
    let order: Int64
}

nonisolated private struct BookshelfDisplaySectionKey: Hashable {
    let id: String
    let title: String
}

nonisolated private struct BookshelfBatchEditInitialValues: Hashable {
    let tagIDs: [Int64]
    let sourceID: Int64?
    let readStatusID: Int64?
    let readStatusChangedAt: Int64?
    let ratingScore: Int64?
}

nonisolated private enum BookshelfMovePlacement {
    case start
    case end
}

private extension BookRepository {
    /// 按 Android `updateBookDataListOrder` 语义顺序更新 Book/Group order 字段。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func updateBookshelfOrder(
        _ db: Database,
        orderedItems: [BookshelfOrderItem]
    ) throws {
        for (index, item) in orderedItems.enumerated() {
            let order = Int64(index)
            switch item.id {
            case .book(let id):
                try updateBookOrder(db, id: id, order: order)
            case .group(let id):
                try updateGroupOrder(db, id: id, order: order)
            }
        }
    }

    /// 按 Android 聚合维度顺序写入对应 order 字段，不更新时间戳。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func updateBookshelfAggregateOrder(
        _ db: Database,
        context: BookshelfAggregateOrderContext,
        orderedIDs: [Int64]
    ) throws {
        for (index, id) in orderedIDs.enumerated() {
            switch context {
            case .readStatus:
                try updateReadStatusOrder(db, id: id, order: Int64(index))
            case .tag:
                try updateTagOrder(db, id: id, order: Int64(index))
            case .source:
                try updateSourceOrder(db, id: id, order: Int64(index))
            }
        }
    }

    /// 按 Android `updateBookListOrder` 语义写入默认分组二级列表的组内顺序。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func updateBooksInGroupOrder(
        _ db: Database,
        groupID: Int64,
        orderedBookIDs: [Int64]
    ) throws {
        let validIDs = try fetchOrderedBookIDs(inGroup: groupID, db: db)
        let validIDSet = Set(validIDs)
        let uniqueOrderedIDs = orderedBookIDs.reduce(into: [Int64]()) { result, id in
            guard validIDSet.contains(id), !result.contains(id) else { return }
            result.append(id)
        }
        let missingIDs = validIDs.filter { !uniqueOrderedIDs.contains($0) }
        for (index, id) in (uniqueOrderedIDs + missingIDs).enumerated() {
            try updateBookOrder(db, id: id, order: Int64(index))
        }
    }

    /// 按默认分组当前顺序计算移到最前/最后后的完整书籍顺序，置顶书籍保持前缀顺序。
    nonisolated func reorderedBookListItems(
        _ ids: [Int64],
        in currentItems: [BookshelfBookListOrderItem],
        placement: BookshelfMovePlacement
    ) -> [BookshelfBookListOrderItem] {
        let selectedIDSet = Set(ids)
        let pinnedItems = currentItems.filter(\.isPinned)
        let normalItems = currentItems.filter { !$0.isPinned }
        let normalByID = Dictionary(uniqueKeysWithValues: normalItems.map { ($0.id, $0) })
        let selectedItems = ids.compactMap { normalByID[$0] }
        let remainingItems = normalItems.filter { !selectedIDSet.contains($0.id) }

        switch placement {
        case .start:
            return pinnedItems + selectedItems + remainingItems
        case .end:
            return pinnedItems + remainingItems + selectedItems
        }
    }

    /// 按 Android 组内置顶语义，使用当前分组内最大 pin_order 作为追加起点。
    /// - Throws: 任一 SQL 读取或写入失败时抛出错误。
    nonisolated func pinBooksInGroup(
        _ db: Database,
        groupID: Int64,
        bookIDs: [Int64]
    ) throws {
        let validIDs = try fetchOrderedBookIDs(inGroup: groupID, db: db)
        let validIDSet = Set(validIDs)
        var nextPinOrder = try maxBookPinOrder(inGroup: groupID, db: db)
        for bookID in bookIDs where validIDSet.contains(bookID) {
            guard try !isBookPinned(db, bookID: bookID) else { continue }
            nextPinOrder += 1
            try updateBookPin(db, bookID: bookID, pinned: true, pinOrder: nextPinOrder)
        }
    }

    /// 批量置顶 Book/Group，使用 Book 与 Group 的全局最大 pin_order 作为追加起点。
    /// - Throws: 任一 SQL 读取或写入失败时抛出错误。
    nonisolated func pinBookshelfItems(
        _ db: Database,
        ids: [BookshelfItemID]
    ) throws {
        var nextPinOrder = try maxBookshelfPinOrder(db)
        for id in ids {
            guard try !isBookshelfItemPinned(db, id: id) else { continue }
            nextPinOrder += 1
            try updateBookshelfPin(db, id: id, pinned: true, pinOrder: nextPinOrder)
        }
    }

    /// 读取批量编辑候选项，单本选择时补齐该书当前值。
    /// - Throws: 任一 SQL 读取失败时抛出错误。
    nonisolated func fetchBookshelfBatchEditOptions(
        _ db: Database,
        bookIDs: [Int64]
    ) throws -> BookshelfBatchEditOptions {
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        let initialValues = uniqueBookIDs.count == 1
            ? try fetchBatchEditInitialValues(db, bookID: uniqueBookIDs[0])
            : nil
        return BookshelfBatchEditOptions(
            tags: try fetchBatchBookTagOptions(db, ownerID: ownerID),
            sources: try fetchBatchSourceOptions(db),
            readStatuses: try fetchBatchReadStatusOptions(db),
            initialTagIDs: initialValues?.tagIDs ?? [],
            initialSourceID: initialValues?.sourceID,
            initialReadStatusID: initialValues?.readStatusID,
            initialReadStatusChangedAt: initialValues?.readStatusChangedAt,
            initialRatingScore: initialValues?.ratingScore
        )
    }

    /// 按 Android 批量标签语义写入：单本替换全部标签，多本只追加缺失标签。
    /// - Throws: 选择为空、标签无效或 SQL 写入失败时抛出错误。
    nonisolated func batchSetBooksTags(
        _ db: Database,
        bookIDs: [Int64],
        tagIDs: [Int64]
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }

        let uniqueTagIDs = normalizedPositiveIDs(tagIDs)
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        let activeTagIDs = try fetchActiveBookTagIDs(db, ownerID: ownerID)
        guard Set(uniqueTagIDs).isSubset(of: activeTagIDs) else { throw BookshelfBatchWriteError.invalidTag }

        let now = timestampMillis()
        if uniqueBookIDs.count == 1, let bookID = uniqueBookIDs.first {
            try softDeleteTags(ofBook: bookID, updatedAt: now, db: db)
            for tagID in uniqueTagIDs {
                try insertTagBook(bookID: bookID, tagID: tagID, createdAt: now, db: db)
            }
            return
        }

        guard !uniqueTagIDs.isEmpty else { return }
        for bookID in uniqueBookIDs {
            let existingTagIDs = try fetchActiveTagIDs(ofBook: bookID, db: db)
            for tagID in uniqueTagIDs where !existingTagIDs.contains(tagID) {
                try insertTagBook(bookID: bookID, tagID: tagID, createdAt: now, db: db)
            }
        }
    }

    /// 按 Android `batchSetBooksSource` 语义批量更新书籍来源。
    /// - Throws: 选择为空、来源无效或 SQL 写入失败时抛出错误。
    nonisolated func batchSetBooksSource(
        _ db: Database,
        bookIDs: [Int64],
        sourceID: Int64
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveSource(db, sourceID: sourceID) else { throw BookshelfBatchWriteError.invalidSource }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            try updateBookSource(db, bookID: bookID, sourceID: sourceID, updatedAt: now)
        }
    }

    /// 按 Android `updateBookReadStatus` 与 `rating` 语义批量更新阅读状态。
    /// - Throws: 选择为空、状态无效、读完未评分或 SQL 写入失败时抛出错误。
    nonisolated func batchSetBookReadStatus(
        _ db: Database,
        bookIDs: [Int64],
        input: BookshelfBatchReadStatusInput
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveReadStatus(db, statusID: input.statusID) else {
            throw BookshelfBatchWriteError.invalidReadStatus
        }

        let finishedStatusID = BookEntryReadingStatus.finished.rawValue
        let ratingScore = input.ratingScore.map { max(0, min($0, 50)) }
        if input.statusID == finishedStatusID, (ratingScore ?? 0) <= 0 {
            throw BookshelfBatchWriteError.ratingRequired
        }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            try updateSingleBookReadStatus(
                db,
                bookID: bookID,
                statusID: input.statusID,
                changedAt: input.changedAt,
                updatedAt: now,
                finishedRatingScore: input.statusID == finishedStatusID ? ratingScore : nil
            )
        }
    }

    /// 读取仍有效的分组候选项，供批量移入分组 Sheet 使用。
    /// - Throws: SQL 读取失败时抛出错误。
    nonisolated func fetchMoveTargetGroups(
        _ db: Database,
        excludingGroupID: Int64?
    ) throws -> [BookEditorNamedOption] {
        let baseSQL = """
            SELECT id, COALESCE(name, '') AS name
            FROM `group`
            WHERE is_deleted = 0
            """

        // SQL 目的：读取可作为批量移入目标的有效分组。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0；默认分组二级页会额外排除当前 group id，避免无意义移入自身。
        // 返回字段用途：id/name 直接构造目标分组 Sheet 选项；时间字段不参与本查询。
        let rows: [Row]
        if let excludingGroupID, excludingGroupID > 0 {
            rows = try Row.fetchAll(
                db,
                sql: baseSQL + "\n  AND id != ?\nORDER BY group_order ASC, id ASC",
                arguments: [excludingGroupID]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: baseSQL + "\nORDER BY group_order ASC, id ASC"
            )
        }
        return rows.map { row in
            let name: String = row["name"] ?? ""
            return BookEditorNamedOption(
                id: row["id"],
                title: name.isEmpty ? "未命名分组" : name
            )
        }
    }

    /// 复刻 Android GroupRepository.moveBooksToGroup，把书籍移动到指定分组。
    /// - Throws: 选择为空、目标分组无效或 SQL 写入失败时抛出错误。
    nonisolated func moveBooksToGroup(
        _ db: Database,
        bookIDs: [Int64],
        targetGroupID: Int64
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveGroup(db, groupID: targetGroupID) else { throw BookshelfBatchWriteError.invalidGroup }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            guard try isActiveBook(db, bookID: bookID) else { continue }
            try updateBookPin(db, bookID: bookID, pinned: false, pinOrder: 0)
            let nextOrder = try maxBookOrder(inGroup: targetGroupID, db: db) + 1
            try softDeleteGroupRelations(ofBook: bookID, updatedAt: now, db: db)
            try insertGroupBook(groupID: targetGroupID, bookID: bookID, createdAt: now, db: db)
            try updateBookOrderWithTimestamp(db, id: bookID, order: nextOrder, updatedAt: now)
        }
    }

    /// 复刻 Android GroupRepository.moveOut，把书籍移回默认书架头部或尾部。
    /// - Throws: 选择为空或 SQL 写入失败时抛出错误。
    nonisolated func moveBooksOutOfGroup(
        _ db: Database,
        bookIDs: [Int64],
        placement: GroupBooksPlacement
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            guard try isActiveBook(db, bookID: bookID) else { continue }
            try updateBookPin(db, bookID: bookID, pinned: false, pinOrder: 0)
            try softDeleteGroupRelations(ofBook: bookID, updatedAt: now, db: db)
            let order = switch placement {
            case .start:
                try minDefaultBookshelfOrder(db) - 1
            case .end:
                try maxDefaultBookshelfOrder(db) + 1
            }
            try updateBookOrderWithTimestamp(db, id: bookID, order: order, updatedAt: now)
        }
    }

    /// 复刻 Android BookRepository.deleteBooksAndGroups，先删除顶层书籍，再处理分组内书籍安置与分组删除。
    /// - Throws: 选择为空或任一 SQL 写入失败时抛出错误。
    nonisolated func deleteBookshelfItems(
        _ db: Database,
        ids: [BookshelfItemID],
        groupBooksPlacement: GroupBooksPlacement
    ) throws {
        guard !ids.isEmpty else { throw BookshelfBatchWriteError.emptySelection }

        let bookIDs = ids.compactMap { id -> Int64? in
            if case .book(let bookID) = id { return bookID }
            return nil
        }
        if !bookIDs.isEmpty {
            try deleteBooks(db, bookIDs: bookIDs)
        }

        let groupIDs = ids.compactMap { id -> Int64? in
            if case .group(let groupID) = id { return groupID }
            return nil
        }
        for groupID in normalizedPositiveIDs(groupIDs) {
            try deleteGroup(db, groupID: groupID, placement: groupBooksPlacement)
        }
    }

    /// 软删除一组书籍及其 Android 对齐关联数据。
    /// - Throws: 选择为空或任一 SQL 写入失败时抛出错误。
    nonisolated func deleteBooks(
        _ db: Database,
        bookIDs: [Int64]
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        for bookID in uniqueBookIDs {
            try deleteBook(db, bookID: bookID)
        }
    }

    /// 软删除单本书，并按 Android deleteBook 的 17 步顺序清理 book_id 关联表。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func deleteBook(
        _ db: Database,
        bookID: Int64
    ) throws {
        guard try isActiveBook(db, bookID: bookID) else { return }
        let now = timestampMillis()
        try softDeleteBook(db, bookID: bookID, updatedAt: now)
        try softDeleteTags(ofBook: bookID, updatedAt: now, db: db)
        try softDeleteTagNotesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteNotesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteAttachImagesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCategoriesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCategoryImagesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCategoryContentsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteReviewsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteReviewImagesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteChaptersOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteGroupRelations(ofBook: bookID, updatedAt: now, db: db)
        try softDeleteReadStatusRecordsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteReadTimeRecordsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteSortRecordsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCheckInsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCollectionBooksOfBook(db, bookID: bookID)
        try softDeleteReadPlansOfBook(db, bookID: bookID)
    }

    /// 删除分组前先将组内书籍移回默认书架，再软删除分组本身。
    /// - Throws: 分组无效或 SQL 写入失败时抛出错误。
    nonisolated func deleteGroup(
        _ db: Database,
        groupID: Int64,
        placement: GroupBooksPlacement
    ) throws {
        guard try isActiveGroup(db, groupID: groupID) else { throw BookshelfBatchWriteError.invalidGroup }
        let bookIDs = try fetchOrderedBookIDs(inGroup: groupID, db: db)
        if !bookIDs.isEmpty {
            try moveBooksOutOfGroup(db, bookIDs: bookIDs, placement: placement)
        }
        try softDeleteGroup(db, groupID: groupID)
    }

    /// 重命名有效分组；Android 分组重命名当前不做重名拦截。
    /// - Throws: 名称为空、分组无效或 SQL 写入失败时抛出错误。
    nonisolated func renameGroup(
        _ db: Database,
        groupID: Int64,
        newName: String
    ) throws {
        guard try isActiveGroup(db, groupID: groupID) else { throw BookshelfBatchWriteError.invalidGroup }
        let name = try validatedManagementName(newName, target: "分组")
        let now = timestampMillis()

        // SQL 目的：重命名有效书籍分组。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0，严格对齐 Android GroupDao.updateName。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新分组名称并触发书架观察流刷新。
        let sql = """
            UPDATE `group`
            SET updated_date = ?,
                name = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [now, name, groupID])
    }

    /// 重命名有效书籍标签，并执行 Android TagRepository.rename 的重名校验。
    /// - Throws: 名称为空、标签无效、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func renameTag(
        _ db: Database,
        tagID: Int64,
        newName: String
    ) throws {
        guard try isActiveBookTag(db, tagID: tagID) else { throw BookshelfBatchWriteError.invalidTag }
        let name = try validatedManagementName(newName, target: "标签")
        guard try !isDuplicateBookTagName(db, name: name, excludingTagID: tagID) else {
            throw BookshelfBatchWriteError.duplicateName("此标签名称已存在，请使用不同的名称")
        }
        let now = timestampMillis()

        // SQL 目的：重命名有效书籍标签。
        // 涉及表：tag。
        // 关键过滤：id = ?、type = 1 且 is_deleted = 0，只影响书籍标签。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新标签名称并触发标签维度与二级列表刷新。
        let sql = """
            UPDATE tag
            SET updated_date = ?,
                name = ?
            WHERE id = ?
              AND type = 1
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [now, name, tagID])
    }

    /// 删除有效书籍标签，同时清理 tag_book 与 tag_note 关系。
    /// - Throws: 标签无效或 SQL 写入失败时抛出错误。
    nonisolated func deleteTag(
        _ db: Database,
        tagID: Int64
    ) throws {
        guard try isActiveBookTag(db, tagID: tagID) else { throw BookshelfBatchWriteError.invalidTag }
        let now = timestampMillis()
        try softDeleteTagBookRelations(db, tagID: tagID, updatedAt: now)
        try softDeleteTagNoteRelations(db, tagID: tagID, updatedAt: now)
        try softDeleteBookTag(db, tagID: tagID, updatedAt: now)
    }

    /// 重命名有效来源，并执行 Android SourceRepository.rename 的重名校验。
    /// - Throws: 名称为空、来源无效、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func renameSource(
        _ db: Database,
        sourceID: Int64,
        newName: String
    ) throws {
        guard try isActiveSource(db, sourceID: sourceID) else { throw BookshelfBatchWriteError.invalidSource }
        let name = try validatedManagementName(newName, target: "来源")
        guard try !isDuplicateSourceName(db, name: name, excludingSourceID: sourceID) else {
            throw BookshelfBatchWriteError.duplicateName("此来源名称已存在，请使用不同的名称")
        }

        // SQL 目的：重命名有效书籍来源。
        // 涉及表：source。
        // 关键过滤：id = ? 且 is_deleted = 0，对齐 Android SourceDao.rename。
        // 时间字段：Android 来源重命名不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：更新来源名称并触发来源维度与二级列表刷新。
        let sql = """
            UPDATE source
            SET name = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [name, sourceID])
    }

    /// 删除有效来源前将书籍迁移到未知来源，再软删除来源本身。
    /// - Throws: 来源无效、尝试删除未知来源或 SQL 写入失败时抛出错误。
    nonisolated func deleteSource(
        _ db: Database,
        sourceID: Int64
    ) throws {
        guard try isActiveSource(db, sourceID: sourceID) else { throw BookshelfBatchWriteError.invalidSource }
        let fallbackSourceID = try unknownSourceID(db, deletingSourceID: sourceID)
        try migrateBooks(fromSourceID: sourceID, toSourceID: fallbackSourceID, db: db)
        try softDeleteSource(db, sourceID: sourceID)
    }

    /// 取消单个 Book/Group 置顶状态，写入 pinned = 0 与 pin_order = 0。
    /// - Throws: SQL 写入失败时抛出错误。
    nonisolated func unpinBookshelfItem(
        _ db: Database,
        id: BookshelfItemID
    ) throws {
        try updateBookshelfPin(db, id: id, pinned: false, pinOrder: 0)
    }

    /// 计算移到最前/最后后的最终完整书架顺序，置顶项保持当前前缀顺序。
    nonisolated func reorderedBookshelfItems(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem],
        placement: BookshelfMovePlacement
    ) -> [BookshelfOrderItem] {
        let selectedIDSet = Set(ids)
        let pinnedItems = currentItems.filter(\.isPinned)
        let normalItems = currentItems.filter { !$0.isPinned }
        let normalByID = Dictionary(uniqueKeysWithValues: normalItems.map { ($0.id, $0) })
        let selectedItems = ids.compactMap { normalByID[$0] }
        let remainingItems = normalItems.filter { !selectedIDSet.contains($0.id) }

        switch placement {
        case .start:
            return pinnedItems + selectedItems + remainingItems
        case .end:
            return pinnedItems + remainingItems + selectedItems
        }
    }

    /// 更新单本书籍的手动排序值；对齐 Android BookDao.updateBookOrderSuspend。
    nonisolated func updateBookOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入 Book 默认书架手动排序下标。
        // 涉及表：book。
        // 关键过滤：严格对齐 Android，where id = ? and is_deleted = 0 and book.id != 0。
        // 副作用用途：仅更新 book_order，不更新 updated_date / last_sync_date，避免产生 Android 不会产生的同步事件。
        let sql = """
            UPDATE book
            SET book_order = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新时间戳并写入单本书排序值；用于移入/移出分组这类 Android 会更新时间的路径。
    nonisolated func updateBookOrderWithTimestamp(
        _ db: Database,
        id: Int64,
        order: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：写入移入/移出分组后的 Book 排序值。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，严格对齐 Android BookDao.updateBookOrder。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新 book_order，让目标分组或默认书架排序立即刷新。
        let sql = """
            UPDATE book
            SET updated_date = ?,
                book_order = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, order, id])
    }

    /// 校验分组是否仍有效。
    nonisolated func isActiveGroup(_ db: Database, groupID: Int64) throws -> Bool {
        // SQL 目的：校验批量移入目标分组是否仍有效。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM `group`
            WHERE id = ?
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0) > 0
    }

    /// 校验书籍是否仍可被书架管理写入处理。
    nonisolated func isActiveBook(_ db: Database, bookID: Int64) throws -> Bool {
        // SQL 目的：校验被移组书籍是否仍有效。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
    }

    /// 软删除单本书当前所有有效分组关系。
    nonisolated func softDeleteGroupRelations(
        ofBook bookID: Int64,
        updatedAt: Int64,
        db: Database
    ) throws {
        // SQL 目的：移入或移出分组时清除该书现有有效分组关系。
        // 涉及表：group_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0；对齐 Android GroupBookDao.deleteByBookId。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：保证同一本书只保留一个有效分组归属，或回到默认书架顶层。
        let sql = """
            UPDATE group_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 插入目标分组与书籍关系。
    nonisolated func insertGroupBook(
        groupID: Int64,
        bookID: Int64,
        createdAt: Int64,
        db: Database
    ) throws {
        var relation = GroupBookRecord(
            id: nil,
            groupId: groupID,
            bookId: bookID,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try relation.insert(db)
    }

    /// 查询指定分组内有效书籍的最大排序值。
    nonisolated func maxBookOrder(inGroup groupID: Int64, db: Database) throws -> Int64 {
        // SQL 目的：读取目标分组内有效书籍最大 book_order，作为移入分组追加位置。
        // 涉及表：group_book JOIN book。
        // 关键过滤：group_id = ?、group_book/book 均未软删除、book.id != 0，并仅保留该书最早有效分组关系。
        // 返回字段用途：移入分组时写入 max + 1；空分组回退 0。
        let sql = """
            SELECT MAX(book.book_order)
            FROM group_book
            JOIN book ON group_book.book_id = book.id
            WHERE group_book.group_id = ?
              AND group_book.is_deleted = 0
              AND book.is_deleted = 0
              AND book.id != 0
              AND group_book.id = (
                  SELECT gb2.id
                  FROM group_book gb2
                  WHERE gb2.book_id = book.id
                    AND gb2.is_deleted = 0
                  ORDER BY gb2.created_date ASC, gb2.id ASC
                  LIMIT 1
              )
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0
    }

    /// 查询默认书架 Book/Group 混排最大排序值。
    nonisolated func maxDefaultBookshelfOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取默认书架顶层有效书籍最大 book_order。
        // 涉及表：book；子查询使用 group_book 排除仍在任意有效分组中的书籍。
        // 关键过滤：book.is_deleted = 0、book.id != 0、group_book.is_deleted = 0。
        // 返回字段用途：与 group_order 最大值合并，移出分组到尾部时写入 max + 1。
        let bookSQL = """
            SELECT MAX(book_order)
            FROM book
            WHERE is_deleted = 0
              AND id != 0
              AND id NOT IN (
                  SELECT book_id
                  FROM group_book
                  WHERE is_deleted = 0
              )
            """
        // SQL 目的：读取默认书架有效分组最大 group_order。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0。
        // 返回字段用途：与顶层书籍最大值合并，保持 Book/Group 共用手动排序空间。
        let groupSQL = """
            SELECT MAX(group_order)
            FROM `group`
            WHERE is_deleted = 0
            """
        let bookMax = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupMax = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return max(bookMax, groupMax)
    }

    /// 查询默认书架 Book/Group 混排最小排序值。
    nonisolated func minDefaultBookshelfOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取默认书架顶层有效书籍最小 book_order。
        // 涉及表：book；子查询使用 group_book 排除仍在任意有效分组中的书籍。
        // 关键过滤：book.is_deleted = 0、book.id != 0、group_book.is_deleted = 0。
        // 返回字段用途：与 group_order 最小值合并，移出分组到头部时写入 min - 1。
        let bookSQL = """
            SELECT MIN(book_order)
            FROM book
            WHERE is_deleted = 0
              AND id != 0
              AND id NOT IN (
                  SELECT book_id
                  FROM group_book
                  WHERE is_deleted = 0
              )
            """
        // SQL 目的：读取默认书架有效分组最小 group_order。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0。
        // 返回字段用途：与顶层书籍最小值合并，保持 Book/Group 共用手动排序空间。
        let groupSQL = """
            SELECT MIN(group_order)
            FROM `group`
            WHERE is_deleted = 0
            """
        let bookMin = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupMin = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return min(bookMin, groupMin)
    }

    /// 写入单本书置顶字段；用于默认分组组内置顶和取消置顶。
    nonisolated func updateBookPin(
        _ db: Database,
        bookID: Int64,
        pinned: Bool,
        pinOrder: Int64
    ) throws {
        let pinnedValue: Int64 = pinned ? 1 : 0
        // SQL 目的：更新 Book 置顶状态与 pin_order。
        // 涉及表：book。
        // 关键过滤：严格对齐 Android updatePinOrder，仅按 id 更新。
        // 副作用用途：写 pinned / pin_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE book
            SET pinned = ?,
                pin_order = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [pinnedValue, pinOrder, bookID])
    }

    /// 更新单个分组的手动排序值；对齐 Android GroupDao.updateGroupOrderSuspend。
    nonisolated func updateGroupOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入 Group 默认书架手动排序下标。
        // 涉及表：`group`。
        // 关键过滤：严格对齐 Android，仅按 id 更新，不额外追加 is_deleted 条件。
        // 副作用用途：仅更新 group_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE `group`
            SET group_order = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新阅读状态排序值；对齐 Android updateBookReadStatusOrder。
    nonisolated func updateReadStatusOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入阅读状态在书架状态维度中的手动排序下标。
        // 涉及表：read_status。
        // 关键过滤：按 id 精确命中，且排除软删除状态。
        // 副作用用途：仅更新 read_status_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE read_status
            SET read_status_order = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新标签排序值；对齐 Android tagRepo.updateOrder。
    nonisolated func updateTagOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入书籍标签在书架标签维度中的手动排序下标。
        // 涉及表：tag。
        // 关键过滤：按 id 精确命中，要求 type = 1 且 is_deleted = 0，避免影响书摘标签。
        // 副作用用途：仅更新 tag_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE tag
            SET tag_order = ?
            WHERE id = ?
              AND type = 1
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新来源排序值；对齐 Android updateBookSourceListOrder。
    nonisolated func updateSourceOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入书籍来源在书架来源维度中的手动排序下标。
        // 涉及表：source。
        // 关键过滤：按 id 精确命中，且排除软删除来源。
        // 副作用用途：仅更新 source_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE source
            SET source_order = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 查询 Book/Group 已置顶项的全局最大 pin_order。
    nonisolated func maxBookshelfPinOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取 Book 已置顶项最大 pin_order。
        // 涉及表：book。
        // 关键过滤：对齐 Android queryMaxPinOrder，is_deleted = 0 且 pinned = 1。
        // 返回字段用途：与 Group 最大值合并，作为批量置顶追加起点。
        let bookSQL = """
            SELECT pin_order
            FROM book
            WHERE is_deleted = 0
              AND pinned = 1
            ORDER BY pin_order DESC
            LIMIT 1
            """
        // SQL 目的：读取 Group 已置顶项最大 pin_order。
        // 涉及表：`group`。
        // 关键过滤：对齐 Android queryMaxPinOrder，is_deleted = 0 且 pinned = 1。
        // 返回字段用途：与 Book 最大值合并，保证 Book/Group 共用 pin_order 序列。
        let groupSQL = """
            SELECT pin_order
            FROM `group`
            WHERE is_deleted = 0
              AND pinned = 1
            ORDER BY pin_order DESC
            LIMIT 1
            """
        let bookMax = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupMax = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return max(bookMax, groupMax)
    }

    /// 查询 Book/Group 是否已置顶，用于批量置顶跳过已有置顶项。
    nonisolated func isBookshelfItemPinned(
        _ db: Database,
        id: BookshelfItemID
    ) throws -> Bool {
        switch id {
        case .book(let bookID):
            // SQL 目的：查询指定 Book 是否已经置顶。
            // 涉及表：book。
            // 关键过滤：严格对齐 Android queryPinnedCount，仅过滤 pinned 与 id，不追加 is_deleted。
            // 返回字段用途：批量置顶时跳过已置顶 Book，保持 pin_order 追加序列。
            let sql = """
                SELECT COUNT(*)
                FROM book
                WHERE pinned = 1
                  AND id = ?
                """
            return try (Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
        case .group(let groupID):
            // SQL 目的：查询指定 Group 是否已经置顶。
            // 涉及表：`group`。
            // 关键过滤：严格对齐 Android queryPinnedCount，过滤 id、pinned 与 is_deleted = 0。
            // 返回字段用途：批量置顶时跳过已置顶 Group，保持 pin_order 追加序列。
            let sql = """
                SELECT COUNT(*)
                FROM `group`
                WHERE id = ?
                  AND pinned = 1
                  AND is_deleted = 0
                """
            return try (Int.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0) > 0
        }
    }

    /// 写入 Book/Group 置顶字段；不更新时间戳。
    nonisolated func updateBookshelfPin(
        _ db: Database,
        id: BookshelfItemID,
        pinned: Bool,
        pinOrder: Int64
    ) throws {
        let pinnedValue: Int64 = pinned ? 1 : 0
        switch id {
        case .book(let bookID):
            // SQL 目的：更新 Book 置顶状态与 pin_order。
            // 涉及表：book。
            // 关键过滤：严格对齐 Android updatePinOrder，仅按 id 更新。
            // 副作用用途：写 pinned / pin_order，不更新 updated_date / last_sync_date。
            let sql = """
                UPDATE book
                SET pinned = ?,
                    pin_order = ?
                WHERE id = ?
                """
            try db.execute(sql: sql, arguments: [pinnedValue, pinOrder, bookID])
        case .group(let groupID):
            // SQL 目的：更新 Group 置顶状态与 pin_order。
            // 涉及表：`group`。
            // 关键过滤：严格对齐 Android updatePinOrder，仅按 id 更新。
            // 副作用用途：写 pinned / pin_order，不更新 updated_date / last_sync_date。
            let sql = """
                UPDATE `group`
                SET pinned = ?,
                    pin_order = ?
                WHERE id = ?
                """
            try db.execute(sql: sql, arguments: [pinnedValue, pinOrder, groupID])
        }
    }

    /// 读取当前用户的书籍标签候选项。
    nonisolated func fetchBatchBookTagOptions(
        _ db: Database,
        ownerID: Int64
    ) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取当前用户下可用于批量设置的书籍标签。
        // 涉及表：tag。
        // 关键过滤：user_id = ?、type = 1 仅书籍标签、is_deleted = 0 排除软删除。
        // 返回字段用途：id/name 直接构造批量标签 Sheet 选项；时间字段不参与本查询。
        let sql = """
            SELECT id, COALESCE(name, '') AS name
            FROM tag
            WHERE user_id = ?
              AND type = 1
              AND is_deleted = 0
            ORDER BY tag_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerID]).map { row in
            let title: String = row["name"] ?? ""
            return BookEditorNamedOption(
                id: row["id"],
                title: title.isEmpty ? "未命名标签" : title
            )
        }
    }

    /// 读取批量来源候选项。
    nonisolated func fetchBatchSourceOptions(_ db: Database) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取可用于批量设置的有效书籍来源。
        // 涉及表：source。
        // 关键过滤：is_deleted = 0 排除软删除来源；隐藏来源仍允许作为存量书籍来源被重新选择。
        // 返回字段用途：id/name 直接构造批量来源 Sheet 选项；时间字段不参与本查询。
        let sql = """
            SELECT id, COALESCE(name, '') AS name
            FROM source
            WHERE is_deleted = 0
            ORDER BY source_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let title: String = row["name"] ?? ""
            return BookEditorNamedOption(
                id: row["id"],
                title: title.isEmpty ? "未知来源" : title
            )
        }
    }

    /// 读取批量阅读状态候选项。
    nonisolated func fetchBatchReadStatusOptions(_ db: Database) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取可用于批量设置的阅读状态字典。
        // 涉及表：read_status。
        // 关键过滤：is_deleted = 0 排除软删除状态。
        // 返回字段用途：id/name 直接构造批量阅读状态 Sheet 选项；时间字段不参与本查询。
        let sql = """
            SELECT id, COALESCE(name, '') AS name
            FROM read_status
            WHERE is_deleted = 0
            ORDER BY read_status_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let title: String = row["name"] ?? ""
            return BookEditorNamedOption(
                id: row["id"],
                title: title.isEmpty ? "未命名状态" : title
            )
        }
    }

    /// 读取单本书当前批量编辑初始值。
    nonisolated func fetchBatchEditInitialValues(
        _ db: Database,
        bookID: Int64
    ) throws -> BookshelfBatchEditInitialValues? {
        // SQL 目的：读取单本书当前来源、阅读状态、状态时间与评分，作为批量编辑 Sheet 初始值。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，跳过已删除书籍和占位书籍。
        // 返回字段用途：source_id/read_status_id/read_status_changed_date/score 只用于 Sheet 默认选择，不产生写入副作用。
        let sql = """
            SELECT source_id, read_status_id, read_status_changed_date, score
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return BookshelfBatchEditInitialValues(
            tagIDs: try fetchBatchSelectedTagIDs(ofBook: bookID, db: db),
            sourceID: row["source_id"],
            readStatusID: row["read_status_id"],
            readStatusChangedAt: row["read_status_changed_date"],
            ratingScore: row["score"]
        )
    }

    /// 读取当前用户仍有效的书籍标签 ID 集合。
    nonisolated func fetchActiveBookTagIDs(_ db: Database, ownerID: Int64) throws -> Set<Int64> {
        // SQL 目的：读取当前用户下仍有效的书籍标签 ID，用于批量标签写入前校验。
        // 涉及表：tag。
        // 关键过滤：user_id = ?、type = 1、is_deleted = 0。
        // 返回字段用途：校验提交 tagIDs 全部来自有效书籍标签；时间字段不参与本查询。
        let sql = """
            SELECT id
            FROM tag
            WHERE user_id = ?
              AND type = 1
              AND is_deleted = 0
        """
        return Set(try Int64.fetchAll(db, sql: sql, arguments: [ownerID]))
    }

    /// 读取单本书当前有效书籍标签 ID，作为单本标签 Sheet 初始勾选项。
    nonisolated func fetchBatchSelectedTagIDs(ofBook bookID: Int64, db: Database) throws -> [Int64] {
        // SQL 目的：读取单本书当前有效书籍标签关系，作为标签 Sheet 初始选择。
        // 涉及表：tag_book tb JOIN tag t。
        // 关键过滤：tb.book_id = ?、tb.is_deleted = 0、t.is_deleted = 0、t.type = 1。
        // 返回字段用途：tag_id 按 tag_order/id 排序返回，用于单本标签替换前的默认勾选；时间字段不参与本查询。
        let sql = """
            SELECT t.id
            FROM tag_book tb
            JOIN tag t ON t.id = tb.tag_id
            WHERE tb.book_id = ?
              AND tb.is_deleted = 0
              AND t.is_deleted = 0
              AND t.type = 1
            ORDER BY t.tag_order ASC, t.id ASC
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [bookID])
    }

    /// 软删除指定书籍当前有效标签关系。
    nonisolated func softDeleteTags(
        ofBook bookID: Int64,
        updatedAt: Int64,
        db: Database
    ) throws {
        // SQL 目的：软删除单本书现有标签关系，复刻 Android 单本批量设置标签的“先清空再插入”语义。
        // 涉及表：tag_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0，仅处理当前有效关系。
        // 时间字段：updated_date 写入毫秒时间戳，last_sync_date 保持原值等待同步层处理。
        // 副作用用途：将旧关系标记为删除，为新标签集合插入干净关系。
        let sql = """
            UPDATE tag_book
            SET is_deleted = 1,
                updated_date = ?
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除单本书主记录。
    nonisolated func softDeleteBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除有效书籍主记录。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，对齐 Android BookDao.deleteBook。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：从所有书架观察流中移除该书，后续 helper 清理关联表。
        let sql = """
            UPDATE book
            SET updated_date = ?,
                is_deleted = 1
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍下书摘与标签的有效关系。
    nonisolated func softDeleteTagNotesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：删除指定书籍下全部书摘与标签关系。
        // 涉及表：tag_note；子查询读取 note。
        // 关键过滤：note.book_id = ? 且 tag_note.is_deleted = 0，覆盖该书所有书摘关系。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 3 步，避免书摘删除后残留 tag_note 关系。
        let sql = """
            UPDATE tag_note
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND note_id IN (
                  SELECT id
                  FROM note
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍下全部书摘。
    nonisolated func softDeleteNotesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部书摘。
        // 涉及表：note。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 4 步，使笔记列表观察流移除这些书摘。
        let sql = """
            UPDATE note
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍下书摘附图。
    nonisolated func softDeleteAttachImagesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部书摘附图。
        // 涉及表：attach_image；子查询读取 note。
        // 关键过滤：attach_image.note_id 属于该书 note，且 attach_image.is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 5 步，避免附图关系残留。
        let sql = """
            UPDATE attach_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND note_id IN (
                  SELECT id
                  FROM note
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍相关分类。
    nonisolated func softDeleteCategoriesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联分类。
        // 涉及表：category。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 6 步，清理相关内容分类入口。
        let sql = """
            UPDATE category
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍相关内容图片。
    nonisolated func softDeleteCategoryImagesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍相关内容的图片。
        // 涉及表：category_image；子查询读取 category_content。
        // 关键过滤：category_content.book_id = ? 且 category_image.is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 7 步，避免相关内容图片残留。
        let sql = """
            UPDATE category_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND category_content_id IN (
                  SELECT id
                  FROM category_content
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍相关内容。
    nonisolated func softDeleteCategoryContentsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部相关内容。
        // 涉及表：category_content。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 7.1 步。
        let sql = """
            UPDATE category_content
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍书评。
    nonisolated func softDeleteReviewsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部书评。
        // 涉及表：review。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 8 步。
        let sql = """
            UPDATE review
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍书评图片。
    nonisolated func softDeleteReviewImagesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍书评关联图片。
        // 涉及表：review_image；子查询读取 review。
        // 关键过滤：review.book_id = ? 且 review_image.is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 9 步。
        let sql = """
            UPDATE review_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND review_id IN (
                  SELECT id
                  FROM review
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍章节。
    nonisolated func softDeleteChaptersOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部章节。
        // 涉及表：chapter。
        // 关键过滤：book_id = ?、id != 0 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 10 步。
        let sql = """
            UPDATE chapter
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND id != 0
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍阅读状态历史。
    nonisolated func softDeleteReadStatusRecordsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍的阅读状态历史。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 12 步。
        let sql = """
            UPDATE book_read_status_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍阅读计时记录。
    nonisolated func softDeleteReadTimeRecordsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联的阅读计时记录。
        // 涉及表：read_time_record。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 13 步。
        let sql = """
            UPDATE read_time_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍排序设置。
    nonisolated func softDeleteSortRecordsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联排序设置。
        // 涉及表：sort。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 14 步。
        let sql = """
            UPDATE sort
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍打卡记录。
    nonisolated func softDeleteCheckInsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联打卡记录。
        // 涉及表：check_in_record。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 15 步。
        let sql = """
            UPDATE check_in_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍与书单关系；这是删书级联清理，不是“加入书单”功能实现。
    nonisolated func softDeleteCollectionBooksOfBook(
        _ db: Database,
        bookID: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联的全部书单关系。
        // 涉及表：collection_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：Android CollectionBookDao.deleteByBookId 不更新时间戳，iOS 保持一致不改 updated_date。
        // 副作用用途：复刻 Android 删除书籍第 16 步，仅作为删除书籍级联清理。
        let sql = """
            UPDATE collection_book
            SET is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [bookID])
    }

    /// 软删除书籍阅读计划。
    nonisolated func softDeleteReadPlansOfBook(
        _ db: Database,
        bookID: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联阅读计划。
        // 涉及表：read_plan。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：Android ReadPlanDao.deleteFromBook 不更新时间戳，iOS 保持一致不改 updated_date。
        // 副作用用途：复刻 Android 删除书籍第 17 步。
        let sql = """
            UPDATE read_plan
            SET is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [bookID])
    }

    /// 读取指定书籍当前有效标签 ID 集合。
    nonisolated func fetchActiveTagIDs(ofBook bookID: Int64, db: Database) throws -> Set<Int64> {
        // SQL 目的：读取单本书现有有效标签关系，用于多本批量追加时避免重复插入。
        // 涉及表：tag_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 返回字段用途：仅返回 tag_id 集合；时间字段不参与本查询。
        let sql = """
            SELECT tag_id
            FROM tag_book
            WHERE book_id = ?
              AND is_deleted = 0
            """
        return Set(try Int64.fetchAll(db, sql: sql, arguments: [bookID]))
    }

    /// 插入一条有效的书籍标签关系。
    nonisolated func insertTagBook(
        bookID: Int64,
        tagID: Int64,
        createdAt: Int64,
        db: Database
    ) throws {
        var relation = TagBookRecord(
            id: nil,
            bookId: bookID,
            tagId: tagID,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try relation.insert(db)
    }

    /// 校验来源是否仍可用于书籍写入。
    nonisolated func isActiveSource(_ db: Database, sourceID: Int64) throws -> Bool {
        // SQL 目的：校验批量来源写入目标仍是有效来源。
        // 涉及表：source。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM source
            WHERE id = ?
              AND is_deleted = 0
        """
        return (try Int.fetchOne(db, sql: sql, arguments: [sourceID]) ?? 0) > 0
    }

    /// 校验书籍标签是否仍有效。
    nonisolated func isActiveBookTag(_ db: Database, tagID: Int64) throws -> Bool {
        // SQL 目的：校验待管理标签是否仍是有效书籍标签。
        // 涉及表：tag。
        // 关键过滤：id = ?、type = 1 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM tag
            WHERE id = ?
              AND type = 1
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [tagID]) ?? 0) > 0
    }

    /// 校验书籍标签名称是否重复。
    nonisolated func isDuplicateBookTagName(
        _ db: Database,
        name: String,
        excludingTagID: Int64
    ) throws -> Bool {
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        // SQL 目的：查询同一用户下是否存在同名书籍标签。
        // 涉及表：tag。
        // 关键过滤：user_id = ?、name = ?、type = 1、is_deleted = 0，并排除当前 tag id。
        // 返回字段用途：用于重命名前置重名拦截；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM tag
            WHERE user_id = ?
              AND name = ?
              AND type = 1
              AND is_deleted = 0
              AND id != ?
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [ownerID, name, excludingTagID]) ?? 0) > 0
    }

    /// 校验来源名称是否重复。
    nonisolated func isDuplicateSourceName(
        _ db: Database,
        name: String,
        excludingSourceID: Int64
    ) throws -> Bool {
        // SQL 目的：查询是否存在同名有效来源。
        // 涉及表：source。
        // 关键过滤：name = ?、is_deleted = 0，并排除当前 source id。
        // 返回字段用途：用于来源重命名前置重名拦截；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM source
            WHERE name = ?
              AND is_deleted = 0
              AND id != ?
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [name, excludingSourceID]) ?? 0) > 0
    }

    /// 校验管理对象的新名称。
    nonisolated func validatedManagementName(
        _ name: String,
        target: String
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BookshelfBatchWriteError.invalidName(target) }
        return trimmed
    }

    /// 软删除分组主记录。
    nonisolated func softDeleteGroup(
        _ db: Database,
        groupID: Int64
    ) throws {
        // SQL 目的：软删除有效分组主记录。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0，对齐 Android GroupDao.deleteGroup。
        // 时间字段：Android 删除分组不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：从默认书架分组入口移除该分组。
        let sql = """
            UPDATE `group`
            SET is_deleted = 1
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [groupID])
    }

    /// 软删除标签与书籍关系。
    nonisolated func softDeleteTagBookRelations(
        _ db: Database,
        tagID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定标签的全部书籍关系。
        // 涉及表：tag_book。
        // 关键过滤：tag_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：删除标签前清理书籍维度关系，避免孤立 tag_book。
        let sql = """
            UPDATE tag_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE tag_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, tagID])
    }

    /// 软删除标签与书摘关系。
    nonisolated func softDeleteTagNoteRelations(
        _ db: Database,
        tagID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定标签的全部书摘关系。
        // 涉及表：tag_note。
        // 关键过滤：tag_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：删除标签前清理书摘维度关系，避免孤立 tag_note。
        let sql = """
            UPDATE tag_note
            SET updated_date = ?,
                is_deleted = 1
            WHERE tag_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, tagID])
    }

    /// 软删除书籍标签主记录。
    nonisolated func softDeleteBookTag(
        _ db: Database,
        tagID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除有效书籍标签主记录。
        // 涉及表：tag。
        // 关键过滤：id = ?、type = 1 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：对齐 Android TagDao.deleteSync，使标签维度观察流移除该标签。
        let sql = """
            UPDATE tag
            SET updated_date = ?,
                is_deleted = 1
            WHERE id = ?
              AND type = 1
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, tagID])
    }

    /// 获取“未知来源”的有效 ID；若缺失且当前删除目标不是默认来源，则按 iOS seed 语义恢复默认来源。
    nonisolated func unknownSourceID(
        _ db: Database,
        deletingSourceID: Int64
    ) throws -> Int64 {
        if deletingSourceID == DatabaseOwnerResolver.defaultSourceID {
            throw BookshelfBatchWriteError.protectedDefaultSource
        }

        // SQL 目的：优先查找仍有效的“未知”来源，作为删除来源时的迁移目标。
        // 涉及表：source。
        // 关键过滤：name = '未知'、is_deleted = 0，并排除当前待删除 source id。
        // 返回字段用途：返回目标 source.id；时间字段不参与本查询。
        let lookupSQL = """
            SELECT id
            FROM source
            WHERE name = ?
              AND is_deleted = 0
              AND id != ?
            ORDER BY source_order ASC, id ASC
            LIMIT 1
            """
        if let sourceID = try Int64.fetchOne(
            db,
            sql: lookupSQL,
            arguments: [DatabaseOwnerResolver.defaultSourceName, deletingSourceID]
        ) {
            return sourceID
        }

        // SQL 目的：恢复 iOS 与 Android 对齐的默认未知来源种子。
        // 涉及表：source。
        // 关键过滤：使用固定 id = 1；INSERT OR IGNORE 避免已有记录时报错。
        // 时间字段：种子来源 created/updated/last_sync_date 均保持 0，与初始化种子一致。
        // 副作用用途：保证删除自定义来源时，总有可迁移的未知来源。
        let insertSQL = """
            INSERT OR IGNORE INTO source (id, name, source_order, bookshelf_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (?, ?, 0, -1, 0, 0, 0, 0, 0)
            """
        try db.execute(
            sql: insertSQL,
            arguments: [DatabaseOwnerResolver.defaultSourceID, DatabaseOwnerResolver.defaultSourceName]
        )

        // SQL 目的：确保默认未知来源处于有效状态并具备标准名称。
        // 涉及表：source。
        // 关键过滤：id = 1 且不是当前待删除来源。
        // 时间字段：保持 Android 删除来源迁移路径不更新时间戳的语义。
        // 副作用用途：恢复未知来源作为迁移目标。
        let restoreSQL = """
            UPDATE source
            SET name = ?,
                is_deleted = 0
            WHERE id = ?
              AND id != ?
            """
        try db.execute(
            sql: restoreSQL,
            arguments: [DatabaseOwnerResolver.defaultSourceName, DatabaseOwnerResolver.defaultSourceID, deletingSourceID]
        )

        guard try isActiveSource(db, sourceID: DatabaseOwnerResolver.defaultSourceID) else {
            throw BookshelfBatchWriteError.invalidSource
        }
        return DatabaseOwnerResolver.defaultSourceID
    }

    /// 将旧来源下的有效书籍迁移到新来源。
    nonisolated func migrateBooks(
        fromSourceID oldSourceID: Int64,
        toSourceID newSourceID: Int64,
        db: Database
    ) throws {
        // SQL 目的：删除来源前把有效书籍迁移到未知来源。
        // 涉及表：book。
        // 关键过滤：source_id = ?、is_deleted = 0、id != 0。
        // 时间字段：Android updateOldSourceToNew 不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：对齐 Android BookDao.updateOldSourceToNew，避免书籍引用已删除来源。
        let sql = """
            UPDATE book
            SET source_id = ?
            WHERE source_id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [newSourceID, oldSourceID])
    }

    /// 软删除来源主记录。
    nonisolated func softDeleteSource(
        _ db: Database,
        sourceID: Int64
    ) throws {
        // SQL 目的：软删除有效来源主记录。
        // 涉及表：source。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 时间字段：Android SourceDao.delete 不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：删除来源维度入口；相关书籍已在前一步迁移到未知来源。
        let sql = """
            UPDATE source
            SET is_deleted = 1
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [sourceID])
    }

    /// 更新单本有效书籍的来源。
    nonisolated func updateBookSource(
        _ db: Database,
        bookID: Int64,
        sourceID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：批量更新书籍来源，对齐 Android BookDao.updateBookSource 的有效书籍过滤。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，避免写入已删除书籍和占位书籍。
        // 时间字段：updated_date 写入毫秒时间戳，last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新 source_id，使来源维度观察流立即刷新。
        let sql = """
            UPDATE book
            SET source_id = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [sourceID, updatedAt, bookID])
    }

    /// 校验阅读状态是否仍可用于书籍写入。
    nonisolated func isActiveReadStatus(_ db: Database, statusID: Int64) throws -> Bool {
        // SQL 目的：校验批量阅读状态写入目标仍是有效阅读状态。
        // 涉及表：read_status。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM read_status
            WHERE id = ?
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [statusID]) ?? 0) > 0
    }

    /// 更新单本书的阅读状态历史、当前状态，并按读完语义同步进度与评分。
    nonisolated func updateSingleBookReadStatus(
        _ db: Database,
        bookID: Int64,
        statusID: Int64,
        changedAt: Int64,
        updatedAt: Int64,
        finishedRatingScore: Int64?
    ) throws {
        guard let bookState = try fetchBatchBookState(db, bookID: bookID) else { return }
        if let latestStatus = try fetchNewestReadStatusRecord(db, bookID: bookID),
           latestStatus.readStatusID == statusID {
            try updateNewestReadStatusRecord(
                db,
                recordID: latestStatus.id,
                changedAt: changedAt,
                updatedAt: updatedAt
            )
        } else {
            try insertBookReadStatusRecord(
                db,
                bookID: bookID,
                statusID: statusID,
                changedAt: changedAt,
                createdAt: updatedAt
            )
        }
        try updateBookCurrentReadStatus(
            db,
            bookID: bookID,
            userID: bookState.userID,
            statusID: statusID,
            changedAt: changedAt,
            updatedAt: updatedAt
        )
        guard let finishedRatingScore else { return }
        try markBookAsFinished(
            db,
            bookID: bookID,
            positionUnit: bookState.positionUnit,
            totalPosition: bookState.totalPosition,
            totalPagination: bookState.totalPagination,
            updatedAt: updatedAt
        )
        try updateBookRating(db, bookID: bookID, ratingScore: finishedRatingScore, updatedAt: updatedAt)
    }

    /// 读取单本书批量阅读状态写入所需的基础字段。
    nonisolated func fetchBatchBookState(
        _ db: Database,
        bookID: Int64
    ) throws -> (userID: Int64, positionUnit: Int64, totalPosition: Int64, totalPagination: Int64)? {
        // SQL 目的：读取批量状态写入所需的书籍用户与进度单位字段。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，跳过已删除书籍和占位书籍。
        // 返回字段用途：user_id 用于对齐 Android 更新过滤；position_unit/total_position/total_pagination 用于读完时同步阅读进度。
        let sql = """
            SELECT user_id, position_unit, total_position, total_pagination
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return (
            userID: row["user_id"] ?? 0,
            positionUnit: row["position_unit"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0
        )
    }

    /// 读取单本书最新的有效阅读状态记录。
    nonisolated func fetchNewestReadStatusRecord(
        _ db: Database,
        bookID: Int64
    ) throws -> (id: Int64, readStatusID: Int64)? {
        // SQL 目的：读取单本书最新有效阅读状态记录，决定复用更新还是插入新记录。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id = ?、is_deleted = 0。
        // 时间字段：changed_date 作为同 id 倒序后的补充排序；id DESC 优先对齐 Android 最新记录查询。
        // 返回字段用途：id 用于更新最新记录，read_status_id 用于判断状态是否相同。
        let sql = """
            SELECT id, read_status_id
            FROM book_read_status_record
            WHERE book_id = ?
              AND is_deleted = 0
            ORDER BY id DESC, changed_date DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return (id: row["id"], readStatusID: row["read_status_id"])
    }

    /// 更新时间相同状态下的最新阅读状态记录。
    nonisolated func updateNewestReadStatusRecord(
        _ db: Database,
        recordID: Int64,
        changedAt: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：当最新阅读状态与目标状态一致时，仅更新时间而不插入新历史。
        // 涉及表：book_read_status_record。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 时间字段：changed_date 写入用户选择的状态时间，updated_date 写入当前毫秒时间戳。
        // 副作用用途：复刻 Android updateBookReadStatus 中“最新同状态则更新”的历史合并语义。
        let sql = """
            UPDATE book_read_status_record
            SET changed_date = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [changedAt, updatedAt, recordID])
    }

    /// 插入一条新的阅读状态历史记录。
    nonisolated func insertBookReadStatusRecord(
        _ db: Database,
        bookID: Int64,
        statusID: Int64,
        changedAt: Int64,
        createdAt: Int64
    ) throws {
        var record = BookReadStatusRecordRecord(
            id: nil,
            bookId: bookID,
            readStatusId: statusID,
            changedDate: changedAt,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }

    /// 同步 book 表当前阅读状态字段。
    nonisolated func updateBookCurrentReadStatus(
        _ db: Database,
        bookID: Int64,
        userID: Int64,
        statusID: Int64,
        changedAt: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：同步 book 当前阅读状态字段，供书架状态维度与详情页直接读取。
        // 涉及表：book。
        // 关键过滤：id = ?、user_id = ?、is_deleted = 0、id != 0，对齐 Android updateBookReadStatus 的用户与有效书过滤。
        // 时间字段：read_status_changed_date 写入用户选择的状态时间，updated_date 写入当前毫秒时间戳。
        // 副作用用途：更新 read_status_id/read_status_changed_date，使 Repository 观察流刷新。
        let sql = """
            UPDATE book
            SET updated_date = ?,
                read_status_id = ?,
                read_status_changed_date = ?
            WHERE id = ?
              AND user_id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, statusID, changedAt, bookID, userID])
    }

    /// 标记书籍阅读进度到当前进度单位的终点。
    nonisolated func markBookAsFinished(
        _ db: Database,
        bookID: Int64,
        positionUnit: Int64,
        totalPosition: Int64,
        totalPagination: Int64,
        updatedAt: Int64
    ) throws {
        let readPosition: Double?
        switch positionUnit {
        case BookEntryProgressUnit.progress.rawValue:
            readPosition = 100.0
        case BookEntryProgressUnit.position.rawValue where totalPosition != 0:
            readPosition = Double(totalPosition)
        case BookEntryProgressUnit.pagination.rawValue where totalPagination != 0:
            readPosition = Double(totalPagination)
        default:
            readPosition = nil
        }
        guard let readPosition else { return }

        // SQL 目的：标记读完时把当前阅读位置推进到终点，对齐 Android updateBookReadPositionSync。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；position_unit/current_position_unit 均按现有书籍字段处理。
        // 副作用用途：更新 current_position_unit 与 read_position，使阅读进度排序和详情展示同步到终点。
        let sql = """
            UPDATE book
            SET current_position_unit = position_unit,
                read_position = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [readPosition, updatedAt, bookID])
    }

    /// 更新单本有效书籍的评分字段。
    nonisolated func updateBookRating(
        _ db: Database,
        bookID: Int64,
        ratingScore: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：标记读完时写入用户选择评分，对齐 Android rating(book.id, score)。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0。
        // 时间字段：updated_date 写入当前毫秒时间戳。
        // 副作用用途：更新 score，使评分维度和二级列表观察流刷新。
        let sql = """
            UPDATE book
            SET score = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [ratingScore, updatedAt, bookID])
    }

    /// 过滤并保留正数 ID 的首次出现顺序。
    nonisolated func normalizedPositiveIDs(_ ids: [Int64]) -> [Int64] {
        ids.reduce(into: [Int64]()) { result, id in
            guard id > 0, !result.contains(id) else { return }
            result.append(id)
        }
    }

    /// 返回当前毫秒时间戳。
    nonisolated func timestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 查询首页书架所有浏览维度共用的只读快照。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfSnapshot(
        _ db: Database,
        settingsByDimension: [BookshelfDimension: BookshelfDisplaySetting],
        searchKeyword: String?
    ) throws -> BookshelfSnapshot {
        let defaultSetting = setting(for: .default, in: settingsByDimension)
        let defaultItems = try fetchBookshelf(db, setting: defaultSetting, searchKeyword: searchKeyword)
        let allBooks = try fetchAllBookshelfBookRows(db)
        let keyword = normalizedSearchKeyword(searchKeyword)
        let filteredBooks = filterBooks(allBooks, keyword: keyword)
        let tagsByBook = try fetchBookshelfTagsByBook(db)

        return BookshelfSnapshot(
            defaultItems: defaultItems,
            defaultSections: makeDefaultSections(from: defaultItems, setting: defaultSetting),
            statusSections: makeStatusSections(from: filteredBooks, setting: setting(for: .status, in: settingsByDimension)),
            tagGroups: makeTagGroups(from: filteredBooks, tagsByBook: tagsByBook, setting: setting(for: .tag, in: settingsByDimension)),
            sourceGroups: makeSourceGroups(from: filteredBooks, setting: setting(for: .source, in: settingsByDimension)),
            ratingSections: makeRatingSections(from: filteredBooks, setting: setting(for: .rating, in: settingsByDimension)),
            authorSections: makeAuthorSections(from: filteredBooks, setting: setting(for: .author, in: settingsByDimension)),
            pressGroups: makePressGroups(from: filteredBooks, setting: setting(for: .press, in: settingsByDimension))
        )
    }

    /// 查询二级书籍列表，按上下文实时读取，避免依赖导航时刻的静态数组。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfBookList(
        _ db: Database,
        context: BookshelfListContext,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) throws -> BookshelfBookListSnapshot {
        let keyword = normalizedSearchKeyword(searchKeyword)
        let rows: [BookshelfBookAggregateRow]
        let title: String

        switch context {
        case .defaultGroup(let groupID):
            let group = try fetchBookshelfGroupPayload(db, groupID: groupID, searchKeyword: "")
            let allRows = try fetchAllBookshelfBookRows(db)
            let groupBookIDs = Set(try fetchOrderedBookIDs(inGroup: groupID, db: db))
            let filteredRows = filterBooks(allRows, keyword: keyword)
                .filter { groupBookIDs.contains($0.payload.id) }
            let sortedRows = sortBookRows(filteredRows, setting: setting)
            title = group?.name ?? "分组"
            return BookshelfBookListSnapshot(
                title: title,
                subtitle: "\(sortedRows.count)本",
                sections: makeBookListSections(from: sortedRows, setting: setting)
            )
        case .readStatus(let statusID):
            let allRows = filterBooks(try fetchAllBookshelfBookRows(db), keyword: keyword)
            rows = allRows.filter { row in
                if let statusID {
                    return row.payload.readStatusId == statusID
                }
                return row.payload.readStatusId == 0 || row.payload.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            title = rows.first?.payload.readStatusName.nonEmptyOrNil ?? "未设置状态"
        case .tag(let tagID):
            let allRows = filterBooks(try fetchAllBookshelfBookRows(db), keyword: keyword)
            let tagsByBook = try fetchBookshelfTagsByBook(db)
            if let tagID {
                rows = allRows.filter { (tagsByBook[$0.payload.id] ?? []).contains { $0.id == tagID } }
                title = tagsByBook.values.flatMap { $0 }.first(where: { $0.id == tagID })?.name ?? "标签"
            } else {
                rows = allRows.filter { (tagsByBook[$0.payload.id] ?? []).isEmpty }
                title = "未设置标签"
            }
        case .source(let sourceID):
            let allRows = filterBooks(try fetchAllBookshelfBookRows(db), keyword: keyword)
            if let sourceID {
                rows = allRows.filter { $0.payload.sourceId == sourceID && !$0.sourceIsHidden }
                title = rows.first?.payload.sourceName.nonEmptyOrNil ?? "来源"
            } else {
                rows = allRows.filter {
                    $0.payload.sourceId == 0
                        || $0.sourceIsHidden
                        || $0.payload.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                title = "未知来源"
            }
        case .rating(let score):
            rows = filterBooks(try fetchAllBookshelfBookRows(db), keyword: keyword)
                .filter { ratingGroupScore(for: $0.payload.score) == score }
            title = score == 0 ? "未评分" : ratingTitle(for: score)
        case .author(let author):
            rows = filterBooks(try fetchAllBookshelfBookRows(db), keyword: keyword)
                .filter { normalizedAuthorName($0.payload.author) == author }
            title = author
        case .press(let press):
            rows = filterBooks(try fetchAllBookshelfBookRows(db), keyword: keyword)
                .filter { normalizedPressName($0.press) == press }
            title = press
        }

        let sortedRows = sortBookRows(rows, setting: setting)
        return BookshelfBookListSnapshot(
            title: title,
            subtitle: "\(sortedRows.count)本",
            sections: makeBookListSections(from: sortedRows, setting: setting)
        )
    }

    /// 查询默认书架混排列表，对齐 Android `getDefaultBookList(CUSTOM)` 的只读展示语义。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelf(
        _ db: Database,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        let topLevelBooks = try fetchTopLevelBookshelfBooks(db, searchKeyword: searchKeyword)
        let groups = try fetchBookshelfGroups(db, searchKeyword: searchKeyword)
        let indexedItems = (topLevelBooks + groups).enumerated().map { index, item in
            IndexedBookshelfItem(item: item, sourceIndex: index)
        }
        return sortBookshelfItems(indexedItems, setting: setting).map(\.item)
    }

    /// 查询不属于任何有效分组的书籍，作为默认书架顶层 Book 条目。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchTopLevelBookshelfBooks(
        _ db: Database,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        // SQL 目的：读取默认书架中不属于有效分组的顶层书籍，并补齐有效书摘数量、阅读时长与条件排序字段。
        // 涉及表：book b；LEFT JOIN note n 统计未删除书摘；LEFT JOIN read_status/source 补齐聚合展示字段；LEFT JOIN read_time_record 聚合总阅读秒数；子查询使用 group_book gb JOIN `group` g 排除仍处于有效分组中的书籍。
        // 关键过滤：b.is_deleted = 0、b.id != 0；n.is_deleted = 0；gb.is_deleted = 0；g.is_deleted = 0；搜索过滤在 Swift 层按书名/作者/阅读状态/来源执行。
        // 排序用途：返回 book_order / pinned / pin_order、created_date / updated_date / pub_date / read_status_changed_date / read_position 等字段，最终在 Swift 层按 Android 显示设置统一混排。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.pub_date, b.source_id, b.score,
                   b.read_status_id, COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   b.pinned, b.pin_order, b.book_order,
                   b.created_date, b.updated_date, b.read_status_changed_date,
                   b.read_position, b.total_position, b.total_pagination,
                   COALESCE(rt.total_reading_time, 0) AS total_reading_time,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
            WHERE b.is_deleted = 0
              AND b.id != 0
              AND b.id NOT IN (
                  SELECT gb.book_id
                  FROM group_book gb
                  JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
                  WHERE gb.is_deleted = 0
            )
            GROUP BY b.id
            """
        let keyword = normalizedSearchKeyword(searchKeyword)
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            let id: Int64 = row["id"]
            let name: String = row["name"] ?? ""
            let author: String = row["author"] ?? ""
            let readStatusName: String = row["read_status_name"] ?? ""
            let sourceName: String = row["source_name"] ?? ""
            guard bookMatchesSearch(
                name: name,
                author: author,
                readStatusName: readStatusName,
                sourceName: sourceName,
                keyword: keyword
            ) else {
                return nil
            }
            let payload = BookshelfBookPayload(
                id: id,
                name: name,
                author: author,
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                readStatusName: readStatusName,
                sourceId: row["source_id"] ?? 0,
                sourceName: sourceName,
                press: "",
                score: row["score"] ?? 0,
                noteCount: row["note_count"] ?? 0
            )
            return BookshelfItem(
                id: .book(id),
                pinned: (row["pinned"] as Int64? ?? 0) != 0,
                pinOrder: row["pin_order"] ?? 0,
                sortOrder: row["book_order"] ?? 0,
                sortMetadata: BookshelfItemSortMetadata(
                    createdDate: row["created_date"] ?? 0,
                    modifiedDate: row["updated_date"] ?? 0,
                    publishDate: publishTimestamp(from: row["pub_date"] ?? ""),
                    noteCount: row["note_count"] ?? 0,
                    rating: row["score"] ?? 0,
                    readDoneDate: row["read_status_changed_date"] ?? 0,
                    totalReadingTime: row["total_reading_time"] ?? 0,
                    readingProgress: readingProgress(
                        readPosition: row["read_position"] ?? 0.0,
                        totalPosition: row["total_position"] ?? 0,
                        totalPagination: row["total_pagination"] ?? 0
                    ),
                    bookCount: 1
                ),
                content: .book(payload)
            )
        }
    }

    /// 查询默认书架中的有效分组，过滤空分组并聚合代表封面。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfGroups(
        _ db: Database,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        // SQL 目的：读取默认书架有效分组及其有效组内书籍，用于生成顶层 Group 条目、代表封面和条件排序元数据。
        // 涉及表：`group` g JOIN group_book gb JOIN book b；LEFT JOIN read_time_record 聚合组内书籍总阅读秒数。
        // 关键过滤：g.is_deleted = 0、gb.is_deleted = 0、b.is_deleted = 0、b.id != 0；无有效书籍的分组不会出现在 JOIN 结果中；搜索过滤在 Swift 层按组名/组内书名/作者/阅读状态/来源执行。
        // 排序用途：返回 group_order / pinned / pin_order、group/book 创建修改时间、出版时间、评分、读完时间、阅读进度等字段，Swift 层继续按 Android 显示设置处理。
        let sql = """
            SELECT g.id AS group_id,
                   COALESCE(g.name, '') AS group_name,
                   g.group_order,
                   g.pinned AS group_pinned,
                   g.pin_order AS group_pin_order,
                   g.created_date AS group_created_date,
                   b.id AS book_id,
                   b.name AS book_name,
                   b.author AS book_author,
                   b.cover AS book_cover,
                   b.pub_date AS book_pub_date,
                   COALESCE(rs.name, '') AS book_read_status_name,
                   COALESCE(s.name, '') AS book_source_name,
                   (
                       SELECT COUNT(n.id)
                       FROM note n
                       WHERE n.book_id = b.id
                         AND n.is_deleted = 0
                   ) AS note_count,
                   b.created_date AS book_created_date,
                   b.updated_date AS book_updated_date,
                   b.score AS book_score,
                   b.read_status_changed_date AS book_read_status_changed_date,
                   b.read_position AS book_read_position,
                   b.total_position AS book_total_position,
                   b.total_pagination AS book_total_pagination,
                   COALESCE(rt.total_reading_time, 0) AS book_total_reading_time,
                   b.book_order AS book_order,
                   b.pinned AS book_pinned,
                   b.pin_order AS book_pin_order
            FROM `group` g
            JOIN group_book gb ON gb.group_id = g.id AND gb.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
            WHERE g.is_deleted = 0
            ORDER BY g.group_order ASC, g.id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)
        var orderedGroupIDs: [Int64] = []
        var builders: [Int64: BookshelfGroupBuilder] = [:]

        for row in rows {
            let groupID: Int64 = row["group_id"]
            if builders[groupID] == nil {
                let rawGroupName: String = row["group_name"] ?? ""
                orderedGroupIDs.append(groupID)
                builders[groupID] = BookshelfGroupBuilder(
                    id: groupID,
                    name: rawGroupName.isEmpty ? "未命名分组" : rawGroupName,
                    pinned: (row["group_pinned"] as Int64? ?? 0) != 0,
                    pinOrder: row["group_pin_order"] ?? 0,
                    sortOrder: row["group_order"] ?? 0,
                    createdDate: row["group_created_date"] ?? 0,
                    books: []
                )
            }
            guard var builder = builders[groupID] else { continue }
            builder.append(
                BookshelfGroupBookPreview(
                    id: row["book_id"],
                    name: row["book_name"] ?? "",
                    author: row["book_author"] ?? "",
                    readStatusName: row["book_read_status_name"] ?? "",
                    sourceName: row["book_source_name"] ?? "",
                    cover: row["book_cover"] ?? "",
                    noteCount: row["note_count"] ?? 0,
                    createdDate: row["book_created_date"] ?? 0,
                    modifiedDate: row["book_updated_date"] ?? 0,
                    publishDate: publishTimestamp(from: row["book_pub_date"] ?? ""),
                    score: row["book_score"] ?? 0,
                    readDoneDate: row["book_read_status_changed_date"] ?? 0,
                    totalReadingTime: row["book_total_reading_time"] ?? 0,
                    readingProgress: readingProgress(
                        readPosition: row["book_read_position"] ?? 0.0,
                        totalPosition: row["book_total_position"] ?? 0,
                        totalPagination: row["book_total_pagination"] ?? 0
                    ),
                    pinned: (row["book_pinned"] as Int64? ?? 0) != 0,
                    pinOrder: row["book_pin_order"] ?? 0,
                    sortOrder: row["book_order"] ?? 0
                )
            )
            builders[groupID] = builder
        }

        return orderedGroupIDs.compactMap { groupID in
            builders[groupID]?.makeItem(searchKeyword: normalizedSearchKeyword(searchKeyword))
        }
    }

    /// 查询单个默认分组的组内书籍，用于二级列表实时观察。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfGroupPayload(
        _ db: Database,
        groupID: Int64,
        searchKeyword: String
    ) throws -> BookshelfGroupPayload? {
        let items = try fetchBookshelfGroups(db, searchKeyword: searchKeyword)
        return items.compactMap { item -> BookshelfGroupPayload? in
            guard case .group(let payload) = item.content, payload.id == groupID else {
                return nil
            }
            return payload
        }.first
    }

    nonisolated func fetchBookIDs(inGroup groupID: Int64, db: Database) throws -> Set<Int64> {
        // SQL 目的：读取指定有效分组下仍有效的书籍 ID，供二级分组列表按当前显示设置重新排序。
        // 涉及表：group_book gb JOIN `group` g JOIN book b。
        // 关键过滤：gb.group_id = ?；gb/g/b 均要求 is_deleted = 0，b.id != 0。
        // 返回字段用途：仅用于在 Swift 层筛选 `fetchAllBookshelfBookRows` 已补齐的排序元数据，不产生写入副作用。
        let sql = """
            SELECT gb.book_id
            FROM group_book gb
            JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE gb.is_deleted = 0
              AND gb.group_id = ?
            """
        return Set(try Int64.fetchAll(db, sql: sql, arguments: [groupID]))
    }

    nonisolated func fetchOrderedBookIDs(inGroup groupID: Int64, db: Database) throws -> [Int64] {
        // SQL 目的：读取指定有效分组下仍有效书籍的当前 Android 自定义排序顺序。
        // 涉及表：group_book gb JOIN `group` g JOIN book b。
        // 关键过滤：gb.group_id = ?；gb/g/b 均要求 is_deleted = 0，b.id != 0；同一本书存在多个有效关系时仅保留最早关系。
        // 返回字段用途：组内拖拽排序写入前校验候选 ID，并为漏传书籍补齐稳定尾部顺序。
        let sql = """
            SELECT b.id
            FROM group_book gb
            JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE gb.is_deleted = 0
              AND gb.group_id = ?
              AND gb.id = (
                  SELECT gb2.id
                  FROM group_book gb2
                  WHERE gb2.book_id = b.id
                    AND gb2.is_deleted = 0
                  ORDER BY gb2.created_date ASC, gb2.id ASC
                  LIMIT 1
              )
            ORDER BY b.pinned DESC, b.pin_order DESC, b.book_order ASC, b.id ASC
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [groupID])
    }

    nonisolated func maxBookPinOrder(inGroup groupID: Int64, db: Database) throws -> Int64 {
        // SQL 目的：读取指定分组内有效书籍的最大 pin_order。
        // 涉及表：group_book JOIN book。
        // 关键过滤：group_book.group_id = ?，book/group_book 均未软删除。
        // 返回字段用途：组内批量置顶时从最大 pin_order 之后连续追加。
        let sql = """
            SELECT MAX(book.pin_order)
            FROM group_book
            JOIN book ON group_book.book_id = book.id
            WHERE group_book.group_id = ?
              AND book.is_deleted = 0
              AND group_book.is_deleted = 0
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0
    }

    nonisolated func isBookPinned(_ db: Database, bookID: Int64) throws -> Bool {
        // SQL 目的：查询指定 Book 是否已经置顶。
        // 涉及表：book。
        // 关键过滤：严格对齐 Android queryPinnedCount，仅过滤 pinned 与 id，不追加 is_deleted。
        // 返回字段用途：组内批量置顶时跳过已置顶 Book。
        let sql = """
            SELECT COUNT(*)
            FROM book
            WHERE pinned = 1
              AND id = ?
            """
        return try (Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
    }

    /// 复刻 Android `BookListFormatHelper.formatByCustom` 的默认书架排序规则。
    nonisolated func sortByAndroidCustomOrder(_ items: [IndexedBookshelfItem]) -> [IndexedBookshelfItem] {
        let pinned = items
            .filter(\.item.pinned)
            .sorted { lhs, rhs in
                if lhs.item.pinOrder != rhs.item.pinOrder {
                    return lhs.item.pinOrder > rhs.item.pinOrder
                }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        let notPinned = items
            .filter { !$0.item.pinned }
            .sorted { lhs, rhs in
                if lhs.item.sortOrder != rhs.item.sortOrder {
                    return lhs.item.sortOrder < rhs.item.sortOrder
                }
                return lhs.sourceIndex < rhs.sourceIndex
        }
        return pinned + notPinned
    }

    /// 按当前显示设置排序默认书架 Book/Group，条件排序时保留 Android 的可选置顶前置语义。
    nonisolated func sortBookshelfItems(
        _ items: [IndexedBookshelfItem],
        setting: BookshelfDisplaySetting
    ) -> [IndexedBookshelfItem] {
        guard setting.sortCriteria != .custom else {
            return sortByAndroidCustomOrder(items)
        }
        return sortedWithOptionalPinned(
            items,
            setting: setting,
            isPinned: { $0.item.pinned },
            pinOrder: { $0.item.pinOrder }
        ) { lhs, rhs in
            compareBookshelfItems(lhs, rhs, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    nonisolated func sortedWithOptionalPinned<T>(
        _ values: [T],
        setting: BookshelfDisplaySetting,
        isPinned: (T) -> Bool,
        pinOrder: (T) -> Int64,
        comparator: (T, T) -> Bool
    ) -> [T] {
        guard setting.pinnedInAllSorts else {
            return values.sorted(by: comparator)
        }
        let pinned = values.filter(isPinned).sorted {
            let lhsPinOrder = pinOrder($0)
            let rhsPinOrder = pinOrder($1)
            if lhsPinOrder != rhsPinOrder {
                return lhsPinOrder > rhsPinOrder
            }
            return comparator($0, $1)
        }
        let normal = values.filter { !isPinned($0) }.sorted(by: comparator)
        return pinned + normal
    }

    /// 查询所有有效书籍，作为非默认维度聚合的统一数据源。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchAllBookshelfBookRows(_ db: Database) throws -> [BookshelfBookAggregateRow] {
        // SQL 目的：读取所有有效书籍并补齐阅读状态、来源、评分、置顶排序、有效书摘数量、阅读时长与条件排序字段，供多维度聚合和二级列表复用。
        // 涉及表：book b；LEFT JOIN note n 统计有效书摘；LEFT JOIN read_status rs/source s 读取维度标题与排序字段；LEFT JOIN read_time_record 聚合总阅读秒数。
        // 关键过滤：b.is_deleted = 0、b.id != 0；n.is_deleted = 0；rs/s 仅连接未软删除记录。
        // 返回字段用途：Book payload 用于 UI 代表封面，order/pin/source/read_status 与创建、修改、出版、读完、阅读进度字段用于 Swift 层稳定聚合和二级列表排序。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press, b.pub_date,
                   b.read_status_id,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(rs.read_status_order, 999999) AS read_status_order,
                   b.source_id,
                   COALESCE(s.name, '') AS source_name,
                   COALESCE(s.source_order, 999999) AS source_order,
                   COALESCE(s.is_hide, 1) AS source_is_hide,
                   b.score, b.pinned, b.pin_order, b.book_order,
                   b.created_date, b.updated_date, b.read_status_changed_date,
                   b.read_position, b.total_position, b.total_pagination,
                   COALESCE(rt.total_reading_time, 0) AS total_reading_time,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON n.book_id = b.id AND n.is_deleted = 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
            WHERE b.is_deleted = 0
              AND b.id != 0
            GROUP BY b.id
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let payload = BookshelfBookPayload(
                id: row["id"],
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                readStatusName: row["read_status_name"] ?? "",
                sourceId: row["source_id"] ?? 0,
                sourceName: row["source_name"] ?? "",
                press: row["press"] ?? "",
                score: row["score"] ?? 0,
                noteCount: row["note_count"] ?? 0
            )
            return BookshelfBookAggregateRow(
                payload: payload,
                press: row["press"] ?? "",
                readStatusOrder: row["read_status_order"] ?? 999999,
                sourceOrder: row["source_order"] ?? 999999,
                sourceIsHidden: (row["source_is_hide"] as Int64? ?? 1) != 0,
                pinned: (row["pinned"] as Int64? ?? 0) != 0,
                pinOrder: row["pin_order"] ?? 0,
                sortOrder: row["book_order"] ?? 0,
                createdDate: row["created_date"] ?? 0,
                modifiedDate: row["updated_date"] ?? 0,
                publishDate: publishTimestamp(from: row["pub_date"] ?? ""),
                readDoneDate: row["read_status_changed_date"] ?? 0,
                totalReadingTime: row["total_reading_time"] ?? 0,
                readingProgress: readingProgress(
                    readPosition: row["read_position"] ?? 0.0,
                    totalPosition: row["total_position"] ?? 0,
                    totalPagination: row["total_pagination"] ?? 0
                )
            )
        }
    }

    /// 查询有效书籍标签关系，供标签维度构建聚合卡。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfTagsByBook(_ db: Database) throws -> [Int64: [BookshelfTagInfo]] {
        // SQL 目的：读取书籍标签关系，供首页标签维度按书籍聚合。
        // 涉及表：tag_book tb JOIN tag t。
        // 关键过滤：tb.is_deleted = 0、t.is_deleted = 0、t.type = 1（书籍标签）。
        // 返回字段用途：book_id 用于归并，tag_order 用于标签卡排序。
        let sql = """
            SELECT tb.book_id, t.id AS tag_id, COALESCE(t.name, '') AS tag_name, t.tag_order
            FROM tag_book tb
            JOIN tag t ON t.id = tb.tag_id
            WHERE tb.is_deleted = 0
              AND t.is_deleted = 0
              AND t.type = 1
            ORDER BY t.tag_order ASC, t.id ASC
            """
        var result: [Int64: [BookshelfTagInfo]] = [:]
        for row in try Row.fetchAll(db, sql: sql) {
            let bookID: Int64 = row["book_id"]
            let tagName: String = row["tag_name"] ?? ""
            let info = BookshelfTagInfo(
                id: row["tag_id"],
                name: tagName.isEmpty ? "未命名标签" : tagName,
                order: row["tag_order"] ?? 0
            )
            result[bookID, default: []].append(info)
        }
        return result
    }

    nonisolated func filterBooks(
        _ books: [BookshelfBookAggregateRow],
        keyword: String
    ) -> [BookshelfBookAggregateRow] {
        guard !keyword.isEmpty else { return books }
        return books.filter {
            bookMatchesSearch(
                name: $0.payload.name,
                author: $0.payload.author,
                readStatusName: $0.payload.readStatusName,
                sourceName: $0.payload.sourceName,
                keyword: keyword
            )
        }
    }

    nonisolated func makeStatusSections(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfSection] {
        let grouped = Dictionary(grouping: books) { row in
            statusKey(for: row)
        }
        let sections = grouped.sorted { lhs, rhs in
            if lhs.key.order != rhs.key.order {
                return lhs.key.order < rhs.key.order
            }
            return lhs.key.id < rhs.key.id
        }.map { key, rows in
            let sortedRows = sortBooksByShelfOrder(rows)
            return BookshelfSection(
                id: "status-\(key.id)",
                title: key.title,
                subtitle: "\(sortedRows.count)本",
                context: .readStatus(key.id == 0 ? nil : key.id),
                orderID: key.id == 0 ? nil : key.id,
                sortMetadata: sortMetadata(from: sortedRows),
                books: sortedRows.map(\.payload)
            )
        }
        return sortAggregateSections(sections, dimension: .status, setting: setting)
    }

    nonisolated func makeTagGroups(
        from books: [BookshelfBookAggregateRow],
        tagsByBook: [Int64: [BookshelfTagInfo]],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
        var untaggedBooks: [BookshelfBookAggregateRow] = []
        var taggedBooks: [BookshelfTagInfo: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let tags = tagsByBook[book.payload.id] ?? []
            if tags.isEmpty {
                untaggedBooks.append(book)
            } else {
                for tag in tags {
                    taggedBooks[tag, default: []].append(book)
                }
            }
        }

        var groups: [BookshelfAggregateGroup] = []
        if !untaggedBooks.isEmpty {
            groups.append(makeAggregateGroup(
                id: "tag-untagged",
                title: "未设置标签",
                context: .tag(nil),
                orderID: nil,
                rows: untaggedBooks
            ))
        }

        groups.append(contentsOf: taggedBooks
            .sorted { lhs, rhs in
                if lhs.key.order != rhs.key.order {
                    return lhs.key.order < rhs.key.order
                }
                return lhs.key.name.localizedStandardCompare(rhs.key.name) == .orderedAscending
            }
            .map { tag, rows in
                makeAggregateGroup(
                    id: "tag-\(tag.id)",
                    title: tag.name,
                    context: .tag(tag.id),
                    orderID: tag.id,
                    rows: rows
                )
            })
        return sortAggregateGroups(groups, dimension: .tag, setting: setting)
    }

    nonisolated func makeSourceGroups(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
        var unknownBooks: [BookshelfBookAggregateRow] = []
        var sourceBooks: [Int64: [BookshelfBookAggregateRow]] = [:]
        var sourceTitles: [Int64: String] = [:]
        var sourceOrders: [Int64: Int64] = [:]

        for book in books {
            let sourceName = book.payload.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if book.payload.sourceId == 0 || book.sourceIsHidden || sourceName.isEmpty {
                unknownBooks.append(book)
            } else {
                sourceBooks[book.payload.sourceId, default: []].append(book)
                sourceTitles[book.payload.sourceId] = sourceName
                sourceOrders[book.payload.sourceId] = book.sourceOrder
            }
        }

        var groups: [BookshelfAggregateGroup] = []
        if !unknownBooks.isEmpty {
            groups.append(makeAggregateGroup(
                id: "source-unknown",
                title: "未知来源",
                context: .source(nil),
                orderID: nil,
                rows: unknownBooks
            ))
        }
        groups.append(contentsOf: sourceBooks.keys.sorted { lhs, rhs in
            let lhsOrder = sourceOrders[lhs] ?? 999999
            let rhsOrder = sourceOrders[rhs] ?? 999999
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs < rhs
        }.map { sourceID in
            makeAggregateGroup(
                id: "source-\(sourceID)",
                title: sourceTitles[sourceID] ?? "未知来源",
                context: .source(sourceID),
                orderID: sourceID,
                rows: sourceBooks[sourceID] ?? []
            )
        })
        return sortAggregateGroups(groups, dimension: .source, setting: setting)
    }

    nonisolated func makeRatingSections(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfSection] {
        let grouped: [Int64: [BookshelfBookAggregateRow]] = Dictionary(grouping: books) { row in
            ratingGroupScore(for: row.payload.score)
        }
        let orderedScores = grouped.keys.sorted { lhs, rhs in
            if lhs == 0 { return true }
            if rhs == 0 { return false }
            return lhs > rhs
        }
        let sections: [BookshelfSection] = orderedScores.compactMap { score in
            guard let rows = grouped[score], !rows.isEmpty else { return nil }
            let sortedRows = score == 0 ? sortBooksByShelfOrder(rows) : rows.sorted {
                if $0.payload.score != $1.payload.score {
                    return $0.payload.score > $1.payload.score
                }
                return $0.payload.name.localizedStandardCompare($1.payload.name) == .orderedAscending
            }
            return BookshelfSection(
                id: "rating-\(score)",
                title: score == 0 ? "未评分" : ratingTitle(for: score),
                subtitle: "\(sortedRows.count)本",
                context: .rating(score),
                orderID: nil,
                sortMetadata: sortMetadata(from: sortedRows),
                books: sortedRows.map(\.payload)
            )
        }
        return sortAggregateSections(sections, dimension: .rating, setting: setting)
    }

    nonisolated func makeAuthorSections(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAuthorSection] {
        var authors: [String: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let name = normalizedAuthorName(book.payload.author)
            authors[name, default: []].append(book)
        }

        let authorGroups = authors.map { author, rows in
            makeAggregateGroup(
                id: "author-\(author)",
                title: author,
                context: .author(author),
                orderID: nil,
                rows: rows
            )
        }
        let sortedGroups = sortAggregateGroups(authorGroups, dimension: .author, setting: setting)
        guard setting.sortCriteria == .authorName else {
            return [
                BookshelfAuthorSection(
                    id: "author-all",
                    title: "",
                    authors: sortedGroups
                )
            ]
        }

        let grouped = Dictionary(grouping: sortedGroups) { authorInitial($0.title) }
        return grouped.keys.sorted { lhs, rhs in
            authorSectionComparator(lhs, rhs, order: setting.sortOrder)
        }.compactMap { key in
            guard let values = grouped[key] else { return nil }
            return BookshelfAuthorSection(
                id: key,
                title: key,
                authors: sortAggregateGroups(values, dimension: .author, setting: setting)
            )
        }
    }

    nonisolated func makePressGroups(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
        var presses: [String: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let press = normalizedPressName(book.press)
            presses[press, default: []].append(book)
        }

        let groups = presses.map { press, rows in
            makeAggregateGroup(
                id: "press-\(press)",
                title: press,
                context: .press(press),
                orderID: nil,
                rows: rows
            )
        }
        return sortAggregateGroups(groups, dimension: .press, setting: setting)
    }

    nonisolated func makeAggregateGroup(
        id: String,
        title: String,
        context: BookshelfListContext,
        orderID: Int64?,
        rows: [BookshelfBookAggregateRow]
    ) -> BookshelfAggregateGroup {
        let sortedRows = sortBooksByShelfOrder(rows)
        return BookshelfAggregateGroup(
            id: id,
            title: title,
            subtitle: "\(sortedRows.count)本",
            count: sortedRows.count,
            context: context,
            orderID: orderID,
            sortMetadata: sortMetadata(from: sortedRows),
            representativeCovers: sortedRows.prefix(6).map(\.payload.cover),
            books: sortedRows.map { BookshelfBookListItem(payload: $0.payload, pinned: $0.pinned) }
        )
    }

    /// 按当前显示设置生成默认书架分区；未启用分区时返回单个无标题 section。
    nonisolated func makeDefaultSections(
        from items: [BookshelfItem],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfDefaultSection] {
        guard !items.isEmpty else { return [] }
        guard setting.isSectionEnabled, setting.sortCriteria.supportsSection else {
            return [
                BookshelfDefaultSection(
                    id: "default",
                    title: nil,
                    items: items
                )
            ]
        }
        var orderedKeys: [BookshelfDisplaySectionKey] = []
        var groupedItems: [BookshelfDisplaySectionKey: [BookshelfItem]] = [:]
        for item in items {
            let key = sectionKey(for: item, criteria: setting.sortCriteria)
            if groupedItems[key] == nil {
                orderedKeys.append(key)
            }
            groupedItems[key, default: []].append(item)
        }
        return orderedKeys.map { key in
            BookshelfDefaultSection(
                id: key.id,
                title: key.title,
                items: groupedItems[key] ?? []
            )
        }
    }

    /// 按二级列表显示设置生成书籍分区；未启用分区时返回单个无标题 section。
    nonisolated func makeBookListSections(
        from rows: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfBookListSection] {
        guard !rows.isEmpty else { return [] }
        guard setting.isSectionEnabled, setting.sortCriteria.supportsSection else {
            return [
                BookshelfBookListSection(
                    id: "books",
                    title: nil,
                    books: rows.map { BookshelfBookListItem(payload: $0.payload, pinned: $0.pinned) }
                )
            ]
        }
        var orderedKeys: [BookshelfDisplaySectionKey] = []
        var groupedRows: [BookshelfDisplaySectionKey: [BookshelfBookAggregateRow]] = [:]
        for row in rows {
            let key = sectionKey(for: row, criteria: setting.sortCriteria)
            if groupedRows[key] == nil {
                orderedKeys.append(key)
            }
            groupedRows[key, default: []].append(row)
        }
        return orderedKeys.map { key in
            BookshelfBookListSection(
                id: key.id,
                title: key.title,
                books: (groupedRows[key] ?? []).map { BookshelfBookListItem(payload: $0.payload, pinned: $0.pinned) }
            )
        }
    }

    /// 对聚合卡执行 Repository 级排序，保留未设置标签/来源/状态/评分的 Android 前置语义。
    nonisolated func sortAggregateGroups(
        _ groups: [BookshelfAggregateGroup],
        dimension: BookshelfDimension,
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
        guard setting.sortCriteria != .custom else { return groups }
        let fixedGroups = groups.filter { isFixedLeadingAggregate($0, dimension: dimension) }
        let sortableGroups = groups.filter { !isFixedLeadingAggregate($0, dimension: dimension) }
        return fixedGroups + sortableGroups.sorted {
            compareAggregateGroups($0, $1, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    /// 对状态/评分这类 section 聚合执行 Repository 级排序。
    nonisolated func sortAggregateSections(
        _ sections: [BookshelfSection],
        dimension: BookshelfDimension,
        setting: BookshelfDisplaySetting
    ) -> [BookshelfSection] {
        guard setting.sortCriteria != .custom else { return sections }
        let fixedSections = sections.filter { isFixedLeadingSection($0, dimension: dimension) }
        let sortableSections = sections.filter { !isFixedLeadingSection($0, dimension: dimension) }
        return fixedSections + sortableSections.sorted {
            compareAggregateSections($0, $1, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    nonisolated func isFixedLeadingAggregate(_ group: BookshelfAggregateGroup, dimension: BookshelfDimension) -> Bool {
        switch dimension {
        case .status, .tag, .source:
            return group.orderID == nil
        case .rating:
            if case .rating(let score) = group.context {
                return score == 0
            }
            return false
        case .default, .author, .press:
            return false
        }
    }

    nonisolated func isFixedLeadingSection(_ section: BookshelfSection, dimension: BookshelfDimension) -> Bool {
        switch dimension {
        case .status:
            return section.orderID == nil
        case .rating:
            if case .rating(let score) = section.context {
                return score == 0
            }
            return false
        case .default, .tag, .source, .author, .press:
            return false
        }
    }

    nonisolated func compareAggregateGroups(
        _ lhs: BookshelfAggregateGroup,
        _ rhs: BookshelfAggregateGroup,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let tieBreaker = lhs.id < rhs.id
        switch criteria {
        case .custom:
            return tieBreaker
        case .bookCount:
            return compareInt(Int64(lhs.count), Int64(rhs.count), order: order, missingLast: false, tie: tieBreaker)
        case .createdDate:
            return compareInt(lhs.sortMetadata.createdDate, rhs.sortMetadata.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhs.sortMetadata.modifiedDate, rhs.sortMetadata.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhs.sortMetadata.publishDate, rhs.sortMetadata.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .noteCount:
            return compareInt(Int64(lhs.sortMetadata.noteCount), Int64(rhs.sortMetadata.noteCount), order: order, missingLast: false, tie: tieBreaker)
        case .rating:
            return compareInt(lhs.sortMetadata.rating, rhs.sortMetadata.rating, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhs.sortMetadata.readDoneDate, rhs.sortMetadata.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhs.sortMetadata.totalReadingTime, rhs.sortMetadata.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhs.sortMetadata.readingProgress, rhs.sortMetadata.readingProgress, order: order, tie: tieBreaker)
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return compareText(lhs.title, rhs.title, order: order, tie: tieBreaker)
        }
    }

    nonisolated func compareAggregateSections(
        _ lhs: BookshelfSection,
        _ rhs: BookshelfSection,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        compareAggregateGroups(
            BookshelfAggregateGroup(
                id: lhs.id,
                title: lhs.title,
                subtitle: lhs.subtitle,
                count: lhs.count,
                context: lhs.context,
                orderID: lhs.orderID,
                sortMetadata: lhs.sortMetadata,
                representativeCovers: [],
                books: []
            ),
            BookshelfAggregateGroup(
                id: rhs.id,
                title: rhs.title,
                subtitle: rhs.subtitle,
                count: rhs.count,
                context: rhs.context,
                orderID: rhs.orderID,
                sortMetadata: rhs.sortMetadata,
                representativeCovers: [],
                books: []
            ),
            criteria: criteria,
            order: order
        )
    }

    nonisolated func sortBooksByShelfOrder(_ rows: [BookshelfBookAggregateRow]) -> [BookshelfBookAggregateRow] {
        rows.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            if lhs.pinned, lhs.pinOrder != rhs.pinOrder {
                return lhs.pinOrder > rhs.pinOrder
            }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.payload.id < rhs.payload.id
        }
    }

    nonisolated func sortBookRows(
        _ rows: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfBookAggregateRow] {
        guard setting.sortCriteria != .custom else {
            return sortBooksByShelfOrder(rows)
        }
        return sortedWithOptionalPinned(
            rows,
            setting: setting,
            isPinned: { $0.pinned },
            pinOrder: { $0.pinOrder }
        ) { lhs, rhs in
            compareBookRows(lhs, rhs, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    nonisolated func sortMetadata(from rows: [BookshelfBookAggregateRow]) -> BookshelfItemSortMetadata {
        BookshelfItemSortMetadata(
            createdDate: rows.map(\.createdDate).min() ?? 0,
            modifiedDate: rows.map(\.modifiedDate).max() ?? 0,
            publishDate: rows.map(\.publishDate).max() ?? 0,
            noteCount: rows.reduce(0) { $0 + $1.payload.noteCount },
            rating: rows.map(\.payload.score).max() ?? 0,
            readDoneDate: rows.map(\.readDoneDate).max() ?? 0,
            totalReadingTime: rows.reduce(0) { $0 + $1.totalReadingTime },
            readingProgress: nil,
            bookCount: rows.count
        )
    }

    nonisolated func compareBookshelfItems(
        _ lhs: IndexedBookshelfItem,
        _ rhs: IndexedBookshelfItem,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let lhsItem = lhs.item
        let rhsItem = rhs.item
        let tieBreaker = lhs.sourceIndex < rhs.sourceIndex
        switch criteria {
        case .custom:
            return tieBreaker
        case .createdDate:
            return compareInt(lhsItem.sortMetadata.createdDate, rhsItem.sortMetadata.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhsItem.sortMetadata.modifiedDate, rhsItem.sortMetadata.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhsItem.sortMetadata.publishDate, rhsItem.sortMetadata.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return compareText(lhsItem.title, rhsItem.title, order: order, tie: tieBreaker)
        case .noteCount:
            return compareInt(Int64(lhsItem.sortMetadata.noteCount), Int64(rhsItem.sortMetadata.noteCount), order: order, missingLast: false, tie: tieBreaker)
        case .bookCount:
            return compareInt(Int64(lhsItem.sortMetadata.bookCount), Int64(rhsItem.sortMetadata.bookCount), order: order, missingLast: false, tie: tieBreaker)
        case .rating:
            return compareInt(lhsItem.sortMetadata.rating, rhsItem.sortMetadata.rating, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhsItem.sortMetadata.readDoneDate, rhsItem.sortMetadata.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhsItem.sortMetadata.totalReadingTime, rhsItem.sortMetadata.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhsItem.sortMetadata.readingProgress, rhsItem.sortMetadata.readingProgress, order: order, tie: tieBreaker)
        }
    }

    nonisolated func compareBookRows(
        _ lhs: BookshelfBookAggregateRow,
        _ rhs: BookshelfBookAggregateRow,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let tieBreaker = lhs.payload.id < rhs.payload.id
        switch criteria {
        case .custom, .bookCount:
            return compareInt(lhs.sortOrder, rhs.sortOrder, order: .ascending, missingLast: false, tie: tieBreaker)
        case .createdDate:
            return compareInt(lhs.createdDate, rhs.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhs.modifiedDate, rhs.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhs.publishDate, rhs.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .name:
            return compareText(lhs.payload.name, rhs.payload.name, order: order, tie: tieBreaker)
        case .noteCount:
            return compareInt(Int64(lhs.payload.noteCount), Int64(rhs.payload.noteCount), order: order, missingLast: false, tie: tieBreaker)
        case .rating:
            return compareInt(lhs.payload.score, rhs.payload.score, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhs.readDoneDate, rhs.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhs.totalReadingTime, rhs.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readStatus:
            if lhs.readStatusOrder != rhs.readStatusOrder {
                return order == .ascending ? lhs.readStatusOrder < rhs.readStatusOrder : lhs.readStatusOrder > rhs.readStatusOrder
            }
            return compareText(lhs.payload.readStatusName, rhs.payload.readStatusName, order: order, tie: tieBreaker)
        case .tagName:
            return compareText(lhs.payload.name, rhs.payload.name, order: order, tie: tieBreaker)
        case .authorName:
            return compareText(lhs.payload.author, rhs.payload.author, order: order, tie: tieBreaker)
        case .pressName:
            return compareText(lhs.press, rhs.press, order: order, tie: tieBreaker)
        case .source:
            if lhs.sourceOrder != rhs.sourceOrder {
                return order == .ascending ? lhs.sourceOrder < rhs.sourceOrder : lhs.sourceOrder > rhs.sourceOrder
            }
            return compareText(lhs.payload.sourceName, rhs.payload.sourceName, order: order, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhs.readingProgress, rhs.readingProgress, order: order, tie: tieBreaker)
        }
    }

    nonisolated func compareText(_ lhs: String, _ rhs: String, order: BookshelfSortOrder, tie: Bool) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        guard comparison != .orderedSame else { return tie }
        return order == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    nonisolated func compareInt(
        _ lhs: Int64,
        _ rhs: Int64,
        order: BookshelfSortOrder,
        missingLast: Bool,
        tie: Bool
    ) -> Bool {
        if missingLast {
            let lhsMissing = lhs == 0
            let rhsMissing = rhs == 0
            if lhsMissing != rhsMissing {
                return !lhsMissing
            }
        }
        guard lhs != rhs else { return tie }
        return order == .ascending ? lhs < rhs : lhs > rhs
    }

    nonisolated func compareOptionalDouble(
        _ lhs: Double?,
        _ rhs: Double?,
        order: BookshelfSortOrder,
        tie: Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return tie
        case (.none, .some):
            return false
        case (.some, .none):
            return true
        case (.some(let lhsValue), .some(let rhsValue)):
            guard lhsValue != rhsValue else { return tie }
            return order == .ascending ? lhsValue < rhsValue : lhsValue > rhsValue
        }
    }

    nonisolated func sectionKey(
        for item: BookshelfItem,
        criteria: BookshelfSortCriteria
    ) -> BookshelfDisplaySectionKey {
        switch criteria {
        case .createdDate:
            return monthSectionKey(timestamp: item.sortMetadata.createdDate, fallback: "未知创建时间", prefix: "created")
        case .modifiedDate:
            return monthSectionKey(timestamp: item.sortMetadata.modifiedDate, fallback: "未知修改时间", prefix: "modified")
        case .readDoneDate:
            return monthSectionKey(timestamp: item.sortMetadata.readDoneDate, fallback: "未读完", prefix: "read-done")
        case .publishDate:
            return yearSectionKey(timestamp: item.sortMetadata.publishDate, fallback: "未知出版年", prefix: "publish")
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return initialSectionKey(text: item.title, prefix: criteria.rawValue)
        case .custom, .noteCount, .bookCount, .rating, .totalReadingTime, .readingProgress:
            return BookshelfDisplaySectionKey(id: "all", title: "全部")
        }
    }

    nonisolated func sectionKey(
        for row: BookshelfBookAggregateRow,
        criteria: BookshelfSortCriteria
    ) -> BookshelfDisplaySectionKey {
        switch criteria {
        case .createdDate:
            return monthSectionKey(timestamp: row.createdDate, fallback: "未知创建时间", prefix: "created")
        case .modifiedDate:
            return monthSectionKey(timestamp: row.modifiedDate, fallback: "未知修改时间", prefix: "modified")
        case .readDoneDate:
            return monthSectionKey(timestamp: row.readDoneDate, fallback: "未读完", prefix: "read-done")
        case .publishDate:
            return yearSectionKey(timestamp: row.publishDate, fallback: "未知出版年", prefix: "publish")
        case .name:
            return initialSectionKey(text: row.payload.name, prefix: "name")
        case .readStatus:
            return initialSectionKey(text: row.payload.readStatusName, prefix: "read-status")
        case .tagName:
            return initialSectionKey(text: row.payload.name, prefix: "tag")
        case .authorName:
            return initialSectionKey(text: row.payload.author, prefix: "author")
        case .pressName:
            return initialSectionKey(text: row.press, prefix: "press")
        case .source:
            return initialSectionKey(text: row.payload.sourceName, prefix: "source")
        case .custom, .noteCount, .bookCount, .rating, .totalReadingTime, .readingProgress:
            return BookshelfDisplaySectionKey(id: "all", title: "全部")
        }
    }

    nonisolated func monthSectionKey(
        timestamp: Int64,
        fallback: String,
        prefix: String
    ) -> BookshelfDisplaySectionKey {
        guard timestamp > 0 else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        return BookshelfDisplaySectionKey(
            id: String(format: "%@-%04d-%02d", prefix, year, month),
            title: "\(year)年\(month)月"
        )
    }

    nonisolated func yearSectionKey(
        timestamp: Int64,
        fallback: String,
        prefix: String
    ) -> BookshelfDisplaySectionKey {
        guard timestamp > 0 else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        guard let year = Calendar.current.dateComponents([.year], from: date).year else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        return BookshelfDisplaySectionKey(id: "\(prefix)-\(year)", title: "\(year)年")
    }

    nonisolated func initialSectionKey(text: String, prefix: String) -> BookshelfDisplaySectionKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: "#")
        }
        let transformed = trimmed
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? trimmed
        guard let first = transformed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: "#")
        }
        let uppercased = String(first).uppercased()
        let title = ("A"..."Z").contains(uppercased) ? uppercased : "#"
        return BookshelfDisplaySectionKey(id: "\(prefix)-\(title)", title: title)
    }

    nonisolated func statusKey(for row: BookshelfBookAggregateRow) -> BookshelfStatusKey {
        let title = row.payload.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.payload.readStatusId != 0, !title.isEmpty else {
            return BookshelfStatusKey(id: 0, title: "未设置状态", order: -1)
        }
        return BookshelfStatusKey(id: row.payload.readStatusId, title: title, order: row.readStatusOrder)
    }

    /// 将数据库原始评分约束到 Android 评分范围，供评分维度分组使用。
    nonisolated func ratingGroupScore(for score: Int64) -> Int64 {
        max(Int64(0), min(score, Int64(50)))
    }

    /// 将 Android 原始评分转换为用户可见星级标题，异常值只在展示层裁剪。
    nonisolated func ratingTitle(for score: Int64) -> String {
        String(format: "%.1f", Double(ratingGroupScore(for: score)) / 10.0)
    }

    nonisolated func publishTimestamp(from pubDate: String) -> Int64 {
        let trimmed = pubDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let pattern = #"(\d{4})(?:[-/.年 ]+(\d{1,2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let yearRange = Range(match.range(at: 1), in: trimmed),
              let year = Int(trimmed[yearRange]) else {
            return 0
        }
        var month = 1
        if match.numberOfRanges > 2,
           let monthRange = Range(match.range(at: 2), in: trimmed),
           let parsedMonth = Int(trimmed[monthRange]) {
            month = max(1, min(parsedMonth, 12))
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = 1
        return components.date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }

    nonisolated func readingProgress(
        readPosition: Double,
        totalPosition: Int64,
        totalPagination: Int64
    ) -> Double? {
        let denominator: Double
        if totalPosition > 0 {
            denominator = Double(totalPosition)
        } else if totalPagination > 0 {
            denominator = Double(totalPagination)
        } else {
            return nil
        }
        let progress = readPosition / denominator * 100
        return progress > 0 ? progress : nil
    }

    nonisolated func normalizedSearchKeyword(_ searchKeyword: String?) -> String {
        searchKeyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated func setting(
        for dimension: BookshelfDimension,
        in settingsByDimension: [BookshelfDimension: BookshelfDisplaySetting]
    ) -> BookshelfDisplaySetting {
        settingsByDimension[dimension] ?? BookshelfDisplaySetting.defaultValue(for: dimension)
    }

    nonisolated func bookMatchesSearch(
        name: String,
        author: String,
        readStatusName: String,
        sourceName: String,
        keyword: String
    ) -> Bool {
        guard !keyword.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(keyword)
            || author.localizedCaseInsensitiveContains(keyword)
            || readStatusName.localizedCaseInsensitiveContains(keyword)
            || sourceName.localizedCaseInsensitiveContains(keyword)
    }

    nonisolated func normalizedAuthorName(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知作者" : trimmed
    }

    nonisolated func normalizedPressName(_ press: String) -> String {
        let trimmed = press.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知出版社" : trimmed
    }

    nonisolated func authorInitial(_ author: String) -> String {
        guard author != "未知作者" else { return "#" }
        let transformed = author
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? author
        guard let first = transformed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "#"
        }
        let uppercased = String(first).uppercased()
        return ("A"..."Z").contains(uppercased) ? uppercased : "#"
    }

    nonisolated func authorSectionComparator(_ lhs: String, _ rhs: String, order: BookshelfSortOrder) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return order == .ascending ? lhs < rhs : lhs > rhs
    }

    /// 查询书架页需要的书籍卡片数据，并补齐每本书的有效笔记数量。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBooks(_ db: Database) throws -> [BookItem] {
        // SQL 目的：读取书架列表并附带每本书的有效笔记数。
        // 表关系：book b LEFT JOIN note n（仅统计 n.is_deleted = 0）。
        // 过滤与排序：仅保留未删除书籍，按置顶状态与排序字段输出用于书架展示。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover,
                   b.read_status_id, b.pinned, b.pin_order, b.book_order,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            WHERE b.is_deleted = 0
            GROUP BY b.id
            ORDER BY b.pinned DESC, b.pin_order ASC, b.book_order ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)

        return rows.map { row in
            BookItem(
                id: row["id"],
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                noteCount: row["note_count"] ?? 0,
                pinned: (row["pinned"] as Int64? ?? 0) != 0
            )
        }
    }

    /// 查询书籍选择流需要的本地书籍列表，并按最近编辑优先排序。
    nonisolated func fetchPickerBooks(_ db: Database, matching query: String) throws -> [BookPickerBook] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // SQL 目的：读取本地可选书籍列表，供通用书籍选择流本地搜索与回显。
        // 涉及表：book。
        // 关键过滤：仅保留未软删除书籍；若存在 query，则匹配 name/author/press/isbn；按 updated_date DESC 对齐 Android 最近编辑优先。
        let baseSQL = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE is_deleted = 0
            """
        let sql: String
        let arguments: StatementArguments
        if trimmedQuery.isEmpty {
            sql = baseSQL + "\nORDER BY updated_date DESC, id DESC"
            arguments = []
        } else {
            sql = baseSQL + """
                
                AND (
                    name LIKE ?
                    OR author LIKE ?
                    OR press LIKE ?
                    OR isbn LIKE ?
                )
                ORDER BY updated_date DESC, id DESC
                """
            let pattern = "%\(trimmedQuery)%"
            arguments = [pattern, pattern, pattern, pattern]
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(mapPickerBook)
    }

    /// 查询单本本地书籍详情，供创建成功后的回填与默认已选恢复。
    nonisolated func fetchPickerBook(_ db: Database, bookId: Int64) throws -> BookPickerBook? {
        // SQL 目的：按主键读取单本本地书籍，供创建成功后回填到书籍选择流。
        // 涉及表：book。
        // 关键过滤：限定 id 精确命中，排除软删除书籍；返回 title/author/press/cover 与位置字段供选择行和回填使用。
        let sql = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE id = ? AND is_deleted = 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }
        return mapPickerBook(row)
    }

    /// 查询指定书籍详情数据，供详情页头部信息区与统计区渲染。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBook(_ db: Database, bookId: Int64) throws -> BookDetail? {
        // SQL 目的：读取单本书详情，并补充阅读状态名称与笔记总数。
        // 表关系：book b LEFT JOIN read_status rs；子查询统计 note 表有效记录。
        // 过滤条件：按 bookId 精确命中且排除软删除书籍。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press,
                   COALESCE(rs.name, '') AS read_status_name,
                   (SELECT COUNT(*) FROM note n
                    WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count
            FROM book b
            LEFT JOIN read_status rs ON b.read_status_id = rs.id
            WHERE b.id = ? AND b.is_deleted = 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }

        return BookDetail(
            id: row["id"],
            name: row["name"] ?? "",
            author: row["author"] ?? "",
            cover: row["cover"] ?? "",
            press: row["press"] ?? "",
            noteCount: row["note_count"] ?? 0,
            readStatusName: row["read_status_name"] ?? ""
        )
    }

    /// 查询书籍下的书摘列表，供详情页“书摘时间线”模块展示。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchNotes(_ db: Database, bookId: Int64) throws -> [NoteExcerpt] {
        // SQL 目的：拉取书籍下的书摘列表（详情页时间倒序）。
        // 过滤条件：限定 book_id 且排除软删除 note。
        // 返回字段：保留富文本内容、位置与 include_time，供详情页渲染。
        let sql = """
            SELECT id, content, idea, position, position_unit,
                   include_time, created_date
            FROM note
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY created_date DESC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [bookId])

        return rows.map { row in
            NoteExcerpt(
                id: row["id"],
                content: row["content"] ?? "",
                idea: row["idea"] ?? "",
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    nonisolated func mapPickerBook(_ row: Row) -> BookPickerBook {
        BookPickerBook(
            id: row["id"],
            title: row["name"] ?? "",
            author: row["author"] ?? "",
            press: row["press"] ?? "",
            coverURL: row["cover"] ?? "",
            positionUnit: row["position_unit"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0
        )
    }
}
