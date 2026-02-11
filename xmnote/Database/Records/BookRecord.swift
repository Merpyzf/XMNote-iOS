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
    var currentPositionUnit: Int64 = 0
    var positionUnit: Int64 = 0
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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
