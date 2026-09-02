/**
 * [INPUT]: 依赖本机私有 B0.db、CryptoKit、GRDB 与 RoomCanonicalSchemaV47
 * [OUTPUT]: 对外提供私有基准定位、字节级克隆、主机同算法结构/外键摘要及生产恢复链路夹具
 * [POS]: xmnoteTests/BookAlignment 测试基础层，确保书籍对齐用例在 B0 独立副本上先整理再迁移
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import GRDB
@testable import xmnote

/// 解析本机私有 B0；仓库只保留约定路径，不包含任何真实数据或业务 ID。
nonisolated enum BookAlignmentPrivateBaseline {
    static let pathEnvironment = "XMNOTE_BOOK_ALIGNMENT_BASELINE_PATH"

    static var resolvedURL: URL? {
        let environmentPath = ProcessInfo.processInfo.environment[pathEnvironment]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentPath.isEmpty {
            let url = URL(fileURLWithPath: environmentPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaultURL = repositoryRoot
            .appendingPathComponent("artifacts/book-alignment/current/B0.db", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    static var isAvailable: Bool {
        resolvedURL != nil
    }
}

/// 不包含业务行值的 B0 预检结果，可安全写入本机测试报告。
nonisolated struct BookAlignmentBaselineMetadata: Equatable, Sendable {
    let sha256: String
    let schemaSHA256: String
    let databaseVersion: Int
    let roomIdentityHash: String
    let foreignKeySummary: BookAlignmentForeignKeySummary
}

/// 仅保留外键异常行摘要及其集合摘要，既能做 multiset 差分，也不会泄露真实表行。
nonisolated struct BookAlignmentForeignKeySummary: Equatable, Sendable {
    let violationCount: Int
    let violationDigests: [String]
    let setDigest: String
}

/// 书籍对齐数据库夹具错误，只输出结构和校验信息，不输出业务行。
nonisolated enum BookAlignmentDatabaseFixtureError: Error, Equatable, CustomStringConvertible {
    case missingPrivateBaseline
    case byteCloneMismatch(expected: String, actual: String)
    case quickCheckFailed(String)
    case integrityCheckFailed(String)
    case databaseVersionMismatch(Int)
    case roomIdentityHashMismatch(String)

    var description: String {
        switch self {
        case .missingPrivateBaseline:
            return "SKIP: missing private baseline (set XMNOTE_BOOK_ALIGNMENT_BASELINE_PATH)"
        case .byteCloneMismatch(let expected, let actual):
            return "B0 clone SHA-256 mismatch: expected \(expected), actual \(actual)"
        case .quickCheckFailed(let result):
            return "B0 PRAGMA quick_check failed: \(result)"
        case .integrityCheckFailed(let result):
            return "B0 PRAGMA integrity_check failed: \(result)"
        case .databaseVersionMismatch(let version):
            return "B0 user_version mismatch: expected 47, actual \(version)"
        case .roomIdentityHashMismatch(let hash):
            return "B0 Room identity mismatch: expected v47, actual \(hash)"
        }
    }
}

/// 从不可变 B0 创建单个用例专属副本；关闭前不会触碰原始基准文件。
@MainActor
final class BookAlignmentDatabaseFixture {
    let baselineURL: URL
    let workingDirectoryURL: URL
    let workingDatabaseURL: URL
    let metadata: BookAlignmentBaselineMetadata
    let preOpenCloneSHA256: String
    let database: AppDatabase
    let databaseManager: DatabaseManager
    let repository: BookRepository

    private init(
        baselineURL: URL,
        workingDirectoryURL: URL,
        workingDatabaseURL: URL,
        metadata: BookAlignmentBaselineMetadata,
        preOpenCloneSHA256: String,
        database: AppDatabase
    ) {
        self.baselineURL = baselineURL
        self.workingDirectoryURL = workingDirectoryURL
        self.workingDatabaseURL = workingDatabaseURL
        self.metadata = metadata
        self.preOpenCloneSHA256 = preOpenCloneSHA256
        self.database = database
        let manager = DatabaseManager(database: database)
        databaseManager = manager
        repository = BookRepository(databaseManager: manager)
    }

    /// 先复制 B0 并证明 SHA-256 一致，再仅在临时副本上执行生产恢复整理与数据库迁移。
    static func clonePrivateBaseline() throws -> BookAlignmentDatabaseFixture {
        guard let baselineURL = BookAlignmentPrivateBaseline.resolvedURL else {
            throw BookAlignmentDatabaseFixtureError.missingPrivateBaseline
        }

        let baselineSHA256 = try sha256(of: baselineURL)
        let workingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-book-alignment-\(UUID().uuidString)", isDirectory: true)
        let workingDatabaseURL = workingDirectoryURL.appendingPathComponent("B0-working.db")

        do {
            try FileManager.default.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: baselineURL, to: workingDatabaseURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: workingDatabaseURL.path
            )
            let cloneSHA256 = try sha256(of: workingDatabaseURL)
            guard cloneSHA256 == baselineSHA256 else {
                throw BookAlignmentDatabaseFixtureError.byteCloneMismatch(
                    expected: baselineSHA256,
                    actual: cloneSHA256
                )
            }

            let metadata = try inspectClone(
                at: workingDatabaseURL,
                baselineSHA256: baselineSHA256
            )
            // B0 保留 Android 历史外键异常；生产恢复会在正式替换前先补齐父记录。
            // 测试必须复用同一恢复闸门，不能让 AppDatabase 的迁移事务直接承接未整理的 v47 库。
            try BackupSchemaValidator.prepareForRestore(at: workingDatabaseURL.path)
            let database = try AppDatabase(path: workingDatabaseURL.path)
            return BookAlignmentDatabaseFixture(
                baselineURL: baselineURL,
                workingDirectoryURL: workingDirectoryURL,
                workingDatabaseURL: workingDatabaseURL,
                metadata: metadata,
                preOpenCloneSHA256: cloneSHA256,
                database: database
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectoryURL)
            throw error
        }
    }

    /// 关闭 GRDB 连接并只删除本用例创建的 UUID 临时目录。
    func cleanup() {
        database.interrupt()
        try? database.close()
        try? FileManager.default.removeItem(at: workingDirectoryURL)
    }

    /// 仅在字节一致的临时副本上验证 B0，避免 WAL 模式的只读打开需求触碰原始基准。
    private nonisolated static func inspectClone(
        at url: URL,
        baselineSHA256: String
    ) throws -> BookAlignmentBaselineMetadata {
        let databaseQueue = try DatabaseQueue(path: url.path)
        defer { try? databaseQueue.close() }

        return try databaseQueue.read { db in
            // SQL 目的：执行 SQLite 快速页结构校验，阻断损坏基准进入对齐用例。
            // 涉及表：全库 B-tree 页；不读取或输出任何业务字段。
            // 关键过滤：无；时间字段：不参与；返回值必须为 ok。
            let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "missing"
            guard quickCheck == "ok" else {
                throw BookAlignmentDatabaseFixtureError.quickCheckFailed(quickCheck)
            }

            // SQL 目的：执行 SQLite 完整页与索引一致性校验，确保 B0 可作为字节基准。
            // 涉及表：全库表与索引；关键过滤：无；时间字段：不参与。
            // 返回用途：只保留 ok/错误摘要，不输出业务行。
            let integrityCheck = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing"
            guard integrityCheck == "ok" else {
                throw BookAlignmentDatabaseFixtureError.integrityCheckFailed(integrityCheck)
            }

            // SQL 目的：读取 SQLite user_version，确认基准与 Android Room v47 合同一致。
            // 涉及表：无，读取数据库 header pragma；时间字段：不参与。
            // 返回用途：阻断旧版 schema 被当作对齐起点。
            let databaseVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard databaseVersion == RoomCanonicalSchemaV47.databaseVersion else {
                throw BookAlignmentDatabaseFixtureError.databaseVersionMismatch(databaseVersion)
            }

            // SQL 目的：读取 Room id=42 的 identity hash，校验 Android v47 物理合同身份。
            // 涉及表：room_master_table；关键过滤：id = 42；时间字段：不参与。
            // 返回字段：identity_hash，报告只显示 schema hash。
            let roomIdentityHash = try String.fetchOne(
                db,
                sql: "SELECT identity_hash FROM room_master_table WHERE id = 42 LIMIT 1"
            ) ?? "missing"
            guard roomIdentityHash == RoomCanonicalSchemaV47.identityHash else {
                throw BookAlignmentDatabaseFixtureError.roomIdentityHashMismatch(roomIdentityHash)
            }

            try RoomCanonicalSchemaV47.validatePhysicalSchema(db)

            // SQL 目的：摘要化 B0 历史外键异常，作为后续场景“不得新增”的 baseline。
            // 涉及表：全部 Room 实体外键；关键过滤：无；时间字段：不参与。
            // 返回用途：只记录逐行 SHA-256 与集合摘要，不持久化或输出原始违规行。
            let foreignKeySummary = try foreignKeySummary(db)
            let schemaSHA256 = try schemaFingerprint(db)

            return BookAlignmentBaselineMetadata(
                sha256: baselineSHA256,
                schemaSHA256: schemaSHA256,
                databaseVersion: databaseVersion,
                roomIdentityHash: roomIdentityHash,
                foreignKeySummary: foreignKeySummary
            )
        }
    }

    /// 按主机 `sqlite-schema-v1` 合同生成结构 SHA-256，保留 null 并折叠 SQL 空白。
    nonisolated static func schemaFingerprint(_ db: Database) throws -> String {
        // SQL 目的：读取主机工具 sqlite-schema-v1 纳入比较的全部结构对象。
        // 涉及表：sqlite_schema；关键过滤：仅排除 SQLite 临时 schema 对象，不排除内部表。
        // 时间字段：不参与；返回字段：type/name/tbl_name/sql，null SQL 保持为 JSON null。
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT type, name, tbl_name, sql
                FROM sqlite_schema
                WHERE name NOT LIKE 'sqlite_temp_%'
                ORDER BY type, name, tbl_name
                """
        )
        let canonicalSchema: [[String: Any]] = rows.map { row in
            let type: String = row["type"] ?? ""
            let name: String = row["name"] ?? ""
            let tableName: String = row["tbl_name"] ?? ""
            let sql: String? = row["sql"]
            return [
                "type": type,
                "name": name,
                "table": tableName,
                "sql": sql.map(normalizedSQL) ?? NSNull()
            ]
        }
        return try jsonDigest(canonicalSchema)
    }

    /// 按主机 common.py 合同摘要 `foreign_key_check`，保留重复摘要以支持 multiset 差分。
    nonisolated static func foreignKeySummary(_ db: Database) throws -> BookAlignmentForeignKeySummary {
        // SQL 目的：读取 SQLite 外键异常并逐行摘要，检测首次打开或场景写入是否产生新异常。
        // 涉及表：全部 Room 实体外键；关键过滤：无；时间字段：不参与。
        // 返回字段：table/rowid/parent/fkid 只进入内存 JSON 哈希，绝不输出或持久化原始值。
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        let violationDigests = try rows.map { row -> String in
            let childTable: String = row["table"] ?? ""
            let childRowID: Int64? = row["rowid"]
            let parentTable: String = row["parent"] ?? ""
            let foreignKeyID: Int64 = row["fkid"] ?? 0
            let canonicalRow: [Any] = [
                childTable,
                childRowID.map { NSNumber(value: $0) } ?? NSNull(),
                parentTable,
                NSNumber(value: foreignKeyID)
            ]
            return try jsonDigest(canonicalRow)
        }.sorted()
        return BookAlignmentForeignKeySummary(
            violationCount: violationDigests.count,
            violationDigests: violationDigests,
            setDigest: try jsonDigest(violationDigests)
        )
    }

    /// 返回 after 相对 baseline 新增的摘要 multiset；旧异常消失是允许的，等量替换会被识别为新增。
    nonisolated static func addedForeignKeyViolationDigests(
        after: BookAlignmentForeignKeySummary,
        baseline: BookAlignmentForeignKeySummary
    ) -> [String] {
        var baselineCounts = Dictionary(
            baseline.violationDigests.map { ($0, 1) },
            uniquingKeysWith: +
        )
        var added: [String] = []
        for digest in after.violationDigests {
            let remainingCount = baselineCounts[digest, default: 0]
            if remainingCount > 0 {
                baselineCounts[digest] = remainingCount - 1
            } else {
                added.append(digest)
            }
        }
        return added
    }

    /// 流式计算文件 SHA-256，避免将用户真实数据库一次性读入内存。
    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hexadecimal(hasher.finalize())
    }

    /// 计算内存中的结构摘要 SHA-256，不保留原始 schema SQL。
    private nonisolated static func sha256(of data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    /// 生成与 Python `json.dumps(..., sort_keys=True, separators=(",", ":"))` 等价的 UTF-8 JSON 摘要。
    private nonisolated static func jsonDigest(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return sha256(of: data)
    }

    /// 将 schema SQL 中连续 Unicode 空白折叠为单个 ASCII 空格，与 Python `" ".join(value.split())` 一致。
    private nonisolated static func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private nonisolated static func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
