/**
 * [INPUT]: 依赖 Foundation、阅读日历领域模型与 Timeline 领域模型
 * [OUTPUT]: 对外提供 ReadCalendarRepositoryProtocol，统一事件/书籍筛选后的月年聚合、当日时间线及写入契约
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
    /// 观察所有会影响日历、当日汇总与单书记录的本地数据变化。
    @MainActor func observeDailyReadingChanges() -> AsyncThrowingStream<Void, Error>

    /// 按 Android 全局统计来源读取最早业务日期；展示筛选不改变日历可回溯下界。
    func fetchEarliestDate(excludedEventTypes: Set<ReadCalendarEventType>) async throws -> Date?

    /// 读取单月日历、排行和摘要聚合结果。
    func fetchMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>,
        excludedBookIDs: Set<Int64>
    ) async throws -> ReadCalendarMonthData

    /// 读取指定自然年的阅读时长排行。
    func fetchYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int,
        includedMonthStarts: Set<Date>?,
        excludedBookIDs: Set<Int64>
    ) async throws -> [ReadCalendarMonthlyDurationBook]

    /// 按日历事件筛选重新计算当日书籍与指标，禁止使用另一套独立书籍集合。
    func fetchDailySummary(
        for date: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> DailyReadingSummary

    /// 读取指定自然日的完整阅读轨迹；bookID 为空时返回全部书籍记录，日历展示筛选不影响结果。
    func fetchDailyTrajectory(
        for date: Date,
        selectedBookID: Int64?,
        filter: DailyReadingTimelineFilter,
        sortOrder: DailyReadingSortOrder
    ) async throws -> DailyReadingTrajectory

    /// 新增或更新打卡；recordID 为空时按 Android 的“同书同日覆盖”语义保存。
    func saveCheckIn(_ draft: ReadCalendarCheckInDraft) async throws

    /// 更新阅读计时，并可在同一事务内追加读完状态记录。
    func updateTiming(_ draft: ReadCalendarTimingDraft) async throws

    /// 按 Android CheckInRecordDao.delete 语义物理删除指定打卡记录。
    func deleteCheckIn(recordID: Int64) async throws

    /// 按 Android ReadTimeRecordDao.delete 语义写入指定阅读计时记录的删除 tombstone。
    func deleteTiming(recordID: Int64) async throws
}

extension ReadCalendarRepositoryProtocol {
    /// 无书籍排除时的常规月查询入口。
    func fetchMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData {
        try await fetchMonthData(
            monthStart: monthStart,
            excludedEventTypes: excludedEventTypes,
            excludedBookIDs: []
        )
    }

    /// 使用 Android 默认年度有效范围且不排除书籍的排行入口。
    func fetchYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        try await fetchYearTopBooks(
            year: year,
            excludedEventTypes: excludedEventTypes,
            limit: limit,
            includedMonthStarts: nil,
            excludedBookIDs: []
        )
    }

    /// 未配置展示筛选时的当日汇总入口。
    func fetchDailySummary(for date: Date) async throws -> DailyReadingSummary {
        try await fetchDailySummary(for: date, excludedEventTypes: [])
    }
}
