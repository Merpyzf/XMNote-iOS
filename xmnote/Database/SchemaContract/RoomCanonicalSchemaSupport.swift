/**
 * [INPUT]: 依赖 Android Room 导出的 schema JSON、GRDB Database 与 RoomSchemaDiagnostic
 * [OUTPUT]: 对外提供 Room canonical schema 加载、建表、identity hash 与物理结构校验的共享实现
 * [POS]: Database/SchemaContract 的内部辅助层，被 v42/v43/v44 Room schema 合同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Room schema 合同共享工具，集中处理版本 JSON 加载、Room master 表写入与物理结构诊断。
nonisolated enum RoomCanonicalSchemaSupport {
    nonisolated static func createAllTables(
        _ db: Database,
        schema: RoomDatabaseSchema,
        databaseVersion: Int,
        identityHash: String
    ) throws {
        for entity in schema.entities {
            // SQL 目的：按 Android Room JSON 的 createSql 创建实体表，保留字段、主键、外键、nullable 与 AUTOINCREMENT 语义。
            // 涉及表：当前 entity.tableName；副作用：只创建缺失表，不改写已有业务数据。
            try db.execute(sql: roomSQL(entity.createSql, tableName: entity.tableName))
        }

        for entity in schema.entities {
            for index in entity.indices {
                // SQL 目的：按 Android Room JSON 创建索引，保证 Room schema validation 与查询计划一致。
                // 涉及表：当前 entity.tableName；关键字段：索引名、唯一性、列顺序均来自 Room JSON。
                try db.execute(sql: roomSQL(index.createSql, tableName: entity.tableName))
            }
        }

        try createRoomMasterTable(db, identityHash: identityHash)

        // SQL 目的：写入 SQLite user_version，作为双端备份恢复与迁移分派的版本依据。
        // 涉及表：无；副作用：更新数据库版本号为当前 Room schema 合同版本。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    nonisolated static func createRoomMasterTable(_ db: Database, identityHash: String) throws {
        // SQL 目的：创建 Room 内部身份表，Android Room 打开数据库时会用它识别 schema。
        // 涉及表：room_master_table；关键字段：id=42、identity_hash=当前 Room 导出 hash。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS room_master_table (
                id INTEGER PRIMARY KEY,
                identity_hash TEXT
            )
        """)

        // SQL 目的：写入当前 Room identity hash；调用方必须先确保表结构已达到对应 canonical 版本。
        // 涉及表：room_master_table；副作用：覆盖 id=42 的 Room 版本标识。
        try db.execute(sql: """
            INSERT OR REPLACE INTO room_master_table (id, identity_hash)
            VALUES (42, ?)
        """, arguments: [identityHash])
    }

    nonisolated static func hasValidIdentityHash(_ db: Database, identityHash: String) throws -> Bool {
        guard try db.tableExists("room_master_table") else { return false }
        // SQL 目的：读取 Room master 表中 id=42 的 identity hash，用于确认数据库物理 schema 版本。
        // 涉及表：room_master_table；关键过滤：id=42；返回字段：identity_hash。
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

    nonisolated static func validatePhysicalSchema(
        _ db: Database,
        schema: RoomDatabaseSchema,
        identityHash: String,
        versionLabel: String
    ) throws {
        guard try hasValidIdentityHash(db, identityHash: identityHash) else {
            throw RoomCanonicalSchemaError.invalidIdentityHashInDatabase
        }
        if let diagnostic = try physicalSchemaDiagnostic(db, schema: schema, versionLabel: versionLabel) {
            throw RoomCanonicalSchemaError.schemaDefinitionMismatch(diagnostic)
        }
    }

    nonisolated static func assertForeignKeyCheckIsEmpty(_ db: Database) throws {
        // SQL 目的：执行 SQLite 原生外键完整性校验，确认恢复库可被 Android Room 与 iOS GRDB 安全打开。
        // 涉及表：全部 Room 实体表；返回行数用于阻断结构异常备份恢复。
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        if !violations.isEmpty {
            throw RoomCanonicalSchemaError.foreignKeyViolation(violations.count)
        }
    }

    nonisolated static func loadSchema(
        resourceName: String,
        databaseVersion: Int,
        identityHash: String
    ) throws -> RoomDatabaseSchema {
        let data: Data
        if let url = bundleSchemaURL(resourceName: resourceName) {
            data = try Data(contentsOf: url)
        } else if let fallbackURL = debugFallbackSchemaURL(resourceName: resourceName) {
            data = try Data(contentsOf: fallbackURL)
        } else {
            throw RoomCanonicalSchemaError.schemaResourceMissing
        }

        let payload = try JSONDecoder().decode(RoomSchemaPayload.self, from: data)
        guard payload.database.version == databaseVersion else {
            throw RoomCanonicalSchemaError.versionMismatch(payload.database.version)
        }
        guard payload.database.identityHash == identityHash else {
            throw RoomCanonicalSchemaError.identityHashMismatch(payload.database.identityHash)
        }
        return payload.database
    }

    nonisolated static func columnNames(in table: String, db: Database) throws -> [String] {
        // SQL 目的：读取目标表的 SQLite 列信息，用于迁移前判断 Android 新增字段是否已经存在。
        // 涉及表：调用方传入的 table；返回字段：PRAGMA table_info.name。
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(quote(table)))").compactMap { row in
            row["name"] as String?
        }
    }
}

private extension RoomCanonicalSchemaSupport {
    nonisolated static func bundleSchemaURL(resourceName: String) -> URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "json")
            ?? Bundle.main.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "Database/SchemaContract"
            )
    }

    nonisolated static func debugFallbackSchemaURL(resourceName: String) -> URL? {
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

    nonisolated static func physicalSchemaDiagnostic(
        _ db: Database,
        schema: RoomDatabaseSchema,
        versionLabel: String
    ) throws -> RoomSchemaDiagnostic? {
        for entity in schema.entities {
            if !(try db.tableExists(entity.tableName)) {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: nil,
                    detail: "缺少 \(versionLabel) 必需表"
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

    nonisolated static func columnsDiagnostic(_ entity: RoomEntitySchema, db: Database) throws -> RoomSchemaDiagnostic? {
        // SQL 目的：读取 Room 实体表的 SQLite 列定义，用于校验字段集合、主键、类型和 nullable 语义。
        // 涉及表：entity.tableName；返回字段：PRAGMA table_info 的 name/type/notnull/pk。
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

    nonisolated static func foreignKeysDiagnostic(_ entity: RoomEntitySchema, db: Database) throws -> RoomSchemaDiagnostic? {
        // SQL 目的：读取 Room 实体表的 SQLite 外键定义，用于校验引用表、引用列与 onUpdate/onDelete 策略。
        // 涉及表：entity.tableName；返回字段：PRAGMA foreign_key_list 的 table/from/to/on_delete/on_update。
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quote(entity.tableName)))")
        let actual = Dictionary(grouping: rows, by: { intValue($0, "id") })
            .values
            .map { group -> ForeignKeySnapshot in
                let ordered = group.sorted { intValue($0, "seq") < intValue($1, "seq") }
                let first = ordered[0]
                return ForeignKeySnapshot(
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
                ForeignKeySnapshot(
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

    nonisolated static func indicesDiagnostic(_ entity: RoomEntitySchema, db: Database) throws -> RoomSchemaDiagnostic? {
        // SQL 目的：读取 Room 实体表的 SQLite 索引清单，用于校验索引存在性与唯一性。
        // 涉及表：entity.tableName；返回字段：PRAGMA index_list 的 name/unique。
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

            // SQL 目的：读取单个索引的列顺序，用于校验 Android Room JSON 声明的索引字段顺序。
            // 涉及对象：index.name；返回字段：PRAGMA index_info 的 seqno/name。
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

    nonisolated static func roomSQL(_ sql: String, tableName: String) -> String {
        sql
            .replacingOccurrences(of: "`${TABLE_NAME}`", with: "`\(tableName)`")
            .replacingOccurrences(of: "${TABLE_NAME}", with: tableName)
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

nonisolated private struct ForeignKeySnapshot: Equatable, Comparable, CustomStringConvertible {
    let table: String
    let onDelete: String
    let onUpdate: String
    let columns: [String]
    let referencedColumns: [String]

    static func < (lhs: ForeignKeySnapshot, rhs: ForeignKeySnapshot) -> Bool {
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
