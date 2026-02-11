import Foundation
import GRDB

/// 分组↔书籍 关系表，对应 Android GroupBookEntity
/// 外键: group_id → group, book_id → book
nonisolated struct GroupBookRecord: BaseRecord {
    static let databaseTableName = "group_book"

    var id: Int64?
    var groupId: Int64 = 0
    var bookId: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
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
