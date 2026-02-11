import Foundation
import GRDB

/// 排序记录表，对应 Android SortEntity
/// 外键: book_id → book
nonisolated struct SortRecord: BaseRecord {
    static let databaseTableName = "sort"

    var id: Int64?
    var bookId: Int64 = 0
    var type: Int64 = 0
    var order: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, type, order
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
