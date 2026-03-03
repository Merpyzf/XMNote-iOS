import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 StatisticsRepositoryProtocol 提供月历聚合数据，依赖 ReadCalendarColorRepositoryProtocol 提供封面取色，依赖 ReadCalendarEventLayoutEngine 生成事件条布局
 * [OUTPUT]: 对外提供 ReadCalendarViewModel（阅读日历页面状态、分页切月/快速跳转、跨周事件条布局、事件条颜色异步回填、月度阅读时长排行与月度摘要透传）
 * [POS]: ReadCalendar 子功能状态中枢，负责数据加载、分页状态、选中态、周布局构建、快速跳月与封面取色任务编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class ReadCalendarViewModel {
    private struct ReadCalendarColorRequest: Hashable {
        let bookId: Int64
        let bookName: String
        let coverURL: String
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        formatter.timeZone = .current
        return formatter
    }()

    private static let yearTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年"
        formatter.timeZone = .current
        return formatter
    }()

    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = .current
        return formatter
    }()

    private static let colorBatchCount = 8
    private static let colorBatchInterval: TimeInterval = 0.12
    private static let yearTopBookLimit = 10

    struct WeekRowData: Identifiable, Hashable {
        let weekStart: Date
        let days: [Date?]
        let segments: [ReadCalendarEventSegment]

        var id: Date { weekStart }
    }

    enum MonthLoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    struct MonthPageState: Hashable {
        let monthStart: Date
        let weeks: [WeekRowData]
        let dayMap: [Date: ReadCalendarDay]
        let readingDurationTopBooks: [ReadCalendarMonthlyDurationBook]
        let summary: ReadCalendarMonthSummary
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let loadState: MonthLoadState
        let errorMessage: String?

        var isLoading: Bool {
            loadState == .loading
        }
    }

    enum YearLoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    struct YearMonthContribution: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalReadSeconds: Int

        var id: Date { monthStart }
    }

    struct YearSummaryState: Hashable {
        let year: Int
        let activeDays: Int
        let totalReadSeconds: Int
        let noteCount: Int
        let finishedBookCount: Int
        let monthContributions: [YearMonthContribution]
        let topBooks: [ReadCalendarMonthlyDurationBook]
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let isLoading: Bool
        let errorMessage: String?
    }

    enum RootContentState: Equatable {
        case loading
        case empty
        case content
    }

    var displayedMonthStart: Date
    var pagerSelection: Date
    var selectedDate: Date?
    var earliestMonthStart: Date?
    var availableMonths: [Date] = []
    var selectedYear: Int
    var availableYears: [Int] = []

    var isLoading = false
    var errorMessage: String?

    var laneLimit: Int { settings.dayEventCount }
    let renderMode: ReadCalendarRenderMode

    private let settings: ReadCalendarSettings
    private let initialDate: Date?
    private var hasLoaded = false
    private var monthCache: [String: ReadCalendarMonthData] = [:]
    private var pageStates: [String: MonthPageState] = [:]
    private var monthIndexByKey: [String: Int] = [:]
    private var yearTopBooksByYear: [Int: [ReadCalendarMonthlyDurationBook]] = [:]
    private var yearRankingBarColorsByYear: [Int: [Int64: ReadCalendarSegmentColor]] = [:]
    private var yearLoadStateByYear: [Int: YearLoadState] = [:]
    private var yearErrorMessageByYear: [Int: String] = [:]
    private var latestYearRequestTicketByYear: [Int: Int] = [:]
    private var latestYearColorTicketByYear: [Int: Int] = [:]
    private var latestRequestTicketByMonthKey: [String: Int] = [:]
    private var latestColorTicketByMonthKey: [String: Int] = [:]
    private var inFlightColorRequestBookIDsByMonthKey: [String: Set<Int64>] = [:]
    private var inFlightYearColorRequestBookIDsByYear: [Int: Set<Int64>] = [:]
    private var monthColorTasks: [String: Task<Void, Never>] = [:]
    private var yearColorTasks: [Int: Task<Void, Never>] = [:]
    private var requestTicketSeed = 0
    private var yearRequestTicketSeed = 0
    private var colorTicketSeed = 0
    private var yearColorTicketSeed = 0
    private var calendar: Calendar

    init(
        initialDate: Date?,
        settings: ReadCalendarSettings,
        renderMode: ReadCalendarRenderMode = .crossWeekContinuous
    ) {
        self.initialDate = initialDate
        self.settings = settings
        self.renderMode = renderMode

        var cal = Calendar.current
        cal.firstWeekday = 2 // 周一起始
        self.calendar = cal

        let today = cal.startOfDay(for: Date())
        let monthStart = Self.monthStart(of: today, using: cal)
        let defaultYear = cal.component(.year, from: initialDate ?? today)
        self.displayedMonthStart = monthStart
        self.pagerSelection = monthStart
        self.selectedDate = today
        self.selectedYear = defaultYear
    }

    var canGoPrevMonth: Bool {
        guard let index = monthIndex(for: pagerSelection) else { return false }
        return index > 0
    }

    var canGoNextMonth: Bool {
        guard let index = monthIndex(for: pagerSelection) else { return false }
        return index < (availableMonths.count - 1)
    }

    var todayMonthStart: Date {
        Self.currentMonthStart(using: calendar)
    }

    var canJumpToToday: Bool {
        isMonthInAvailableRange(todayMonthStart) && pagerSelection != todayMonthStart
    }

    var monthTitle: String {
        Self.monthTitleFormatter.string(from: pagerSelection)
    }

    var yearTitle: String {
        guard let date = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1)) else {
            return "\(selectedYear)年"
        }
        return Self.yearTitleFormatter.string(from: date)
    }

    var rootContentState: RootContentState {
        if isLoading && availableMonths.isEmpty {
            return .loading
        }
        if availableMonths.isEmpty {
            return .empty
        }
        return .content
    }

    func loadIfNeeded(
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        guard !hasLoaded else { return }
        await reload(using: repository, colorRepository: colorRepository)
    }

    func reload(
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let today = calendar.startOfDay(for: Date())

        do {
            let earliestDate = try await repository.fetchReadCalendarEarliestDate(
                excludedEventTypes: settings.excludedEventTypes
            )
            let earliest = Self.monthStart(of: earliestDate ?? today, using: calendar)
            let current = Self.currentMonthStart(using: calendar)
            earliestMonthStart = earliest

            rebuildMonthRange(from: earliest, to: current)
            rebuildYearRange(from: earliest, to: current)

            let preferredSelectedDate = clampSelectedDate(
                calendar.startOfDay(for: initialDate ?? today),
                earliestMonthStart: earliest,
                latestDate: today
            )
            selectedDate = preferredSelectedDate

            let preferredMonth = Self.monthStart(of: preferredSelectedDate, using: calendar)
            let defaultMonth = clampMonthStart(preferredMonth, earliest: earliest, latest: current)
            displayedMonthStart = defaultMonth
            pagerSelection = defaultMonth
            selectedYear = clampYear(calendar.component(.year, from: preferredSelectedDate))

            monthCache = [:]
            pageStates = [:]
            yearTopBooksByYear = [:]
            yearRankingBarColorsByYear = [:]
            yearLoadStateByYear = [:]
            yearErrorMessageByYear = [:]
            latestYearRequestTicketByYear = [:]
            latestYearColorTicketByYear = [:]
            latestRequestTicketByMonthKey = [:]
            latestColorTicketByMonthKey = [:]
            inFlightColorRequestBookIDsByMonthKey = [:]
            inFlightYearColorRequestBookIDsByYear = [:]
            cancelAllColorTasks()

            await ensureMonthLoaded(
                for: defaultMonth,
                using: repository,
                colorRepository: colorRepository,
                showLoading: true,
                forceRefresh: false,
                reportError: true
            )
            await prefetchAdjacentMonths(
                around: defaultMonth,
                using: repository,
                colorRepository: colorRepository
            )
            cancelOutOfScopeColorTasks(around: defaultMonth)
            syncDisplayedMonthError()
            hasLoaded = true
        } catch {
            errorMessage = "阅读日历加载失败：\(error.localizedDescription)"
            availableMonths = []
            availableYears = []
            monthIndexByKey = [:]
            pageStates = [:]
            yearTopBooksByYear = [:]
            yearRankingBarColorsByYear = [:]
            yearLoadStateByYear = [:]
            yearErrorMessageByYear = [:]
            latestYearRequestTicketByYear = [:]
            latestYearColorTicketByYear = [:]
            cancelAllColorTasks()
            hasLoaded = false
        }

        isLoading = false
    }

    func stepPager(offset: Int) {
        guard let target = monthAtOffset(offset, from: pagerSelection) else { return }
        pagerSelection = target
    }

    func jumpToToday() {
        let today = calendar.startOfDay(for: Date())
        let todayMonth = Self.monthStart(of: today, using: calendar)
        guard isMonthInAvailableRange(todayMonth) else { return }
        selectedDate = today
        pagerSelection = todayMonth
        selectedYear = clampYear(calendar.component(.year, from: todayMonth))
    }

    func handlePagerSelectionChange(
        to monthStart: Date,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        guard hasLoaded else { return }
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        guard isMonthInAvailableRange(normalized) else {
            pagerSelection = displayedMonthStart
            return
        }

        pagerSelection = normalized
        selectedYear = clampYear(calendar.component(.year, from: normalized))
        if normalized != displayedMonthStart {
            displayedMonthStart = normalized
            errorMessage = nil
        }

        await ensureMonthLoaded(
            for: normalized,
            using: repository,
            colorRepository: colorRepository,
            showLoading: true,
            forceRefresh: false,
            reportError: true
        )
        await prefetchAdjacentMonths(
            around: normalized,
            using: repository,
            colorRepository: colorRepository
        )
        cancelOutOfScopeColorTasks(around: normalized)
        syncDisplayedMonthError()
    }

    func handleYearSelectionChange(
        to year: Int,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        guard hasLoaded else { return }
        let clampedYear = clampYear(year)
        let hasLoadedYearData = yearLoadState(for: clampedYear) == .loaded
        let hasYearError = yearErrorMessageByYear[clampedYear] != nil
        selectedYear = clampedYear

        if !hasLoadedYearData || hasYearError {
            await ensureYearLoaded(
                for: clampedYear,
                using: repository,
                colorRepository: colorRepository,
                reportError: false
            )
        }
        await ensureYearTopBooksLoaded(
            for: clampedYear,
            using: repository,
            colorRepository: colorRepository
        )
        await preloadComparisonYearIfNeeded(
            for: clampedYear,
            using: repository,
            colorRepository: colorRepository
        )
    }

    func prepareHeatmapYearIfNeeded(
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        guard hasLoaded else { return }
        selectedYear = clampYear(selectedYear)
        await ensureYearLoaded(
            for: selectedYear,
            using: repository,
            colorRepository: colorRepository,
            reportError: false
        )
        await ensureYearTopBooksLoaded(
            for: selectedYear,
            using: repository,
            colorRepository: colorRepository
        )
        await preloadComparisonYearIfNeeded(
            for: selectedYear,
            using: repository,
            colorRepository: colorRepository
        )
    }

    func retryDisplayedMonth(
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        await ensureMonthLoaded(
            for: displayedMonthStart,
            using: repository,
            colorRepository: colorRepository,
            showLoading: true,
            forceRefresh: true,
            reportError: true
        )
        await prefetchAdjacentMonths(
            around: displayedMonthStart,
            using: repository,
            colorRepository: colorRepository
        )
        cancelOutOfScopeColorTasks(around: displayedMonthStart)
        syncDisplayedMonthError()
    }

    func cancelAsyncTasks() {
        cancelAllColorTasks()
    }

    func preloadComparisonYearIfNeeded(
        for year: Int,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        let previousYear = year - 1
        guard availableYears.contains(previousYear) else { return }

        let hasLoadedYearData = yearLoadState(for: previousYear) == .loaded
        let hasYearError = yearErrorMessageByYear[previousYear] != nil

        if !hasLoadedYearData || hasYearError {
            await ensureYearLoaded(
                for: previousYear,
                using: repository,
                colorRepository: colorRepository,
                reportError: false
            )
        }
        await ensureYearTopBooksLoaded(
            for: previousYear,
            using: repository,
            colorRepository: colorRepository
        )
    }

    /// dayEventCount 变更：从 cache 重建全量 layout 再按新 laneLimit 过滤，回填已解析颜色
    func applyLaneLimitChange() {
        for (key, state) in pageStates where state.loadState == .loaded {
            guard let data = monthCache[key] else { continue }
            // 收集已解析的封面颜色
            var colorMap = state.rankingBarColorsByBookId
            for week in state.weeks {
                for seg in week.segments where seg.color.state != .pending {
                    colorMap[seg.bookId] = seg.color
                }
            }
            // 重建 weeks（全量 lane → 按新阈值过滤）
            let newWeeks = buildWeeks(monthStart: state.monthStart, dayMap: data.days)
            // 回填已有颜色
            let coloredWeeks = newWeeks.map { week in
                WeekRowData(
                    weekStart: week.weekStart,
                    days: week.days,
                    segments: week.segments.map { seg in
                        guard let resolved = colorMap[seg.bookId] else { return seg }
                        return seg.withColor(resolved)
                    }
                )
            }
            pageStates[key] = MonthPageState(
                monthStart: state.monthStart,
                weeks: coloredWeeks,
                dayMap: state.dayMap,
                readingDurationTopBooks: state.readingDurationTopBooks,
                summary: state.summary,
                rankingBarColorsByBookId: state.rankingBarColorsByBookId,
                loadState: .loaded,
                errorMessage: nil
            )
        }
    }

    /// 设置变更后清缓存并重新加载
    func applySettingsChange(
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        hasLoaded = false
        monthCache = [:]
        pageStates = [:]
        yearTopBooksByYear = [:]
        yearRankingBarColorsByYear = [:]
        yearLoadStateByYear = [:]
        yearErrorMessageByYear = [:]
        latestYearRequestTicketByYear = [:]
        latestYearColorTicketByYear = [:]
        latestRequestTicketByMonthKey = [:]
        inFlightColorRequestBookIDsByMonthKey = [:]
        inFlightYearColorRequestBookIDsByYear = [:]
        cancelAllColorTasks()
        await reload(using: repository, colorRepository: colorRepository)
    }

    func monthState(for monthStart: Date) -> MonthPageState {
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        let key = Self.monthKey(for: normalized, using: calendar)
        return pageStates[key] ?? placeholderState(for: normalized)
    }

    func monthStartsForYear(_ year: Int) -> [Date] {
        Self.monthStarts(of: clampYear(year), using: calendar)
    }

    func yearLoadState(for year: Int) -> YearLoadState {
        yearLoadStateByYear[year] ?? .idle
    }

    func yearSummaryState(for year: Int) -> YearSummaryState {
        let clampedYear = clampYear(year)
        let monthStarts = monthStartsForYear(clampedYear)
        var activeDays = 0
        var totalReadSeconds = 0
        var noteCount = 0
        var finishedBookCount = 0
        var contributions: [YearMonthContribution] = []

        for monthStart in monthStarts {
            let state = monthState(for: monthStart)
            let monthActiveDays = activeDayCount(in: state.dayMap)
            activeDays += monthActiveDays
            totalReadSeconds += state.summary.totalReadSeconds
            noteCount += state.summary.noteCount
            finishedBookCount += state.summary.finishedBookCount
            contributions.append(
                YearMonthContribution(
                    monthStart: monthStart,
                    activeDays: monthActiveDays,
                    totalReadSeconds: state.summary.totalReadSeconds
                )
            )
        }

        let topBooks = yearTopBooksByYear[clampedYear] ?? []
        return YearSummaryState(
            year: clampedYear,
            activeDays: activeDays,
            totalReadSeconds: totalReadSeconds,
            noteCount: noteCount,
            finishedBookCount: finishedBookCount,
            monthContributions: contributions.sorted { $0.monthStart < $1.monthStart },
            topBooks: topBooks,
            rankingBarColorsByBookId: buildInitialYearRankingBarColorMap(
                topBooks: topBooks,
                existingMap: yearRankingBarColorsByYear[clampedYear]
            ),
            isLoading: yearLoadState(for: clampedYear) == .loading,
            errorMessage: yearErrorMessageByYear[clampedYear]
        )
    }

    func selectDate(_ date: Date?) {
        guard let date else {
            selectedDate = nil
            return
        }
        let normalized = calendar.startOfDay(for: date)
        guard !isFutureDate(normalized) else { return }
        if let selectedDate, calendar.isDate(selectedDate, inSameDayAs: normalized) {
            self.selectedDate = nil
            return
        }
        selectedDate = normalized
    }

    func dayPayload(for date: Date, in monthStart: Date) -> ReadCalendarDay? {
        let normalized = calendar.startOfDay(for: date)
        return monthState(for: monthStart).dayMap[normalized]
    }

    func overflowCount(for date: Date, in monthStart: Date) -> Int {
        let count = dayPayload(for: date, in: monthStart)?.books.count ?? 0
        return max(0, count - laneLimit)
    }

    func isSelected(_ date: Date) -> Bool {
        guard let selectedDate else { return false }
        return calendar.isDate(date, inSameDayAs: selectedDate)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func isFutureDate(_ date: Date) -> Bool {
        calendar.startOfDay(for: date) > calendar.startOfDay(for: Date())
    }
}

// MARK: - Private

private extension ReadCalendarViewModel {
    func ensureMonthLoaded(
        for monthStart: Date,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol,
        showLoading: Bool,
        forceRefresh: Bool,
        reportError: Bool
    ) async {
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        let key = Self.monthKey(for: normalized, using: calendar)
        let previousState = pageStates[key]
        if !forceRefresh, let existing = pageStates[key], existing.loadState == .loaded {
            if hasPendingSegmentColor(existing) {
                scheduleColorResolutionIfNeeded(
                    for: normalized,
                    using: colorRepository
                )
            }
            return
        }

        if showLoading {
            let current = pageStates[key] ?? placeholderState(for: normalized)
            pageStates[key] = MonthPageState(
                monthStart: current.monthStart,
                weeks: current.weeks,
                dayMap: current.dayMap,
                readingDurationTopBooks: current.readingDurationTopBooks,
                summary: current.summary,
                rankingBarColorsByBookId: current.rankingBarColorsByBookId,
                loadState: .loading,
                errorMessage: nil
            )
            if normalized == displayedMonthStart {
                errorMessage = nil
            }
        }

        requestTicketSeed += 1
        let ticket = requestTicketSeed
        latestRequestTicketByMonthKey[key] = ticket

        do {
            let data = try await fetchMonthData(
                monthStart: normalized,
                using: repository,
                forceRefresh: forceRefresh
            )
            guard latestRequestTicketByMonthKey[key] == ticket else { return }
            let loaded = buildLoadedState(monthStart: normalized, data: data)
            pageStates[key] = loaded
            scheduleColorResolutionIfNeeded(
                for: normalized,
                using: colorRepository
            )
            if normalized == displayedMonthStart {
                errorMessage = nil
            }
        } catch {
            guard latestRequestTicketByMonthKey[key] == ticket else { return }

            if error is CancellationError || Task.isCancelled {
                monthColorTasks[key]?.cancel()
                monthColorTasks[key] = nil
                inFlightColorRequestBookIDsByMonthKey[key] = nil

                if let previousState {
                    pageStates[key] = previousState
                } else if showLoading {
                    pageStates[key] = placeholderState(for: normalized)
                }
                return
            }

            monthColorTasks[key]?.cancel()
            monthColorTasks[key] = nil
            let failed = MonthPageState(
                monthStart: normalized,
                weeks: makeDisplayWeeks(for: normalized),
                dayMap: [:],
                readingDurationTopBooks: [],
                summary: .empty,
                rankingBarColorsByBookId: [:],
                loadState: .failed,
                errorMessage: "月份切换失败：\(error.localizedDescription)"
            )
            pageStates[key] = failed
            inFlightColorRequestBookIDsByMonthKey[key] = nil
            if reportError && normalized == displayedMonthStart {
                errorMessage = failed.errorMessage
            }
        }
    }

    func prefetchAdjacentMonths(
        around monthStart: Date,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        let neighbors = [
            monthAtOffset(-1, from: monthStart),
            monthAtOffset(1, from: monthStart)
        ].compactMap { $0 }

        for month in neighbors {
            await ensureMonthLoaded(
                for: month,
                using: repository,
                colorRepository: colorRepository,
                showLoading: false,
                forceRefresh: false,
                reportError: false
            )
        }
    }

    func ensureYearLoaded(
        for year: Int,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol,
        reportError: Bool
    ) async {
        guard hasLoaded else { return }
        let clampedYear = clampYear(year)
        let months = monthStartsForYear(clampedYear).filter { isMonthInAvailableRange($0) }
        guard !months.isEmpty else {
            yearLoadStateByYear[clampedYear] = .failed
            yearErrorMessageByYear[clampedYear] = "该年份暂无可展示数据"
            return
        }

        if yearLoadStateByYear[clampedYear] == .loaded {
            return
        }

        yearRequestTicketSeed += 1
        let ticket = yearRequestTicketSeed
        latestYearRequestTicketByYear[clampedYear] = ticket
        yearLoadStateByYear[clampedYear] = .loading
        yearErrorMessageByYear[clampedYear] = nil

        for monthStart in months {
            await ensureMonthLoaded(
                for: monthStart,
                using: repository,
                colorRepository: colorRepository,
                showLoading: false,
                forceRefresh: false,
                reportError: false
            )
        }

        guard latestYearRequestTicketByYear[clampedYear] == ticket else { return }

        let hasFailedMonth = months.contains { monthStart in
            monthState(for: monthStart).loadState == .failed
        }
        if hasFailedMonth {
            yearLoadStateByYear[clampedYear] = .failed
            yearErrorMessageByYear[clampedYear] = "该年份部分月份加载失败"
            if reportError {
                errorMessage = yearErrorMessageByYear[clampedYear]
            }
        } else {
            yearLoadStateByYear[clampedYear] = .loaded
            yearErrorMessageByYear[clampedYear] = nil
        }
    }

    func ensureYearTopBooksLoaded(
        for year: Int,
        using repository: any StatisticsRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        let clampedYear = clampYear(year)
        if yearTopBooksByYear[clampedYear] == nil {
            do {
                let topBooks = try await repository.fetchReadCalendarYearTopBooks(
                    year: clampedYear,
                    excludedEventTypes: settings.excludedEventTypes,
                    limit: Self.yearTopBookLimit
                )
                yearTopBooksByYear[clampedYear] = topBooks
                yearRankingBarColorsByYear[clampedYear] = buildInitialYearRankingBarColorMap(
                    topBooks: topBooks,
                    existingMap: yearRankingBarColorsByYear[clampedYear]
                )
                if yearLoadStateByYear[clampedYear] != .failed {
                    yearErrorMessageByYear[clampedYear] = nil
                }
            } catch {
                if yearErrorMessageByYear[clampedYear] == nil {
                    yearErrorMessageByYear[clampedYear] = "年度排行加载失败：\(error.localizedDescription)"
                }
                return
            }
        }

        guard let topBooks = yearTopBooksByYear[clampedYear] else { return }
        yearRankingBarColorsByYear[clampedYear] = buildInitialYearRankingBarColorMap(
            topBooks: topBooks,
            existingMap: yearRankingBarColorsByYear[clampedYear]
        )
        // 年度榜单颜色采用与月度一致的封面取色链路，避免出现“有封面但颜色固定”的割裂感。
        scheduleYearTopBookColorResolutionIfNeeded(
            for: clampedYear,
            topBooks: topBooks,
            using: colorRepository
        )
    }

    func scheduleYearTopBookColorResolutionIfNeeded(
        for year: Int,
        topBooks: [ReadCalendarMonthlyDurationBook],
        using colorRepository: any ReadCalendarColorRepositoryProtocol
    ) {
        let colorMap = yearRankingBarColorsByYear[year] ?? [:]
        let requests = buildYearTopBookColorRequests(
            topBooks: topBooks,
            colorsByBookId: colorMap
        )
        guard !requests.isEmpty else {
            yearColorTasks[year]?.cancel()
            yearColorTasks[year] = nil
            inFlightYearColorRequestBookIDsByYear[year] = nil
            return
        }

        let requestBookIDs = Set(requests.map(\.bookId))
        if let inFlightBookIDs = inFlightYearColorRequestBookIDsByYear[year],
           yearColorTasks[year] != nil,
           requestBookIDs.isSubset(of: inFlightBookIDs) {
            return
        }

        yearColorTasks[year]?.cancel()
        yearColorTicketSeed += 1
        let ticket = yearColorTicketSeed
        latestYearColorTicketByYear[year] = ticket
        inFlightYearColorRequestBookIDsByYear[year] = requestBookIDs

        yearColorTasks[year] = Task { [weak self] in
            guard let self else { return }
            await self.resolveYearTopBookColors(
                year: year,
                requests: requests,
                ticket: ticket,
                using: colorRepository
            )
        }
    }

    private func resolveYearTopBookColors(
        year: Int,
        requests: [ReadCalendarColorRequest],
        ticket: Int,
        using colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        var stagedColors: [Int64: ReadCalendarSegmentColor] = [:]
        stagedColors.reserveCapacity(Self.colorBatchCount)
        var lastFlushAt = Date()

        for request in requests {
            if Task.isCancelled {
                return
            }

            let color = await colorRepository.resolveEventColor(
                bookId: request.bookId,
                bookName: request.bookName,
                coverURL: request.coverURL
            )
            if Task.isCancelled {
                return
            }

            stagedColors[request.bookId] = color

            let now = Date()
            let shouldFlushByCount = stagedColors.count >= Self.colorBatchCount
            let shouldFlushByTime = now.timeIntervalSince(lastFlushAt) >= Self.colorBatchInterval
            if shouldFlushByCount || shouldFlushByTime {
                applyYearTopBookColors(stagedColors, year: year, ticket: ticket)
                stagedColors.removeAll(keepingCapacity: true)
                lastFlushAt = now
            }
        }

        if !stagedColors.isEmpty {
            applyYearTopBookColors(stagedColors, year: year, ticket: ticket)
        }

        if latestYearColorTicketByYear[year] == ticket {
            yearColorTasks[year] = nil
            inFlightYearColorRequestBookIDsByYear[year] = nil
        }
    }

    private func applyYearTopBookColors(
        _ colorsByBookId: [Int64: ReadCalendarSegmentColor],
        year: Int,
        ticket: Int
    ) {
        guard !colorsByBookId.isEmpty else { return }
        guard latestYearColorTicketByYear[year] == ticket else { return }
        guard let topBooks = yearTopBooksByYear[year] else { return }

        let topBookIds = Set(topBooks.map(\.bookId))
        var updatedColorsByBookId = buildInitialYearRankingBarColorMap(
            topBooks: topBooks,
            existingMap: yearRankingBarColorsByYear[year]
        )
        var hasChange = false

        for (bookId, color) in colorsByBookId where topBookIds.contains(bookId) {
            guard updatedColorsByBookId[bookId] != color else { continue }
            updatedColorsByBookId[bookId] = color
            hasChange = true
        }

        guard hasChange else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            yearRankingBarColorsByYear[year] = updatedColorsByBookId
        }
    }

    func scheduleColorResolutionIfNeeded(
        for monthStart: Date,
        using colorRepository: any ReadCalendarColorRepositoryProtocol
    ) {
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        let monthKey = Self.monthKey(for: normalized, using: calendar)
        guard let state = pageStates[monthKey], state.loadState == .loaded else { return }

        let requests = buildColorRequests(from: state)
        guard !requests.isEmpty else {
            inFlightColorRequestBookIDsByMonthKey[monthKey] = nil
            return
        }

        let requestBookIDs = Set(requests.map(\.bookId))
        if let inFlightBookIDs = inFlightColorRequestBookIDsByMonthKey[monthKey],
           monthColorTasks[monthKey] != nil,
           requestBookIDs.isSubset(of: inFlightBookIDs) {
            return
        }

        monthColorTasks[monthKey]?.cancel()
        colorTicketSeed += 1
        let ticket = colorTicketSeed
        latestColorTicketByMonthKey[monthKey] = ticket
        inFlightColorRequestBookIDsByMonthKey[monthKey] = requestBookIDs

        monthColorTasks[monthKey] = Task { [weak self] in
            guard let self else { return }
            await self.resolveSegmentColors(
                monthKey: monthKey,
                requests: requests,
                ticket: ticket,
                using: colorRepository
            )
        }
    }

    private func resolveSegmentColors(
        monthKey: String,
        requests: [ReadCalendarColorRequest],
        ticket: Int,
        using colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        var stagedColors: [Int64: ReadCalendarSegmentColor] = [:]
        stagedColors.reserveCapacity(Self.colorBatchCount)
        var lastFlushAt = Date()

        for request in requests {
            if Task.isCancelled {
                return
            }

            let color = await colorRepository.resolveEventColor(
                bookId: request.bookId,
                bookName: request.bookName,
                coverURL: request.coverURL
            )
            if Task.isCancelled {
                return
            }

            stagedColors[request.bookId] = color

            let now = Date()
            let shouldFlushByCount = stagedColors.count >= Self.colorBatchCount
            let shouldFlushByTime = now.timeIntervalSince(lastFlushAt) >= Self.colorBatchInterval
            if shouldFlushByCount || shouldFlushByTime {
                applyColors(stagedColors, monthKey: monthKey, ticket: ticket)
                stagedColors.removeAll(keepingCapacity: true)
                lastFlushAt = now
            }
        }

        if !stagedColors.isEmpty {
            applyColors(stagedColors, monthKey: monthKey, ticket: ticket)
        }

        await fillPendingRankingFallbackColorsIfNeeded(
            monthKey: monthKey,
            ticket: ticket,
            using: colorRepository
        )

        if latestColorTicketByMonthKey[monthKey] == ticket {
            monthColorTasks[monthKey] = nil
            inFlightColorRequestBookIDsByMonthKey[monthKey] = nil
        }
    }

    private func fillPendingRankingFallbackColorsIfNeeded(
        monthKey: String,
        ticket: Int,
        using colorRepository: any ReadCalendarColorRepositoryProtocol
    ) async {
        guard latestColorTicketByMonthKey[monthKey] == ticket else { return }
        guard let state = pageStates[monthKey], state.loadState == .loaded else { return }

        let pendingTopBooks = state.readingDurationTopBooks.filter { book in
            guard let color = state.rankingBarColorsByBookId[book.bookId] else { return true }
            return color.state == .pending
        }
        guard !pendingTopBooks.isEmpty else { return }

        var fallbackColors: [Int64: ReadCalendarSegmentColor] = [:]
        fallbackColors.reserveCapacity(pendingTopBooks.count)

        for book in pendingTopBooks {
            if Task.isCancelled {
                return
            }

            // 通过空 URL 直接走仓储失败回退路径，确保 pending 不会长期悬挂。
            let fallbackColor = await colorRepository.resolveEventColor(
                bookId: book.bookId,
                bookName: book.name,
                coverURL: ""
            )
            if Task.isCancelled {
                return
            }
            fallbackColors[book.bookId] = fallbackColor
        }

        applyColors(fallbackColors, monthKey: monthKey, ticket: ticket)
    }

    private func applyColors(
        _ colorsByBookId: [Int64: ReadCalendarSegmentColor],
        monthKey: String,
        ticket: Int
    ) {
        guard !colorsByBookId.isEmpty else { return }
        guard latestColorTicketByMonthKey[monthKey] == ticket else { return }
        guard let state = pageStates[monthKey], state.loadState == .loaded else { return }

        var hasWeekChange = false
        let targetBookIds = Set(colorsByBookId.keys)
        let updatedWeeks = state.weeks.map { week in
            let updatedSegments = week.segments.map { segment in
                guard targetBookIds.contains(segment.bookId),
                      let color = colorsByBookId[segment.bookId] else {
                    return segment
                }
                guard segment.color != color else { return segment }
                hasWeekChange = true
                return segment.withColor(color)
            }
            return WeekRowData(
                weekStart: week.weekStart,
                days: week.days,
                segments: updatedSegments
            )
        }

        var hasRankingColorChange = false
        var updatedRankingBarColorsByBookId = state.rankingBarColorsByBookId
        let topBookIds = Set(state.readingDurationTopBooks.map(\.bookId))
        for (bookId, color) in colorsByBookId where topBookIds.contains(bookId) {
            guard updatedRankingBarColorsByBookId[bookId] != color else { continue }
            updatedRankingBarColorsByBookId[bookId] = color
            hasRankingColorChange = true
        }

        guard hasWeekChange || hasRankingColorChange else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            pageStates[monthKey] = MonthPageState(
                monthStart: state.monthStart,
                weeks: updatedWeeks,
                dayMap: state.dayMap,
                readingDurationTopBooks: state.readingDurationTopBooks,
                summary: state.summary,
                rankingBarColorsByBookId: updatedRankingBarColorsByBookId,
                loadState: state.loadState,
                errorMessage: state.errorMessage
            )
        }
    }

    private func buildColorRequests(from state: MonthPageState) -> [ReadCalendarColorRequest] {
        var seenBookIds = Set<Int64>()
        var requests: [ReadCalendarColorRequest] = []

        for book in state.readingDurationTopBooks {
            if let color = state.rankingBarColorsByBookId[book.bookId], color.state != .pending {
                continue
            }
            guard seenBookIds.insert(book.bookId).inserted else { continue }
            requests.append(ReadCalendarColorRequest(
                bookId: book.bookId,
                bookName: book.name,
                coverURL: book.coverURL
            ))
        }

        for week in state.weeks {
            for segment in week.segments where segment.color.state == .pending {
                guard seenBookIds.insert(segment.bookId).inserted else { continue }
                requests.append(ReadCalendarColorRequest(
                    bookId: segment.bookId,
                    bookName: segment.bookName,
                    coverURL: segment.bookCoverURL
                ))
            }
        }
        return requests
    }

    private func buildYearTopBookColorRequests(
        topBooks: [ReadCalendarMonthlyDurationBook],
        colorsByBookId: [Int64: ReadCalendarSegmentColor]
    ) -> [ReadCalendarColorRequest] {
        var seenBookIds = Set<Int64>()
        var requests: [ReadCalendarColorRequest] = []
        requests.reserveCapacity(topBooks.count)

        for book in topBooks {
            if let color = colorsByBookId[book.bookId], color.state != .pending {
                continue
            }
            guard seenBookIds.insert(book.bookId).inserted else { continue }
            requests.append(ReadCalendarColorRequest(
                bookId: book.bookId,
                bookName: book.name,
                coverURL: book.coverURL
            ))
        }
        return requests
    }

    func hasPendingSegmentColor(_ state: MonthPageState) -> Bool {
        let hasPendingSegment = state.weeks.contains { week in
            week.segments.contains { $0.color.state == .pending }
        }
        if hasPendingSegment {
            return true
        }
        return state.readingDurationTopBooks.contains { book in
            guard let color = state.rankingBarColorsByBookId[book.bookId] else { return true }
            return color.state == .pending
        }
    }

    func cancelOutOfScopeColorTasks(around monthStart: Date) {
        let validMonths: [Date] = [
            monthStart,
            monthAtOffset(-1, from: monthStart),
            monthAtOffset(1, from: monthStart)
        ].compactMap { $0 }
        let keepKeys = Set(validMonths.map { Self.monthKey(for: $0, using: calendar) })

        let keysToCancel = monthColorTasks.keys.filter { !keepKeys.contains($0) }
        for key in keysToCancel {
            monthColorTasks[key]?.cancel()
            monthColorTasks.removeValue(forKey: key)
            latestColorTicketByMonthKey.removeValue(forKey: key)
            inFlightColorRequestBookIDsByMonthKey.removeValue(forKey: key)
        }
    }

    func cancelAllColorTasks() {
        for task in monthColorTasks.values {
            task.cancel()
        }
        for task in yearColorTasks.values {
            task.cancel()
        }
        monthColorTasks = [:]
        yearColorTasks = [:]
        latestColorTicketByMonthKey = [:]
        latestYearColorTicketByYear = [:]
        inFlightColorRequestBookIDsByMonthKey = [:]
        inFlightYearColorRequestBookIDsByYear = [:]
    }

    func fetchMonthData(
        monthStart: Date,
        using repository: any StatisticsRepositoryProtocol,
        forceRefresh: Bool
    ) async throws -> ReadCalendarMonthData {
        let key = Self.monthKey(for: monthStart, using: calendar)
        if forceRefresh {
            monthCache.removeValue(forKey: key)
        }
        if let cached = monthCache[key] {
            return cached
        }

        let fetched = try await repository.fetchReadCalendarMonthData(
            monthStart: monthStart,
            excludedEventTypes: settings.excludedEventTypes
        )
        monthCache[key] = fetched
        return fetched
    }

    func buildLoadedState(monthStart: Date, data: ReadCalendarMonthData) -> MonthPageState {
        let weeks = buildWeeks(monthStart: monthStart, dayMap: data.days)
        return MonthPageState(
            monthStart: monthStart,
            weeks: weeks,
            dayMap: data.days,
            readingDurationTopBooks: data.readingDurationTopBooks,
            summary: data.summary,
            rankingBarColorsByBookId: buildInitialRankingBarColorMap(
                weeks: weeks,
                topBooks: data.readingDurationTopBooks
            ),
            loadState: .loaded,
            errorMessage: nil
        )
    }

    func placeholderState(for monthStart: Date) -> MonthPageState {
        MonthPageState(
            monthStart: monthStart,
            weeks: makeDisplayWeeks(for: monthStart),
            dayMap: [:],
            readingDurationTopBooks: [],
            summary: .empty,
            rankingBarColorsByBookId: [:],
            loadState: .idle,
            errorMessage: nil
        )
    }

    func buildInitialRankingBarColorMap(
        weeks: [WeekRowData],
        topBooks: [ReadCalendarMonthlyDurationBook]
    ) -> [Int64: ReadCalendarSegmentColor] {
        var colorsByBookId: [Int64: ReadCalendarSegmentColor] = [:]
        for week in weeks {
            for segment in week.segments where segment.color.state != .pending {
                colorsByBookId[segment.bookId] = segment.color
            }
        }

        var rankingColorsByBookId: [Int64: ReadCalendarSegmentColor] = [:]
        for book in topBooks {
            rankingColorsByBookId[book.bookId] = colorsByBookId[book.bookId] ?? .pending
        }
        return rankingColorsByBookId
    }

    func buildInitialYearRankingBarColorMap(
        topBooks: [ReadCalendarMonthlyDurationBook],
        existingMap: [Int64: ReadCalendarSegmentColor]?
    ) -> [Int64: ReadCalendarSegmentColor] {
        let existingMap = existingMap ?? [:]
        var colorsByBookId: [Int64: ReadCalendarSegmentColor] = [:]
        colorsByBookId.reserveCapacity(topBooks.count)
        for book in topBooks {
            colorsByBookId[book.bookId] = existingMap[book.bookId] ?? .pending
        }
        return colorsByBookId
    }

    func buildWeeks(monthStart: Date, dayMap: [Date: ReadCalendarDay]) -> [WeekRowData] {
        let displayWeeks = makeDisplayWeeks(for: monthStart)
        let engine = ReadCalendarEventLayoutEngine(calendar: calendar, mode: renderMode)
        let layouts = engine.buildWeekLayouts(days: dayMap)
        let layoutMap = Dictionary(uniqueKeysWithValues: layouts.map { ($0.weekStart, $0) })

        return displayWeeks.map { week in
            let segments = (layoutMap[week.weekStart]?.segments ?? []).filter { $0.laneIndex < laneLimit }
            return WeekRowData(
                weekStart: week.weekStart,
                days: week.days,
                segments: segments
            )
        }
    }

    func makeDisplayWeeks(for monthStart: Date) -> [WeekRowData] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let firstDay = monthStart
        let weekday = calendar.component(.weekday, from: firstDay)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var slots: [Date?] = Array(repeating: nil, count: leading)
        for day in dayRange {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            slots.append(calendar.startOfDay(for: date))
        }
        while slots.count % 7 != 0 {
            slots.append(nil)
        }

        var result: [WeekRowData] = []
        var index = 0
        while index < slots.count {
            let chunk = Array(slots[index..<min(index + 7, slots.count)])
            let weekStart = weekStartDate(for: chunk, monthStart: monthStart, weekOffset: index / 7)
            result.append(WeekRowData(weekStart: weekStart, days: chunk, segments: []))
            index += 7
        }
        return result
    }

    func rebuildMonthRange(from earliest: Date, to latest: Date) {
        var months: [Date] = []
        var cursor = earliest
        while cursor <= latest {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = Self.monthStart(of: next, using: calendar)
        }
        availableMonths = months
        monthIndexByKey = Dictionary(uniqueKeysWithValues: months.enumerated().map { index, month in
            (Self.monthKey(for: month, using: calendar), index)
        })
    }

    func rebuildYearRange(from earliest: Date, to latest: Date) {
        let earliestYear = calendar.component(.year, from: earliest)
        let latestYear = calendar.component(.year, from: latest)
        guard earliestYear <= latestYear else {
            availableYears = []
            return
        }
        availableYears = Array(earliestYear...latestYear).sorted(by: >)
    }

    func monthIndex(for monthStart: Date) -> Int? {
        let key = Self.monthKey(for: monthStart, using: calendar)
        return monthIndexByKey[key]
    }

    func monthAtOffset(_ offset: Int, from monthStart: Date) -> Date? {
        guard let index = monthIndex(for: monthStart) else { return nil }
        let target = index + offset
        guard availableMonths.indices.contains(target) else { return nil }
        return availableMonths[target]
    }

    func weekStartDate(for chunk: [Date?], monthStart: Date, weekOffset: Int) -> Date {
        if let date = chunk.compactMap({ $0 }).first {
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            return calendar.startOfDay(for: start)
        }
        guard let fallback = calendar.date(byAdding: .day, value: weekOffset * 7, to: monthStart) else {
            return monthStart
        }
        let start = calendar.dateInterval(of: .weekOfYear, for: fallback)?.start ?? fallback
        return calendar.startOfDay(for: start)
    }

    func clampMonthStart(_ monthStart: Date, earliest: Date, latest: Date) -> Date {
        if monthStart < earliest { return earliest }
        if monthStart > latest { return latest }
        return monthStart
    }

    func clampYear(_ year: Int) -> Int {
        guard let minYear = availableYears.min(),
              let maxYear = availableYears.max() else {
            return year
        }
        if year < minYear { return minYear }
        if year > maxYear { return maxYear }
        return year
    }

    func clampSelectedDate(_ date: Date, earliestMonthStart: Date, latestDate: Date) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let upper = calendar.startOfDay(for: latestDate)
        if normalized < earliestMonthStart { return earliestMonthStart }
        if normalized > upper { return upper }
        return normalized
    }

    func isMonthInAvailableRange(_ monthStart: Date) -> Bool {
        monthIndex(for: monthStart) != nil
    }

    func syncDisplayedMonthError() {
        let key = Self.monthKey(for: displayedMonthStart, using: calendar)
        errorMessage = pageStates[key]?.errorMessage
    }

    func activeDayCount(in dayMap: [Date: ReadCalendarDay]) -> Int {
        dayMap.values.filter { !$0.books.isEmpty || $0.isReadDoneDay }.count
    }

    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: normalized)
        let monthStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: monthStart)
    }

    static func monthKey(for date: Date, using calendar: Calendar) -> String {
        let monthStart = monthStart(of: date, using: calendar)
        return Self.monthKeyFormatter.string(from: monthStart)
    }

    static func currentMonthStart(using calendar: Calendar) -> Date {
        monthStart(of: Date(), using: calendar)
    }

    static func monthStarts(of year: Int, using calendar: Calendar) -> [Date] {
        (1...12).compactMap { month -> Date? in
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                return nil
            }
            return monthStart(of: date, using: calendar)
        }
    }
}

private extension ReadCalendarEventSegment {
    func withColor(_ color: ReadCalendarSegmentColor) -> ReadCalendarEventSegment {
        ReadCalendarEventSegment(
            bookId: bookId,
            bookName: bookName,
            bookCoverURL: bookCoverURL,
            firstEventTime: firstEventTime,
            weekStart: weekStart,
            segmentStartDate: segmentStartDate,
            segmentEndDate: segmentEndDate,
            laneIndex: laneIndex,
            continuesFromPrevWeek: continuesFromPrevWeek,
            continuesToNextWeek: continuesToNextWeek,
            showsReadDoneBadge: showsReadDoneBadge,
            color: color
        )
    }
}
