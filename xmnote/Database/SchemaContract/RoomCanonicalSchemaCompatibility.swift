/**
 * [INPUT]: 依赖 Android Room v40-v43 schema JSON、GRDB Database 与 RoomCanonicalSchemaV40/RoomCanonicalSchemaV41
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaCompatibility，按备份库 user_version 选择可恢复的 Room 物理 schema 校验
 * [POS]: Database/SchemaContract 的跨端恢复兼容入口，被备份恢复闸门与 GRDB 迁移标记流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room 备份恢复兼容层；iOS 新建库仍停留在 v41，仅允许恢复闸门识别 Android 当前 v42/v43 备份结构。
nonisolated enum RoomCanonicalSchemaCompatibility {
    nonisolated static let maximumRestorableDatabaseVersion = 43

    /// 按数据库 `PRAGMA user_version` 校验 Room 物理结构；v42/v43 只做只读恢复兼容，不触发 iOS schema 升级。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        let userVersion = try databaseVersion(db)
        switch userVersion {
        case 43...:
            try VersionedRoomSchema(
                version: 43,
                identityHash: "24d3737f9e3495337a4fbe9d9b3ac68f",
                resourceName: "RoomSchemaV43"
            ).validatePhysicalSchema(db)
        case 42:
            try VersionedRoomSchema(
                version: 42,
                identityHash: "4e0d2220f86e560a5ca24defac2ceefe",
                resourceName: "RoomSchemaV42"
            ).validatePhysicalSchema(db)
        case RoomCanonicalSchemaV41.databaseVersion:
            try RoomCanonicalSchemaV41.validatePhysicalSchema(db)
        default:
            try RoomCanonicalSchemaV40.validatePhysicalSchema(db)
        }
    }

    /// 校验外键闭包是否完整；v42/v43 与 v41 表关系一致，统一使用 SQLite foreign_key_check。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        // SQL 目的：执行 SQLite 原生外键完整性校验，确认恢复库可被 Android Room 与 iOS GRDB 安全打开。
        // 涉及表：全部 Room 实体表；返回行数用于阻断结构异常备份恢复。
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        if !violations.isEmpty {
            throw RoomCanonicalSchemaError.foreignKeyViolation(violations.count)
        }
    }

    /// 读取 SQLite user_version，作为恢复闸门选择 schema 合同的事实源。
    nonisolated static func databaseVersion(_ db: Database) throws -> Int {
        // SQL 目的：读取 SQLite schema 版本号，判断 Android Room 备份库的物理合同版本。
        // 涉及表：无；返回字段：PRAGMA user_version 单值。
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }
}

private extension RoomCanonicalSchemaCompatibility {
    nonisolated struct VersionedRoomSchema {
        let version: Int
        let identityHash: String
        let resourceName: String

        nonisolated func validatePhysicalSchema(_ db: Database) throws {
            guard try hasValidIdentityHash(db) else {
                throw RoomCanonicalSchemaError.invalidIdentityHashInDatabase
            }
            if let diagnostic = try physicalSchemaDiagnostic(db) {
                throw RoomCanonicalSchemaError.schemaDefinitionMismatch(diagnostic)
            }
        }

        nonisolated func loadSchema() throws -> RoomDatabaseSchema {
            let data: Data
            if let url = bundleSchemaURL() {
                data = try Data(contentsOf: url)
            } else if let fallbackURL = debugFallbackSchemaURL() {
                data = try Data(contentsOf: fallbackURL)
            } else {
                throw RoomCanonicalSchemaError.schemaResourceMissing
            }

            let payload = try JSONDecoder().decode(RoomSchemaPayload.self, from: data)
            guard payload.database.version == version else {
                throw RoomCanonicalSchemaError.versionMismatch(payload.database.version)
            }
            guard payload.database.identityHash == identityHash else {
                throw RoomCanonicalSchemaError.identityHashMismatch(payload.database.identityHash)
            }
            return payload.database
        }

        nonisolated func hasValidIdentityHash(_ db: Database) throws -> Bool {
            guard try db.tableExists("room_master_table") else { return false }
            let hash = try String.fetchOne(
                db,
                sql: """
                    SELECT identity_hash
                    FROM room_master_table
                    WHERE id = 42
                    LIMIT 1
                """
            )
            return hash == identityHash
        }

        nonisolated func physicalSchemaDiagnostic(_ db: Database) throws -> RoomSchemaDiagnostic? {
            for entity in try loadSchema().entities {
                if !(try db.tableExists(entity.tableName)) {
                    return RoomSchemaDiagnostic(
                        tableName: entity.tableName,
                        objectName: nil,
                        detail: "缺少 Room v\(version) 必需表"
                    )
                }

                if let diagnostic = try columnsDiagnostic(entity, db: db) {
                    return diagnostic
                }

                if let diagnostic = try foreignKeysDiagnostic(entity, db: db) {
                    return diagnostic
                }

                if let diagnostic = try indicesDiagnostic(entity, db: db) {
                    return diagnostic
                }
            }
            return nil
        }

        nonisolated func bundleSchemaURL() -> URL? {
            Bundle.main.url(forResource: resourceName, withExtension: "json")
                ?? Bundle.main.url(
                    forResource: resourceName,
                    withExtension: "json",
                    subdirectory: "Database/SchemaContract"
                )
        }

        nonisolated func debugFallbackSchemaURL() -> URL? {
            #if DEBUG
            let fileManager = FileManager.default
            let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            let candidates = [
                currentDirectory.appendingPathComponent("xmnote/Database/\(resourceName).json"),
                currentDirectory.appendingPathComponent("xmnote/Database/SchemaContract/\(resourceName).json"),
                currentDirectory.appendingPathComponent("Database/\(resourceName).json")
            ]
            return candidates.first { fileManager.fileExists(atPath: $0.path) }
            #else
            return nil
            #endif
        }
    }

    nonisolated static func columnsDiagnostic(
        _ entity: RoomEntitySchema,
        db: Database
    ) throws -> RoomSchemaDiagnostic? {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quote(entity.tableName)))")
        let actualByName = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Row)? in
            guard let name = stringValue(row, "name") else { return nil }
            return (name, row)
        })
        let expectedColumns = Set(entity.fields.map(\.columnName))
        let actualColumns = Set(actualByName.keys)
        guard actualColumns == expectedColumns else {
            return RoomSchemaDiagnostic(
                tableName: entity.tableName,
                objectName: nil,
                detail: setDiffDescription(actual: actualColumns, expected: expectedColumns, noun: "字段")
            )
        }

        let actualPrimaryKey = rows
            .filter { intValue($0, "pk") > 0 }
            .sorted { intValue($0, "pk") < intValue($1, "pk") }
            .compactMap { stringValue($0, "name") }
        guard actualPrimaryKey == entity.primaryKey.columnNames else {
            return RoomSchemaDiagnostic(
                tableName: entity.tableName,
                objectName: nil,
                detail: "主键不一致，期望 \(entity.primaryKey.columnNames.joined(separator: ","))，实际 \(actualPrimaryKey.joined(separator: ","))"
            )
        }

        for field in entity.fields {
            guard let row = actualByName[field.columnName] else {
                return RoomSchemaDiagnostic(tableName: entity.tableName, objectName: field.columnName, detail: "缺少字段")
            }
            let actualAffinity = stringValue(row, "type")?.uppercased() ?? ""
            guard actualAffinity == field.affinity.uppercased() else {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: field.columnName,
                    detail: "字段类型不一致，期望 \(field.affinity.uppercased())，实际 \(actualAffinity)"
                )
            }

            let actualNotNull = intValue(row, "notnull") != 0
            guard actualNotNull == field.notNull else {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: field.columnName,
                    detail: "nullable 不一致，期望 notNull=\(field.notNull)，实际 notNull=\(actualNotNull)"
                )
            }
        }

        return nil
    }

    nonisolated static func foreignKeysDiagnostic(
        _ entity: RoomEntitySchema,
        db: Database
    ) throws -> RoomSchemaDiagnostic? {
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quote(entity.tableName)))")
        let actual = Dictionary(grouping: rows, by: { intValue($0, "id") })
            .values
            .map { group -> RoomForeignKeySnapshot in
                let ordered = group.sorted { intValue($0, "seq") < intValue($1, "seq") }
                let first = ordered[0]
                return RoomForeignKeySnapshot(
                    table: stringValue(first, "table") ?? "",
                    onDelete: normalizedAction(stringValue(first, "on_delete")),
                    onUpdate: normalizedAction(stringValue(first, "on_update")),
                    columns: ordered.compactMap { stringValue($0, "from") },
                    referencedColumns: ordered.compactMap { stringValue($0, "to") }
                )
            }
            .sorted()

        let expected = entity.foreignKeys
            .map {
                RoomForeignKeySnapshot(
                    table: $0.table,
                    onDelete: normalizedAction($0.onDelete),
                    onUpdate: normalizedAction($0.onUpdate),
                    columns: $0.columns,
                    referencedColumns: $0.referencedColumns
                )
            }
            .sorted()

        guard actual == expected else {
            return RoomSchemaDiagnostic(
                tableName: entity.tableName,
                objectName: nil,
                detail: "外键定义不一致，期望 \(expected.map(\.description).joined(separator: "; "))，实际 \(actual.map(\.description).joined(separator: "; "))"
            )
        }
        return nil
    }

    nonisolated static func indicesDiagnostic(
        _ entity: RoomEntitySchema,
        db: Database
    ) throws -> RoomSchemaDiagnostic? {
        let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(\(quote(entity.tableName)))")
        let actualByName = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Row)? in
            guard let name = stringValue(row, "name") else { return nil }
            return (name, row)
        })

        for index in entity.indices {
            guard let row = actualByName[index.name] else {
                return RoomSchemaDiagnostic(tableName: entity.tableName, objectName: index.name, detail: "缺少索引")
            }
            let isUnique = intValue(row, "unique") != 0
            guard isUnique == index.unique else {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: index.name,
                    detail: "索引唯一性不一致，期望 unique=\(index.unique)，实际 unique=\(isUnique)"
                )
            }

            let indexInfo = try Row.fetchAll(db, sql: "PRAGMA index_info(\(quote(index.name)))")
            let actualColumns = indexInfo
                .sorted { intValue($0, "seqno") < intValue($1, "seqno") }
                .compactMap { stringValue($0, "name") }
            guard actualColumns == index.columnNames else {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: index.name,
                    detail: "索引字段不一致，期望 \(index.columnNames.joined(separator: ","))，实际 \(actualColumns.joined(separator: ","))"
                )
            }
        }

        return nil
    }

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

    nonisolated static func normalizedAction(_ action: String?) -> String {
        (action ?? "").uppercased()
    }

    nonisolated static func setDiffDescription(actual: Set<String>, expected: Set<String>, noun: String) -> String {
        let missing = expected.subtracting(actual).sorted()
        let extra = actual.subtracting(expected).sorted()
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("缺少\(noun)：\(missing.joined(separator: ","))")
        }
        if !extra.isEmpty {
            parts.append("多出\(noun)：\(extra.joined(separator: ","))")
        }
        return parts.joined(separator: "；")
    }
}

nonisolated private struct RoomForeignKeySnapshot: Equatable, Comparable, CustomStringConvertible {
    let table: String
    let onDelete: String
    let onUpdate: String
    let columns: [String]
    let referencedColumns: [String]

    static func < (lhs: RoomForeignKeySnapshot, rhs: RoomForeignKeySnapshot) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        [
            table,
            columns.joined(separator: ","),
            referencedColumns.joined(separator: ","),
            onDelete,
            onUpdate
        ].joined(separator: "|")
    }

    var description: String {
        "\(columns.joined(separator: ","))->\(table)(\(referencedColumns.joined(separator: ","))) delete=\(onDelete) update=\(onUpdate)"
    }
}
