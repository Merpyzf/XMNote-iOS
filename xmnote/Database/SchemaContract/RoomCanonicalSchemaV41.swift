/**
 * [INPUT]: 依赖 Android Room 导出的 v41 schema JSON 与 GRDB Database 执行物理建表、v40 升级与校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV41，作为当前 iOS/Android 双向恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v41 schema 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v41 物理结构合同，覆盖章节来源字段与 Room identity hash 校验。
nonisolated enum RoomCanonicalSchemaV41 {
    nonisolated static let databaseVersion = 41
    nonisolated static let identityHash = "3e918b510106da51cfd45e4c6e34d972"
    nonisolated static let schemaResourceName = "RoomSchemaV41"

    /// 按 Room v41 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=41。
    nonisolated static func createAllTables(_ db: Database) throws {
        let schema = try loadSchema()

        for entity in schema.entities {
            // SQL 目的：按 Android Room v41 JSON 的 createSql 创建实体表，保留物理 nullable、外键、主键与 AUTOINCREMENT 语义。
            // 涉及表：Room JSON 中的全部实体表；副作用：只创建缺失表，不改写已有表数据。
            try db.execute(sql: roomSQL(entity.createSql, tableName: entity.tableName))
        }

        for entity in schema.entities {
            for index in entity.indices {
                // SQL 目的：按 Android Room v41 JSON 创建索引，确保 Room schema validation 与查询计划一致。
                // 涉及表：当前 entity.tableName；关键字段：索引名、唯一性、列顺序均来自 Room JSON。
                try db.execute(sql: roomSQL(index.createSql, tableName: entity.tableName))
            }
        }

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=41，供双端恢复前版本判断使用。
        // 涉及表：无；副作用：更新数据库版本号为 Android 当前版本。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 在已具备 Room v40 物理结构的数据库上执行 Android 40→41 等价迁移。
    nonisolated static func migrateFromV40(_ db: Database) throws {
        let existingColumns = Set(try columnNames(in: "chapter", db: db))
        try addChapterColumnIfNeeded(db, existingColumns: existingColumns, name: "chapter_level", definition: "INTEGER NOT NULL DEFAULT 0")
        try addChapterColumnIfNeeded(db, existingColumns: existingColumns, name: "source_type", definition: "INTEGER NOT NULL DEFAULT 0")
        try addChapterColumnIfNeeded(db, existingColumns: existingColumns, name: "source_uid", definition: "TEXT")
        try addChapterColumnIfNeeded(db, existingColumns: existingColumns, name: "source_anchor", definition: "TEXT")
        try addChapterColumnIfNeeded(db, existingColumns: existingColumns, name: "source_order", definition: "INTEGER NOT NULL DEFAULT 0")
        try addChapterColumnIfNeeded(db, existingColumns: existingColumns, name: "source_path", definition: "TEXT")

        // SQL 目的：创建 Android v41 章节 book_id 索引，供章节按书籍读取与 Room schema 校验使用。
        // 涉及表：chapter；关键字段：book_id；副作用：仅创建缺失索引。
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_chapter_book_id ON chapter(book_id)")
        // SQL 目的：创建 Android v41 章节 parent_id 索引，供目录树按父章节读取与 Room schema 校验使用。
        // 涉及表：chapter；关键字段：parent_id；副作用：仅创建缺失索引。
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_chapter_parent_id ON chapter(parent_id)")
        // SQL 目的：创建 Android v41 章节树排序索引，供同书同父章节按 chapter_order 排序。
        // 涉及表：chapter；关键字段：book_id、parent_id、chapter_order；副作用：仅创建缺失索引。
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_chapter_book_id_parent_id_chapter_order ON chapter(book_id, parent_id, chapter_order)")
        // SQL 目的：创建 Android v41 章节来源唯一定位辅助索引，供外部目录导入去重与定位使用。
        // 涉及表：chapter；关键字段：book_id、source_type、source_uid、source_anchor；副作用：仅创建缺失索引。
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_chapter_book_id_source_type_source_uid_source_anchor ON chapter(book_id, source_type, source_uid, source_anchor)")

        try fillChapterLevelAndPath(db)
        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=41，标记 v40→v41 schema 迁移已完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android 当前版本。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v41 identity hash；调用方必须先确保实际表结构已经 canonical。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        // SQL 目的：创建 Room 内部身份表，Android Room 打开数据库时会用它快速识别 schema。
        // 涉及表：room_master_table；关键字段：id=42、identity_hash=Room v41 导出 hash。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS room_master_table (
                id INTEGER PRIMARY KEY,
                identity_hash TEXT
            )
        """)

        // SQL 目的：写入 Room v41 identity hash；只有 canonical 表结构创建或修复完成后才能调用。
        // 涉及表：room_master_table；副作用：覆盖 id=42 的 Room 版本标识。
        try db.execute(sql: """
            INSERT OR REPLACE INTO room_master_table (id, identity_hash)
            VALUES (42, ?)
        """, arguments: [identityHash])
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v41 可接受值。
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
        return hash == identityHash
    }

    /// 校验当前数据库是否与 Android Room v41 物理 schema 合同一致；只读校验，不修复、不改业务表。
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

    /// 校验当前数据库是否与 Android Room v41 物理 schema 合同一致，并且数据外键闭包完整。
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

private extension RoomCanonicalSchemaV41 {
    nonisolated static func addChapterColumnIfNeeded(
        _ db: Database,
        existingColumns: Set<String>,
        name: String,
        definition: String
    ) throws {
        guard !existingColumns.contains(name) else { return }
        // SQL 目的：执行 Android 40→41 章节字段补丁，补齐 Room v41 `chapter` 表新增列。
        // 涉及表：chapter；关键字段：当前 name 参数；副作用：新增列并使用 Android 默认值或 nullable 语义。
        try db.execute(sql: "ALTER TABLE chapter ADD COLUMN \(name) \(definition)")
    }

    nonisolated static func fillChapterLevelAndPath(_ db: Database) throws {
        // SQL 目的：按 Android MIGRATION_40_41 的递归 CTE 回填章节层级与来源路径。
        // 涉及表：chapter；关键过滤：以 book_id + parent_id 构建目录树，软删除数据同样保持历史字段可回填。
        // 时间字段：不修改 created_date/updated_date/last_sync_date；副作用：仅填充 chapter_level/source_path。
        try db.execute(sql: """
            WITH RECURSIVE chapter_tree(id, book_id, depth, path, visited) AS (
                SELECT
                    id,
                    book_id,
                    1,
                    TRIM(COALESCE(title, '')),
                    ',' || id || ','
                FROM chapter
                WHERE parent_id = 0

                UNION ALL

                SELECT
                    c.id,
                    c.book_id,
                    chapter_tree.depth + 1,
                    CASE
                        WHEN chapter_tree.path = '' THEN TRIM(COALESCE(c.title, ''))
                        WHEN TRIM(COALESCE(c.title, '')) = '' THEN chapter_tree.path
                        ELSE chapter_tree.path || '/' || TRIM(COALESCE(c.title, ''))
                    END,
                    chapter_tree.visited || c.id || ','
                FROM chapter c
                JOIN chapter_tree ON c.parent_id = chapter_tree.id
                WHERE c.book_id = chapter_tree.book_id
                  AND instr(chapter_tree.visited, ',' || c.id || ',') = 0
            )
            UPDATE chapter
            SET
                chapter_level = (
                    SELECT depth
                    FROM chapter_tree
                    WHERE chapter_tree.id = chapter.id
                ),
                source_path = (
                    SELECT path
                    FROM chapter_tree
                    WHERE chapter_tree.id = chapter.id
                )
            WHERE id IN (SELECT id FROM chapter_tree)
            """)

        // SQL 目的：为未被递归树覆盖的历史章节提供 Android fallback 层级与路径。
        // 涉及表：chapter；关键过滤：chapter_level 仍为 0 的遗留孤儿节点；副作用：只补默认层级和标题路径。
        try db.execute(sql: """
            UPDATE chapter
            SET
                chapter_level = CASE WHEN parent_id = 0 THEN 1 ELSE 2 END,
                source_path = TRIM(COALESCE(title, ''))
            WHERE chapter_level = 0
            """)
    }

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
                    detail: "缺少 Room v41 必需表"
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
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quote(entity.tableName)))")
        let actual = Dictionary(grouping: rows, by: { intValue($0, "id") })
            .values
            .map { group -> ForeignKeySnapshotV41 in
                let ordered = group.sorted { intValue($0, "seq") < intValue($1, "seq") }
                let first = ordered[0]
                return ForeignKeySnapshotV41(
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
                ForeignKeySnapshotV41(
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

nonisolated private struct ForeignKeySnapshotV41: Equatable, Comparable, CustomStringConvertible {
    let table: String
    let onDelete: String
    let onUpdate: String
    let columns: [String]
    let referencedColumns: [String]

    static func < (lhs: ForeignKeySnapshotV41, rhs: ForeignKeySnapshotV41) -> Bool {
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
