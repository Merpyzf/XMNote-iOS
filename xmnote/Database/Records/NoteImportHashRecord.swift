/**
 * [INPUT]: 依赖 GRDB Record 协议与 Android Room v45 note_import_hash 表结构
 * [OUTPUT]: 对外提供 NoteImportHashRecord，映射按书保存的导入内容 Hash 与冲突忽略语义
 * [POS]: Database/Records 层单表映射模型，供后续书摘导入去重链路通过 Repository 使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 按书保存的导入内容 Hash；复合主键避免同一本书重复记录相同内容。
nonisolated struct NoteImportHashRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_import_hash"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .ignore, update: .abort)

    var bookId: Int64
    var contentHash: String
    var noteId: Int64

    /// 映射 Swift 属性名与 Android Room snake_case 字段名。
    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case contentHash = "content_hash"
        case noteId = "note_id"
    }
}
