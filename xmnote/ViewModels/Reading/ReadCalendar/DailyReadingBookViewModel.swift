/**
 * [INPUT]: 依赖 ReadCalendarRepositoryProtocol 与 ContentRepositoryProtocol 获取、筛选并物理删除单书当日记录
 * [OUTPUT]: 对外提供 DailyReadingBookViewModel，驱动三级记录流、筛选、排序与写入反馈
 * [POS]: Reading/ReadCalendar 三级页面状态中枢，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 单书当日记录页状态中枢；筛选与排序变化会取消前一读取任务，写入后以数据库重查收敛。
@MainActor
@Observable
final class DailyReadingBookViewModel {
    let date: Date
    let bookSummary: DailyReadingBookSummary
    var filter: DailyReadingTimelineFilter = .all
    var sortOrder: DailyReadingSortOrder = .descending
    private(set) var records: [DailyReadingRecord] = []
    private(set) var loadPhase: DailyReadingLoadPhase = .idle
    private(set) var errorMessage: String?
    private(set) var isWriting = false

    private var loadTask: Task<Void, Never>?
    private var requestToken: UInt64 = 0

    /// 以日期和单书摘要初始化三级页；列表本身仍会从 Repository 重新读取。
    init(date: Date, bookSummary: DailyReadingBookSummary) {
        self.date = Calendar.current.startOfDay(for: date)
        self.bookSummary = bookSummary
    }

    var dateSubtitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 首次进入时读取记录。
    func loadIfNeeded(using repository: any ReadCalendarRepositoryProtocol) async {
        guard loadPhase == .idle else { return }
        await reload(using: repository)
    }

    /// 按当前筛选和排序读取记录；取消和 token 双重保护避免旧请求覆盖新选择。
    func reload(using repository: any ReadCalendarRepositoryProtocol) async {
        loadTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        loadPhase = .loading
        errorMessage = nil

        let requestedFilter = filter
        let requestedSort = sortOrder
        let task = Task {
            do {
                let result = try await repository.fetchDailyBookRecords(
                    for: date,
                    bookID: bookSummary.book.id,
                    filter: requestedFilter,
                    sortOrder: requestedSort
                )
                guard !Task.isCancelled, token == requestToken else { return }
                records = result
                loadPhase = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, token == requestToken else { return }
                errorMessage = error.localizedDescription
                loadPhase = .failed
            }
        }
        loadTask = task
        await task.value
    }

    /// 切换筛选后立即刷新，旧筛选请求不会回写。
    func selectFilter(
        _ newFilter: DailyReadingTimelineFilter,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        guard filter != newFilter else { return }
        filter = newFilter
        await reload(using: repository)
    }

    /// 切换排序后立即刷新，保留当前筛选。
    func selectSort(
        _ newSortOrder: DailyReadingSortOrder,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        guard sortOrder != newSortOrder else { return }
        sortOrder = newSortOrder
        await reload(using: repository)
    }

    /// 按事件真实类型调用对应 Repository 的物理删除事务，成功后重查当前记录流。
    func delete(
        _ record: DailyReadingRecord,
        readCalendarRepository: any ReadCalendarRepositoryProtocol,
        contentRepository: any ContentRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }

        switch record.event.kind {
        case .checkIn:
            try await readCalendarRepository.deleteCheckIn(recordID: record.recordID)
        case .readTiming:
            try await readCalendarRepository.deleteTiming(recordID: record.recordID)
        case .note(let note):
            try await contentRepository.delete(itemID: .note(note.noteId))
        case .review(let review):
            try await contentRepository.delete(itemID: .review(review.reviewId))
        case .relevant(let relevant):
            try await contentRepository.delete(itemID: .relevant(relevant.contentId))
        case .relevantBook(let relevantBook):
            try await contentRepository.deleteRelatedRelation(relationID: record.recordID)
            _ = relevantBook
        case .readStatus:
            return
        }
        await reload(using: readCalendarRepository)
    }

    /// 更新打卡后重新查询当前筛选，写入期间阻止重复提交。
    func updateCheckIn(
        recordID: Int64,
        bookID: Int64,
        amount: Int,
        using repository: any ReadCalendarRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await repository.saveCheckIn(
            ReadCalendarCheckInDraft(
                recordID: recordID,
                bookID: bookID,
                amount: amount,
                date: date
            )
        )
        await reload(using: repository)
    }

    /// 更新阅读计时后重新查询当前筛选，Repository 负责时间校验与读完状态事务。
    func updateTiming(
        _ draft: ReadCalendarTimingDraft,
        using repository: any ReadCalendarRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await repository.updateTiming(draft)
        await reload(using: repository)
    }

    /// 页面离开时取消读取任务，写入任务由调用方结构化并发负责等待完成。
    func cancel() {
        requestToken &+= 1
        loadTask?.cancel()
        loadTask = nil
    }
}
