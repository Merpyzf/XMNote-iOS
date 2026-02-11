import Foundation
import GRDB

// MARK: - 关系表建表（5 张）
// tag_note, tag_book, group, group_book, sort

extension AppDatabase {

    static func createRelationTables(_ db: Database) throws {

        // ── tag_note ──
        // 标签↔书摘 多对多关系
        try db.create(table: "tag_note") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tag_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("note_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── tag_book ──
        // 标签↔书籍 多对多关系
        try db.create(table: "tag_book") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("tag_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── group ──
        // 书籍分组（注意: group 是 SQL 保留字，GRDB 会自动加反引号）
        try db.create(table: "group") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("user_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("name", .text)
            t.column("group_order", .integer).notNull().defaults(to: 0)
            t.column("pinned", .integer).notNull().defaults(to: 0)
            t.column("pin_order", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── group_book ──
        // 分组↔书籍 多对多关系
        try db.create(table: "group_book") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("group_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── sort ──
        // 排序记录
        try db.create(table: "sort") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }
    }
}
