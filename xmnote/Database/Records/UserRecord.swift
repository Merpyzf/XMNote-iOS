import Foundation
import GRDB

/// 用户表，对应 Android UserEntity
nonisolated struct UserRecord: BaseRecord {
    static let databaseTableName = "user"

    var id: Int64?
    var userId: Int64 = 0
    var nickName: String?
    var gender: Int64 = 0
    var phone: String?

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case nickName
        case gender, phone
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
