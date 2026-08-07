/**
 * [INPUT]: 依赖 GRDB Database/Row、sort 与 note 表，以及 BookContentSortType/Rule 领域模型
 * [OUTPUT]: 对外提供 BookContentSortQuery，统一解析单书排序偏好并生成稳定的书摘顺序
 * [POS]: Data/Repositories 只读查询协作者，被 BookReadQuery 与 ContentRepository 共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 单书内容排序查询协作者，收口 Android `SortRepository` 的默认值、类型常量与书摘比较规则。
nonisolated enum BookContentSortQuery {
    private static let weReadSourceID: Int64 = 4
    private static let iReaderEBookSourceID: Int64 = 24

    /// 读取同一本书三个内容类型互不共享的排序规则；未落库的书摘规则会按全书 weread_range 判定。
    static func fetchPreferences(_ db: Database, bookID: Int64) throws -> BookContentSortPreferences {
        guard bookID > 0 else { return .fallback }
        return BookContentSortPreferences(
            notes: try fetchRule(db, bookID: bookID, type: .notes),
            related: try fetchRule(db, bookID: bookID, type: .related),
            reviews: try fetchRule(db, bookID: bookID, type: .reviews)
        )
    }

    /// 读取指定 `(book_id, type)` 的有效记录并规范历史异常值；没有记录时复刻 Android 首次默认规则。
    static func fetchRule(
        _ db: Database,
        bookID: Int64,
        type: BookContentSortType
    ) throws -> BookContentSortRule {
        // SQL 目的：读取单本书、单内容类型当前有效的持久化排序规则。
        // 涉及表：sort。
        // 关键过滤：book_id/type 精确匹配且 is_deleted=0；历史重复记录以最早主键稳定读取，正常写入会同步更新全部有效重复项。
        // 时间字段：不读取时间字段。
        // 返回字段用途：将 Android sort.order 映射为 BookContentSortRule。
        let persistedSQL = """
            SELECT "order"
            FROM sort
            WHERE book_id = ? AND type = ? AND is_deleted = 0
            ORDER BY id ASC
            LIMIT 1
            """
        if let rawValue = try Int64.fetchOne(
            db,
            sql: persistedSQL,
            arguments: [bookID, type.rawValue]
        ) {
            return normalizedRule(rawValue: rawValue, type: type)
        }

        guard type == .notes else { return .createdDateAscending }

        // SQL 目的：判断当前书是否存在 weread_range 为空的有效书摘，复刻 Android SortRepository 的首次默认分支。
        // 涉及表：note。
        // 关键过滤：限定 book_id、is_deleted=0，并把 NULL weread_range 视为空；计数为零时（包括空书）默认按位置由前到后。
        // 时间字段：不读取或转换时间字段。
        // 返回字段用途：决定未持久化 NOTE 排序是 ASC_BY_POSITION 还是 ASC_BY_CREATED_DATE。
        let blankRangeSQL = """
            SELECT COUNT(*)
            FROM note
            WHERE book_id = ?
              AND is_deleted = 0
              AND COALESCE(weread_range, '') = ''
            """
        let blankRangeCount = try Int.fetchOne(db, sql: blankRangeSQL, arguments: [bookID]) ?? 0
        return blankRangeCount == 0 ? .positionAscending : .createdDateAscending
    }

    /// 按 Android 书摘来源语义排序查询结果，并始终用 note.id 作为同值时的稳定兜底。
    static func sortedNoteRows(
        _ rows: [Row],
        rule: BookContentSortRule
    ) -> [Row] {
        guard rows.count > 1 else { return rows }
        let entries = rows.map(NoteSortEntry.init)
        let sourceID = entries.first?.sourceID ?? 1
        let isAscending = rule == .createdDateAscending || rule == .positionAscending

        let primary: (NoteSortEntry, NoteSortEntry) -> ComparisonResult
        switch rule {
        case .createdDateAscending, .createdDateDescending:
            let shouldUseIDAsTime = sourceID == weReadSourceID
                && entries.allSatisfy { !$0.includesTime }
            primary = shouldUseIDAsTime
                ? { compare($0.id, $1.id) }
                : { compare($0.createdDate, $1.createdDate) }
        case .positionAscending, .positionDescending:
            if sourceID == weReadSourceID,
               entries.allSatisfy({ !$0.weReadRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                primary = { compare(rangeStart($0.weReadRange), rangeStart($1.weReadRange)) }
            } else if sourceID == iReaderEBookSourceID {
                primary = { compare($0.position, $1.position) }
            } else if entries.contains(where: { positionNumber($0.position).rounded() != 0 }) {
                primary = { compare(positionNumber($0.position), positionNumber($1.position)) }
            } else {
                primary = { compare($0.id, $1.id) }
            }
        }

        return entries.sorted { lhs, rhs in
            let primaryResult = primary(lhs, rhs)
            if primaryResult != .orderedSame {
                return isAscending
                    ? primaryResult == .orderedAscending
                    : primaryResult == .orderedDescending
            }
            return isAscending ? lhs.id < rhs.id : lhs.id > rhs.id
        }.map(\.row)
    }

    /// 校验某内容类型是否允许目标规则，供 Repository 写入门闩复用。
    static func isRuleAllowed(_ rule: BookContentSortRule, for type: BookContentSortType) -> Bool {
        BookContentSortRule.allowedRules(for: type).contains(rule)
    }

    /// 将历史非法 order 值收敛到 Android 菜单实际选中分支，避免页面出现无选择状态。
    private static func normalizedRule(
        rawValue: Int64,
        type: BookContentSortType
    ) -> BookContentSortRule {
        guard let rule = BookContentSortRule(rawValue: rawValue) else {
            return type == .notes ? .positionDescending : .createdDateDescending
        }
        return isRuleAllowed(rule, for: type)
            ? rule
            : (type == .notes ? .positionDescending : .createdDateDescending)
    }

    /// 解析 Android RegexUtil.getNotePosNum 等价的范围起点数字。
    private static func positionNumber(_ value: String) -> Double {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("#") {
            candidate.removeFirst()
        }
        if let separator = candidate.firstIndex(of: "-") {
            candidate = String(candidate[..<separator])
        }
        return Double(candidate) ?? 0
    }

    /// 解析微信读书 `start-end` range 的起点；无效值按 Android 行为回退为零。
    private static func rangeStart(_ value: String) -> Int64 {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return 0 }
        return Int64(pieces[0]) ?? 0
    }

    /// 比较整数排序键，统一返回 Foundation 三态结果供升降序分支复用。
    private static func compare(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    /// 比较位置小数排序键；所有输入均由解析器收敛为有限值或零。
    private static func compare(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    /// 比较 iReader 原始位置文本，保持 Android 字符串位置顺序语义。
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}

/// 缓存一次 Row 字段解析，避免排序比较器在 O(n log n) 路径重复做字符串与数据库值转换。
private nonisolated struct NoteSortEntry {
    let row: Row
    let id: Int64
    let createdDate: Int64
    let position: String
    let weReadRange: String
    let includesTime: Bool
    let sourceID: Int64

    /// 从 BookReadQuery/ContentRepository 约定的列别名读取稳定排序字段。
    init(row: Row) {
        self.row = row
        id = row["id"] ?? 0
        createdDate = row["created_date"] ?? 0
        position = row["position"] ?? ""
        weReadRange = row["weread_range"] ?? ""
        includesTime = (row["include_time"] as Int64? ?? 0) != 0
        sourceID = row["source_id"] ?? 1
    }
}
