import Foundation
import GRDB

/// 阅读时间记录表，对应 Android ReadTimeRecordEntity
/// 外键: book_id → book
nonisolated struct ReadTimeRecordRecord: BaseRecord {
    static let databaseTableName = "read_time_record"

    var id: Int64?
    var bookId: Int64 = 0
    var startTime: Int64 = 0
    var endTime: Int64 = 0
    /// 中断时间戳
    var interruptTime: Int64 = 0
    /// 实际阅读秒数
    var elapsedSeconds: Int64 = 0
    /// 倒计时设定秒数
    var countdownSeconds: Int64 = 0
    /// 暂停累计毫秒数
    var pausedDurationMillis: Int64 = 0
    /// 是否暂停中: 0=否, 1=是
    var paused: Int64 = 0
    var position: Double = 0.0
    /// 记录状态
    var status: Int64 = 0
    /// 模糊阅读日期（手动补录时使用）
    var fuzzyReadDate: Int64 = 0
    /// 微信读书中记录的阅读日期
    var wereadReadDate: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, position, status, paused
        case bookId = "book_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case interruptTime = "interrupt_time"
        case elapsedSeconds = "elapsed_seconds"
        case countdownSeconds = "countdown_seconds"
        case pausedDurationMillis = "paused_duration_millis"
        case fuzzyReadDate = "fuzzy_read_date"
        case wereadReadDate = "weread_read_date"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
