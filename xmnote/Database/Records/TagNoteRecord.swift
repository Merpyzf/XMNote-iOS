import Foundation
import GRDB

/// 标签↔书摘 关系表，对应 Android TagNoteEntity
/// 外键: tag_id → tag, note_id → note
nonisolated struct TagNoteRecord: BaseRecord {
    static let databaseTableName = "tag_note"

    var id: Int64?
    var tagId: Int64 = 0
    var noteId: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case tagId = "tag_id"
        case noteId = "note_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
