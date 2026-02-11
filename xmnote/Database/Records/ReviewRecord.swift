import Foundation
import GRDB

/// 书评表，对应 Android ReviewEntity
/// 外键: book_id → book
nonisolated struct ReviewRecord: BaseRecord {
    static let databaseTableName = "review"

    var id: Int64?
    var bookId: Int64 = 0
    var title: String?
    var content: String?

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, content
        case bookId = "book_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
