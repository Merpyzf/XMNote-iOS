import Foundation
import GRDB

/// 阅读目标表，对应 Android ReadTargetEntity
/// 两类场景: 每日阅读时间 / 每年阅读书籍数目
nonisolated struct ReadTargetRecord: BaseRecord {
    static let databaseTableName = "read_target"

    var id: Int64?
    var time: Int64 = 0
    var target: Int64 = 0
    /// 目标类型: 0=阅读书籍数, 1=阅读时长
    var type: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, time, target, type
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
