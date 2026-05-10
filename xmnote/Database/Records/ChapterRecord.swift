/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 ChapterRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 章节表，对应 Android ChapterEntity
/// 外键: book_id → book
nonisolated struct ChapterRecord: BaseRecord {
    static let databaseTableName = "chapter"

    var id: Int64?
    var bookId: Int64 = 0
    var parentId: Int64 = 0
    var title: String = ""
    var remark: String = ""
    var chapterOrder: Int64 = 0
    var isImport: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    /// 映射 Swift 属性名与数据库字段名，保证 Record 与表结构一致。
    enum CodingKeys: String, CodingKey {
        case id, title, remark
        case bookId = "book_id"
        case parentId = "parent_id"
        case chapterOrder = "chapter_order"
        case isImport = "is_import"
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

extension ChapterRecord {
    /// 从 Room canonical 表解码章节记录；Android 允许部分文本列为 NULL，进入 iOS 业务模型前统一映射为空字符串。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id),
            bookId: try container.decodeIfPresent(Int64.self, forKey: .bookId) ?? 0,
            parentId: try container.decodeIfPresent(Int64.self, forKey: .parentId) ?? 0,
            title: try container.decodeStringOrEmpty(forKey: .title),
            remark: try container.decodeStringOrEmpty(forKey: .remark),
            chapterOrder: try container.decodeIfPresent(Int64.self, forKey: .chapterOrder) ?? 0,
            isImport: try container.decodeIfPresent(Int64.self, forKey: .isImport) ?? 0,
            createdDate: try container.decodeIfPresent(Int64.self, forKey: .createdDate) ?? 0,
            updatedDate: try container.decodeIfPresent(Int64.self, forKey: .updatedDate) ?? 0,
            lastSyncDate: try container.decodeIfPresent(Int64.self, forKey: .lastSyncDate) ?? 0,
            isDeleted: try container.decodeIfPresent(Int64.self, forKey: .isDeleted) ?? 0
        )
    }
}
