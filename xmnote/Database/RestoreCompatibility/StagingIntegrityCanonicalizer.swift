/**
 * [INPUT]: 依赖 DefaultRootSeeder、ForeignKeyViolationReader 与 TombstoneFactory，接收备份 staging 数据库
 * [OUTPUT]: 对外提供 StagingIntegrityCanonicalizer，用于恢复前整理 Android 历史备份外键闭包
 * [POS]: Database/RestoreCompatibility 的 staging 整理编排器，被 BackupSchemaValidator 调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 仅在备份 staging 库中执行外键闭包整理；不会修改原始备份包或正式库。
nonisolated enum StagingIntegrityCanonicalizer {
    private nonisolated static let maxRepairPassCount = 8

    /// 补齐 Android 历史备份中的默认父行与 tombstone 父行，并软删除失去父级的活跃子记录。
    nonisolated static func canonicalize(_ db: Database) throws {
        try DefaultRootSeeder.seed(db)

        for _ in 0..<maxRepairPassCount {
            let violations = try ForeignKeyViolationReader.fetchViolations(db)
            if violations.isEmpty {
                return
            }

            for violation in violations {
                try repair(violation, db: db)
            }
        }

        let remainingCount = try ForeignKeyViolationReader.fetchViolations(db).count
        if remainingCount > 0 {
            throw StagingIntegrityCanonicalizerError.unrepairableForeignKeys(remainingCount)
        }
    }
}

private extension StagingIntegrityCanonicalizer {
    nonisolated static func repair(_ violation: ForeignKeyViolation, db: Database) throws {
        let reference = try ForeignKeyViolationReader.reference(for: violation, db: db)
        guard reference.parentColumns == ["id"], reference.childColumns.count == 1 else {
            throw StagingIntegrityCanonicalizerError.unsupportedForeignKey(
                child: violation.childTable,
                parent: violation.parentTable
            )
        }
        guard let childColumn = reference.childColumns.first else {
            throw StagingIntegrityCanonicalizerError.unsupportedForeignKey(
                child: violation.childTable,
                parent: violation.parentTable
            )
        }
        guard let parentID = try referencedID(
            table: violation.childTable,
            column: childColumn,
            rowID: violation.childRowID,
            db: db
        ) else {
            return
        }

        try TombstoneFactory.ensureParent(table: violation.parentTable, id: parentID, db: db)
        try softDeleteChildIfNeeded(violation, db: db)
    }

    nonisolated static func referencedID(
        table: String,
        column: String,
        rowID: Int64,
        db: Database
    ) throws -> Int64? {
        // SQL 目的：根据 foreign_key_check 返回的 child rowid 读取实际断开的父记录 id。
        // 涉及表：当前异常子表；关键字段：外键列来自 PRAGMA foreign_key_list。
        try Int64.fetchOne(
            db,
            sql: """
                SELECT \(quote(column))
                FROM \(quote(table))
                WHERE rowid = ?
                LIMIT 1
            """,
            arguments: [rowID]
        )
    }

    nonisolated static func softDeleteChildIfNeeded(_ violation: ForeignKeyViolation, db: Database) throws {
        guard try tableHasColumn(violation.childTable, "is_deleted", db: db) else { return }
        guard !(try isSystemRootRow(table: violation.childTable, rowID: violation.childRowID, db: db)) else { return }

        if try tableHasColumn(violation.childTable, "updated_date", db: db) {
            // SQL 目的：软删除仍活跃但父记录缺失的子记录，避免恢复后孤儿记录继续进入 UI。
            // 涉及表：当前异常子表；关键过滤：rowid 精确定位且仅更新 is_deleted=0 的活跃行。
            try db.execute(
                sql: """
                    UPDATE \(quote(violation.childTable))
                    SET is_deleted = 1,
                        updated_date = ?
                    WHERE rowid = ?
                      AND is_deleted = 0
                """,
                arguments: [currentMilliseconds(), violation.childRowID]
            )
        } else {
            // SQL 目的：软删除缺少 updated_date 字段的异常子记录，避免其进入业务查询。
            // 涉及表：当前异常子表；关键过滤：rowid 精确定位且仅更新 is_deleted=0 的活跃行。
            try db.execute(
                sql: """
                    UPDATE \(quote(violation.childTable))
                    SET is_deleted = 1
                    WHERE rowid = ?
                      AND is_deleted = 0
                """,
                arguments: [violation.childRowID]
            )
        }
    }

    nonisolated static func tableHasColumn(_ table: String, _ column: String, db: Database) throws -> Bool {
        // SQL 目的：读取表字段元数据，判断 staging 整理是否可以安全更新软删除和更新时间字段。
        // 涉及表：当前异常子表；返回字段：字段名集合。
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(quote(table)))").contains { row in
            stringValue(row, "name") == column
        }
    }

    nonisolated static func isSystemRootRow(table: String, rowID: Int64, db: Database) throws -> Bool {
        // SQL 目的：读取异常子表主键，避免默认系统根记录被软删除。
        // 涉及表：当前异常子表；关键过滤：foreign_key_check 返回的 rowid。
        guard let id = try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM \(quote(table))
                WHERE rowid = ?
                LIMIT 1
            """,
            arguments: [rowID]
        ) else {
            return false
        }

        switch table {
        case "book", "chapter", "source":
            return id == 0
        case "user":
            return id == 1
        case "read_status":
            return (1...5).contains(Int(id))
        default:
            return false
        }
    }

    nonisolated static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated static func currentMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    nonisolated static func stringValue(_ row: Row, _ column: String) -> String? {
        let value: String? = row[column]
        return value
    }
}

nonisolated private enum StagingIntegrityCanonicalizerError: LocalizedError {
    case unsupportedForeignKey(child: String, parent: String)
    case unrepairableForeignKeys(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedForeignKey(let child, let parent):
            return "备份内存在无法安全整理的历史关系：\(child) -> \(parent)"
        case .unrepairableForeignKeys(let count):
            return "备份内仍有 \(count) 处历史关系无法安全整理"
        }
    }
}
