/**
 * [INPUT]: 依赖 Android Room 导出的 v40 schema JSON 与 GRDB Database 执行物理建表
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV40，作为 iOS/Android 双向恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room schema 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v40 物理结构合同，用于让 iOS 新库和修复后的旧库具备 Room 可识别的表、索引、外键和 identity hash。
nonisolated enum RoomCanonicalSchemaV40 {
    nonisolated static let databaseVersion = 40
    nonisolated static let identityHash = "104ccc4da4aae1203a5850535d772d84"
    nonisolated static let legacyIdentityHash = "5e050a12d7f48b9fbdb0dd9e76b567b6"
    nonisolated static let schemaResourceName = "RoomSchemaV40"

    /// 按 Room JSON 创建全部实体表、索引、room_master_table，并写入 user_version=40。
    nonisolated static func createAllTables(_ db: Database) throws {
        let schema = try loadSchema()

        for entity in schema.entities {
            // SQL 目的：按 Android Room v40 JSON 的 createSql 创建实体表，保留物理 nullable、外键、主键与 AUTOINCREMENT 语义。
            // 涉及表：Room JSON 中的 35 张实体表；副作用：只创建缺失表，不改写已有表数据。
            try db.execute(sql: roomSQL(entity.createSql, tableName: entity.tableName))
        }

        for entity in schema.entities {
            for index in entity.indices {
                // SQL 目的：按 Android Room v40 JSON 创建索引，确保 Room schema validation 与查询计划一致。
                // 涉及表：当前 entity.tableName；关键字段：索引名、唯一性、列顺序均来自 Room JSON。
                try db.execute(sql: roomSQL(index.createSql, tableName: entity.tableName))
            }
        }

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=40，供双端恢复前版本判断使用。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room identity hash；调用方必须先确保实际表结构已经 canonical，禁止用 hash 伪装兼容。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        // SQL 目的：创建 Room 内部身份表，Android Room 打开数据库时会用它快速识别 schema。
        // 涉及表：room_master_table；关键字段：id=42、identity_hash=Room v40 导出 hash。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS room_master_table (
                id INTEGER PRIMARY KEY,
                identity_hash TEXT
            )
        """)

        // SQL 目的：写入 Room v40 identity hash；只有 canonical 表结构创建或修复完成后才能调用。
        try db.execute(sql: """
            INSERT OR REPLACE INTO room_master_table (id, identity_hash)
            VALUES (42, ?)
        """, arguments: [identityHash])
    }

    /// 返回 Room JSON 声明的实体表名，顺序与 Android `@Database(entities=...)` 一致。
    nonisolated static func tableNames() throws -> [String] {
        try loadSchema().entities.map(\.tableName)
    }

    /// 返回指定 Room 表在 JSON 中声明的列名。
    nonisolated static func columnNames(for tableName: String) throws -> [String] {
        guard let entity = try loadSchema().entities.first(where: { $0.tableName == tableName }) else {
            return []
        }
        return entity.fields.map(\.columnName)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v40 可接受值。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
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
        return hash == identityHash || hash == legacyIdentityHash
    }

    /// 校验当前数据库是否与 Android Room v40 物理 schema 合同一致；只读校验，不修复、不改业务表。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        guard try hasValidIdentityHash(db) else {
            throw RoomCanonicalSchemaError.invalidIdentityHashInDatabase
        }
        if let diagnostic = try physicalSchemaDiagnostic(db) {
            throw RoomCanonicalSchemaError.schemaDefinitionMismatch(diagnostic)
        }
    }

    /// 校验当前数据库的外键关系闭包是否完整；用于 staging 整理后阻断仍不可安全识别的备份。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        try assertForeignKeyCheckIsEmpty(db)
    }

    /// 校验当前数据库是否与 Android Room v40 物理 schema 合同一致，并且数据外键闭包完整。
    nonisolated static func validateExistingDatabase(_ db: Database) throws {
        try validatePhysicalSchema(db)
        try assertForeignKeyIntegrity(db)
    }

    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        let data: Data
        if let url = bundleSchemaURL() {
            data = try Data(contentsOf: url)
        } else if let fallbackURL = debugFallbackSchemaURL() {
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
}

// MARK: - JSON Model

nonisolated struct RoomSchemaPayload: Decodable {
    let database: RoomDatabaseSchema
}

nonisolated struct RoomDatabaseSchema: Decodable {
    let version: Int
    let identityHash: String
    let entities: [RoomEntitySchema]
}

nonisolated struct RoomEntitySchema: Decodable {
    let tableName: String
    let createSql: String
    let fields: [RoomFieldSchema]
    let primaryKey: RoomPrimaryKeySchema
    let foreignKeys: [RoomForeignKeySchema]
    let indices: [RoomIndexSchema]

    enum CodingKeys: String, CodingKey {
        case tableName
        case createSql
        case fields
        case primaryKey
        case foreignKeys
        case indices
    }

    /// Room JSON 会在无索引或无外键的表上省略对应字段，解码时按空集合处理，保持物理 schema 合同完整可读。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tableName = try container.decode(String.self, forKey: .tableName)
        createSql = try container.decode(String.self, forKey: .createSql)
        fields = try container.decode([RoomFieldSchema].self, forKey: .fields)
        primaryKey = try container.decode(RoomPrimaryKeySchema.self, forKey: .primaryKey)
        foreignKeys = try container.decodeIfPresent([RoomForeignKeySchema].self, forKey: .foreignKeys) ?? []
        indices = try container.decodeIfPresent([RoomIndexSchema].self, forKey: .indices) ?? []
    }
}

nonisolated struct RoomFieldSchema: Decodable {
    let columnName: String
    let affinity: String
    let notNull: Bool

    enum CodingKeys: String, CodingKey {
        case columnName
        case affinity
        case notNull
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columnName = try container.decode(String.self, forKey: .columnName)
        affinity = try container.decode(String.self, forKey: .affinity)
        notNull = try container.decodeIfPresent(Bool.self, forKey: .notNull) ?? false
    }
}

nonisolated struct RoomPrimaryKeySchema: Decodable {
    let autoGenerate: Bool
    let columnNames: [String]
}

nonisolated struct RoomIndexSchema: Decodable {
    let createSql: String
    let name: String
    let unique: Bool
    let columnNames: [String]
}

nonisolated struct RoomForeignKeySchema: Decodable {
    let table: String
    let onDelete: String
    let onUpdate: String
    let columns: [String]
    let referencedColumns: [String]
}

// MARK: - Errors

nonisolated enum RoomCanonicalSchemaError: LocalizedError {
    case schemaResourceMissing
    case versionMismatch(Int)
    case identityHashMismatch(String)
    case invalidIdentityHashInDatabase
    case schemaDefinitionMismatch(RoomSchemaDiagnostic)
    case foreignKeyViolation(Int)

    var errorDescription: String? {
        switch self {
        case .schemaResourceMissing:
            return "缺少 Room v40 schema JSON，无法安全识别备份结构"
        case .versionMismatch(let version):
            return "Room schema 版本不匹配：\(version)"
        case .identityHashMismatch(let hash):
            return "Room schema identityHash 不匹配：\(hash)"
        case .invalidIdentityHashInDatabase:
            return "数据库缺少有效的 Room v40 identityHash"
        case .schemaDefinitionMismatch(let diagnostic):
            return "数据库物理结构与 Room v40 schema 不一致：\(diagnostic.description)"
        case .foreignKeyViolation(let count):
            return "数据库外键校验失败：\(count) 处异常引用"
        }
    }
}

private extension RoomCanonicalSchemaV40 {
    nonisolated static func roomSQL(_ sql: String, tableName: String) -> String {
        sql
            .replacingOccurrences(of: "`${TABLE_NAME}`", with: "`\(tableName)`")
            .replacingOccurrences(of: "${TABLE_NAME}", with: tableName)
    }

    nonisolated static func bundleSchemaURL() -> URL? {
        Bundle.main.url(forResource: schemaResourceName, withExtension: "json")
            ?? Bundle.main.url(
                forResource: schemaResourceName,
                withExtension: "json",
                subdirectory: "Database/SchemaContract"
            )
    }

    nonisolated static func debugFallbackSchemaURL() -> URL? {
        #if DEBUG
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            currentDirectory.appendingPathComponent("xmnote/Database/\(schemaResourceName).json"),
            currentDirectory.appendingPathComponent("xmnote/Database/SchemaContract/\(schemaResourceName).json"),
            currentDirectory.appendingPathComponent("Database/\(schemaResourceName).json")
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
        #else
        return nil
        #endif
    }

    nonisolated static func physicalSchemaDiagnostic(_ db: Database) throws -> RoomSchemaDiagnostic? {
        for entity in try loadSchema().entities {
            if !(try db.tableExists(entity.tableName)) {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: nil,
                    detail: "缺少 Room v40 必需表"
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
                detail: setDiffDescription(
                    actual: actualColumns,
                    expected: expectedColumns,
                    noun: "字段"
                )
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
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: field.columnName,
                    detail: "缺少字段"
                )
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
        let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(\(quote(entity.tableName)))")
        let actualByName = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Row)? in
            guard let name = stringValue(row, "name") else { return nil }
            return (name, row)
        })

        for index in entity.indices {
            guard let row = actualByName[index.name] else {
                return RoomSchemaDiagnostic(
                    tableName: entity.tableName,
                    objectName: index.name,
                    detail: "缺少索引"
                )
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

    nonisolated static func assertForeignKeyCheckIsEmpty(_ db: Database) throws {
        // SQL 目的：执行 SQLite 原生外键完整性校验，确认恢复库可被 Android Room 与 iOS GRDB 安全打开。
        // 涉及表：全部 Room 实体表；返回行数用于阻断结构异常备份恢复。
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        if !violations.isEmpty {
            throw RoomCanonicalSchemaError.foreignKeyViolation(violations.count)
        }
    }

    nonisolated static func columnNames(in table: String, db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(quote(table)))").compactMap { row in
            row["name"] as String?
        }
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
