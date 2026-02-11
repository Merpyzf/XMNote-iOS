import Foundation
import GRDB

/// 通用图片表，对应 Android ImageEntity
nonisolated struct ImageRecord: BaseRecord {
    static let databaseTableName = "image"

    var id: Int64?
    var url: String = ""
    var type: Int64 = 0
    /// 是否为付费资源: 0=免费, 1=付费
    var pro: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, url, type, pro
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
