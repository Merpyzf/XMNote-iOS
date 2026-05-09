/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 ReadTimeRecordRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

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
    /// 阅读感悟，Android v39 增加。
    var insight: String = ""
    /// 本次记录的进度单位快照，Android v40 增加，可为空。
    var recordedPositionUnit: Int64?

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    /// 映射 Swift 属性名与数据库字段名，保证 Record 与表结构一致。
    enum CodingKeys: String, CodingKey {
        case id, position, status, paused, insight
        case bookId = "book_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case interruptTime = "interrupt_time"
        case elapsedSeconds = "elapsed_seconds"
        case countdownSeconds = "countdown_seconds"
        case pausedDurationMillis = "paused_duration_millis"
        case fuzzyReadDate = "fuzzy_read_date"
        case wereadReadDate = "weread_read_date"
        case recordedPositionUnit = "recorded_position_unit"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    /// 在数据库插入后回填自增主键，保证内存对象与持久化记录一致。
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
