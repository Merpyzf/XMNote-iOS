import Foundation
import GRDB

/// 设置表，对应 Android SettingEntity
/// 外键: user_id → user
nonisolated struct SettingRecord: BaseRecord {
    static let databaseTableName = "setting"

    var id: Int64?
    var key: String?
    var value: String?
    var userId: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, key, value
        case userId = "user_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
