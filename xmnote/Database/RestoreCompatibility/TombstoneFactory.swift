/**
 * [INPUT]: 接收外键异常中缺失父表名称和父记录 id
 * [OUTPUT]: 对外提供 TombstoneFactory，用于创建最小合法软删除父记录
 * [POS]: Database/RestoreCompatibility 的 tombstone 生成器，被 StagingIntegrityCanonicalizer 调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 为 Android 历史备份中的缺失父记录创建最小合法 tombstone，保证外键闭包可被双端识别。
nonisolated enum TombstoneFactory {
    /// 若父记录缺失，则按父表结构插入软删除 tombstone；不硬删、不覆盖已有记录。
    nonisolated static func ensureParent(table: String, id: Int64, db: Database) throws {
        guard !(try parentExists(table: table, id: id, db: db)) else { return }

        switch table {
        case "user":
            try insertUserTombstone(id, db: db)
        case "source":
            try insertSourceTombstone(id, db: db)
        case "read_status":
            try insertReadStatusTombstone(id, db: db)
        case "book":
            try insertBookTombstone(id, db: db)
        case "chapter":
            try insertChapterTombstone(id, db: db)
        case "note":
            try insertNoteTombstone(id, db: db)
        case "category":
            try insertCategoryTombstone(id, db: db)
        case "category_content":
            try insertCategoryContentTombstone(id, db: db)
        case "review":
            try insertReviewTombstone(id, db: db)
        case "read_plan":
            try insertReadPlanTombstone(id, db: db)
        case "tag":
            try insertTagTombstone(id, db: db)
        case "group":
            try insertGroupTombstone(id, db: db)
        case "collection":
            try insertCollectionTombstone(id, db: db)
        default:
            throw TombstoneFactoryError.unsupportedParentTable(table)
        }
    }
}

nonisolated enum TombstoneFactoryError: LocalizedError {
    case unsupportedParentTable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedParentTable(let table):
            return "备份内存在无法安全整理的父表：\(table)"
        }
    }
}

private extension TombstoneFactory {
    nonisolated static func parentExists(table: String, id: Int64, db: Database) throws -> Bool {
        // SQL 目的：确认缺失父记录是否已被默认 root 或前一轮 tombstone 修复补齐。
        // 涉及表：外键 parent 表；关键字段：所有 Room v40 外键均引用 id。
        let exists = try Int.fetchOne(
            db,
            sql: """
                SELECT 1
                FROM \(quote(table))
                WHERE id = ?
                LIMIT 1
            """,
            arguments: [id]
        )
        return exists != nil
    }

    nonisolated static func insertUserTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 user 父记录创建软删除 tombstone，满足 tag/group/setting 等表的物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO user (id, user_id, nickName, gender, phone, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (?, ?, '', 1, '', 0, ?, 0, 1)
            """,
            arguments: [id, id, currentMilliseconds()]
        )
    }

    nonisolated static func insertSourceTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 source 父记录创建隐藏软删除 tombstone，满足 book.source_id 的物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO source (id, name, source_order, bookshelf_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (?, '', -1, -1, 1, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertReadStatusTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为异常 read_status_id 创建软删除 tombstone，满足 book/book_read_status_record 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO read_status (id, name, read_status_order, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (?, '', ?, 0, ?, 0, 1)
            """,
            arguments: [id, id, currentMilliseconds()]
        )
    }

    nonisolated static func insertBookTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 book 父记录创建软删除 tombstone，满足章节、笔记、关系表和阅读记录外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO book (
                    id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                    isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                    type, current_position_unit, position_unit, source_id, purchase_date, price,
                    book_order, pinned, pin_order, read_status_id, read_status_changed_date,
                    score, catalog, book_mark_modified_time, word_count, created_date, updated_date,
                    last_sync_date, is_deleted
                )
                VALUES (
                    ?, 1, 0, '', '', '', '', '', '',
                    '', '', '', '', 0, 0, 0,
                    1, 1, 2, 0, 0, 0,
                    0, 0, 0, 1, 0,
                    0, '', 0, NULL, 0, ?,
                    0, 1
                )
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertChapterTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 chapter 父记录创建软删除 tombstone，满足 note.chapter_id 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO chapter (
                    id, book_id, parent_id, title, remark, chapter_order, is_import,
                    created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 0, 0, '', '', 0, 0, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertNoteTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 note 父记录创建软删除 tombstone，满足图片和标签关系表外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO note (
                    id, book_id, chapter_id, content, idea, position, position_unit,
                    weread_range, include_time, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 0, 0, '', '', '', 0, '', 0, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertCategoryTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 category 父记录创建软删除 tombstone，满足 category_content 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO category (
                    id, book_id, title, "order", is_hide, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 0, '', 0, 1, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertCategoryContentTombstone(_ id: Int64, db: Database) throws {
        try ensureParent(table: "category", id: 0, db: db)
        // SQL 目的：为缺失 category_content 父记录创建软删除 tombstone，满足 category_image 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO category_content (
                    id, category_id, book_id, title, content, content_book_id, url,
                    created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 0, 0, '', '', 0, '', 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertReviewTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 review 父记录创建软删除 tombstone，满足 review_image 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO review (
                    id, book_id, title, content, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 0, '', '', 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertReadPlanTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 read_plan 父记录创建软删除 tombstone，满足 reminder_event 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO read_plan (
                    id, book_id, total_page_number, read_page_number, position_type,
                    read_start_date, day_read_number, read_interval, reminder_time,
                    description, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 0, 0, 0, 0, 0, 0, 0, 0, '', 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertTagTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 tag 父记录创建软删除 tombstone，满足 tag_book/tag_note 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO tag (
                    id, user_id, name, color, tag_order, type, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 1, '', 0, 0, 1, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertGroupTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 group 父记录创建软删除 tombstone，满足 group_book 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO "group" (
                    id, user_id, name, group_order, pinned, pin_order, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, 1, '', 0, 0, 0, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func insertCollectionTombstone(_ id: Int64, db: Database) throws {
        // SQL 目的：为缺失 collection 父记录创建软删除 tombstone，满足 collection_book 物理外键。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO collection (
                    id, title, "desc", "order", is_annual, year, created_date, updated_date, last_sync_date, is_deleted
                )
                VALUES (?, '', '', 0, 0, 0, 0, ?, 0, 1)
            """,
            arguments: [id, currentMilliseconds()]
        )
    }

    nonisolated static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated static func currentMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
