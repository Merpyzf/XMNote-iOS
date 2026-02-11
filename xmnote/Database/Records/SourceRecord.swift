import Foundation
import GRDB

/// 书籍来源表，对应 Android SourceEntity
nonisolated struct SourceRecord: BaseRecord {
    static let databaseTableName = "source"

    var id: Int64?
    var name: String = ""
    var sourceOrder: Int64 = 0       // 列名: source_order
    var bookshelfOrder: Int64 = -1   // 列名: bookshelf_order
    var isHide: Int64 = 0            // 列名: is_hide

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name
        case sourceOrder = "source_order"
        case bookshelfOrder = "bookshelf_order"
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
