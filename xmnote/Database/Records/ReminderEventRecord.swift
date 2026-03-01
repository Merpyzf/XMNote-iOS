/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 ReminderEventRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 阅读提醒事件表，对应 Android ReminderEventEntity
/// 外键: read_plan_id → read_plan
nonisolated struct ReminderEventRecord: BaseRecord {
    static let databaseTableName = "reminder_event"

    var id: Int64?
    var eventId: Int64 = 0
    var readPlanId: Int64 = 0
    var dayReadNumber: Double = 0.0
    var reminderDateTime: Int64 = 0
    /// 是否已完成: 0=否, 1=是
    var isDone: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case readPlanId = "read_plan_id"
        case dayReadNumber = "day_read_number"
        case reminderDateTime = "reminder_date_time"
        case isDone = "is_done"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
