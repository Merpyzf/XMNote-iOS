import Foundation
import GRDB

/// 分组表，对应 Android GroupEntity
/// 外键: user_id → user
nonisolated struct GroupRecord: BaseRecord {
    static let databaseTableName = "group"

    var id: Int64?
    var userId: Int64 = 0
    var name: String?
    var groupOrder: Int64 = 0
    var pinned: Int64 = 0
    var pinOrder: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name, pinned
        case userId = "user_id"
        case groupOrder = "group_order"
        case pinOrder = "pin_order"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
