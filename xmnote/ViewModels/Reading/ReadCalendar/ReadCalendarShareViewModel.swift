import Foundation

/**
 * [INPUT]: 依赖 ReadCalendarRepositoryProtocol、ReadCalendarShareModels 与 ReadCalendarSettings
 * [OUTPUT]: 对外提供 ReadCalendarShareViewModel，驱动分享预览、月份切换、排行与排除书籍状态
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
    var excludedBookIDs: Set<Int64> = []
    var selectedMonth: Date
    private(set) var snapshot: ReadCalendarShareSnapshot?
    private(set) var availableMonths: [Date]
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let settings: ReadCalendarSettings
    private var loadTask: Task<Void, Never>?
    private var requestToken: UInt64 = 0

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
        scopedBooks
            .filter { $0.readSeconds > 0 }
            .filter { !excludedBookIDs.contains($0.bookId) }
            .prefix(rankingDisplayCount)
            .map { $0 }
    }

    var filterBooks: [ReadCalendarMonthlyDurationBook] {
        scopedBooks
    }

    /// 汇总当前分享周期内全部活跃书籍；无计时但有打卡/书摘的书也必须进入排除列表。
    private var scopedBooks: [ReadCalendarMonthlyDurationBook] {
        guard let snapshot else { return [] }
        let months = shareType == .yearHeatmap ? snapshot.yearMonths : [snapshot.monthData]
        var booksByID: [Int64: ReadCalendarMonthlyDurationBook] = [:]

        for month in months {
            for ranking in month.readingDurationTopBooks {
                let accumulatedSeconds = (booksByID[ranking.bookId]?.readSeconds ?? 0) + ranking.readSeconds
                booksByID[ranking.bookId] = ReadCalendarMonthlyDurationBook(
                    bookId: ranking.bookId,
                    name: ranking.name,
                    coverURL: ranking.coverURL,
                    readSeconds: accumulatedSeconds
                )
            }
            for day in month.days.values.sorted(by: { $0.date < $1.date }) {
                for book in day.books where booksByID[book.id] == nil {
                    booksByID[book.id] = ReadCalendarMonthlyDurationBook(
                        bookId: book.id,
                        name: book.name,
                        coverURL: book.coverURL,
                        readSeconds: 0
                    )
                }
            }
        }

        return booksByID.values.sorted {
            if $0.readSeconds != $1.readSeconds { return $0.readSeconds > $1.readSeconds }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        await reload(using: repository)
    }

    /// 同时读取目标月与目标年度 12 个月份；任务取消时丢弃未完成快照。
    func reload(using repository: any ReadCalendarRepositoryProtocol) async {
        loadTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        let requestedMonth = selectedMonth
        let excludedTypes = settings.excludedEventTypes
        isLoading = true
        errorMessage = nil

        let task = Task {
            do {
                let earliestDate = try await repository.fetchEarliestDate(excludedEventTypes: excludedTypes)
                let monthData = try await repository.fetchMonthData(
                    monthStart: requestedMonth,
                    excludedEventTypes: excludedTypes
                )
                let year = Calendar.current.component(.year, from: requestedMonth)
                let starts = Self.monthStarts(in: year)
                var yearMonths: [ReadCalendarMonthData] = []
                yearMonths.reserveCapacity(starts.count)
                for monthStart in starts {
                    try Task.checkCancellation()
                    if monthStart == requestedMonth {
                        yearMonths.append(monthData)
                    } else {
                        yearMonths.append(
                            try await repository.fetchMonthData(
                                monthStart: monthStart,
                                excludedEventTypes: excludedTypes
                            )
                        )
                    }
                }
                guard !Task.isCancelled, token == requestToken else { return }
                availableMonths = Self.availableMonthStarts(
                    from: earliestDate.map(Self.monthStart) ?? requestedMonth,
                    through: Self.monthStart(Date())
                )
                snapshot = ReadCalendarShareSnapshot(
                    selectedMonth: requestedMonth,
                    monthData: monthData,
                    yearMonths: yearMonths
                )
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
