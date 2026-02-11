import Foundation
import GRDB

/// 标签表，对应 Android TagEntity
/// 外键: user_id → user
nonisolated struct TagRecord: BaseRecord {
    static let databaseTableName = "tag"

    var id: Int64?
    var userId: Int64 = 0
    var name: String?
    /// 标签颜色值
    var color: Int64 = 0
    var tagOrder: Int64 = 0
    /// 标签类型: 0=笔记标签, 1=书籍标签
    var type: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name, color, type
        case userId = "user_id"
        case tagOrder = "tag_order"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
