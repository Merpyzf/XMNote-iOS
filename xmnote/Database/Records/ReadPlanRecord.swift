import Foundation
import GRDB

/// 阅读计划表，对应 Android ReadPlanEntity
/// 外键: book_id → book
nonisolated struct ReadPlanRecord: BaseRecord {
    static let databaseTableName = "read_plan"

    var id: Int64?
    var bookId: Int64 = 0
    var totalPageNumber: Int64 = 0
    var readPageNumber: Double = 0.0
    /// 进度单位类型
    var positionType: Int64 = 0
    var readStartDate: Int64 = 0
    var dayReadNumber: Double = 0.0
    /// 阅读间隔天数
    var readInterval: Int64 = 1
    var reminderTime: Int64 = 0
    var description: String = ""

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, description
        case bookId = "book_id"
        case totalPageNumber = "total_page_number"
        case readPageNumber = "read_page_number"
        case positionType = "position_type"
        case readStartDate = "read_start_date"
        case dayReadNumber = "day_read_number"
        case readInterval = "read_interval"
        case reminderTime = "reminder_time"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
