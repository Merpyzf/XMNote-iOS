/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 CheckInRecordRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 打卡记录表，对应 Android CheckInRecordEntity
/// 外键: book_id → book
nonisolated struct CheckInRecordRecord: BaseRecord {
    static let databaseTableName = "check_in_record"

    var id: Int64?
    var bookId: Int64 = 0
    var amount: Int64 = 0
    var position: String = ""
    var positionUnit: Int64 = 0
    var remark: String = ""
    var checkinDate: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, amount, position, remark
        case bookId = "book_id"
        case positionUnit = "position_unit"
        case checkinDate = "checkin_date"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
