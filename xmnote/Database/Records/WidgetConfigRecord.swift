import Foundation
import GRDB

/// 小组件配置表，对应 Android WidgetConfigEntity
nonisolated struct WidgetConfigRecord: BaseRecord {
    static let databaseTableName = "widget_config"

    var id: Int64?
    var widgetId: Int64 = 0
    var type: Int64 = 0
    var themeId: Int64 = 0
    var patternId: Int64 = -1
    var bookIds: String = ""
    var tagIds: String = ""
    var refreshInterval: Int64 = 0
    var fontSize: Int64 = 2
    var sortType: Int64 = 0
    /// 是否加密保护: 0=否, 1=是
    var isProtected: Int64 = 0
    var statisticsDataType: Int64 = 0
    var displayElements: Int64 = 0
    var transparent: Int64 = 100
    /// 筛选规则是否为 OR: 1=OR, 0=AND
    var filterRuleIsOr: Int64 = 1

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, type, transparent
        case widgetId = "widget_id"
        case themeId = "theme_id"
        case patternId = "pattern_id"
        case bookIds = "book_ids"
        case tagIds = "tag_ids"
        case refreshInterval = "refresh_interval"
        case fontSize = "font_size"
        case sortType = "sort_type"
        case isProtected = "is_protected"
        case statisticsDataType = "statistics_data_type"
        case displayElements = "display_elements"
        case filterRuleIsOr = "filter_rule_is_or"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
