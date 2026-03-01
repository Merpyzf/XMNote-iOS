/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 NoteRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 书摘/笔记表，对应 Android NoteEntity
/// 外键: book_id → book, chapter_id → chapter
nonisolated struct NoteRecord: BaseRecord {
    static let databaseTableName = "note"

    var id: Int64?
    var bookId: Int64 = 0
    var chapterId: Int64 = 0
    var content: String = ""
    /// 用户批注/想法
    var idea: String = ""
    var position: String = ""
    var positionUnit: Int64 = 0
    /// 微信读书划线范围
    var wereadRange: String = ""
    /// 是否包含时间信息: 1=是, 0=否
    var includeTime: Int64 = 1

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, content, idea, position
        case bookId = "book_id"
        case chapterId = "chapter_id"
        case positionUnit = "position_unit"
        case wereadRange = "weread_range"
        case includeTime = "include_time"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
