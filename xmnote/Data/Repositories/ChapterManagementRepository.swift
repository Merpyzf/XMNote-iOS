/**
 * [INPUT]: 依赖 DatabaseManager/GRDB/ObservationStream、BookRemoteSearchService、AppBackendConfigRepository 与 chapter/note/book Room v44 表
 * [OUTPUT]: 对外提供 ChapterManagementRepository（完整章节树观察、文曲/手工目录事务导入、新增、编辑、星标、可撤销重排移动与硬删除）
 * [POS]: Data/Repositories 的书内目录管理实现，对齐 Android ChapterRepository 并应用项目全局硬删除规则
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 章节管理仓储实现；parent_id 是结构真相，chapter_level/source_path 只作为派生元数据回写。
struct ChapterManagementRepository: ChapterManagementRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let remoteSearchService: BookRemoteSearchService
    private let appBackendConfigRepository: any AppBackendConfigRepositoryProtocol

    /// 注入数据库、远端书源与动态配置仓储，避免 ViewModel 直接访问网络或持久层。
    init(
        databaseManager: DatabaseManager,
        remoteSearchService: BookRemoteSearchService = .init(),
        appBackendConfigRepository: any AppBackendConfigRepositoryProtocol = AppBackendConfigRepository()
    ) {
        self.databaseManager = databaseManager
        self.remoteSearchService = remoteSearchService
        self.appBackendConfigRepository = appBackendConfigRepository
    }

    /// 观察完整目录树；任一 chapter/note/book 变化都会重新生成同一快照。
    func observeSnapshot(bookID: Int64) -> AsyncThrowingStream<ChapterManagementSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try Self.fetchSnapshot(db, bookID: bookID)
        }
    }

    /// 读取本地书籍匹配信息后获取文曲目录；动态配置由独立方法异步读取，不阻断目录 API。
    func discoverRemoteCatalog(bookID: Int64) async throws -> ChapterRemoteCatalogDiscovery {
        let context = try await databaseManager.database.dbPool.read { db in
            try Self.fetchRemoteCatalogContext(db, bookID: bookID)
        }
        let candidates = try await remoteSearchService.fetchWenquCatalogCandidates(
            doubanID: context.doubanID,
            bookTitle: context.bookTitle
        )
        return ChapterRemoteCatalogDiscovery(
            bookTitle: context.bookTitle,
            matchMode: context.doubanID == nil ? .bookTitleCandidates : .exactDoubanID,
            candidates: candidates
        )
    }

    /// 通过通用应用配置仓储获取并缓存 WENQU-CONFIG；网络失败由仓储回退最近缓存。
    func fetchRemoteConfigurationState() async -> ChapterRemoteConfigurationState {
        let value = await appBackendConfigRepository.queryValue(key: "WENQU-CONFIG")
        return Self.isUsableWenquConfiguration(value) ? .available : .unavailable
    }

    /// 原子导入选中目录；同名根章节按 Android 查询规则复用，并把导入区稳定追加到现有根目录末尾。
    func importRemoteCatalog(bookID: Int64, titles: [String]) async throws -> ChapterRemoteImportResult {
        var seenTitles: Set<String> = []
        let normalizedTitles = try titles.compactMap { rawTitle -> String? in
            let normalized = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            guard seenTitles.insert(normalized).inserted else { return nil }
            return try Self.validatedTitle(normalized)
        }
        guard !normalizedTitles.isEmpty else { throw ChapterManagementError.emptyTitle }

        return try await databaseManager.database.dbPool.write { db in
            try Self.ensureActiveBook(db, bookID: bookID)
            // SQL 目的：读取当前有效根章节，用标题复用 Android saveImportedChapterSync 的同父级冲突规则。
            // 涉及表：chapter。
            // 关键过滤：限定目标书、parent_id = 0 与 is_deleted = 0；同序时按主键稳定排序。
            // 时间字段：不读取时间字段。
            // 返回字段用途：保留未命中章节顺序，并把命中或新建章节按远端选择顺序追加到末尾。
            let rootRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title
                    FROM chapter
                    WHERE book_id = ? AND parent_id = 0 AND is_deleted = 0
                    ORDER BY chapter_order ASC, id ASC
                """,
                arguments: [bookID]
            )
            var firstRootIDByTitle: [String: Int64] = [:]
            let existingRootIDs: [Int64] = rootRows.compactMap { row in
                guard let id = row["id"] as Int64? else { return nil }
                let title = row["title"] as String? ?? ""
                if firstRootIDByTitle[title] == nil { firstRootIDByTitle[title] = id }
                return id
            }
            let now = Self.timestampMillis()
            var selectedRootIDs: [Int64] = []
            var reusedCount = 0

            for title in normalizedTitles {
                if let existingID = firstRootIDByTitle[title] {
                    selectedRootIDs.append(existingID)
                    reusedCount += 1
                    continue
                }
                var record = ChapterRecord(
                    id: nil,
                    bookId: bookID,
                    parentId: 0,
                    title: title,
                    remark: "",
                    chapterOrder: 0,
                    isImport: 0,
                    chapterLevel: 1,
                    sourceType: 0,
                    sourceUid: nil,
                    sourceAnchor: nil,
                    sourceOrder: 0,
                    sourcePath: title,
                    isStarred: 0,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try record.insert(db)
                guard let insertedID = record.id else { throw ChapterManagementError.chapterNotFound }
                firstRootIDByTitle[title] = insertedID
                selectedRootIDs.append(insertedID)
            }

            let selectedSet = Set(selectedRootIDs)
            let finalRootOrder = existingRootIDs.filter { !selectedSet.contains($0) } + selectedRootIDs
            try Self.updateSiblingOrder(
                db,
                bookID: bookID,
                parentID: 0,
                orderedIDs: finalRootOrder,
                updatedAt: now
            )
            try Self.refreshTreeMetadata(db, bookID: bookID, updatedAt: now)
            return ChapterRemoteImportResult(
                importedChapterCount: selectedRootIDs.count,
                reusedChapterCount: reusedCount
            )
        }
    }

    /// 按 Android BatchAddChapter 的先序树语义原子导入；同父级同名章节复用，新建项写入目录导入元数据。
    func importChapterBatch(
        bookID: Int64,
        draft: ChapterBatchImportDraft
    ) async throws -> ChapterBatchImportResult {
        try Self.validateBatchDraft(draft)
        return try await databaseManager.database.dbPool.write { db in
            try Self.ensureActiveBook(db, bookID: bookID)

            // SQL 目的：一次读取当前书籍全部有效章节，为批量导入建立同父级标题复用索引。
            // 涉及表：chapter。
            // 关键过滤：限定 book_id、排除系统根与兼容删除行；同名时按 order/id 选择 Android 查询语义下的首条。
            // 时间字段：不读取时间字段。
            // 返回字段用途：避免逐行查询，并在新章节插入后增量补充索引。
            let existingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, parent_id, COALESCE(title, '') AS title
                    FROM chapter
                    WHERE book_id = ? AND id != 0 AND is_deleted = 0
                    ORDER BY parent_id ASC, chapter_order ASC, id ASC
                """,
                arguments: [bookID]
            )
            var firstChapterIDByKey: [ImportMatchKey: Int64] = [:]
            for row in existingRows {
                let chapterID = row["id"] as Int64
                let key = ImportMatchKey(
                    parentID: row["parent_id"] as Int64? ?? 0,
                    title: row["title"] as String? ?? ""
                )
                if firstChapterIDByKey[key] == nil {
                    firstChapterIDByKey[key] = chapterID
                }
            }

            let now = Self.timestampMillis()
            var databaseIDByEntryID: [Int: Int64] = [:]
            var importedChapterIDs: [Int64] = []
            var createdCount = 0
            var reusedCount = 0

            for entry in draft.entries {
                let parentID: Int64
                if let parentEntryID = entry.parentEntryID {
                    guard let resolvedParentID = databaseIDByEntryID[parentEntryID] else {
                        throw ChapterBatchImportError.invalidDraft
                    }
                    parentID = resolvedParentID
                } else {
                    parentID = 0
                }
                let key = ImportMatchKey(parentID: parentID, title: entry.title)
                let chapterID: Int64

                if let existingID = firstChapterIDByKey[key] {
                    // SQL 目的：复用同父级同名章节，并仅刷新 Android saveImportedChapterSync 会改变的顺序、层级和路径元数据。
                    // 涉及表：chapter。
                    // 关键过滤：限定 id、book_id 与有效行，既有 remark/is_import/source identity 保持原值。
                    // 时间字段：updated_date 写本次事务统一毫秒时间戳。
                    // 副作用：不会覆盖文曲/微信读书来源字段，避免手工目录破坏既有同步身份。
                    try db.execute(
                        sql: """
                            UPDATE chapter
                            SET chapter_order = ?, chapter_level = ?, source_path = ?, updated_date = ?
                            WHERE id = ? AND book_id = ? AND is_deleted = 0
                        """,
                        arguments: [
                            entry.siblingOrder,
                            entry.level,
                            entry.pathTitles.joined(separator: ChapterManagementPolicy.pathSeparator),
                            now,
                            existingID,
                            bookID
                        ]
                    )
                    guard db.changesCount > 0 else { throw ChapterManagementError.chapterNotFound }
                    chapterID = existingID
                    reusedCount += 1
                } else {
                    var record = ChapterRecord(
                        id: nil,
                        bookId: bookID,
                        parentId: parentID,
                        title: entry.title,
                        remark: entry.remark,
                        chapterOrder: entry.siblingOrder,
                        isImport: entry.isImported ? 1 : 0,
                        chapterLevel: Int64(entry.level),
                        sourceType: entry.sourceType,
                        sourceUid: entry.sourceUID,
                        sourceAnchor: entry.sourceAnchor,
                        sourceOrder: entry.sourceOrder,
                        sourcePath: entry.pathTitles.joined(separator: ChapterManagementPolicy.pathSeparator),
                        isStarred: 0,
                        createdDate: now,
                        updatedDate: 0,
                        lastSyncDate: 0,
                        isDeleted: 0
                    )
                    try record.insert(db)
                    guard let insertedID = record.id else {
                        throw ChapterManagementError.chapterNotFound
                    }
                    chapterID = insertedID
                    firstChapterIDByKey[key] = insertedID
                    createdCount += 1
                }

                databaseIDByEntryID[entry.id] = chapterID
                importedChapterIDs.append(chapterID)
            }

            return ChapterBatchImportResult(
                importedChapterIDs: importedChapterIDs,
                createdChapterCount: createdCount,
                reusedChapterCount: reusedCount
            )
        }
    }

    /// 在目标父级末尾新增章节；写事务内校验书籍、父级和五层深度。
    func createChapter(bookID: Int64, parentID: Int64, title: String) async throws -> Int64 {
        let normalizedTitle = try Self.validatedTitle(title)
        return try await databaseManager.database.dbPool.write { db in
            try Self.ensureActiveBook(db, bookID: bookID)
            let snapshot = try Self.fetchSnapshot(db, bookID: bookID)
            let parentPath: [String]
            let level: Int
            if parentID == 0 {
                parentPath = []
                level = 1
            } else {
                guard let parent = snapshot.node(id: parentID) else {
                    throw ChapterManagementError.parentNotFound
                }
                guard parent.item.level < ChapterManagementPolicy.maximumDepth else {
                    throw ChapterManagementError.exceedsMaximumDepth
                }
                parentPath = parent.item.pathTitles
                level = parent.item.level + 1
            }

            // SQL 目的：读取目标父级当前最大 chapter_order，使新章节按 Android addChapterSync 追加到同级末尾。
            // 涉及表：chapter。
            // 关键过滤：限定同一本书、目标 parent_id 与有效记录；根章节同样按 parent_id = 0 查询。
            // 时间字段：不读取时间字段。
            // 返回字段用途：新章节 chapter_order 使用 MAX + 1，空目录从 1 开始。
            let maxOrder = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(chapter_order)
                    FROM chapter
                    WHERE book_id = ? AND parent_id = ? AND is_deleted = 0
                """,
                arguments: [bookID, parentID]
            ) ?? 0
            let now = Self.timestampMillis()
            var record = ChapterRecord(
                id: nil,
                bookId: bookID,
                parentId: parentID,
                title: normalizedTitle,
                remark: "",
                chapterOrder: maxOrder + 1,
                isImport: 0,
                chapterLevel: Int64(level),
                sourceType: 0,
                sourceUid: nil,
                sourceAnchor: nil,
                sourceOrder: 0,
                sourcePath: (parentPath + [normalizedTitle]).joined(separator: ChapterManagementPolicy.pathSeparator),
                isStarred: 0,
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
            guard let chapterID = record.id else {
                throw ChapterManagementError.chapterNotFound
            }
            return chapterID
        }
    }

    /// 重命名章节后刷新整书派生元数据，使所有后代 path 与真实 parent_id 树一致。
    func renameChapter(bookID: Int64, chapterID: Int64, title: String) async throws {
        let normalizedTitle = try Self.validatedTitle(title)
        try await databaseManager.database.dbPool.write { db in
            try Self.ensureActiveBook(db, bookID: bookID)
            let now = Self.timestampMillis()
            // SQL 目的：按主键重命名当前书中的有效章节。
            // 涉及表：chapter。
            // 关键过滤：同时限定 id、book_id 与 is_deleted = 0，阻止并发删除或跨书误写。
            // 时间字段：updated_date 写当前毫秒时间戳，不做时区换算。
            // 副作用：仅修改 title/updated_date；后续 refreshTreeMetadata 同事务刷新后代路径。
            try db.execute(
                sql: """
                    UPDATE chapter
                    SET title = ?, updated_date = ?
                    WHERE id = ? AND book_id = ? AND is_deleted = 0
                """,
                arguments: [normalizedTitle, now, chapterID, bookID]
            )
            guard db.changesCount > 0 else { throw ChapterManagementError.chapterNotFound }
            try Self.refreshTreeMetadata(db, bookID: bookID, updatedAt: now)
        }
    }

    /// 更新单个章节星标，写入时间与 Android ChapterDao.updateStarredSync 一致。
    func setChapterStarred(bookID: Int64, chapterID: Int64, isStarred: Bool) async throws {
        guard chapterID > 0 else { throw ChapterManagementError.chapterNotFound }
        try await databaseManager.database.dbPool.write { db in
            let now = Self.timestampMillis()
            // SQL 目的：切换指定章节的星标状态，供首页星标章节聚合立即刷新。
            // 涉及表：chapter。
            // 关键过滤：限定 id、book_id、非系统根记录与有效状态。
            // 时间字段：updated_date 写本地当前毫秒时间戳，不做时区换算。
            // 副作用：只更新 is_starred 与 updated_date，不改变树结构。
            try db.execute(
                sql: """
                    UPDATE chapter
                    SET is_starred = ?, updated_date = ?
                    WHERE id = ? AND book_id = ? AND id != 0 AND is_deleted = 0
                """,
                arguments: [isStarred ? 1 : 0, now, chapterID, bookID]
            )
            guard db.changesCount > 0 else { throw ChapterManagementError.chapterNotFound }
        }
    }

    /// 完整重写一个父级的同级顺序；集合不完全一致时拒绝并发覆盖并返回真实恢复快照。
    func reorderSiblings(
        bookID: Int64,
        parentID: Int64,
        orderedChapterIDs: [Int64]
    ) async throws -> ChapterStructureRestoreSnapshot {
        try await databaseManager.database.dbPool.write { db in
            let snapshot = try Self.fetchSnapshot(db, bookID: bookID)
            if parentID != 0, snapshot.node(id: parentID) == nil {
                throw ChapterManagementError.parentNotFound
            }
            let currentIDs = snapshot.directChildren(parentID: parentID).map(\.id)
            let uniqueIDs = Self.uniquePositiveIDs(orderedChapterIDs)
            guard uniqueIDs.count == orderedChapterIDs.count,
                  uniqueIDs.count == currentIDs.count,
                  Set(uniqueIDs) == Set(currentIDs) else {
                throw ChapterManagementError.invalidSiblingOrder
            }
            let restorePositions = try Self.fetchStructurePositions(db, bookID: bookID)
            let now = Self.timestampMillis()
            try Self.updateSiblingOrder(
                db,
                bookID: bookID,
                parentID: parentID,
                orderedIDs: uniqueIDs,
                updatedAt: now
            )
            try Self.refreshTreeMetadata(db, bookID: bookID, updatedAt: now)
            return ChapterStructureRestoreSnapshot(
                bookID: bookID,
                restorePositions: restorePositions,
                expectedCurrentPositions: try Self.fetchStructurePositions(db, bookID: bookID)
            )
        }
    }

    /// 把选中顶层子树移动到目标父级末尾；事务内完成循环、深度、并发校验并返回恢复快照。
    func moveChapters(
        bookID: Int64,
        chapterIDs: [Int64],
        targetParentID: Int64
    ) async throws -> ChapterStructureRestoreSnapshot {
        try await databaseManager.database.dbPool.write { db in
            let snapshot = try Self.fetchSnapshot(db, bookID: bookID)
            let requestedIDs = Set(Self.uniquePositiveIDs(chapterIDs))
            guard !requestedIDs.isEmpty,
                  requestedIDs.count == Set(chapterIDs).count,
                  requestedIDs.isSubset(of: Set(snapshot.flattened.map(\.id))) else {
                throw ChapterManagementError.invalidSelection
            }
            let movingRoots = snapshot.topLevelSelection(from: requestedIDs)
            guard !movingRoots.isEmpty else { throw ChapterManagementError.invalidSelection }
            if targetParentID != 0, snapshot.node(id: targetParentID) == nil {
                throw ChapterManagementError.parentNotFound
            }

            let movingSubtreeIDs = movingRoots.reduce(into: Set<Int64>()) { result, node in
                result.formUnion(node.subtreeIDs())
            }
            guard !movingSubtreeIDs.contains(targetParentID) else {
                throw ChapterManagementError.moveIntoOwnSubtree
            }
            let targetDepth = targetParentID == 0
                ? 0
                : snapshot.node(id: targetParentID)?.item.level ?? 0
            let movingHeight = movingRoots.map { $0.subtreeHeight() }.max() ?? 0
            guard targetDepth + movingHeight <= ChapterManagementPolicy.maximumDepth else {
                throw ChapterManagementError.exceedsMaximumDepth
            }

            let restorePositions = try Self.fetchStructurePositions(db, bookID: bookID)
            let movingRootIDs = movingRoots.map(\.id)
            let movingRootIDSet = Set(movingRootIDs)
            let oldParentIDs = Set(movingRoots.map { $0.item.parentID })
            let targetSurvivors = snapshot.directChildren(parentID: targetParentID)
                .map(\.id)
                .filter { !movingRootIDSet.contains($0) }
            let now = Self.timestampMillis()
            try Self.updateSiblingOrder(
                db,
                bookID: bookID,
                parentID: targetParentID,
                orderedIDs: targetSurvivors + movingRootIDs,
                updatedAt: now
            )
            for oldParentID in oldParentIDs where oldParentID != targetParentID {
                let oldSurvivors = snapshot.directChildren(parentID: oldParentID)
                    .map(\.id)
                    .filter { !movingRootIDSet.contains($0) }
                try Self.updateSiblingOrder(
                    db,
                    bookID: bookID,
                    parentID: oldParentID,
                    orderedIDs: oldSurvivors,
                    updatedAt: now
                )
            }
            try Self.refreshTreeMetadata(db, bookID: bookID, updatedAt: now)
            return ChapterStructureRestoreSnapshot(
                bookID: bookID,
                restorePositions: restorePositions,
                expectedCurrentPositions: try Self.fetchStructurePositions(db, bookID: bookID)
            )
        }
    }

    /// 当前结构仍等于写后快照时，事务恢复全部章节的 parent/order；后续写入会使令牌安全失效。
    func restoreChapterStructure(_ snapshot: ChapterStructureRestoreSnapshot) async throws {
        try await databaseManager.database.dbPool.write { db in
            try Self.ensureActiveBook(db, bookID: snapshot.bookID)
            let currentPositions = try Self.fetchStructurePositions(db, bookID: snapshot.bookID)
            guard currentPositions == snapshot.expectedCurrentPositions,
                  Set(currentPositions.map(\.chapterID)) == Set(snapshot.restorePositions.map(\.chapterID)),
                  currentPositions.count == snapshot.restorePositions.count else {
                throw ChapterManagementError.undoConflict
            }

            let now = Self.timestampMillis()
            for position in snapshot.restorePositions {
                // SQL 目的：恢复结构写入前的 parent_id 与 chapter_order，形成真实持久化 Undo。
                // 涉及表：chapter。
                // 关键过滤：限定 id、同一本书与有效记录；完整结构已在循环前通过写后快照校验。
                // 时间字段：updated_date 写撤销事务统一毫秒时间戳。
                // 副作用：随后 refreshTreeMetadata 重算层级与路径，不恢复与结构无关的业务字段。
                try db.execute(
                    sql: """
                        UPDATE chapter
                        SET parent_id = ?, chapter_order = ?, updated_date = ?
                        WHERE id = ? AND book_id = ? AND is_deleted = 0
                    """,
                    arguments: [
                        position.parentID,
                        position.order,
                        now,
                        position.chapterID,
                        snapshot.bookID
                    ]
                )
                guard db.changesCount > 0 else { throw ChapterManagementError.undoConflict }
            }
            try Self.refreshTreeMetadata(db, bookID: snapshot.bookID, updatedAt: now)
        }
    }

    /// 删除选中章节及后代；先解除 note 外键，再物理删除 chapter 行。
    func deleteChapters(bookID: Int64, chapterIDs: [Int64]) async throws -> ChapterDeletionResult {
        try await databaseManager.database.dbPool.write { db in
            let snapshot = try Self.fetchSnapshot(db, bookID: bookID)
            let requestedIDs = Set(Self.uniquePositiveIDs(chapterIDs))
            guard !requestedIDs.isEmpty,
                  requestedIDs.count == Set(chapterIDs).count,
                  requestedIDs.isSubset(of: Set(snapshot.flattened.map(\.id))) else {
                throw ChapterManagementError.invalidSelection
            }
            let selectedRoots = snapshot.topLevelSelection(from: requestedIDs)
            let deleteIDs = selectedRoots.reduce(into: Set<Int64>()) { result, node in
                result.formUnion(node.subtreeIDs())
            }
            return try Self.hardDeleteChapters(db, bookID: bookID, chapterIDs: deleteIDs)
        }
    }

    /// 清空指定父级的全部后代；父章节及其直接书摘保持不变。
    func deleteDescendants(bookID: Int64, parentID: Int64) async throws -> ChapterDeletionResult {
        try await databaseManager.database.dbPool.write { db in
            let snapshot = try Self.fetchSnapshot(db, bookID: bookID)
            guard let parent = snapshot.node(id: parentID) else {
                throw ChapterManagementError.parentNotFound
            }
            let deleteIDs = parent.children.reduce(into: Set<Int64>()) { result, child in
                result.formUnion(child.subtreeIDs())
            }
            guard !deleteIDs.isEmpty else {
                return ChapterDeletionResult(deletedChapterCount: 0, unassignedNoteCount: 0)
            }
            return try Self.hardDeleteChapters(db, bookID: bookID, chapterIDs: deleteIDs)
        }
    }
}

private extension ChapterManagementRepository {
    nonisolated struct RemoteCatalogContext: Hashable, Sendable {
        let bookTitle: String
        let doubanID: Int?
    }

    nonisolated struct StoredChapter: Hashable, Sendable {
        let id: Int64
        let bookID: Int64
        let parentID: Int64
        let title: String
        let remark: String
        let order: Int64
        let isStarred: Bool
    }

    /// 批量导入的同父级标题复用键，与 Android querySubChapterTitle 的匹配维度一致。
    nonisolated struct ImportMatchKey: Hashable, Sendable {
        let parentID: Int64
        let title: String
    }

    /// 在进入数据库前校验草稿的先序父子关系、层级、顺序与 Android 目录导入元数据。
    nonisolated static func validateBatchDraft(_ draft: ChapterBatchImportDraft) throws {
        guard !draft.entries.isEmpty else { throw ChapterBatchImportError.emptyInput }
        var seenEntryIDs: Set<Int> = []
        var entryByID: [Int: ChapterBatchImportEntry] = [:]
        var lastOrderByParentEntryID: [Int: Int64] = [:]

        for entry in draft.entries {
            guard seenEntryIDs.insert(entry.id).inserted,
                  !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.level >= 1,
                  entry.level <= ChapterManagementPolicy.maximumDepth,
                  entry.siblingOrder > 0,
                  entry.isImported,
                  entry.sourceType == ChapterBatchImportParser.catalogImportSourceType,
                  entry.pathTitles.count == entry.level,
                  entry.pathTitles.last == entry.title else {
                throw ChapterBatchImportError.invalidDraft
            }
            if let parentEntryID = entry.parentEntryID {
                guard let parent = entryByID[parentEntryID],
                      parent.level + 1 == entry.level,
                      entry.pathTitles.dropLast() == parent.pathTitles[...] else {
                    throw ChapterBatchImportError.invalidDraft
                }
            } else if entry.level != 1 {
                throw ChapterBatchImportError.invalidDraft
            }
            let parentOrderKey = entry.parentEntryID ?? 0
            let previousOrder = lastOrderByParentEntryID[parentOrderKey] ?? 0
            guard entry.siblingOrder == previousOrder + 1 else {
                throw ChapterBatchImportError.invalidDraft
            }
            lastOrderByParentEntryID[parentOrderKey] = entry.siblingOrder
            entryByID[entry.id] = entry
        }
    }

    /// 只读取撤销所需的 id/parent/order，并按主键稳定排序用于并发比较。
    nonisolated static func fetchStructurePositions(
        _ db: Database,
        bookID: Int64
    ) throws -> [ChapterStructurePosition] {
        // SQL 目的：读取整书有效章节的最小结构快照，供移动/重排写前保存与 Undo 冲突校验。
        // 涉及表：chapter。
        // 关键过滤：限定 book_id、排除系统根和兼容删除行；按 id 稳定排序保证值比较可靠。
        // 时间字段：不读取时间字段。
        // 返回字段用途：生成 ChapterStructureRestoreSnapshot，不包含标题与来源等非结构元数据。
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, parent_id, chapter_order
                FROM chapter
                WHERE book_id = ? AND id != 0 AND is_deleted = 0
                ORDER BY id ASC
            """,
            arguments: [bookID]
        ).map { row in
            ChapterStructurePosition(
                chapterID: row["id"],
                parentID: row["parent_id"] ?? 0,
                order: row["chapter_order"] ?? 0
            )
        }
    }

    /// 从本地书籍读取 Android 目录匹配所需的最小字段，避免服务层接触数据库。
    nonisolated static func fetchRemoteCatalogContext(
        _ db: Database,
        bookID: Int64
    ) throws -> RemoteCatalogContext {
        try ensureActiveBook(db, bookID: bookID)
        // SQL 目的：读取目录远端匹配所需书名与豆瓣 ID。
        // 涉及表：book。
        // 关键过滤：主键精确命中、排除系统根与已删除/引用占位书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：douban_id > 0 时精确查询文曲，否则按 name 搜索候选。
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT name, douban_id
                FROM book
                WHERE id = ? AND id != 0 AND is_deleted = 0
            """,
            arguments: [bookID]
        ) else {
            throw ChapterManagementError.invalidBook
        }
        let title = (row["name"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDoubanID = row["douban_id"] as Int64? ?? 0
        guard !title.isEmpty || rawDoubanID > 0 else { throw ChapterManagementError.invalidBook }
        return RemoteCatalogContext(
            bookTitle: title,
            doubanID: rawDoubanID > 0 && rawDoubanID <= Int64(Int.max) ? Int(rawDoubanID) : nil
        )
    }

    /// Android 将 WENQU-CONFIG 作为独立扩展配置缓存；这里只判断是否拿到可解析 JSON，不参与目录鉴权。
    nonisolated static func isUsableWenquConfiguration(_ rawValue: String?) -> Bool {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return false
        }
        return true
    }

    /// 在同一数据库快照中读取章节、直接书摘数和未分章节书摘数，并校验完整树结构。
    nonisolated static func fetchSnapshot(_ db: Database, bookID: Int64) throws -> ChapterManagementSnapshot {
        try ensureActiveBook(db, bookID: bookID)

        // SQL 目的：读取单本书全部有效章节，parent_id 作为唯一树结构真相。
        // 涉及表：chapter。
        // 关键过滤：限定 book_id、排除 id = 0 系统根记录与 is_deleted != 0 兼容行。
        // 时间字段：不读取时间；排序按 parent_id/chapter_order/id 提供稳定同级顺序。
        // 返回字段用途：构建最多五层的 ChapterManagementNode 树并校验孤儿/循环关系。
        let chapterRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, book_id, parent_id,
                       COALESCE(title, '') AS title,
                       COALESCE(remark, '') AS remark,
                       chapter_order, is_starred
                FROM chapter
                WHERE book_id = ? AND id != 0 AND is_deleted = 0
                ORDER BY parent_id ASC, chapter_order ASC, id ASC
            """,
            arguments: [bookID]
        )
        let stored = chapterRows.map { row in
            StoredChapter(
                id: row["id"],
                bookID: row["book_id"],
                parentID: row["parent_id"] ?? 0,
                title: row["title"] ?? "",
                remark: row["remark"] ?? "",
                order: row["chapter_order"] ?? 0,
                isStarred: (row["is_starred"] as Int64? ?? 0) != 0
            )
        }

        // SQL 目的：批量统计单本书各有效章节直接关联的有效书摘数量。
        // 涉及表：note n INNER JOIN chapter c，n.chapter_id -> c.id。
        // 关键过滤：限定 n.book_id、n.is_deleted = 0、c.is_deleted = 0，排除未分章节 chapter_id = 0。
        // 时间字段：不读取或转换时间字段。
        // 返回字段用途：填充 directNoteCount，并在内存中向上汇总 descendantNoteCount。
        let noteCountRows = try Row.fetchAll(
            db,
            sql: """
                SELECT n.chapter_id, COUNT(*) AS note_count
                FROM note n
                INNER JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
                WHERE n.book_id = ? AND n.is_deleted = 0 AND n.chapter_id != 0
                GROUP BY n.chapter_id
            """,
            arguments: [bookID]
        )
        let directNoteCountByChapterID = Dictionary(uniqueKeysWithValues: noteCountRows.map { row in
            (row["chapter_id"] as Int64, row["note_count"] as Int)
        })

        // SQL 目的：统计当前书籍未分章节的有效书摘，供管理页解释删除/移动后的归属。
        // 涉及表：note。
        // 关键过滤：book_id 精确命中、chapter_id = 0 且 is_deleted = 0。
        // 时间字段：不读取时间字段。
        // 返回字段用途：填充 ChapterManagementSnapshot.unassignedNoteCount。
        let unassignedNoteCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM note
                WHERE book_id = ? AND chapter_id = 0 AND is_deleted = 0
            """,
            arguments: [bookID]
        ) ?? 0

        return try makeSnapshot(
            bookID: bookID,
            stored: stored,
            directNoteCountByChapterID: directNoteCountByChapterID,
            unassignedNoteCount: unassignedNoteCount
        )
    }

    /// 从 parent_id 生成经过孤儿、循环与深度校验的不可变树。
    nonisolated static func makeSnapshot(
        bookID: Int64,
        stored: [StoredChapter],
        directNoteCountByChapterID: [Int64: Int],
        unassignedNoteCount: Int
    ) throws -> ChapterManagementSnapshot {
        let itemByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        for item in stored where item.parentID != 0 && itemByID[item.parentID] == nil {
            throw ChapterManagementError.orphanedChapter(chapterID: item.id)
        }
        let childrenByParentID = Dictionary(grouping: stored, by: \.parentID)
            .mapValues { children in
                children.sorted { lhs, rhs in
                    lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
                }
            }
        let rootRows = childrenByParentID[0] ?? []
        var visiting: Set<Int64> = []
        var visited: Set<Int64> = []

        func buildNode(_ row: StoredChapter, level: Int, pathTitles: [String]) throws -> ChapterManagementNode {
            guard level <= ChapterManagementPolicy.maximumDepth else {
                throw ChapterManagementError.exceedsMaximumDepth
            }
            guard visiting.insert(row.id).inserted else {
                throw ChapterManagementError.cyclicTree
            }
            let nextPath = pathTitles + [row.title]
            let children = try (childrenByParentID[row.id] ?? []).map { child in
                try buildNode(child, level: level + 1, pathTitles: nextPath)
            }
            visiting.remove(row.id)
            guard visited.insert(row.id).inserted else {
                throw ChapterManagementError.cyclicTree
            }
            let directNoteCount = directNoteCountByChapterID[row.id] ?? 0
            let descendantNoteCount = directNoteCount + children.reduce(0) {
                $0 + $1.item.descendantNoteCount
            }
            return ChapterManagementNode(
                item: ChapterManagementItem(
                    id: row.id,
                    bookID: row.bookID,
                    parentID: row.parentID,
                    title: row.title,
                    remark: row.remark,
                    order: row.order,
                    level: level,
                    pathTitles: nextPath,
                    directNoteCount: directNoteCount,
                    descendantNoteCount: descendantNoteCount,
                    childCount: children.count,
                    isStarred: row.isStarred
                ),
                children: children
            )
        }

        let roots = try rootRows.map { try buildNode($0, level: 1, pathTitles: []) }
        guard visited.count == stored.count else {
            throw ChapterManagementError.cyclicTree
        }
        return ChapterManagementSnapshot(
            bookID: bookID,
            roots: roots,
            unassignedNoteCount: unassignedNoteCount
        )
    }

    /// 校验书籍仍然是可管理的有效本地对象。
    nonisolated static func ensureActiveBook(_ db: Database, bookID: Int64) throws {
        guard bookID > 0 else { throw ChapterManagementError.invalidBook }
        // SQL 目的：确认目录写入目标书籍仍存在且不是引用占位书。
        // 涉及表：book。
        // 关键过滤：id 精确命中、id != 0、is_deleted = 0。
        // 时间字段：不读取时间字段。
        // 返回字段用途：只判断是否存在，阻止并发删除后的孤立写入。
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM book WHERE id = ? AND id != 0 AND is_deleted = 0)",
            arguments: [bookID]
        ) ?? false
        guard exists else { throw ChapterManagementError.invalidBook }
    }

    /// 归一化标题；Android 管理页只要求 trim 后非空。
    nonisolated static func validatedTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ChapterManagementError.emptyTitle }
        return normalized
    }

    /// 保序去重并排除系统根 ID。
    nonisolated static func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return ids.filter { $0 > 0 && seen.insert($0).inserted }
    }

    /// 在一个写事务内更新完整同级顺序与 parent_id；目标列表可为空。
    nonisolated static func updateSiblingOrder(
        _ db: Database,
        bookID: Int64,
        parentID: Int64,
        orderedIDs: [Int64],
        updatedAt: Int64
    ) throws {
        for (index, chapterID) in orderedIDs.enumerated() {
            // SQL 目的：按给定完整顺序更新同级章节的 parent_id 与 chapter_order。
            // 涉及表：chapter。
            // 关键过滤：限定章节 id、book_id 与有效状态，避免跨书或并发删除后静默写入。
            // 时间字段：updated_date 使用本次事务统一毫秒时间戳。
            // 副作用：parent_id/序号从 1 开始写入，随后 refreshTreeMetadata 重算层级和路径。
            try db.execute(
                sql: """
                    UPDATE chapter
                    SET parent_id = ?, chapter_order = ?, updated_date = ?
                    WHERE id = ? AND book_id = ? AND is_deleted = 0
                """,
                arguments: [parentID, index + 1, updatedAt, chapterID, bookID]
            )
            guard db.changesCount > 0 else { throw ChapterManagementError.chapterNotFound }
        }
    }

    /// 依据真实 parent_id 树刷新全书 chapter_level/source_path，与 Android refreshChapterTreeMetadata 对齐。
    nonisolated static func refreshTreeMetadata(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        let snapshot = try fetchSnapshot(db, bookID: bookID)
        for node in snapshot.flattened {
            // SQL 目的：把 parent_id 推导出的真实层级和完整标题路径回写章节元数据。
            // 涉及表：chapter。
            // 关键过滤：限定 id、book_id 与有效状态；不改变 parent_id 和业务来源字段。
            // 时间字段：updated_date 使用结构写入事务的统一毫秒时间戳。
            // 副作用：更新 chapter_level/source_path，保证详情、导出和其他端读取一致。
            try db.execute(
                sql: """
                    UPDATE chapter
                    SET chapter_level = ?, source_path = ?, updated_date = ?
                    WHERE id = ? AND book_id = ? AND is_deleted = 0
                """,
                arguments: [
                    node.item.level,
                    node.item.pathTitles.joined(separator: ChapterManagementPolicy.pathSeparator),
                    updatedAt,
                    node.id,
                    bookID
                ]
            )
            guard db.changesCount > 0 else { throw ChapterManagementError.chapterNotFound }
        }
    }

    /// 解除书摘外键后物理删除章节；500 条分块与 Android deleteSubChapters 保持同级规模控制。
    nonisolated static func hardDeleteChapters(
        _ db: Database,
        bookID: Int64,
        chapterIDs: Set<Int64>
    ) throws -> ChapterDeletionResult {
        let orderedIDs = chapterIDs.sorted()
        guard !orderedIDs.isEmpty else {
            return ChapterDeletionResult(deletedChapterCount: 0, unassignedNoteCount: 0)
        }
        var affectedActiveNoteCount = 0
        var deletedChapterCount = 0
        let now = timestampMillis()
        for chunk in orderedIDs.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")

            // SQL 目的：统计即将被移出目录的有效书摘数量，供页面解释关联影响。
            // 涉及表：note。
            // 关键过滤：限定同一本书、chapter_id 位于当前删除分块且 note.is_deleted = 0。
            // 时间字段：不读取时间字段。
            // 返回字段用途：累加 ChapterDeletionResult.unassignedNoteCount。
            affectedActiveNoteCount += try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM note
                    WHERE book_id = ? AND chapter_id IN (\(placeholders)) AND is_deleted = 0
                """,
                arguments: StatementArguments([bookID] + chunk)
            ) ?? 0

            // SQL 目的：在物理删除章节前解除所有 note.chapter_id 外键，包括旧备份残留的兼容删除行。
            // 涉及表：note。
            // 关键过滤：限定同一本书且 chapter_id 位于删除分块；不按 note.is_deleted 过滤以保证外键完整性。
            // 时间字段：updated_date 写本次事务统一毫秒时间戳。
            // 副作用：书摘正文保留，chapter_id 归零进入“未分章节”。
            try db.execute(
                sql: """
                    UPDATE note
                    SET chapter_id = 0, updated_date = ?
                    WHERE book_id = ? AND chapter_id IN (\(placeholders))
                """,
                arguments: StatementArguments([now, bookID] + chunk)
            )

            // SQL 目的：物理删除已完成书摘解绑的章节行，落实项目全局硬删除规则。
            // 涉及表：chapter。
            // 关键过滤：限定同一本书、id 位于完整后代闭包分块且排除系统根 id = 0。
            // 时间字段：物理删除不再写时间戳。
            // 副作用：章节记录不可恢复；调用方已经把所有后代纳入闭包，避免留下孤儿节点。
            try db.execute(
                sql: """
                    DELETE FROM chapter
                    WHERE book_id = ? AND id != 0 AND id IN (\(placeholders))
                """,
                arguments: StatementArguments([bookID] + chunk)
            )
            deletedChapterCount += db.changesCount
        }
        guard deletedChapterCount == orderedIDs.count else {
            throw ChapterManagementError.chapterNotFound
        }
        return ChapterDeletionResult(
            deletedChapterCount: deletedChapterCount,
            unassignedNoteCount: affectedActiveNoteCount
        )
    }

    /// 返回 Android/Room 统一使用的 Unix 毫秒时间戳。
    nonisolated static func timestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

private extension Array {
    /// 按固定上限切分数组，避免 SQLite 参数数量超过单条语句限制。
    nonisolated func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
