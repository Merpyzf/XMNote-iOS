import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB Database 与 UserRecord/各 user_id 业务表，统一解析当前 owner user
 * [OUTPUT]: 对外提供 DatabaseOwnerResolver，供迁移和 Repository 共享当前用户归属逻辑
 * [POS]: Database 层兼容桥梁，负责兼容 Android 单临时用户模型并修复遗留 user_id 脏数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 统一解析当前数据库 owner，并修复旧库中遗留的无效 user_id。
enum DatabaseOwnerResolver {
    nonisolated static let tempUserExternalID: Int64 = 1
    nonisolated static let tempUserName = "临时用户"
    nonisolated static let tempUserGender: Int64 = 1
    nonisolated static let defaultSourceID: Int64 = 1
    nonisolated static let defaultSourceName = "未知"
    nonisolated static let defaultReadStatusID: Int64 = 1
    nonisolated static let defaultReadStatusName = "想读"

    /// 返回当前 owner 的 user 主键；若不存在则自动创建 Android 对齐的临时用户。
    nonisolated static func resolveOwnerID(in db: Database) throws -> Int64 {
        if let fallbackOwnerId = try fetchExistingOwnerID(in: db) {
            return fallbackOwnerId
        }

        var record = UserRecord(
            id: nil,
            userId: tempUserExternalID,
            nickName: tempUserName,
            gender: tempUserGender,
            phone: nil,
            createdDate: 0,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        record.touchCreatedDate()
        try record.insert(db)

        guard let ownerId = record.id else {
            throw DatabaseOwnerError.createOwnerFailed
        }
        return ownerId
    }

    /// 修复依赖 owner user 的业务表，使旧库与 Android 恢复库都能满足后续写入要求。
    nonisolated static func repairUserScopedReferences(in db: Database) throws {
        let ownerId = try resolveOwnerID(in: db)
        let fallbackSourceID = try ensureDefaultSourceID(in: db)
        let fallbackReadStatusID = try ensureDefaultReadStatusID(in: db)

        // Android 历史库里可能存在 source_id/read_status_id = 0 的占位行。
        // 先修复 book 的外键字段，再更新 user_id，避免触发 FK 校验失败。
        try db.execute(
            sql: """
                UPDATE book
                SET source_id = ?
                WHERE source_id = 0
                   OR source_id NOT IN (SELECT id FROM source WHERE is_deleted = 0)
                """,
            arguments: [fallbackSourceID]
        )
        try db.execute(
            sql: """
                UPDATE book
                SET read_status_id = ?
                WHERE read_status_id = 0
                   OR read_status_id NOT IN (SELECT id FROM read_status WHERE is_deleted = 0)
                """,
            arguments: [fallbackReadStatusID]
        )
        try repairOwnerID(in: db, table: "book", ownerId: ownerId)

        for table in ["setting", "tag", "`group`"] {
            try repairOwnerID(in: db, table: table, ownerId: ownerId)
        }
    }

    /// 只读场景下获取当前 owner；若数据库仍未初始化出 owner，则返回 nil。
    nonisolated static func fetchExistingOwnerID(in db: Database) throws -> Int64? {
        if let ownerId = try fetchTempOwnerID(in: db) {
            return ownerId
        }
        return try fetchFirstActiveOwnerID(in: db)
    }
}

private enum DatabaseOwnerError: LocalizedError {
    case createOwnerFailed
    case createDefaultSourceFailed
    case createDefaultReadStatusFailed

    var errorDescription: String? {
        switch self {
        case .createOwnerFailed:
            return "创建默认用户失败"
        case .createDefaultSourceFailed:
            return "创建默认书籍来源失败"
        case .createDefaultReadStatusFailed:
            return "创建默认阅读状态失败"
        }
    }
}

private extension DatabaseOwnerResolver {
    nonisolated static func repairOwnerID(in db: Database, table: String, ownerId: Int64) throws {
        try db.execute(
            sql: """
                UPDATE \(table)
                SET user_id = ?
                WHERE user_id = 0
                   OR user_id NOT IN (SELECT id FROM user WHERE is_deleted = 0)
                """,
            arguments: [ownerId]
        )
    }

    nonisolated static func ensureDefaultSourceID(in db: Database) throws -> Int64 {
        if let sourceID = try fetchAvailableSourceID(in: db) {
            return sourceID
        }

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO source (id, name, source_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (?, ?, 0, 0, 0, 0, 0, 0)
                """,
            arguments: [defaultSourceID, defaultSourceName]
        )
        try db.execute(
            sql: """
                UPDATE source
                SET is_deleted = 0
                WHERE id = ?
                """,
            arguments: [defaultSourceID]
        )

        if let sourceID = try fetchAvailableSourceID(in: db) {
            return sourceID
        }
        throw DatabaseOwnerError.createDefaultSourceFailed
    }

    nonisolated static func ensureDefaultReadStatusID(in db: Database) throws -> Int64 {
        if let statusID = try fetchAvailableReadStatusID(in: db) {
            return statusID
        }

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO read_status (id, name, read_status_order, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (?, ?, 1, 0, 0, 0, 0)
                """,
            arguments: [defaultReadStatusID, defaultReadStatusName]
        )
        try db.execute(
            sql: """
                UPDATE read_status
                SET is_deleted = 0
                WHERE id = ?
                """,
            arguments: [defaultReadStatusID]
        )

        if let statusID = try fetchAvailableReadStatusID(in: db) {
            return statusID
        }
        throw DatabaseOwnerError.createDefaultReadStatusFailed
    }

    nonisolated static func fetchAvailableSourceID(in db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM source
                WHERE is_deleted = 0
                ORDER BY source_order ASC, id ASC
                LIMIT 1
                """
        )
    }

    nonisolated static func fetchAvailableReadStatusID(in db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM read_status
                WHERE is_deleted = 0
                ORDER BY read_status_order ASC, id ASC
                LIMIT 1
                """
        )
    }

    nonisolated static func fetchTempOwnerID(in db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM user
                WHERE user_id = ?
                  AND is_deleted = 0
                ORDER BY id ASC
                LIMIT 1
                """,
            arguments: [tempUserExternalID]
        )
    }

    nonisolated static func fetchFirstActiveOwnerID(in db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM user
                WHERE is_deleted = 0
                ORDER BY id ASC
                LIMIT 1
                """
        )
    }
}
