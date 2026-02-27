import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接
 * [OUTPUT]: 对外提供 NoteRepository（NoteRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层笔记仓储实现，统一封装标签分组查询与笔记详情读写
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct NoteRepository: NoteRepositoryProtocol {
    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchTagSections(db)
        }
    }

    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload? {
        try await databaseManager.database.dbPool.read { db in
            try fetchNotePayload(db: db, noteId: noteId)
        }
    }

    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
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
    func fetchTagSections(_ db: Database) throws -> [TagSection] {
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

    func fetchNotePayload(db: Database, noteId: Int64) throws -> NoteDetailPayload? {
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
