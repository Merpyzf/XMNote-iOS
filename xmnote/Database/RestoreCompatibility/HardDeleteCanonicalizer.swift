/**
 * [INPUT]: 依赖 GRDB、DefaultRootSeeder 与 Room v44 实体/外键合同，接收已达到 canonical schema 的数据库
 * [OUTPUT]: 对外提供 HardDeleteCanonicalizer，物理清理历史删除标记、失效关系与外键孤儿
 * [POS]: Database/RestoreCompatibility 的硬删除语义内核，被正式库迁移和备份 staging 整理共同调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 将历史软删除数据收敛为物理删除，同时保留系统根与仍承担有效引用展示的占位书。
nonisolated enum HardDeleteCanonicalizer {
    private nonisolated static let deletionSetTable = "ios_hard_delete_rows"
    private nonisolated static let preservedBookTable = "ios_preserved_placeholder_books"

    /// Room v44 中带 `is_deleted` 与单列 `id` 主键的全部业务实体表。
    private nonisolated static let entityTables = [
        "note", "book", "user", "tag", "group", "tag_note", "group_book", "setting",
        "attach_image", "chapter", "read_status", "read_time_record", "category",
        "category_content", "review", "tag_book", "review_image", "sort", "category_image",
        "white_noise", "widget_config", "image", "source", "read_target",
        "book_read_status_record", "collection", "collection_book", "backup_server",
        "cos_config", "read_plan", "reminder_event", "check_in_record", "author", "press",
        "cover_mosaic"
    ]

    /// 按 FK 子级到父级排序；该顺序保证 NO ACTION 外键下的每次 DELETE 都合法。
    private nonisolated static let childFirstDeletionOrder = [
        "category_image", "review_image", "attach_image", "tag_note", "group_book",
        "tag_book", "reminder_event", "setting", "read_time_record",
        "book_read_status_record", "collection_book", "check_in_record", "sort", "note",
        "category_content", "review", "read_plan", "chapter", "category", "tag", "group",
        "collection", "book", "user", "source", "read_status", "white_noise",
        "widget_config", "image", "read_target", "backup_server", "cos_config", "author",
        "press", "cover_mosaic"
    ]

    /// 执行幂等整理；每轮物理删除后重算占位书引用，直到删除集合为空，避免最后引用在上一轮消失后残留占位书。
    nonisolated static func canonicalize(_ db: Database) throws {
        try DefaultRootSeeder.seed(db)
        while true {
            try prepareTemporaryState(db)
            try collectPreservedPlaceholderBooks(db)
            try collectTombstones(db)
            try collectInvalidRelationshipClosure(db)

            guard try deletionCandidateCount(db) > 0 else {
                try assertNoUnexpectedTombstones(db)
                try RoomCanonicalSchemaSupport.assertForeignKeyCheckIsEmpty(db)
                return
            }
            try deleteCollectedRows(db)
        }
    }
}

private extension HardDeleteCanonicalizer {
    /// 一条 Room 外键边；`allowsPlaceholderBook` 仅允许引用关系消费被保留的占位书。
    nonisolated struct ForeignKeyEdge {
        let childTable: String
        let childColumn: String
        let parentTable: String
        let allowsPlaceholderBook: Bool

        nonisolated init(
            _ childTable: String,
            _ childColumn: String,
            _ parentTable: String,
            allowsPlaceholderBook: Bool = false
        ) {
            self.childTable = childTable
            self.childColumn = childColumn
            self.parentTable = parentTable
            self.allowsPlaceholderBook = allowsPlaceholderBook
        }
    }

    /// Room v44 的全部显式外键；父列均为 `id`，与 schema JSON 一致。
    nonisolated static var foreignKeyEdges: [ForeignKeyEdge] {
        [
            .init("note", "book_id", "book"),
            .init("note", "chapter_id", "chapter"),
            .init("book", "user_id", "user"),
            .init("book", "read_status_id", "read_status"),
            .init("book", "source_id", "source"),
            .init("tag", "user_id", "user"),
            .init("group", "user_id", "user"),
            .init("tag_note", "tag_id", "tag"),
            .init("tag_note", "note_id", "note"),
            .init("group_book", "group_id", "group"),
            .init("group_book", "book_id", "book"),
            .init("setting", "user_id", "user"),
            .init("attach_image", "note_id", "note"),
            .init("chapter", "book_id", "book"),
            .init("read_time_record", "book_id", "book"),
            .init("category", "book_id", "book"),
            .init("category_content", "category_id", "category"),
            .init("category_content", "book_id", "book"),
            .init("category_content", "content_book_id", "book", allowsPlaceholderBook: true),
            .init("review", "book_id", "book"),
            .init("tag_book", "book_id", "book"),
            .init("tag_book", "tag_id", "tag"),
            .init("review_image", "review_id", "review"),
            .init("sort", "book_id", "book"),
            .init("category_image", "category_content_id", "category_content"),
            .init("book_read_status_record", "book_id", "book"),
            .init("book_read_status_record", "read_status_id", "read_status"),
            .init("collection_book", "collection_id", "collection"),
            .init("collection_book", "book_id", "book", allowsPlaceholderBook: true),
            .init("read_plan", "book_id", "book"),
            .init("reminder_event", "read_plan_id", "read_plan"),
            .init("check_in_record", "book_id", "book")
        ]
    }

    /// 创建并清空连接级临时表；临时状态不会进入 Room schema 或备份文件。
    nonisolated static func prepareTemporaryState(_ db: Database) throws {
        // SQL 目的：建立本次整理的待删除集合；涉及表：TEMP.ios_hard_delete_rows；
        // 关键字段：table_name + id 联合主键；副作用：仅创建连接级临时表，不修改 Room 物理 schema。
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS \(quote(deletionSetTable)) (
                table_name TEXT NOT NULL,
                id INTEGER NOT NULL,
                PRIMARY KEY (table_name, id)
            ) WITHOUT ROWID
        """)

        // SQL 目的：清空可能由同一数据库连接上次幂等整理留下的待删除集合；涉及表：TEMP.ios_hard_delete_rows；
        // 关键过滤：无；副作用：只重置临时工作状态，不删除业务数据。
        try db.execute(sql: "DELETE FROM \(quote(deletionSetTable))")

        // SQL 目的：建立仍有有效业务引用的占位书集合；涉及表：TEMP.ios_preserved_placeholder_books；
        // 关键字段：book_id 主键；副作用：仅创建连接级临时表，不进入 Room identity hash。
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS \(quote(preservedBookTable)) (
                book_id INTEGER NOT NULL PRIMARY KEY
            ) WITHOUT ROWID
        """)

        // SQL 目的：清空可能由同一数据库连接上次整理留下的占位书集合；涉及表：TEMP.ios_preserved_placeholder_books；
        // 关键过滤：无；副作用：只重置临时工作状态。
        try db.execute(sql: "DELETE FROM \(quote(preservedBookTable))")
    }

    /// 仅保留被活跃书单关系或活跃相关书籍内容引用的正数 tombstone 书籍。
    nonisolated static func collectPreservedPlaceholderBooks(_ db: Database) throws {
        // SQL 目的：收集仍被有效书单关系引用且自身系统父级可用的占位书；涉及 collection_book、collection、book、user、source、read_status；
        // 关键过滤：关系与书单均活跃、目标 book.id>0/is_deleted=1，且用户/来源/阅读状态为活跃记录或受保护根；副作用：写入连接级保留集合。
        try db.execute(sql: """
            INSERT OR IGNORE INTO \(quote(preservedBookTable)) (book_id)
            SELECT target.id
            FROM collection_book AS relation
            JOIN collection AS owner
              ON owner.id = relation.collection_id
             AND owner.is_deleted = 0
            JOIN book AS target
              ON target.id = relation.book_id
             AND target.id > 0
             AND target.is_deleted = 1
            JOIN user AS target_user
              ON target_user.id = target.user_id
             AND (target_user.is_deleted = 0 OR target_user.id = 1)
            JOIN source AS target_source
              ON target_source.id = target.source_id
             AND (target_source.is_deleted = 0 OR target_source.id = 0)
            JOIN read_status AS target_status
              ON target_status.id = target.read_status_id
             AND (target_status.is_deleted = 0 OR target_status.id BETWEEN 1 AND 5)
            WHERE relation.is_deleted = 0
        """)

        // SQL 目的：收集仍被有效“相关书籍”内容引用且自身系统父级可用的占位书；涉及 category_content、category、三次 book、user、source、read_status；
        // 关键过滤：内容/分类/宿主书均活跃、目标书 id>0/is_deleted=1，且目标书用户/来源/阅读状态为活跃记录或受保护根；副作用：写入连接级保留集合。
        try db.execute(sql: """
            INSERT OR IGNORE INTO \(quote(preservedBookTable)) (book_id)
            SELECT target.id
            FROM category_content AS content
            JOIN category AS category
              ON category.id = content.category_id
             AND category.is_deleted = 0
            JOIN book AS category_host
              ON category_host.id = category.book_id
             AND category_host.is_deleted = 0
            JOIN book AS content_host
              ON content_host.id = content.book_id
             AND content_host.is_deleted = 0
            JOIN book AS target
              ON target.id = content.content_book_id
             AND target.id > 0
             AND target.is_deleted = 1
            JOIN user AS target_user
              ON target_user.id = target.user_id
             AND (target_user.is_deleted = 0 OR target_user.id = 1)
            JOIN source AS target_source
              ON target_source.id = target.source_id
             AND (target_source.is_deleted = 0 OR target_source.id = 0)
            JOIN read_status AS target_status
              ON target_status.id = target.read_status_id
             AND (target_status.is_deleted = 0 OR target_status.id BETWEEN 1 AND 5)
            WHERE content.is_deleted = 0
        """)
    }

    /// 将所有非例外 `is_deleted=1` 行登记到待删除集合，暂不触碰业务表。
    nonisolated static func collectTombstones(_ db: Database) throws {
        for table in entityTables {
            let protectedPredicate = protectedRowPredicate(table: table, alias: "entity")
            // SQL 目的：登记当前业务表中需要物理清理的历史删除行；涉及表：当前 entity 与 TEMP 待删除/保留集合；
            // 关键过滤：is_deleted=1，排除系统根及有效引用占位书；返回字段：table_name、id；副作用：不立即删除业务行。
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO \(quote(deletionSetTable)) (table_name, id)
                    SELECT ?, entity.id
                    FROM \(quote(table)) AS entity
                    WHERE entity.is_deleted = 1
                      AND NOT (\(protectedPredicate))
                """,
                arguments: [table]
            )
        }
    }

    /// 沿全部 FK 向子级传播删除集合，并同时登记物理缺父的孤儿行。
    nonisolated static func collectInvalidRelationshipClosure(_ db: Database) throws {
        while true {
            let countBefore = try deletionCandidateCount(db)
            for edge in foreignKeyEdges {
                try collectInvalidChildren(for: edge, db: db)
            }
            let countAfter = try deletionCandidateCount(db)
            if countAfter == countBefore {
                return
            }
        }
    }

    /// 登记一条外键边上父级缺失、已待删或仅能作为受限占位引用的子记录。
    nonisolated static func collectInvalidChildren(for edge: ForeignKeyEdge, db: Database) throws {
        let childProtected = protectedRowPredicate(table: edge.childTable, alias: "child")
        let parentUsable = usableParentPredicate(for: edge, alias: "parent")
        // SQL 目的：沿单条 Room 外键登记无效子记录；涉及当前 child/parent 与 TEMP 待删除/占位书集合；
        // 关键过滤：父行缺失、父行已待删或父行不是该关系允许消费的有效记录；副作用：将子 id 加入物理删除闭包。
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO \(quote(deletionSetTable)) (table_name, id)
                SELECT ?, child.id
                FROM \(quote(edge.childTable)) AS child
                LEFT JOIN \(quote(edge.parentTable)) AS parent
                  ON parent.id = child.\(quote(edge.childColumn))
                LEFT JOIN \(quote(deletionSetTable)) AS doomed_parent
                  ON doomed_parent.table_name = ?
                 AND doomed_parent.id = parent.id
                WHERE NOT (\(childProtected))
                  AND (
                      parent.id IS NULL
                      OR doomed_parent.id IS NOT NULL
                      OR NOT (\(parentUsable))
                  )
            """,
            arguments: [edge.childTable, edge.parentTable]
        )
    }

    /// 按 FK 子级到父级执行物理删除，保持 Room 的 NO ACTION 外键始终可满足。
    nonisolated static func deleteCollectedRows(_ db: Database) throws {
        for table in childFirstDeletionOrder {
            // SQL 目的：物理删除当前表已进入闭包的行；涉及当前业务表与 TEMP 待删除集合；
            // 关键过滤：table_name 与 id 精确匹配；副作用：不可恢复地删除历史 tombstone、失效后代与外键孤儿。
            try db.execute(
                sql: """
                    DELETE FROM \(quote(table))
                    WHERE id IN (
                        SELECT id
                        FROM \(quote(deletionSetTable))
                        WHERE table_name = ?
                    )
                """,
                arguments: [table]
            )
        }
    }

    /// 阻断未被算法覆盖的 tombstone，避免迁移标识写入后留下半完成语义。
    nonisolated static func assertNoUnexpectedTombstones(_ db: Database) throws {
        for table in entityTables {
            let protectedPredicate = protectedRowPredicate(table: table, alias: "entity")
            // SQL 目的：统计硬删除后仍存在的非例外历史删除行；涉及当前业务表与 TEMP 占位书集合；
            // 关键过滤：is_deleted=1 且非系统根/有效引用占位书；返回字段：异常行数；副作用：无。
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM \(quote(table)) AS entity
                    WHERE entity.is_deleted = 1
                      AND NOT (\(protectedPredicate))
                """
            ) ?? 0
            if count > 0 {
                throw HardDeleteCanonicalizerError.unexpectedTombstones(table: table, count: count)
            }
        }
    }

    /// 返回待删除集合规模，用于判断外键闭包是否已稳定。
    nonisolated static func deletionCandidateCount(_ db: Database) throws -> Int {
        // SQL 目的：统计 TEMP 待删除集合规模；涉及 ios_hard_delete_rows；关键过滤：无；
        // 返回字段：去重后的 table_name/id 行数，用于终止有限闭包迭代；副作用：无。
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quote(deletionSetTable))") ?? 0
    }

    /// 返回某表不可删除的系统根或引用占位书条件；默认无例外。
    nonisolated static func protectedRowPredicate(table: String, alias: String) -> String {
        switch table {
        case "book":
            return "\(alias).id = 0 OR EXISTS (SELECT 1 FROM \(quote(preservedBookTable)) AS kept WHERE kept.book_id = \(alias).id)"
        case "chapter", "source":
            return "\(alias).id = 0"
        case "user":
            return "\(alias).id = 1"
        case "read_status":
            return "\(alias).id BETWEEN 1 AND 5"
        default:
            return "0"
        }
    }

    /// 返回父记录是否可被当前外键消费；占位书只对两个已批准的引用关系有效。
    nonisolated static func usableParentPredicate(for edge: ForeignKeyEdge, alias: String) -> String {
        if edge.parentTable == "book" {
            if edge.allowsPlaceholderBook {
                return "\(alias).is_deleted = 0 OR \(alias).id = 0 OR EXISTS (SELECT 1 FROM \(quote(preservedBookTable)) AS kept WHERE kept.book_id = \(alias).id)"
            }
            // 引用占位书只允许被 collection_book.book_id 与 category_content.content_book_id 消费；
            // note/chapter/group_book 等从属关系必须随原书删除，不能因为同一 book 被外部引用而继续存活。
            return "\(alias).is_deleted = 0 OR \(alias).id = 0"
        }
        let systemRoot = protectedRowPredicate(table: edge.parentTable, alias: alias)
        return "\(alias).is_deleted = 0 OR (\(systemRoot))"
    }

    /// 对内部固定标识符执行 SQLite 双引号转义，防止关键字表名破坏动态 SQL。
    nonisolated static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// 硬删除整理未能收敛到治理规则时返回的可诊断错误。
nonisolated private enum HardDeleteCanonicalizerError: LocalizedError {
    case unexpectedTombstones(table: String, count: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedTombstones(let table, let count):
            return "硬删除迁移后 \(table) 仍有 \(count) 条非例外删除标记"
        }
    }
}
