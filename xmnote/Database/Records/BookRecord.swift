/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 BookRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 书籍表，对应 Android BookEntity
/// 外键: user_id → user, read_status_id → read_status, source_id → source
nonisolated struct BookRecord: BaseRecord {
    static let databaseTableName = "book"

    var id: Int64?
    var userId: Int64 = 0
    var doubanId: Int64 = 0
    var name: String = ""
    var rawName: String = ""
    var cover: String = ""
    var author: String = ""
    var authorIntro: String = ""
    var translator: String = ""
    var isbn: String = ""
    var pubDate: String = ""
    var press: String = ""
    var summary: String = ""
    var readPosition: Double = 0.0
    var totalPosition: Int64 = 0
    var totalPagination: Int64 = 0
    /// 书籍类型: 0=纸质书, 1=电子书
    var type: Int64 = 0
    var currentPositionUnit: Int64 = 2
    var positionUnit: Int64 = 2
    var sourceId: Int64 = 1
    var purchaseDate: Int64 = 0
    var price: Double = 0.0
    var bookOrder: Int64 = 0
    var pinned: Int64 = 0
    var pinOrder: Int64 = 0
    var readStatusId: Int64 = 0
    var readStatusChangedDate: Int64 = 0
    var score: Int64 = 0
    var catalog: String = ""
    var bookMarkModifiedTime: Int64 = 0
    /// 字数，可为 null
    var wordCount: Int64?

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    /// 映射 Swift 属性名与数据库字段名，保证 Record 与表结构一致。
    enum CodingKeys: String, CodingKey {
        case id, name, cover, author, translator, isbn, press, summary, type, score, catalog, pinned, price
        case userId = "user_id"
        case doubanId = "douban_id"
        case rawName = "raw_name"
        case authorIntro = "author_intro"
        case pubDate = "pub_date"
        case readPosition = "read_position"
        case totalPosition = "total_position"
        case totalPagination = "total_pagination"
        case currentPositionUnit = "current_position_unit"
        case positionUnit = "position_unit"
        case sourceId = "source_id"
        case purchaseDate = "purchase_date"
        case bookOrder = "book_order"
        case pinOrder = "pin_order"
        case readStatusId = "read_status_id"
        case readStatusChangedDate = "read_status_changed_date"
        case bookMarkModifiedTime = "book_mark_modified_time"
        case wordCount = "word_count"
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

extension BookRecord {
    /// 从 Room canonical 表解码书籍记录；Android 允许部分文本列为 NULL，进入 iOS 业务模型前统一映射为空字符串。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id),
            userId: try container.decodeIfPresent(Int64.self, forKey: .userId) ?? 0,
            doubanId: try container.decodeIfPresent(Int64.self, forKey: .doubanId) ?? 0,
            name: try container.decodeStringOrEmpty(forKey: .name),
            rawName: try container.decodeStringOrEmpty(forKey: .rawName),
            cover: try container.decodeStringOrEmpty(forKey: .cover),
            author: try container.decodeStringOrEmpty(forKey: .author),
            authorIntro: try container.decodeStringOrEmpty(forKey: .authorIntro),
            translator: try container.decodeStringOrEmpty(forKey: .translator),
            isbn: try container.decodeStringOrEmpty(forKey: .isbn),
            pubDate: try container.decodeStringOrEmpty(forKey: .pubDate),
            press: try container.decodeStringOrEmpty(forKey: .press),
            summary: try container.decodeStringOrEmpty(forKey: .summary),
            readPosition: try container.decodeIfPresent(Double.self, forKey: .readPosition) ?? 0,
            totalPosition: try container.decodeIfPresent(Int64.self, forKey: .totalPosition) ?? 0,
            totalPagination: try container.decodeIfPresent(Int64.self, forKey: .totalPagination) ?? 0,
            type: try container.decodeIfPresent(Int64.self, forKey: .type) ?? 0,
            currentPositionUnit: try container.decodeIfPresent(Int64.self, forKey: .currentPositionUnit) ?? 2,
            positionUnit: try container.decodeIfPresent(Int64.self, forKey: .positionUnit) ?? 2,
            sourceId: try container.decodeIfPresent(Int64.self, forKey: .sourceId) ?? 1,
            purchaseDate: try container.decodeIfPresent(Int64.self, forKey: .purchaseDate) ?? 0,
            price: try container.decodeIfPresent(Double.self, forKey: .price) ?? 0,
            bookOrder: try container.decodeIfPresent(Int64.self, forKey: .bookOrder) ?? 0,
            pinned: try container.decodeIfPresent(Int64.self, forKey: .pinned) ?? 0,
            pinOrder: try container.decodeIfPresent(Int64.self, forKey: .pinOrder) ?? 0,
            readStatusId: try container.decodeIfPresent(Int64.self, forKey: .readStatusId) ?? 0,
            readStatusChangedDate: try container.decodeIfPresent(Int64.self, forKey: .readStatusChangedDate) ?? 0,
            score: try container.decodeIfPresent(Int64.self, forKey: .score) ?? 0,
            catalog: try container.decodeStringOrEmpty(forKey: .catalog),
            bookMarkModifiedTime: try container.decodeIfPresent(Int64.self, forKey: .bookMarkModifiedTime) ?? 0,
            wordCount: try container.decodeIfPresent(Int64.self, forKey: .wordCount),
            createdDate: try container.decodeIfPresent(Int64.self, forKey: .createdDate) ?? 0,
            updatedDate: try container.decodeIfPresent(Int64.self, forKey: .updatedDate) ?? 0,
            lastSyncDate: try container.decodeIfPresent(Int64.self, forKey: .lastSyncDate) ?? 0,
            isDeleted: try container.decodeIfPresent(Int64.self, forKey: .isDeleted) ?? 0
        )
    }
}
