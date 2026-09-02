/**
 * [INPUT]: 依赖 GRDB Database 与 Room v48 三类书籍关系表字段合同
 * [OUTPUT]: 对外提供跨书籍入口共用的 INSERT OR IGNORE 关系写入原语
 * [POS]: Data/Repositories 的书籍关系底层写入协作者，统一 App、Web 与年度书单的业务唯一冲突策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB

/// 统一执行 Room v48 关系插入，重复业务键只保留既有行且不覆盖其时间、顺序或说明字段。
nonisolated enum BookRelationWriter {
    /// 幂等建立书籍唯一分组归属。
    nonisolated static func insertGroup(
        _ db: Database,
        groupID: Int64,
        bookID: Int64,
        createdAt: Int64,
        updatedAt: Int64 = 0
    ) throws {
        // SQL 目的：建立书籍分组关系；重试或并发命中同一 book_id 时保留已存在关系。
        // 涉及表：group_book。
        // 关键过滤：v48 唯一索引以 book_id 判定冲突；INSERT OR IGNORE 不覆盖原 group_id 或时间。
        // 时间字段：created_date/updated_date 使用调用方业务时刻，last_sync_date 保持现有本地默认值 0。
        // 副作用用途：与 Android GroupBookDao OnConflictStrategy.IGNORE 保持等价。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO group_book (
                    group_id, book_id, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, 0, 0)
                """,
            arguments: [groupID, bookID, createdAt, updatedAt]
        )
    }

    /// 幂等建立书籍标签关系。
    nonisolated static func insertTag(
        _ db: Database,
        bookID: Int64,
        tagID: Int64,
        createdAt: Int64,
        updatedAt: Int64 = 0
    ) throws {
        // SQL 目的：建立书籍标签关系；重试或并发命中同一 book_id + tag_id 时保留已存在关系。
        // 涉及表：tag_book。
        // 关键过滤：v48 唯一索引以 book_id + tag_id 判定冲突；INSERT OR IGNORE 不覆盖原时间。
        // 时间字段：created_date/updated_date 使用调用方业务时刻，last_sync_date 保持现有本地默认值 0。
        // 副作用用途：与 Android TagBookDao OnConflictStrategy.IGNORE 保持等价。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO tag_book (
                    book_id, tag_id, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, 0, 0)
                """,
            arguments: [bookID, tagID, createdAt, updatedAt]
        )
    }

    /// 幂等建立书单成员关系。
    nonisolated static func insertCollectionBook(
        _ db: Database,
        collectionID: Int64,
        bookID: Int64,
        recommend: String = "",
        order: Int64 = 0,
        createdAt: Int64,
        updatedAt: Int64 = 0
    ) throws {
        // SQL 目的：建立书单成员关系；重试或并发命中同一 collection_id + book_id 时保留既有行。
        // 涉及表：collection_book。
        // 关键过滤：v48 唯一索引以 collection_id + book_id 判定冲突；INSERT OR IGNORE 不覆盖说明、顺序或时间。
        // 时间字段：created_date/updated_date 使用调用方业务时刻，last_sync_date 保持现有本地默认值 0。
        // 副作用用途：与 Android CollectionBookDao OnConflictStrategy.IGNORE 保持等价。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO collection_book (
                    collection_id, book_id, recommend, "order",
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [collectionID, bookID, recommend, order, createdAt, updatedAt]
        )
    }
}
