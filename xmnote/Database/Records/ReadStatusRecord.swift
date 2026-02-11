import Foundation
import GRDB

/// 阅读状态表，对应 Android ReadStatusEntity
/// 预定义数据：1=未读, 2=在读, 3=已读, 4=搁置
/// 注意：id 不自增，使用手动赋值
nonisolated struct ReadStatusRecord: BaseRecord {
    static let databaseTableName = "read_status"

    var id: Int64  // 手动赋值，不自增
    var name: String
    var readStatusOrder: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name
        case readStatusOrder = "read_status_order"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }
}
