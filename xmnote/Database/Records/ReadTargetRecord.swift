/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 ReadTargetRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

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

    /// 映射 Swift 属性名与数据库字段名，保证 Record 与表结构一致。
    enum CodingKeys: String, CodingKey {
        case id, time, target, type
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
