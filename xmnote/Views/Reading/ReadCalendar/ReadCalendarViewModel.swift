import Foundation

/**
 * [INPUT]: 依赖 StatisticsRepositoryProtocol 提供月历聚合数据，依赖 ReadCalendarColorRepositoryProtocol 提供封面取色，依赖 ReadCalendarEventLayoutEngine 生成事件条布局
 * [OUTPUT]: 对外提供 ReadCalendarViewModel（阅读日历页面状态、分页切月、跨周事件条布局、事件条颜色异步回填）
 * [POS]: ReadCalendar 子功能状态中枢，负责数据加载、分页状态、选中态、周布局构建与封面取色任务编排
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
        let loadState: MonthLoadState
        let errorMessage: String?

        var isLoading: Bool {
            loadState == .loading
        }
    }

    enum RootContentState: Equatable {
        case loading
        case empty
        case content
    }

    var displayedMonthStart: Date
    var pagerSelection: Date
    var selectedDate: Date
    var earliestMonthStart: Date?
    var availableMonths: [Date] = []

    var isLoading = false
    var errorMessage: String?

    let laneLimit = 4
    let renderMode: ReadCalendarRenderMode

    private let initialDate: Date?
    private var hasLoaded = false
    private var monthCache: [String: ReadCalendarMonthData] = [:]
    private var pageStates: [String: MonthPageState] = [:]
    private var monthIndexByKey: [String: Int] = [:]
    private var latestRequestTicketByMonthKey: [String: Int] = [:]
    private var latestColorTicketByMonthKey: [String: Int] = [:]
    private var monthColorTasks: [String: Task<Void, Never>] = [:]
    private var requestTicketSeed = 0
    private var colorTicketSeed = 0
    private var calendar: Calendar

    init(
        initialDate: Date?,
        renderMode: ReadCalendarRenderMode = .crossWeekContinuous
    ) {
        self.initialDate = initialDate
        self.renderMode = renderMode

        var cal = Calendar.current
        cal.firstWeekday = 2 // 周一起始
        self.calendar = cal

        let today = cal.startOfDay(for: Date())
        let monthStart = Self.monthStart(of: today, using: cal)
        self.displayedMonthStart = monthStart
        self.pagerSelection = monthStart
        self.selectedDate = today
    }

    var canGoPrevMonth: Bool {
        guard let index = monthIndex(for: pagerSelection) else { return false }
        return index > 0
    }

    var canGoNextMonth: Bool {
        guard let index = monthIndex(for: pagerSelection) else { return false }
        return index < (availableMonths.count - 1)
    }

    var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        formatter.timeZone = .current
        return formatter.string(from: pagerSelection)
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
        selectedDate = today

        do {
            let earliestDate = try await repository.fetchReadCalendarEarliestDate()
            let earliest = Self.monthStart(of: earliestDate ?? today, using: calendar)
            let current = Self.currentMonthStart(using: calendar)
            earliestMonthStart = earliest

            rebuildMonthRange(from: earliest, to: current)

            let preferredMonth = Self.monthStart(
                of: calendar.startOfDay(for: initialDate ?? today),
                using: calendar
            )
            let defaultMonth = clampMonthStart(preferredMonth, earliest: earliest, latest: current)
            displayedMonthStart = defaultMonth
            pagerSelection = defaultMonth

            monthCache = [:]
            pageStates = [:]
            latestRequestTicketByMonthKey = [:]
            latestColorTicketByMonthKey = [:]
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
            monthIndexByKey = [:]
            pageStates = [:]
            cancelAllColorTasks()
            hasLoaded = false
        }

        isLoading = false
    }

    func stepPager(offset: Int) {
        guard let target = monthAtOffset(offset, from: pagerSelection) else { return }
        pagerSelection = target
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

    func monthState(for monthStart: Date) -> MonthPageState {
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        let key = Self.monthKey(for: normalized, using: calendar)
        return pageStates[key] ?? placeholderState(for: normalized)
    }

    func selectDate(_ date: Date?) {
        guard let date else { return }
        let normalized = calendar.startOfDay(for: date)
        guard !isFutureDate(normalized) else { return }
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
        calendar.isDate(date, inSameDayAs: selectedDate)
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
            monthColorTasks[key]?.cancel()
            monthColorTasks[key] = nil
            let failed = MonthPageState(
                monthStart: normalized,
                weeks: makeDisplayWeeks(for: normalized),
                dayMap: [:],
                loadState: .failed,
                errorMessage: "月份切换失败：\(error.localizedDescription)"
            )
            pageStates[key] = failed
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

    func scheduleColorResolutionIfNeeded(
        for monthStart: Date,
        using colorRepository: any ReadCalendarColorRepositoryProtocol
    ) {
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        let monthKey = Self.monthKey(for: normalized, using: calendar)
        guard let state = pageStates[monthKey], state.loadState == .loaded else { return }

        let requests = buildColorRequests(from: state)
        guard !requests.isEmpty else { return }

        monthColorTasks[monthKey]?.cancel()
        colorTicketSeed += 1
        let ticket = colorTicketSeed
        latestColorTicketByMonthKey[monthKey] = ticket

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
            applyColor(color, for: request.bookId, monthKey: monthKey, ticket: ticket)
        }

        if latestColorTicketByMonthKey[monthKey] == ticket {
            monthColorTasks[monthKey] = nil
        }
    }

    func applyColor(
        _ color: ReadCalendarSegmentColor,
        for bookId: Int64,
        monthKey: String,
        ticket: Int
    ) {
        guard latestColorTicketByMonthKey[monthKey] == ticket else { return }
        guard let state = pageStates[monthKey], state.loadState == .loaded else { return }

        var hasChange = false
        let updatedWeeks = state.weeks.map { week in
            let updatedSegments = week.segments.map { segment in
                guard segment.bookId == bookId else { return segment }
                guard segment.color != color else { return segment }
                hasChange = true
                return segment.withColor(color)
            }
            return WeekRowData(
                weekStart: week.weekStart,
                days: week.days,
                segments: updatedSegments
            )
        }

        guard hasChange else { return }
        pageStates[monthKey] = MonthPageState(
            monthStart: state.monthStart,
            weeks: updatedWeeks,
            dayMap: state.dayMap,
            loadState: state.loadState,
            errorMessage: state.errorMessage
        )
    }

    private func buildColorRequests(from state: MonthPageState) -> [ReadCalendarColorRequest] {
        var requestMap: [Int64: ReadCalendarColorRequest] = [:]
        for week in state.weeks {
            for segment in week.segments where segment.color.state == .pending {
                requestMap[segment.bookId] = ReadCalendarColorRequest(
                    bookId: segment.bookId,
                    bookName: segment.bookName,
                    coverURL: segment.bookCoverURL
                )
            }
        }
        return requestMap.values.sorted { lhs, rhs in
            lhs.bookId < rhs.bookId
        }
    }

    func hasPendingSegmentColor(_ state: MonthPageState) -> Bool {
        state.weeks.contains { week in
            week.segments.contains { $0.color.state == .pending }
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
        }
    }

    func cancelAllColorTasks() {
        for task in monthColorTasks.values {
            task.cancel()
        }
        monthColorTasks = [:]
        latestColorTicketByMonthKey = [:]
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

        let fetched = try await repository.fetchReadCalendarMonthData(monthStart: monthStart)
        monthCache[key] = fetched
        return fetched
    }

    func buildLoadedState(monthStart: Date, data: ReadCalendarMonthData) -> MonthPageState {
        MonthPageState(
            monthStart: monthStart,
            weeks: buildWeeks(monthStart: monthStart, dayMap: data.days),
            dayMap: data.days,
            loadState: .loaded,
            errorMessage: nil
        )
    }

    func placeholderState(for monthStart: Date) -> MonthPageState {
        MonthPageState(
            monthStart: monthStart,
            weeks: makeDisplayWeeks(for: monthStart),
            dayMap: [:],
            loadState: .idle,
            errorMessage: nil
        )
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

    func isMonthInAvailableRange(_ monthStart: Date) -> Bool {
        monthIndex(for: monthStart) != nil
    }

    func syncDisplayedMonthError() {
        let key = Self.monthKey(for: displayedMonthStart, using: calendar)
        errorMessage = pageStates[key]?.errorMessage
    }

    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: normalized)
        let monthStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: monthStart)
    }

    static func monthKey(for date: Date, using calendar: Calendar) -> String {
        let monthStart = monthStart(of: date, using: calendar)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = .current
        return formatter.string(from: monthStart)
    }

    static func currentMonthStart(using calendar: Calendar) -> Date {
        monthStart(of: Date(), using: calendar)
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
            color: color
        )
    }
}
