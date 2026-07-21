/**
 * [INPUT]: 依赖 Foundation、阅读日历领域模型与 Timeline 领域模型
 * [OUTPUT]: 对外提供 ReadCalendarRepositoryProtocol，统一阅读日历聚合、当日时间线及打卡/计时写入契约
 * [POS]: Domain/Repositories 层阅读日历专属仓储契约，被阅读日历相关 ViewModel 统一依赖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 阅读日历写入校验错误，供 ViewModel 映射为可感知反馈。
enum ReadCalendarRepositoryError: LocalizedError {
    case invalidBook
    case invalidCheckInAmount
    case invalidTimingRange
    case futureDate
    case recordNotFound

    var errorDescription: String? {
        switch self {
        case .invalidBook: "书籍信息异常，请重新选择书籍"
        case .invalidCheckInAmount: "请选择有效的阅读量"
        case .invalidTimingRange: "阅读开始时间必须早于结束时间，且阅读时长不能为零"
        case .futureDate: "阅读记录时间不能晚于当前时间"
        case .recordNotFound: "记录不存在或已被删除"
        }
    }
}

/// 阅读日历仓储契约，确保日历、摘要、时间线与分享复用同一业务口径。
protocol ReadCalendarRepositoryProtocol {
    /// 读取启用事件源中的最早业务日期，作为日历可回溯下界。
    func fetchEarliestDate(excludedEventTypes: Set<ReadCalendarEventType>) async throws -> Date?

    /// 读取单月日历、排行和摘要聚合结果。
    func fetchMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData

    /// 读取指定自然年的阅读时长排行。
    func fetchYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook]

    /// 重新按目标日期计算当日全部书籍与指标，禁止依赖导航参数中的书籍快照。
    func fetchDailySummary(for date: Date) async throws -> DailyReadingSummary

    /// 读取某书在指定自然日内的可管理记录，按过滤类型与排序方向返回。
    func fetchDailyBookRecords(
        for date: Date,
        bookID: Int64,
        filter: DailyReadingTimelineFilter,
        sortOrder: DailyReadingSortOrder
    ) async throws -> [DailyReadingRecord]

    /// 新增或更新打卡；recordID 为空时按 Android 的“同书同日覆盖”语义保存。
    func saveCheckIn(_ draft: ReadCalendarCheckInDraft) async throws

    /// 更新阅读计时，并可在同一事务内追加读完状态记录。
    func updateTiming(_ draft: ReadCalendarTimingDraft) async throws

    /// 物理删除指定打卡记录。
    func deleteCheckIn(recordID: Int64) async throws

    /// 物理删除指定阅读计时记录。
    func deleteTiming(recordID: Int64) async throws
}
