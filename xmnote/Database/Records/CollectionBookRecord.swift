import Foundation
import GRDB

/// 书单↔书籍 关系表，对应 Android CollectionBookEntity
/// 外键: collection_id → collection, book_id → book
nonisolated struct CollectionBookRecord: BaseRecord {
    static let databaseTableName = "collection_book"

    var id: Int64?
    var collectionId: Int64 = 0
    var bookId: Int64 = 0
    var recommend: String = ""
    var order: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, recommend, order
        case collectionId = "collection_id"
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
