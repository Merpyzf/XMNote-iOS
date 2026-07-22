import Foundation

/**
 * [INPUT]: 依赖 ReadCalendarRepositoryProtocol、ReadCalendarShareModels 与 ReadCalendarSettings
 * [OUTPUT]: 对外提供 ReadCalendarShareViewModel，驱动分享预览、访问范围遮罩、完整贡献排行及排除书籍后的月年重算
 * [POS]: Reading/ReadCalendar 分享页状态中枢，所有读取统一经 Repository 完成
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历分享状态中枢；新选择会取消旧请求，并通过 token 防止过期数据回写预览。
@MainActor
@Observable
final class ReadCalendarShareViewModel {
    var shareType: ReadCalendarShareType
    var template: ReadCalendarShareTemplate = .pureWhite
    var rankingDisplayCount = 3
    private(set) var excludedBookIDs: Set<Int64> = []
    var selectedMonth: Date
    private(set) var snapshot: ReadCalendarShareSnapshot?
    private(set) var availableMonths: [Date]
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let settings: ReadCalendarSettings
    private var loadTask: Task<Void, Never>?
    private var requestToken: UInt64 = 0
    private var unfilteredSnapshot: ReadCalendarShareSnapshot?
    private var minimumAccessibleMonthStart: Date?

    /// 以入口月份和日历显示模式初始化分享选项。
    init(
        monthStart: Date,
        initialType: ReadCalendarShareType,
        settings: ReadCalendarSettings? = nil
    ) {
        self.selectedMonth = Self.monthStart(monthStart)
        self.availableMonths = [Self.monthStart(monthStart)]
        self.shareType = initialType
        self.settings = settings ?? ReadCalendarSettings()
    }

    var selectedYear: Int {
        Calendar.current.component(.year, from: selectedMonth)
    }

    var visibleTopBooks: [ReadCalendarMonthlyDurationBook] {
        let ranking = shareType == .yearHeatmap
            ? snapshot?.yearTopBooks ?? []
            : snapshot?.monthData.readingDurationTopBooks ?? []
        return ranking
            .prefix(rankingDisplayCount)
            .map { $0 }
    }

    var filterBooks: [ReadCalendarBookContribution] {
        scopedBooks(in: unfilteredSnapshot ?? snapshot)
    }

    /// 汇总当前已应用书籍排除的完整贡献，排行榜不再依赖各月 Top 10 截断结果。
    private var scopedBooks: [ReadCalendarBookContribution] {
        scopedBooks(in: snapshot)
    }

    /// 按当前分享周期合并全量书籍贡献，并对齐 Android 的秒数、活跃天数、名称与 ID 排序。
    private func scopedBooks(in snapshot: ReadCalendarShareSnapshot?) -> [ReadCalendarBookContribution] {
        guard let snapshot else { return [] }
        let months = shareType == .yearHeatmap ? snapshot.yearMonths : [snapshot.monthData]
        var booksByID: [Int64: ReadCalendarBookContribution] = [:]

        for month in months {
            for contribution in month.bookContributions {
                let previous = booksByID[contribution.bookId]
                booksByID[contribution.bookId] = ReadCalendarBookContribution(
                    bookId: contribution.bookId,
                    name: contribution.name,
                    coverURL: contribution.coverURL,
                    readSeconds: (previous?.readSeconds ?? 0) + contribution.readSeconds,
                    activeDays: (previous?.activeDays ?? 0) + contribution.activeDays
                )
            }
        }

        return booksByID.values.sorted {
            if $0.readSeconds != $1.readSeconds { return $0.readSeconds > $1.readSeconds }
            if $0.activeDays != $1.activeDays { return $0.activeDays > $1.activeDays }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.bookId < $1.bookId
        }
    }

    /// 首次进入时加载月与年度预览数据。
    func loadIfNeeded(using repository: any ReadCalendarRepositoryProtocol) async {
        guard snapshot == nil, !isLoading else { return }
        await reload(using: repository)
    }

    /// 切换月份并刷新预览，旧月份请求被取消后不能覆盖当前选择。
    func selectMonth(_ date: Date, using repository: any ReadCalendarRepositoryProtocol) async {
        let normalized = Self.monthStart(date)
        guard normalized != selectedMonth else { return }
        selectedMonth = normalized
        excludedBookIDs = []
        unfilteredSnapshot = nil
        await reload(using: repository)
    }

    /// 更新免费账号可访问下界；年度分享会像 Android 一样把更早月份替换为零值遮罩。
    func updateAccessBoundary(minimumAccessibleMonthStart: Date?) {
        self.minimumAccessibleMonthStart = minimumAccessibleMonthStart.map(Self.monthStart)
    }

    /// 应用分享书籍排除并重跑月/年聚合，使热力、摘要、排行和贡献使用同一书籍集合。
    func changeExcludedBooks(
        _ bookIDs: Set<Int64>,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        guard bookIDs != excludedBookIDs else { return }
        excludedBookIDs = bookIDs
        await reload(using: repository)
    }

    /// 切换单本书籍排除状态，并立即以 Android 聚合口径刷新预览。
    func toggleExcludedBook(
        _ bookID: Int64,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        var next = excludedBookIDs
        if !next.insert(bookID).inserted {
            next.remove(bookID)
        }
        await changeExcludedBooks(next, using: repository)
    }

    /// 同时读取目标月与目标年度 12 个月份；任务取消时丢弃未完成快照。
    func reload(using repository: any ReadCalendarRepositoryProtocol) async {
        loadTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        let requestedMonth = selectedMonth
        let excludedTypes = settings.excludedEventTypes
        let requestedExcludedBookIDs = excludedBookIDs
        let requestedMinimumAccessibleMonthStart = minimumAccessibleMonthStart
        isLoading = true
        errorMessage = nil

        let task = Task {
            do {
                let earliestDate = try await repository.fetchEarliestDate(excludedEventTypes: excludedTypes)
                let monthData = try await repository.fetchMonthData(
                    monthStart: requestedMonth,
                    excludedEventTypes: excludedTypes,
                    excludedBookIDs: requestedExcludedBookIDs
                )
                let year = Calendar.current.component(.year, from: requestedMonth)
                let starts = Self.monthStarts(in: year)
                var yearMonths: [ReadCalendarMonthData] = []
                yearMonths.reserveCapacity(starts.count)
                let currentMonth = Self.monthStart(Date())
                var includedMonthStarts = Set<Date>()
                for monthStart in starts {
                    try Task.checkCancellation()
                    let isLocked = requestedMinimumAccessibleMonthStart.map {
                        monthStart < $0
                    } ?? false
                    if monthStart > currentMonth || isLocked {
                        yearMonths.append(.empty(for: monthStart))
                    } else if monthStart == requestedMonth {
                        includedMonthStarts.insert(monthStart)
                        yearMonths.append(monthData)
                    } else {
                        includedMonthStarts.insert(monthStart)
                        yearMonths.append(
                            try await repository.fetchMonthData(
                                monthStart: monthStart,
                                excludedEventTypes: excludedTypes,
                                excludedBookIDs: requestedExcludedBookIDs
                            )
                        )
                    }
                }
                let yearTopBooks = try await repository.fetchYearTopBooks(
                    year: year,
                    excludedEventTypes: excludedTypes,
                    limit: 10,
                    includedMonthStarts: includedMonthStarts,
                    excludedBookIDs: requestedExcludedBookIDs
                )
                guard !Task.isCancelled, token == requestToken else { return }
                availableMonths = Self.availableMonthStarts(
                    from: earliestDate.map(Self.monthStart) ?? requestedMonth,
                    through: Self.monthStart(Date())
                )
                let nextSnapshot = ReadCalendarShareSnapshot(
                    selectedMonth: requestedMonth,
                    monthData: monthData,
                    yearMonths: yearMonths,
                    yearTopBooks: yearTopBooks
                )
                snapshot = nextSnapshot
                if requestedExcludedBookIDs.isEmpty {
                    unfilteredSnapshot = nextSnapshot
                }
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, token == requestToken else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
        loadTask = task
        await task.value
    }

    /// 页面退出时取消年度聚合，避免无消费者的数据库查询继续执行。
    func cancel() {
        requestToken &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    /// 把任意日期规整到本地自然月首日。
    private static func monthStart(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    /// 生成指定年份 12 个自然月起点。
    private static func monthStarts(in year: Int) -> [Date] {
        let calendar = Calendar.current
        guard let january = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return [] }
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: january) }
    }

    /// 生成最早业务月份到当前月的连续可选列表，保证空月份也可生成分享卡。
    private static func availableMonthStarts(from earliest: Date, through latest: Date) -> [Date] {
        let calendar = Calendar.current
        var cursor = monthStart(earliest)
        let end = max(cursor, monthStart(latest))
        var result: [Date] = []
        while cursor <= end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}
