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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
