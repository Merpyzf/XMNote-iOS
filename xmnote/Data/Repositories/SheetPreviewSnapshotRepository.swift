#if DEBUG
/**
 * [INPUT]: 依赖 GRDB backup、AppDatabase、DatabaseManager 与 RepositoryContainer，把当前 App 数据复制到 Debug 临时数据库
 * [OUTPUT]: 对外提供 SheetPreviewSnapshotRepository、SheetPreviewSnapshot 与 SheetPreviewWorkspace，支持刷新基础快照和逐次生成隔离工作副本
 * [POS]: Data/Repositories 的 Debug 专用 Sheet 生产数据隔离边界，禁止把预览写入正式数据库或正式偏好
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated struct SheetPreviewSnapshotCounts: Hashable, Sendable {
    let books: Int
    let notes: Int
    let tags: Int
    let collections: Int
    let chapters: Int
    let readingRecords: Int

    var summary: String {
        "书籍 \(books) · 书摘 \(notes) · 标签 \(tags) · 书单 \(collections) · 章节 \(chapters) · 阅读记录 \(readingRecords)"
    }
}

nonisolated struct SheetPreviewNamedEntity: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
}

nonisolated struct SheetPreviewSnapshot: Hashable, Sendable {
    let createdAt: Date
    let counts: SheetPreviewSnapshotCounts
    let representativeBooks: [BookPickerBook]
    let representativeNoteText: String?
    let representativeTags: [SheetPreviewNamedEntity]
    let representativeCollections: [SheetPreviewNamedEntity]
    let representativeChapters: [SheetPreviewNamedEntity]
    let copiedPreferenceCount: Int
    let supplementalFixtureCount: Int

    var representativeDataSummary: String {
        let titles = representativeBooks.prefix(3).map(\.title)
        guard !titles.isEmpty else { return counts.summary }
        return "\(counts.summary)；样例：\(titles.joined(separator: "、"))"
    }
}

@MainActor
final class SheetPreviewWorkspace {
    let id = UUID()
    let databaseManager: DatabaseManager
    let repositories: RepositoryContainer
    let userDefaults: UserDefaults
    let snapshot: SheetPreviewSnapshot

    private let databaseFiles: [String]
    private let suiteName: String

    init(
        databaseManager: DatabaseManager,
        repositories: RepositoryContainer,
        userDefaults: UserDefaults,
        snapshot: SheetPreviewSnapshot,
        databaseFiles: [String],
        suiteName: String
    ) {
        self.databaseManager = databaseManager
        self.repositories = repositories
        self.userDefaults = userDefaults
        self.snapshot = snapshot
        self.databaseFiles = databaseFiles
        self.suiteName = suiteName
    }

    /// 关闭隔离连接并删除本次工作副本；失败不影响正式数据库，下一次打开仍从基础快照重建。
    func destroy() {
        try? databaseManager.database.close()
        let fileManager = FileManager.default
        for path in databaseFiles where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
final class SheetPreviewSnapshotRepository {
    private let sourceDatabaseManager: DatabaseManager
    private var baseDatabase: AppDatabase?
    private var snapshot: SheetPreviewSnapshot?
    private var basePreferences: [String: Any] = [:]

    init(sourceDatabaseManager: DatabaseManager) {
        self.sourceDatabaseManager = sourceDatabaseManager
    }

    /// 重新复制当前 App 数据库和非敏感轻量偏好，形成后续全部 Sheet 共用的只读起点。
    func refreshSnapshot() async throws -> SheetPreviewSnapshot {
        destroyBaseDatabase()

        let database = try AppDatabase.empty()
        try sourceDatabaseManager.database.dbPool.backup(to: database.dbPool)
        try await Self.redactSensitiveDatabaseValues(in: database)
        let preferences = Self.nonSensitivePreferences()
        let copiedPreferenceCount = preferences.count
        let snapshot = try await Self.readSnapshot(
            from: database,
            copiedPreferenceCount: copiedPreferenceCount,
            supplementalFixtureCount: 0
        )
        baseDatabase = database
        basePreferences = preferences
        self.snapshot = snapshot
        return snapshot
    }

    /// 为一次生产 Sheet 打开动作创建独立数据库和偏好 suite，关闭后由调用方销毁。
    func makeWorkspace(requiresFixtureFallback: Bool) async throws -> SheetPreviewWorkspace {
        let baseDatabase: AppDatabase
        let baseSnapshot: SheetPreviewSnapshot
        if let existingDatabase = self.baseDatabase, let existingSnapshot = snapshot {
            baseDatabase = existingDatabase
            baseSnapshot = existingSnapshot
        } else {
            baseSnapshot = try await refreshSnapshot()
            guard let refreshedDatabase = self.baseDatabase else {
                throw SheetPreviewSnapshotError.snapshotUnavailable
            }
            baseDatabase = refreshedDatabase
        }

        let workingDatabase = try AppDatabase.empty()
        try baseDatabase.dbPool.backup(to: workingDatabase.dbPool)

        let suiteName = "com.xmnote.debug.sheet-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SheetPreviewSnapshotError.preferenceSuiteUnavailable
        }
        for (key, value) in basePreferences {
            defaults.set(value, forKey: key)
        }

        var supplementalFixtureCount = 0
        if requiresFixtureFallback && baseSnapshot.counts.books == 0 {
            supplementalFixtureCount += try await SheetPreviewFixtureRepository(
                database: workingDatabase
            ).insertMinimalBookIfNeeded()
        }

        let workspaceSnapshot = try await Self.readSnapshot(
            from: workingDatabase,
            copiedPreferenceCount: baseSnapshot.copiedPreferenceCount,
            supplementalFixtureCount: supplementalFixtureCount
        )
        let databaseManager = DatabaseManager(database: workingDatabase)
        let repositories = RepositoryContainer(
            sheetPreviewDatabaseManager: databaseManager,
            userDefaults: defaults
        )
        return SheetPreviewWorkspace(
            databaseManager: databaseManager,
            repositories: repositories,
            userDefaults: defaults,
            snapshot: workspaceSnapshot,
            databaseFiles: workingDatabase.databaseFiles,
            suiteName: suiteName
        )
    }

    /// 清理基础快照；只处理 Debug 临时文件，不触碰 sourceDatabaseManager 持有的正式数据库。
    func destroyBaseDatabase() {
        guard let baseDatabase else { return }
        try? baseDatabase.close()
        let fileManager = FileManager.default
        for path in baseDatabase.databaseFiles where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        self.baseDatabase = nil
        snapshot = nil
        basePreferences = [:]
    }

    private static func readSnapshot(
        from database: AppDatabase,
        copiedPreferenceCount: Int,
        supplementalFixtureCount: Int
    ) async throws -> SheetPreviewSnapshot {
        try await database.dbPool.read { db in
            // SQL 目的：一次读取 Sheet 校准页的数据规模摘要。
            // 涉及表：book、note、tag、collection、chapter、read_time_record、check_in_record；各子查询相互独立。
            // 关键过滤：业务实体仅统计 is_deleted=0，书籍排除系统根记录 id=0；阅读记录表按实际行数统计。
            // 时间字段：不执行时间换算；仅返回数量。
            // 返回字段：六类业务数量，用于判断真实快照是否需要补充最小夹具。
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    (SELECT COUNT(*) FROM book WHERE id != 0 AND is_deleted = 0) AS book_count,
                    (SELECT COUNT(*) FROM note WHERE is_deleted = 0) AS note_count,
                    (SELECT COUNT(*) FROM tag WHERE is_deleted = 0) AS tag_count,
                    (SELECT COUNT(*) FROM collection WHERE is_deleted = 0) AS collection_count,
                    (SELECT COUNT(*) FROM chapter WHERE is_deleted = 0) AS chapter_count,
                    ((SELECT COUNT(*) FROM read_time_record) +
                     (SELECT COUNT(*) FROM check_in_record)) AS reading_record_count
                """
            )
            let counts = SheetPreviewSnapshotCounts(
                books: row?["book_count"] ?? 0,
                notes: row?["note_count"] ?? 0,
                tags: row?["tag_count"] ?? 0,
                collections: row?["collection_count"] ?? 0,
                chapters: row?["chapter_count"] ?? 0,
                readingRecords: row?["reading_record_count"] ?? 0
            )

            let records = try BookRecord
                .filter(Column("id") != 0 && Column("is_deleted") == 0)
                .order(Column("book_order").asc, Column("id").asc)
                .limit(8)
                .fetchAll(db)
            let books = records.compactMap { record -> BookPickerBook? in
                guard let id = record.id else { return nil }
                return BookPickerBook(
                    id: id,
                    title: record.name,
                    author: record.author,
                    press: record.press,
                    coverURL: record.cover,
                    positionUnit: record.positionUnit,
                    totalPosition: record.totalPosition,
                    totalPagination: record.totalPagination
                )
            }

            let noteText = try NoteRecord
                .filter(Column("is_deleted") == 0 && Column("content") != "")
                .order(Column("updated_date").desc, Column("id").desc)
                .limit(1)
                .fetchOne(db)?
                .content
            let tags = try TagRecord
                .filter(Column("is_deleted") == 0)
                .order(Column("tag_order").asc, Column("id").asc)
                .limit(8)
                .fetchAll(db)
                .compactMap { record -> SheetPreviewNamedEntity? in
                    guard let id = record.id,
                          let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else { return nil }
                    return SheetPreviewNamedEntity(id: id, title: name)
                }
            let collections = try CollectionRecord
                .filter(Column("is_deleted") == 0)
                .order(Column("order").asc, Column("id").asc)
                .limit(8)
                .fetchAll(db)
                .compactMap { record -> SheetPreviewNamedEntity? in
                    guard let id = record.id else { return nil }
                    let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return SheetPreviewNamedEntity(id: id, title: title)
                }
            let chapters = try ChapterRecord
                .filter(Column("is_deleted") == 0 && Column("id") != 0)
                .order(Column("chapter_order").asc, Column("id").asc)
                .limit(8)
                .fetchAll(db)
                .compactMap { record -> SheetPreviewNamedEntity? in
                    guard let id = record.id else { return nil }
                    let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return SheetPreviewNamedEntity(id: id, title: title)
                }
            return SheetPreviewSnapshot(
                createdAt: Date(),
                counts: counts,
                representativeBooks: books,
                representativeNoteText: noteText,
                representativeTags: tags,
                representativeCollections: collections,
                representativeChapters: chapters,
                copiedPreferenceCount: copiedPreferenceCount,
                supplementalFixtureCount: supplementalFixtureCount
            )
        }
    }

    private static func redactSensitiveDatabaseValues(in database: AppDatabase) async throws {
        try await database.dbPool.write { db in
            // SQL 目的：从 Sheet Debug 基础快照移除 WebDAV 地址、账号和密码，防止预览链路读取生产凭据。
            // 涉及表：backup_server；无跨表关联。
            // 关键过滤：全表脱敏；时间字段与记录身份保持不变。
            // 副作用：只改写临时快照中的三个敏感字段，正式数据库不受影响。
            try db.execute(
                sql: "UPDATE backup_server SET server_address = '', account = '', password = ''"
            )
            // SQL 目的：从 Sheet Debug 基础快照移除对象存储 SecretId、SecretKey、区域和桶名。
            // 涉及表：cos_config；无跨表关联。
            // 关键过滤：全表脱敏；时间字段与记录身份保持不变。
            // 副作用：只改写临时快照中的外部存储配置，正式数据库不受影响。
            try db.execute(
                sql: "UPDATE cos_config SET secret_id = '', secret_key = '', region = '', bucket = ''"
            )
        }
    }

    private static func nonSensitivePreferences() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { key, value in
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { return false }
            let normalized = key.lowercased()
            let sensitiveFragments = [
                "token", "password", "secret", "credential", "authorization", "cookie",
                "apikey", "api_key", "webdav", "s3", "aliyun", "accesskey", "privatekey",
                "ai.configuration", "external-app.integration"
            ]
            return !sensitiveFragments.contains(where: normalized.contains)
        }
    }
}

private struct SheetPreviewFixtureRepository {
    let database: AppDatabase

    /// 当正式快照完全没有书籍时，仅向工作副本补一条合法书籍，供依赖 Repository 的生产 View 正常启动。
    func insertMinimalBookIfNeeded() async throws -> Int {
        try await database.dbPool.write { db in
            let count = try BookRecord
                .filter(Column("id") != 0 && Column("is_deleted") == 0)
                .fetchCount(db)
            guard count == 0 else { return 0 }

            let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 1
            // SQL 目的：为 Debug 工作副本中的最小书籍选择一个有效来源。
            // 涉及表：source；无跨表关联。
            // 关键过滤：仅取 is_deleted=0 的首条来源；时间字段不参与处理。
            // 返回字段：source.id，仅写入隔离 book.source_id，正式数据库无副作用。
            let sourceID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM source WHERE is_deleted = 0 ORDER BY id LIMIT 1"
            ) ?? 1
            // SQL 目的：为 Debug 工作副本中的最小书籍选择一个有效阅读状态。
            // 涉及表：read_status；无跨表关联。
            // 关键过滤：仅取 is_deleted=0 的首条状态；时间字段不参与处理。
            // 返回字段：read_status.id，仅写入隔离 book.read_status_id，正式数据库无副作用。
            let readStatusID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM read_status WHERE is_deleted = 0 ORDER BY id LIMIT 1"
            ) ?? 1
            // SQL 目的：在 Debug 工作副本中生成不与现有书籍冲突的主键。
            // 涉及表：book；无跨表关联。
            // 关键过滤：聚合全部 id；时间字段不参与处理。
            // 返回字段：当前最大 id 加一，仅用于随后向隔离 book 插入最小夹具。
            let nextID = (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) + 1 FROM book")) ?? 1
            var record = BookRecord()
            record.id = nextID
            record.userId = ownerID
            record.name = "设计中的设计"
            record.rawName = record.name
            record.author = "原研哉"
            record.press = "山东人民出版社"
            record.sourceId = sourceID
            record.readStatusId = readStatusID
            record.createdDate = Int64(Date().timeIntervalSince1970 * 1_000)
            record.updatedDate = record.createdDate
            try record.insert(db)
            return 1
        }
    }
}

enum SheetPreviewSnapshotError: LocalizedError {
    case snapshotUnavailable
    case preferenceSuiteUnavailable

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            "生产数据库快照尚未准备完成"
        case .preferenceSuiteUnavailable:
            "无法创建隔离偏好容器"
        }
    }
}
#endif
