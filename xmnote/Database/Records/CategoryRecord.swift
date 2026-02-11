import Foundation
import GRDB

/// 相关分类表，对应 Android CategoryEntity
/// 外键: book_id → book
nonisolated struct CategoryRecord: BaseRecord {
    static let databaseTableName = "category"

    var id: Int64?
    var bookId: Int64 = 0
    var title: String?
    var order: Int64 = 0
    var isHide: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, order
        case bookId = "book_id"
        case isHide = "is_hide"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
