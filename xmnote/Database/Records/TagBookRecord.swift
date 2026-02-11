import Foundation
import GRDB

/// 标签↔书籍 关系表，对应 Android TagBookEntity
/// 外键: tag_id → tag, book_id → book
nonisolated struct TagBookRecord: BaseRecord {
    static let databaseTableName = "tag_book"

    var id: Int64?
    var bookId: Int64 = 0
    var tagId: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case tagId = "tag_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
