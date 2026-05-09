/**
 * [INPUT]: 依赖 GRDB DatabaseMigrator，依赖 DatabaseSchema+*.swift 各分片
 * [OUTPUT]: 对外提供 AppDatabase.migrator 静态属性，v40 兼容迁移
 * [POS]: Database 模块的迁移入口，被 AppDatabase.init 调用执行 Schema 创建
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - v40 兼容 Schema
// 以 Android Room 当前 v40 为目标，保留 v38 基础迁移标识以兼容已安装 iOS 本地库。
// 建表顺序：先建无外键依赖的表，再建有外键依赖的表

extension AppDatabase {

    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // iOS 从零开始，直接创建基础 Schema；迁移标识保留 v38 以兼容既有 GRDB 迁移记录。
        migrator.registerMigration("v38-schema") { db in
            try createCoreTables(db)
            try createRelationTables(db)
            try createContentTables(db)
            try createReadingTables(db)
            try createConfigTables(db)

            // 同步 Android 的数据库版本号，备份恢复时通过此值校验兼容性
            // SQL 目的：显式写入 SQLite user_version，随后由 v40 对齐迁移推进到 Android 当前版本。
            try db.execute(sql: "PRAGMA user_version = 38")
        }

        // 初始数据填充（独立迁移，便于维护）
        migrator.registerMigration("v38-seed") { db in
            try seedInitialData(db)
        }

        // 仅对已经由旧 iOS 版本创建过的本地库执行标签枚举搬迁；Android Room 既有库在打开时会预先标记此迁移已完成。
        migrator.registerMigration("legacy-ios-tag-type-alignment") { db in
            try migrateLegacyIOSTagTypes(db)
        }

        migrator.registerMigration("v40-schema-alignment") { db in
            try ensureV40ReadTimeRecordColumns(db)
            try ensureAndroidDefaultBook(db)
            // SQL 目的：显式推进 SQLite user_version 到 Android DBConfig.DB_VERSION=40，确保备份恢复版本校验一致。
            try db.execute(sql: "PRAGMA user_version = 40")
        }

        migrator.registerMigration("v40-p1-data-alignment") { db in
            try ensureAndroidDefaultChapter(db)
            try normalizeAndroidNullableTextColumns(db)
        }

        migrator.registerMigration("v40-p2-reference-integrity") { db in
            try DatabaseSoftReferenceRepair.repair(db)
        }

        return migrator
    }
}

private extension AppDatabase {
    nonisolated static func ensureV40ReadTimeRecordColumns(_ db: Database) throws {
        if !(try columnExists(db, table: "read_time_record", column: "insight")) {
            // SQL 目的：补齐 Android 38→39 迁移，为阅读记录增加轻量感悟字段。
            // 涉及表：read_time_record。
            // 关键字段：insight 使用非空文本并默认空字符串，保证旧记录和 Android v39+ Room Entity 兼容。
            try db.execute(sql: "ALTER TABLE read_time_record ADD COLUMN insight TEXT NOT NULL DEFAULT ''")
        }
        if !(try columnExists(db, table: "read_time_record", column: "recorded_position_unit")) {
            // SQL 目的：补齐 Android 39→40 迁移，为阅读记录增加位置单位快照字段。
            // 涉及表：read_time_record。
            // 关键字段：recorded_position_unit 允许 NULL，对齐 Android `Int?` 语义。
            try db.execute(sql: "ALTER TABLE read_time_record ADD COLUMN recorded_position_unit INTEGER")
        }
    }

    nonisolated static func migrateLegacyIOSTagTypes(_ db: Database) throws {
        let legacyNoteTagCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM tag WHERE type = 0"
        ) ?? 0

        if legacyNoteTagCount > 0 {
            // SQL 目的：临时搬迁旧 iOS 书籍标签，避免 NOTE 0→1 时与旧 BOOK 1 冲突。
            // 涉及表：tag。
            // 关键过滤：type = 1 是旧 iOS 书籍标签；先写入临时负值，不改变删除状态或时间字段。
            try db.execute(sql: "UPDATE tag SET type = -2 WHERE type = 1")
            // SQL 目的：将旧 iOS 笔记标签枚举 0 搬迁为 Android NOTE=1。
            // 涉及表：tag。
            // 关键过滤：type = 0；仅调整枚举值，updated_date/last_sync_date 保持不变。
            try db.execute(sql: "UPDATE tag SET type = 1 WHERE type = 0")
            // SQL 目的：将旧 iOS 书籍标签枚举搬迁为 Android BOOK=2。
            // 涉及表：tag。
            // 关键过滤：type = -2 是本迁移临时值；仅调整枚举值，保留同步时间语义。
            try db.execute(sql: "UPDATE tag SET type = 2 WHERE type = -2")
            return
        }

        // SQL 目的：兼容极早期仅存在书籍标签、没有笔记标签的 iOS 本地库。
        // 涉及表：tag 与 tag_book。
        // 关键过滤：只搬迁仍被 tag_book 引用的旧 type=1 标签，避免误改 Android NOTE=1 备份数据。
        try db.execute(sql: """
            UPDATE tag
            SET type = 2
            WHERE type = 1
              AND id IN (
                  SELECT tag_id
                  FROM tag_book
              )
        """)
    }

    nonisolated static func ensureAndroidDefaultBook(_ db: Database) throws {
        // SQL 目的：确保 Android 默认占位书 id=0 存在，承接未归属书摘和外键引用。
        // 涉及表：book。
        // 关键字段：type/current_position_unit/position_unit/source_id/read_status_id 严格对齐 Android initBookTabData。
        try db.execute(sql: """
            INSERT OR IGNORE INTO book (
                id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                type, current_position_unit, position_unit, source_id, purchase_date, price,
                book_order, score, catalog, book_mark_modified_time, read_status_id,
                read_status_changed_date, pinned, pin_order, created_date, updated_date,
                last_sync_date, is_deleted
            )
            VALUES (
                0, 1, 0, '', '', '', '', '', '',
                '', '', '', '', 0, 0, 0,
                1, 1, 2, 0, 0, 0,
                0, 0, '', 0, 1,
                0, 0, 0, 0, 0,
                0, 0
            )
        """)

        // SQL 目的：修正已存在的默认占位书字段，避免旧 iOS seed 与 Android 默认行语义不一致。
        // 涉及表：book。
        // 关键过滤：id = 0；该行是系统占位书，不代表用户业务书籍。
        try db.execute(sql: """
            UPDATE book
            SET user_id = 1,
                douban_id = 0,
                name = '',
                raw_name = '',
                cover = '',
                author = '',
                author_intro = '',
                translator = '',
                isbn = '',
                pub_date = '',
                press = '',
                summary = '',
                read_position = 0,
                total_position = 0,
                total_pagination = 0,
                type = 1,
                current_position_unit = 1,
                position_unit = 2,
                source_id = 0,
                purchase_date = 0,
                price = 0,
                book_order = 0,
                score = 0,
                catalog = '',
                book_mark_modified_time = 0,
                read_status_id = 1,
                read_status_changed_date = 0,
                pinned = 0,
                pin_order = 0,
                created_date = 0,
                updated_date = 0,
                last_sync_date = 0,
                is_deleted = 0
            WHERE id = 0
        """)

        // SQL 目的：隐藏旧 iOS 错误自增生成的空占位书，避免其作为真实书进入书架聚合。
        // 涉及表：book。
        // 关键过滤：id=1 且所有业务字段为空、时间字段为 0、无有效笔记/分组/标签关系，才视为旧占位污染。
        try db.execute(sql: """
            UPDATE book
            SET is_deleted = 1
            WHERE id = 1
              AND is_deleted = 0
              AND user_id = 1
              AND douban_id = 0
              AND TRIM(name) = ''
              AND TRIM(raw_name) = ''
              AND TRIM(author) = ''
              AND TRIM(translator) = ''
              AND TRIM(isbn) = ''
              AND TRIM(press) = ''
              AND source_id = 0
              AND created_date = 0
              AND updated_date = 0
              AND last_sync_date = 0
              AND NOT EXISTS (SELECT 1 FROM note WHERE book_id = 1 AND is_deleted = 0)
              AND NOT EXISTS (SELECT 1 FROM group_book WHERE book_id = 1 AND is_deleted = 0)
              AND NOT EXISTS (SELECT 1 FROM tag_book WHERE book_id = 1 AND is_deleted = 0)
        """)
    }

    nonisolated static func ensureAndroidDefaultChapter(_ db: Database) throws {
        // SQL 目的：确保 Android 默认占位章节 id=0 存在，承接未归属章节的书摘引用。
        // 涉及表：chapter。
        // 关键字段：id/book_id/parent_id 均为 0；文本字段为空字符串；同步字段保持 0。
        try db.execute(sql: """
            INSERT OR IGNORE INTO chapter (
                id, book_id, parent_id, title, remark, chapter_order, is_import,
                created_date, updated_date, last_sync_date, is_deleted
            )
            VALUES (0, 0, 0, '', '', 0, 0, 0, 0, 0, 0)
        """)

        // SQL 目的：修正已存在的默认占位章节字段，避免旧库 id=0 行带入错误状态。
        // 涉及表：chapter。
        // 关键过滤：id = 0 是系统默认章节，不代表用户业务章节。
        try db.execute(sql: """
            UPDATE chapter
            SET book_id = 0,
                parent_id = 0,
                title = '',
                remark = '',
                chapter_order = 0,
                is_import = 0,
                created_date = 0,
                updated_date = 0,
                last_sync_date = 0,
                is_deleted = 0
            WHERE id = 0
        """)

        // SQL 目的：把旧 iOS 误生成的空章节 id=1 引用迁回 Android 默认章节 id=0。
        // 涉及表：note 与 chapter。
        // 关键过滤：仅当 chapter.id=1 完全符合旧占位特征时更新 note.chapter_id，避免误改真实章节。
        try db.execute(sql: """
            UPDATE note
            SET chapter_id = 0
            WHERE chapter_id = 1
              AND EXISTS (
                  SELECT 1
                  FROM chapter
                  WHERE id = 1
                    AND book_id = 0
                    AND parent_id = 0
                    AND TRIM(title) = ''
                    AND TRIM(remark) = ''
                    AND chapter_order = 0
                    AND is_import = 0
                    AND created_date = 0
                    AND updated_date = 0
                    AND last_sync_date = 0
                    AND is_deleted = 0
              )
        """)

        // SQL 目的：软删除旧 iOS 空章节占位行，避免它继续作为真实章节参与 UI 计算。
        // 涉及表：chapter。
        // 关键过滤：只处理完全匹配占位特征的 id=1 行，保留用户真实章节。
        try db.execute(sql: """
            UPDATE chapter
            SET is_deleted = 1
            WHERE id = 1
              AND book_id = 0
              AND parent_id = 0
              AND TRIM(title) = ''
              AND TRIM(remark) = ''
              AND chapter_order = 0
              AND is_import = 0
              AND created_date = 0
              AND updated_date = 0
              AND last_sync_date = 0
              AND is_deleted = 0
        """)
    }

    nonisolated static func normalizeAndroidNullableTextColumns(_ db: Database) throws {
        try normalizeTextColumns(
            db,
            table: "book",
            columns: [
                "name", "raw_name", "cover", "author", "author_intro", "translator",
                "isbn", "pub_date", "press", "summary", "catalog"
            ]
        )
        try normalizeTextColumns(
            db,
            table: "note",
            columns: ["content", "idea", "position", "weread_range"]
        )
        try normalizeTextColumns(
            db,
            table: "chapter",
            columns: ["title", "remark"]
        )
    }

    nonisolated static func normalizeTextColumns(
        _ db: Database,
        table: String,
        columns: [String]
    ) throws {
        let assignments = columns
            .map { "\($0) = COALESCE(\($0), '')" }
            .joined(separator: ", ")
        let nullChecks = columns
            .map { "\($0) IS NULL" }
            .joined(separator: " OR ")
        // SQL 目的：兼容 Android 恢复库中 nullable 文本落入 iOS 非可选 Record 的情况。
        // 涉及表：由调用方传入的固定 schema 表；列名也是固定白名单。
        // 副作用：仅把 NULL 归一化为空字符串，不 trim、不改写已有非空文本。
        try db.execute(sql: """
            UPDATE \(table)
            SET \(assignments)
            WHERE \(nullChecks)
        """)
    }

    nonisolated static func columnExists(_ db: Database, table: String, column: String) throws -> Bool {
        // SQL 目的：通过 SQLite PRAGMA 查询表结构，用于幂等补列。
        // 涉及表：调用方传入的固定 schema 表名；返回字段 name 用于判断列是否已存在。
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.contains { row in
            let name: String = row["name"] ?? ""
            return name == column
        }
    }
}
