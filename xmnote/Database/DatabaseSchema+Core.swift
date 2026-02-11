import Foundation
import GRDB

// MARK: - 核心业务表建表（7 张）
// user, read_status, source, book, note, chapter, tag

extension AppDatabase {

    static func createCoreTables(_ db: Database) throws {

        // ── user ──
        try db.create(table: "user") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("user_id", .integer).notNull().defaults(to: 0)
            t.column("nickName", .text)
            t.column("gender", .integer).notNull().defaults(to: 0)
            t.column("phone", .text)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── read_status ──
        // 注意：id 不自增，使用手动赋值（预定义: 1=未读, 2=在读, 3=已读, 4=搁置）
        try db.create(table: "read_status") { t in
            t.primaryKey("id", .integer)
            t.column("name", .text).notNull()
            t.column("read_status_order", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── source ──
        try db.create(table: "source") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().defaults(to: "")
            t.column("source_order", .integer).notNull().defaults(to: 0)
            t.column("bookshelf_order", .integer).notNull().defaults(to: -1)
            t.column("is_hide", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── book ──
        // 外键: user_id → user, read_status_id → read_status, source_id → source
        try db.create(table: "book") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("user_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("douban_id", .integer).notNull().defaults(to: 0)
            t.column("name", .text).notNull().defaults(to: "")
            t.column("raw_name", .text).notNull().defaults(to: "")
            t.column("cover", .text).notNull().defaults(to: "")
            t.column("author", .text).notNull().defaults(to: "")
            t.column("author_intro", .text).notNull().defaults(to: "")
            t.column("translator", .text).notNull().defaults(to: "")
            t.column("isbn", .text).notNull().defaults(to: "")
            t.column("pub_date", .text).notNull().defaults(to: "")
            t.column("press", .text).notNull().defaults(to: "")
            t.column("summary", .text).notNull().defaults(to: "")
            t.column("read_position", .double).notNull().defaults(to: 0.0)
            t.column("total_position", .integer).notNull().defaults(to: 0)
            t.column("total_pagination", .integer).notNull().defaults(to: 0)
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("current_position_unit", .integer).notNull().defaults(to: 0)
            t.column("position_unit", .integer).notNull().defaults(to: 0)
            t.column("source_id", .integer).notNull().defaults(to: 1)
                .indexed()
            t.column("purchase_date", .integer).notNull().defaults(to: 0)
            t.column("price", .double).notNull().defaults(to: 0.0)
            t.column("book_order", .integer).notNull().defaults(to: 0)
            t.column("pinned", .integer).notNull().defaults(to: 0)
            t.column("pin_order", .integer).notNull().defaults(to: 0)
            t.column("read_status_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("read_status_changed_date", .integer).notNull().defaults(to: 0)
            t.column("score", .integer).notNull().defaults(to: 0)
            t.column("catalog", .text).notNull().defaults(to: "")
            t.column("book_mark_modified_time", .integer).notNull().defaults(to: 0)
            t.column("word_count", .integer) // nullable
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── chapter ──
        // 外键: book_id → book
        try db.create(table: "chapter") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("parent_id", .integer).notNull().defaults(to: 0)
            t.column("title", .text).notNull().defaults(to: "")
            t.column("remark", .text).notNull().defaults(to: "")
            t.column("chapter_order", .integer).notNull().defaults(to: 0)
            t.column("is_import", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── note ──
        // 外键: book_id → book, chapter_id → chapter
        try db.create(table: "note") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("chapter_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("content", .text).notNull().defaults(to: "")
            t.column("idea", .text).notNull().defaults(to: "")
            t.column("position", .text).notNull().defaults(to: "")
            t.column("position_unit", .integer).notNull().defaults(to: 0)
            t.column("weread_range", .text).notNull().defaults(to: "")
            t.column("include_time", .integer).notNull().defaults(to: 1)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── tag ──
        // 外键: user_id → user
        try db.create(table: "tag") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("user_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("name", .text)
            t.column("color", .integer).notNull().defaults(to: 0)
            t.column("tag_order", .integer).notNull().defaults(to: 0)
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }
    }
}
