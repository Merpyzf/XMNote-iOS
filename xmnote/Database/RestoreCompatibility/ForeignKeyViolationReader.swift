/**
 * [INPUT]: 接收备份 staging 数据库与 SQLite 外键元数据
 * [OUTPUT]: 对外提供 ForeignKeyViolationReader，用于读取外键异常与对应引用列
 * [POS]: Database/RestoreCompatibility 的外键异常读取器，被 StagingIntegrityCanonicalizer 调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// SQLite `PRAGMA foreign_key_check` 返回的一条异常关系。
nonisolated struct ForeignKeyViolation {
    let childTable: String
    let childRowID: Int64
    let parentTable: String
    let foreignKeyID: Int
}

/// 某条外键定义中子表列与父表列的对应关系。
nonisolated struct ForeignKeyReference {
    let childColumns: [String]
    let parentColumns: [String]
}

/// 读取 staging 库中的外键异常，避免修复编排器直接理解 SQLite PRAGMA 行结构。
nonisolated enum ForeignKeyViolationReader {
    /// 返回当前 staging 数据库全部外键异常，用于后续按缺失父记录做受限整理。
    nonisolated static func fetchViolations(_ db: Database) throws -> [ForeignKeyViolation] {
        // SQL 目的：读取 SQLite 外键异常清单，用于在 staging 库中按缺失父记录做受限整理。
        // 涉及表：全部 Room 实体表；返回字段：child table、child rowid、parent table、外键编号。
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").compactMap { row in
            guard
                let childTable = stringValue(row, "table"),
                let parentTable = stringValue(row, "parent")
            else {
                return nil
            }
            return ForeignKeyViolation(
                childTable: childTable,
                childRowID: int64Value(row, "rowid"),
                parentTable: parentTable,
                foreignKeyID: intValue(row, "fkid")
            )
        }
    }

    /// 根据 `foreign_key_check` 的 `fkid` 定位异常关系对应的外键列定义。
    nonisolated static func reference(
        for violation: ForeignKeyViolation,
        db: Database
    ) throws -> ForeignKeyReference {
        // SQL 目的：读取异常子表的外键定义，定位 foreign_key_check 中 fkid 对应的子列与父列。
        // 涉及表：当前异常子表；返回字段：from/to/id/seq，用于后续补齐缺失父记录。
        let rows = try Row.fetchAll(
            db,
            sql: "PRAGMA foreign_key_list(\(quote(violation.childTable)))"
        )
            .filter { intValue($0, "id") == violation.foreignKeyID }
            .sorted { intValue($0, "seq") < intValue($1, "seq") }

        return ForeignKeyReference(
            childColumns: rows.compactMap { stringValue($0, "from") },
            parentColumns: rows.compactMap { stringValue($0, "to") }
        )
    }
}

private extension ForeignKeyViolationReader {
    nonisolated static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated static func stringValue(_ row: Row, _ column: String) -> String? {
        let value: String? = row[column]
        return value
    }

    nonisolated static func intValue(_ row: Row, _ column: String) -> Int {
        let value: Int? = row[column]
        return value ?? 0
    }

    nonisolated static func int64Value(_ row: Row, _ column: String) -> Int64 {
        let value: Int64? = row[column]
        return value ?? 0
    }
}
