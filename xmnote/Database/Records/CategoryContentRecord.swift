import Foundation
import GRDB

/// 分类内容表，对应 Android CategoryContentEntity
/// 外键: category_id → category, book_id → book, content_book_id → book
nonisolated struct CategoryContentRecord: BaseRecord {
    static let databaseTableName = "category_content"

    var id: Int64?
    var categoryId: Int64 = 0
    var bookId: Int64 = 0
    var title: String?
    var content: String?
    /// 关联的内容书籍 ID
    var contentBookId: Int64 = 0
    var url: String?

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, content, url
        case categoryId = "category_id"
        case bookId = "book_id"
        case contentBookId = "content_book_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
