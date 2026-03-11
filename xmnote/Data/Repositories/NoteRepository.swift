import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接
 * [OUTPUT]: 对外提供 NoteRepository（NoteRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层笔记仓储实现，统一封装标签分组查询与笔记详情读写
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 笔记仓储实现，负责标签分组订阅与笔记详情读写。
struct NoteRepository: NoteRepositoryProtocol {
    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，供标签分组查询与笔记详情读写复用同一数据源。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 为笔记主页提供标签分组订阅流，标签或标签关联变更后自动刷新分组计数。
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchTagSections(db)
        }
    }

    /// 读取单条笔记详情，供笔记编辑页初始化富文本内容与位置信息。
    /// - Throws: 数据库查询失败时抛出错误。
    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload? {
        try await databaseManager.database.dbPool.read { db in
            // SQL 目的：按 noteId 读取单条笔记详情（富文本内容 + 位置信息）。
            // 过滤条件：限定主键并排除软删除记录；LIMIT 1 保证只返回单条。
            // 返回字段：覆盖 NoteDetailPayload 的全部展示字段。
            let sql = """
                SELECT content, idea, position, position_unit, include_time, created_date
                FROM note
                WHERE id = ? AND is_deleted = 0
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteId]) else {
                return nil
            }
            return NoteDetailPayload(
                contentHTML: row["content"] ?? "",
                ideaHTML: row["idea"] ?? "",
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    /// 持久化编辑页提交的笔记正文与想法内容，并刷新更新时间戳。
    /// - Throws: 数据库写入失败时抛出错误。
    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
                // SQL 目的：更新笔记内容与更新时间戳（毫秒）。
                // 过滤条件：按 id 精确更新，且仅对未删除记录生效。
                // 副作用：只修改 content/idea/updated_date 三列，不触碰其他业务字段。
                sql: """
                    UPDATE note
                    SET content = ?, idea = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0
                """,
                arguments: [contentHTML, ideaHTML, now, noteId]
            )
        }
    }
}

private extension NoteRepository {
    /// 查询标签分组和各标签笔记数，供标签入口页展示“笔记标签/书籍标签”两个分区。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchTagSections(_ db: Database) throws -> [TagSection] {
        // SQL 目的：读取标签列表并统计每个标签关联的有效笔记数。
        // 表关系：tag t LEFT JOIN tag_note tn（仅 tn.is_deleted = 0）。
        // 分组与排序：按标签 id 聚合计数，再按 type/tag_order 输出用于分组展示。
        let sql = """
            SELECT t.id, t.name, t.type, t.tag_order,
                   COUNT(tn.id) AS note_count
            FROM tag t
            LEFT JOIN tag_note tn ON t.id = tn.tag_id AND tn.is_deleted = 0
            WHERE t.is_deleted = 0
            GROUP BY t.id
            ORDER BY t.type ASC, t.tag_order ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)

        var noteTagItems: [Tag] = []
        var bookTagItems: [Tag] = []

        for row in rows {
            let id: Int64 = row["id"]
            let name: String = row["name"] ?? ""
            let type: Int64 = row["type"]
            let noteCount: Int = row["note_count"]
            let tag = Tag(id: id, name: name, noteCount: noteCount)

            if type == 0 {
                noteTagItems.append(tag)
            } else {
                bookTagItems.append(tag)
            }
        }

        var sections: [TagSection] = []
        if !noteTagItems.isEmpty {
            sections.append(TagSection(id: 0, title: "笔记标签", tags: noteTagItems))
        }
        if !bookTagItems.isEmpty {
            sections.append(TagSection(id: 1, title: "书籍标签", tags: bookTagItems))
        }
        return sections
    }

}
