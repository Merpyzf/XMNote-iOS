import Foundation
import GRDB

/// 书摘附图表，对应 Android AttachImageEntity
/// 外键: note_id → note
nonisolated struct AttachImageRecord: BaseRecord {
    static let databaseTableName = "attach_image"

    var id: Int64?
    var noteId: Int64 = 0
    var imageUrl: String = ""

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case noteId = "note_id"
        case imageUrl = "image_url"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
