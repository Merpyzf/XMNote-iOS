/**
 * [INPUT]: 依赖 GRDB Record 协议与 Android Room v46 notion_page_sync 表结构
 * [OUTPUT]: 对外提供 NotionPageSyncRecord，完整映射页面级同步和快速判断基线
 * [POS]: Database/Records 层单表映射模型；当前只服务 schema/恢复兼容，不开放 Notion 业务入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 一本书在一个 Notion 数据源中的持续同步页面映射。
nonisolated struct NotionPageSyncRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notion_page_sync"

    var id: Int64?
    var connectionKey: String
    var dataSourceId: String
    var scope: String
    var bookId: Int64
    var syncId: String
    var pageId: String
    var pageUrl: String
    var status: String
    var conflictCount: Int
    var firstSyncDate: Int64
    var lastSyncDate: Int64
    var sourceFingerprint: String = ""
    var remoteLastEditedTime: String = ""
    var lastExportedTitle: String = ""

    /// 映射 Swift 属性名与 Android Room snake_case 字段名。
    enum CodingKeys: String, CodingKey {
        case id, scope, status
        case connectionKey = "connection_key"
        case dataSourceId = "data_source_id"
        case bookId = "book_id"
        case syncId = "sync_id"
        case pageId = "page_id"
        case pageUrl = "page_url"
        case conflictCount = "conflict_count"
        case firstSyncDate = "first_sync_date"
        case lastSyncDate = "last_sync_date"
        case sourceFingerprint = "source_fingerprint"
        case remoteLastEditedTime = "remote_last_edited_time"
        case lastExportedTitle = "last_exported_title"
    }

    /// 在数据库插入后回填自增主键。
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
