/**
 * [INPUT]: 接收通过物理 schema 校验的备份 staging 数据库
 * [OUTPUT]: 对外提供 DefaultRootSeeder，用于补齐 Android Room 默认根父行
 * [POS]: Database/RestoreCompatibility 的默认根记录补齐器，被 StagingIntegrityCanonicalizer 调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 在 staging 修复开始前补齐 Android 默认根记录，避免默认占位数据继续触发外键异常。
nonisolated enum DefaultRootSeeder {
    /// 补齐系统根父行；只插缺失记录，不覆盖备份里已有的用户数据。
    nonisolated static func seed(_ db: Database) throws {
        // SQL 目的：补齐默认用户 id=1，作为默认书、标签、分组和设置的跨端根父行。
        // 涉及表：user；副作用：仅在缺失时插入，不覆盖 Android 备份已有用户数据。
        try db.execute(sql: """
            INSERT OR IGNORE INTO user (id, user_id, nickName, gender, phone, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (1, 1, '临时用户', 1, '', 0, 0, 0, 0)
        """)

        let statuses = ["想读", "在读", "读完", "弃读", "搁置"]
        for (index, name) in statuses.enumerated() {
            let id = index + 1
            // SQL 目的：补齐 Android 固定阅读状态枚举，作为 book 与 book_read_status_record 的父行。
            // 涉及表：read_status；副作用：仅补缺失枚举，不修改已有状态名称或排序。
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO read_status (id, name, read_status_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, ?, 0, 0, 0, 0)
                    """,
                arguments: [id, name, id]
            )
        }

        // SQL 目的：补齐默认来源 id=0，修复 Android 历史备份中默认书 book.source_id=0 的父行缺失。
        // 涉及表：source；副作用：该来源保持隐藏且软删除，不进入来源 UI。
        try db.execute(sql: """
            INSERT OR IGNORE INTO source (id, name, source_order, bookshelf_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (0, '', -1, -1, 1, 0, 0, 0, 1)
        """)

        // SQL 目的：补齐默认占位书 id=0，承接未归属书摘、章节和 tombstone 记录的物理父行。
        // 涉及表：book、user、source、read_status；关键字段：source_id=0/read_status_id=1。
        try db.execute(sql: """
            INSERT OR IGNORE INTO book (
                id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                type, current_position_unit, position_unit, source_id, purchase_date, price,
                book_order, pinned, pin_order, read_status_id, read_status_changed_date,
                score, catalog, book_mark_modified_time, word_count, created_date, updated_date,
                last_sync_date, is_deleted
            )
            VALUES (
                0, 1, 0, '', '', '', '', '', '',
                '', '', '', '', 0, 0, 0,
                1, 1, 2, 0, 0, 0,
                0, 0, 0, 1, 0,
                0, '', 0, NULL, 0, 0,
                0, 0
            )
        """)

        // SQL 目的：补齐默认占位章节 id=0，承接未归属章节的书摘和 tombstone note。
        // 涉及表：chapter 与 book；关键字段：id/book_id/parent_id 均为 0。
        try db.execute(sql: """
            INSERT OR IGNORE INTO chapter (
                id, book_id, parent_id, title, remark, chapter_order, is_import,
                created_date, updated_date, last_sync_date, is_deleted
            )
            VALUES (0, 0, 0, '', '', 0, 0, 0, 0, 0, 0)
        """)
    }
}
