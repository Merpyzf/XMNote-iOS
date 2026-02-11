import Foundation
import GRDB

/// 阅读状态变更记录表，对应 Android BookReadStatusRecordEntity
/// 外键: book_id → book, read_status_id → read_status
nonisolated struct BookReadStatusRecordRecord: BaseRecord {
    static let databaseTableName = "book_read_status_record"

    var id: Int64?
    var bookId: Int64 = 0
    var readStatusId: Int64 = 2
    var changedDate: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case bookId = "book_id"
        case readStatusId = "read_status_id"
        case changedDate = "changed_date"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
