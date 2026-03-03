/**
 * [INPUT]: 依赖 CalendarMonthStepperBar/ReadCalendarMonthGrid 页面私有组件、ReadCalendarDay/ReadCalendarMonthlyDurationBook 领域模型与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供 ReadCalendarContentView（完整阅读日历控件：模式切换 + 月份/年份切换 + 月分页/年度热力图 + 月/年总结弹层）
 * [POS]: ReadCalendar 业务页面壳层组件，负责日历主内容组合与业务内弹层触发
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct ReadCalendarContentView: View {
    enum DisplayMode: String, CaseIterable, Hashable {
        case heatmap
        case activityEvent
        case bookCover

        var title: String {
            switch self {
            case .heatmap:
                return "热力图"
            case .activityEvent:
                return "活动事件"
            case .bookCover:
                return "书籍封面"
            }
        }

        func iconName(isSelected: Bool) -> String {
            switch self {
            case .heatmap:
                return isSelected ? "square.grid.3x3.fill" : "square.grid.3x3"
            case .activityEvent:
                return isSelected ? "list.bullet.rectangle.fill" : "list.bullet.rectangle"
            case .bookCover:
                return isSelected ? "books.vertical.fill" : "books.vertical"
            }
        }
    }

    enum RootContentState: Hashable {
        case loading
        case empty
        case content
    }

    enum MonthLoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum YearLoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    struct MonthPage: Identifiable, Hashable {
        let monthStart: Date
        let weeks: [ReadCalendarMonthGrid.WeekData]
        let dayMap: [Date: ReadCalendarDay]
        let readingDurationTopBooks: [ReadCalendarMonthlyDurationBook]
        let summary: ReadCalendarMonthSummary
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let selectedDate: Date?
        let todayStart: Date
        let laneLimit: Int
        let isDayMapEmpty: Bool
        let loadState: MonthLoadState
        let errorMessage: String?

        var id: Date { monthStart }

        var isLoading: Bool {
            loadState == .loading
        }

        func payload(for date: Date) -> ReadCalendarMonthGrid.DayPayload {
            let cal = Calendar.current
            let normalized = cal.startOfDay(for: date)
            let dayData = dayMap[normalized]
            let bookCount = dayData?.books.count ?? 0

            return ReadCalendarMonthGrid.DayPayload(
                bookCount: bookCount,
                isReadDoneDay: dayData?.isReadDoneDay == true,
                heatmapLevel: dayData?.heatmapLevel ?? .none,
                overflowCount: max(0, bookCount - laneLimit),
                isStreakDay: isStreakDay(on: normalized),
                isToday: cal.isDate(normalized, inSameDayAs: todayStart),
                isSelected: selectedDate.map { cal.isDate(normalized, inSameDayAs: $0) } ?? false,
                isFuture: normalized > todayStart
            )
        }

        func streakLengthEnding(at date: Date) -> Int {
            let cal = Calendar.current
            let monthFloor = cal.startOfDay(for: monthStart)
            var cursor = cal.startOfDay(for: date)
            var count = 0
            while cursor >= monthFloor && hasActivity(on: cursor) {
                count += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = cal.startOfDay(for: prev)
            }
            return count
        }

        private func isStreakDay(on date: Date) -> Bool {
            guard hasActivity(on: date) else { return false }
            let cal = Calendar.current
            guard let prev = cal.date(byAdding: .day, value: -1, to: date),
                  let next = cal.date(byAdding: .day, value: 1, to: date) else {
                return false
            }
            return hasActivity(on: prev) || hasActivity(on: next)
        }

        private func hasActivity(on date: Date) -> Bool {
            let cal = Calendar.current
            let normalized = cal.startOfDay(for: date)
            guard let dayData = dayMap[normalized] else { return false }
            return !dayData.books.isEmpty || dayData.isReadDoneDay
        }
    }

    struct Props: Hashable {
        let monthTitle: String
        let yearTitle: String
        let availableMonths: [Date]
        let availableYears: [Int]
        let pagerSelection: Date
        let selectedYear: Int
        let displayMode: DisplayMode
        let laneLimit: Int
        let isHapticsEnabled: Bool
        let isStreakHintEnabled: Bool
        let rootContentState: RootContentState
        let errorMessage: String?
        let monthPages: [MonthPage]
        let heatmapYearMonthPages: [MonthPage]
        let selectedYearLoadState: YearLoadState
        let selectedYearErrorMessage: String?
        let yearSummary: YearSummarySheetData
    }

    struct MonthSummarySheetData: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalDays: Int
        let longestStreak: Int
        let monthSummary: ReadCalendarMonthSummary
        let activeDaysDelta: Int?
        let readSecondsDelta: Int?
        let noteCountDelta: Int?
        let peakTimeSlot: ReadCalendarTimeSlot?
        let peakTimeSlotRatio: Int?
        let durationTopBooks: [ReadCalendarMonthlyDurationBook]
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let hasDurationRankingFallback: Bool

        var id: Date { monthStart }

        var hasActivity: Bool {
            activeDays > 0
        }
    }

    struct YearSummaryMonthContribution: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalReadSeconds: Int

        var id: Date { monthStart }
    }

    struct YearSummarySheetData: Identifiable, Hashable {
        let year: Int
        let activeDays: Int
        let totalReadSeconds: Int
        let noteCount: Int
        let finishedBookCount: Int
        let activeDaysDelta: Int?
        let readSecondsDelta: Int?
        let noteCountDelta: Int?
        let topBooks: [ReadCalendarMonthlyDurationBook]
        // 年度 TOP 条颜色，按 bookId 透传给 Sheet，保持与月度总结一致的封面取色体验。
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let monthContributions: [YearSummaryMonthContribution]
        let isLoading: Bool
        let errorMessage: String?

        var id: Int { year }
    }

    private enum Layout {
        static let topControlTopPadding: CGFloat = 10
        static let topControlBottomPadding: CGFloat = 14
        static let topControlBackgroundOpacity: CGFloat = 1
        static let topControlLayerZIndex: Double = 12
        static let streakHintLayerZIndex: Double = 11
        static let contentLayerZIndex: Double = 0
        static let weekdayHeaderHeight: CGFloat = 32
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerTopPadding: CGFloat = Spacing.cozy
        static let calendarInnerBottomPadding: CGFloat = 0
        static let contentBleedBottomInset: CGFloat = Spacing.cozy
        static let interactiveBottomInset: CGFloat = Spacing.half
        static let headerToGridSpacing: CGFloat = Spacing.half
        static let gridTopInset: CGFloat = 2
        static let streakHintBottomPadding: CGFloat = Spacing.cozy
        static let summarySheetCompactRatio: CGFloat = 0.48
        static let summaryFloatingButtonTrailing: CGFloat = Spacing.screenEdge
        static let summaryFloatingButtonBottomBase: CGFloat = Spacing.base
        static let summaryFloatingButtonShowResponse: CGFloat = 0.34
        static let summaryFloatingButtonShowDamping: CGFloat = 0.82
        static let summaryFloatingButtonHideDuration: CGFloat = 0.18
        static let summaryFloatingButtonShowScaleFrom: CGFloat = 0.92
        static let summaryFloatingButtonHideScaleTo: CGFloat = 0.96
        static let summaryFloatingButtonShowOffsetY: CGFloat = 10
        static let summaryFloatingButtonHideOffsetY: CGFloat = 6
        static let summaryFloatingButtonIdleHideDelay: TimeInterval = 7
        static let summaryFloatingButtonInitialVisibleProtection: TimeInterval = 5
        static let summaryFloatingButtonPostDismissProtection: TimeInterval = 3
        static let summaryFloatingButtonPostInteractionProtection: TimeInterval = 1.5
        static let summaryFloatingButtonScrollInteractionProtection: TimeInterval = 2
        static let summaryFloatingButtonInteractionThrottle: TimeInterval = 0.25
        static let yearHeatmapGridSpacing: CGFloat = Spacing.base
        static let yearHeatmapMonthCardSpacing: CGFloat = Spacing.half
        static let yearHeatmapMonthCardPadding: CGFloat = Spacing.contentEdge
        static let yearHeatmapMonthCardTitleHeight: CGFloat = 20
        static let yearHeatmapCompactWeekCount = 6
        static let yearHeatmapLegendSquare: CGFloat = 10
        static let yearHeatmapLoadingCellSpacing: CGFloat = 3
        static let yearHeatmapLegendTopPadding: CGFloat = Spacing.half
        static let yearHeatmapMonthCardCornerRadius: CGFloat = CornerRadius.containerMedium
        static let yearHeatmapErrorBannerHorizontalInset: CGFloat = Spacing.screenEdge
        static let yearHeatmapErrorBannerBottomInset: CGFloat = Spacing.base
        static let yearSummarySheetCompactRatio: CGFloat = 0.54
    }

    let props: Props
    let onDisplayModeChanged: (DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onYearSelectionChanged: (Int) -> Void
    let onSelectDate: (Date?) -> Void
    let onRetry: () -> Void
    @State private var streakHintMessage: String?
    @State private var streakHintTask: Task<Void, Never>?
    @State private var shownStreakMilestonesByMonth: [Date: Set<Int>] = [:]
    @State private var isSummarySheetPresented = false
    @State private var summarySheetMonthStart: Date?
    @State private var isYearSummarySheetPresented = false
    @State private var isSummaryFloatingButtonVisible = false
    @State private var summaryFloatingButtonAutoHideTask: Task<Void, Never>?
    @State private var summaryFloatingButtonInteractionToken: UInt64 = 0
    @State private var summaryFloatingButtonHideNotBefore: Date = .distantPast
    @State private var summaryFloatingButtonLastInteractionAt: Date = .distantPast
    @State private var hasAppliedSummaryFloatingButtonInitialPolicy = false
    @State private var summaryFloatingButtonHiddenScale: CGFloat = Layout.summaryFloatingButtonShowScaleFrom
    @State private var summaryFloatingButtonHiddenOffsetY: CGFloat = Layout.summaryFloatingButtonShowOffsetY

    var body: some View {
        VStack(spacing: 0) {
            ReadCalendarTopControlBar(
                monthTitle: props.monthTitle,
                yearTitle: props.yearTitle,
                availableMonths: props.availableMonths,
                availableYears: props.availableYears,
                pagerSelection: props.pagerSelection,
                selectedYear: props.selectedYear,
                displayMode: props.displayMode,
                onDisplayModeChanged: onDisplayModeChanged,
                onPagerSelectionChanged: onPagerSelectionChanged,
                onYearSelectionChanged: onYearSelectionChanged
            )
                .padding(.top, Layout.topControlTopPadding)
                .padding(.bottom, Layout.topControlBottomPadding)
                .background {
                    Color.windowBackground.opacity(Layout.topControlBackgroundOpacity)
                }
                // 保证底部沉浸滚动时，顶部控制区始终位于最上层。
                .zIndex(Layout.topControlLayerZIndex)

            if let streakHintMessage,
               props.rootContentState == .content,
               props.displayMode == .activityEvent,
               props.isStreakHintEnabled {
                ReadCalendarStreakHintBanner(text: streakHintMessage)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.bottom, Layout.streakHintBottomPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(Layout.streakHintLayerZIndex)
            }

            integratedCalendarContainer
                .ignoresSafeArea(.container, edges: .bottom)
                .zIndex(Layout.contentLayerZIndex)

            if let errorMessage = props.errorMessage,
               props.rootContentState == .content {
                ReadCalendarInlineErrorBanner(message: errorMessage, onRetry: onRetry)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: props.errorMessage)
        .onAppear {
            evaluateStreakHintIfNeeded()
            if props.rootContentState == .content {
                applySummaryFloatingButtonInitialPolicyIfNeeded()
            }
        }
        .onChange(of: props.rootContentState) { _, state in
            switch state {
            case .content:
                applySummaryFloatingButtonInitialPolicyIfNeeded()
            case .loading, .empty:
                hideSummaryFloatingButtonImmediately()
            }
        }
        .onChange(of: props.pagerSelection) { _, monthStart in
            evaluateStreakHintIfNeeded()
            syncSummarySheetMonthIfNeeded(monthStart: monthStart)
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
            )
        }
        .onChange(of: activeSelectedDate) { _, _ in
            evaluateStreakHintIfNeeded()
            markSummaryFloatingButtonInteraction()
        }
        .onChange(of: props.displayMode) { _, mode in
            markSummaryFloatingButtonInteraction()
            if mode != .heatmap {
                isYearSummarySheetPresented = false
            }
            guard mode == .activityEvent else {
                streakHintTask?.cancel()
                streakHintTask = nil
                withAnimation(.smooth(duration: 0.18)) {
                    streakHintMessage = nil
                }
                return
            }
            evaluateStreakHintIfNeeded()
        }
        .onChange(of: props.selectedYear) { _, _ in
            guard props.displayMode == .heatmap else { return }
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
            )
        }
        .onChange(of: props.isStreakHintEnabled) { _, isEnabled in
            guard isEnabled else {
                streakHintTask?.cancel()
                streakHintTask = nil
                withAnimation(.smooth(duration: 0.18)) {
                    streakHintMessage = nil
                }
                return
            }
            evaluateStreakHintIfNeeded()
        }
        .onDisappear {
            streakHintTask?.cancel()
            streakHintTask = nil
            summaryFloatingButtonAutoHideTask?.cancel()
            summaryFloatingButtonAutoHideTask = nil
        }
        .sheet(isPresented: $isSummarySheetPresented, onDismiss: {
            summarySheetMonthStart = nil
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonPostDismissProtection,
                force: true
            )
        }) {
            ReadCalendarMonthSummarySheet(
                sheet: presentedSummarySheetData,
                availableMonths: props.availableMonths,
                onSwitchMonth: { monthStart in
                    switchSummarySheetMonth(to: monthStart)
                }
            )
                .presentationDetents([.fraction(Layout.summarySheetCompactRatio), .large])
                .presentationDragIndicator(.visible)
                // 宿主层使用中等强度系统材质，保证玻璃效果可感知且半/全展开一致。
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $isYearSummarySheetPresented, onDismiss: {
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonPostDismissProtection,
                force: true
            )
        }) {
            ReadCalendarYearSummarySheet(
                sheet: props.yearSummary,
                availableYears: props.availableYears,
                onSwitchYear: { year in
                    withAnimation(.snappy(duration: 0.3)) {
                        onYearSelectionChanged(year)
                    }
                },
                onSelectMonth: { monthStart in
                    withAnimation(.snappy(duration: 0.3)) {
                        onPagerSelectionChanged(monthStart)
                    }
                    openMonthSummaryAfterAuxSheetDismiss(monthStart: monthStart)
                },
                onRetry: onRetry
            )
            .presentationDetents([.fraction(Layout.yearSummarySheetCompactRatio), .large])
            .presentationDragIndicator(.visible)
            // 宿主层使用中等强度系统材质，保证玻璃效果可感知且半/全展开一致。
            .presentationBackground(.regularMaterial)
        }
    }
}

// MARK: - Subviews

private extension ReadCalendarContentView {
    var isHeatmapMode: Bool {
        props.displayMode == .heatmap
    }

    var shouldMountSummaryFloatingButton: Bool {
        props.rootContentState == .content
            && !isSummarySheetPresented
            && !isYearSummarySheetPresented
    }

    var shouldShowSummaryFloatingButton: Bool {
        shouldMountSummaryFloatingButton
            && isSummaryFloatingButtonVisible
    }

    var activeMonthPage: MonthPage? {
        monthPageStateIfLoaded(for: props.pagerSelection)
    }

    var activeSelectedDate: Date? {
        activeMonthPage?.selectedDate
    }

    var heatmapYearMonthPages: [MonthPage] {
        props.heatmapYearMonthPages
            .sorted(by: { $0.monthStart < $1.monthStart })
    }

    var isCurrentYearHeatmapLoading: Bool {
        let hasLoadedMonth = heatmapYearMonthPages.contains { $0.loadState == .loaded }
        return props.selectedYearLoadState == .loading && !hasLoadedMonth
    }

    var summaryFloatingButtonIconName: String {
        "chart.bar.xaxis"
    }

    var summaryFloatingButtonAccessibilityLabel: String {
        isHeatmapMode ? "打开年度阅读总结" : "打开月度阅读总结"
    }

    var presentedSummarySheetData: MonthSummarySheetData {
        let monthStart = summarySheetMonthStart ?? props.pagerSelection
        return summarySheetData(for: monthStart)
    }

    func monthPageStateIfLoaded(for monthStart: Date) -> MonthPage? {
        props.monthPages.first(where: { $0.monthStart == monthStart })
    }

    func openSummaryManually() {
        if isHeatmapMode {
            openYearSummaryManually()
            return
        }
        openMonthSummaryManually()
    }

    func openMonthSummaryManually() {
        let normalizedMonthStart = Calendar.current.startOfDay(for: props.pagerSelection)
        summarySheetMonthStart = normalizedMonthStart
        isSummaryFloatingButtonVisible = false
        isSummarySheetPresented = true
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    func openYearSummaryManually() {
        isSummaryFloatingButtonVisible = false
        isYearSummarySheetPresented = true
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    func applySummaryFloatingButtonInitialPolicyIfNeeded() {
        if !hasAppliedSummaryFloatingButtonInitialPolicy {
            hasAppliedSummaryFloatingButtonInitialPolicy = true
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonInitialVisibleProtection,
                force: true
            )
            return
        }
        markSummaryFloatingButtonInteraction(force: true)
    }

    func hideSummaryFloatingButtonImmediately() {
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
        guard isSummaryFloatingButtonVisible else { return }
        summaryFloatingButtonHiddenScale = Layout.summaryFloatingButtonHideScaleTo
        summaryFloatingButtonHiddenOffsetY = Layout.summaryFloatingButtonHideOffsetY
        withAnimation(.easeOut(duration: Layout.summaryFloatingButtonHideDuration)) {
            isSummaryFloatingButtonVisible = false
        }
    }

    func markSummaryFloatingButtonInteraction(
        protectedFor: TimeInterval = Layout.summaryFloatingButtonPostInteractionProtection,
        force: Bool = false
    ) {
        guard props.rootContentState == .content,
              !isSummarySheetPresented,
              !isYearSummarySheetPresented else {
            return
        }

        let now = Date()
        if !force,
           isSummaryFloatingButtonVisible,
           now.timeIntervalSince(summaryFloatingButtonLastInteractionAt) < Layout.summaryFloatingButtonInteractionThrottle {
            return
        }

        summaryFloatingButtonLastInteractionAt = now
        summaryFloatingButtonHideNotBefore = now.addingTimeInterval(protectedFor)
        summaryFloatingButtonInteractionToken &+= 1

        if !isSummaryFloatingButtonVisible {
            summaryFloatingButtonHiddenScale = Layout.summaryFloatingButtonShowScaleFrom
            summaryFloatingButtonHiddenOffsetY = Layout.summaryFloatingButtonShowOffsetY
            withAnimation(.spring(
                response: Layout.summaryFloatingButtonShowResponse,
                dampingFraction: Layout.summaryFloatingButtonShowDamping
            )) {
                isSummaryFloatingButtonVisible = true
            }
        }

        scheduleSummaryFloatingButtonAutoHide(for: summaryFloatingButtonInteractionToken)
    }

    func scheduleSummaryFloatingButtonAutoHide(for token: UInt64) {
        summaryFloatingButtonAutoHideTask?.cancel()
        let fireDate = max(
            summaryFloatingButtonHideNotBefore,
            Date().addingTimeInterval(Layout.summaryFloatingButtonIdleHideDelay)
        )
        let sleepSeconds = max(0, fireDate.timeIntervalSinceNow)

        summaryFloatingButtonAutoHideTask = Task {
            try? await Task.sleep(for: .seconds(sleepSeconds))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard token == summaryFloatingButtonInteractionToken else { return }
                guard props.rootContentState == .content,
                      !isSummarySheetPresented,
                      !isYearSummarySheetPresented,
                      isSummaryFloatingButtonVisible else {
                    return
                }

                summaryFloatingButtonHiddenScale = Layout.summaryFloatingButtonHideScaleTo
                summaryFloatingButtonHiddenOffsetY = Layout.summaryFloatingButtonHideOffsetY
                withAnimation(.easeOut(duration: Layout.summaryFloatingButtonHideDuration)) {
                    isSummaryFloatingButtonVisible = false
                }
            }
        }
    }

    func syncSummarySheetMonthIfNeeded(monthStart: Date) {
        guard isSummarySheetPresented else { return }
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        guard summarySheetMonthStart != normalizedMonthStart else { return }
        withAnimation(.snappy(duration: 0.24)) {
            summarySheetMonthStart = normalizedMonthStart
        }
    }

    func switchSummarySheetMonth(to monthStart: Date) {
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        guard normalizedMonthStart != props.pagerSelection else { return }
        withAnimation(.snappy(duration: 0.3)) {
            onPagerSelectionChanged(normalizedMonthStart)
            summarySheetMonthStart = normalizedMonthStart
        }
    }

    func summarySheetData(for monthStart: Date) -> MonthSummarySheetData {
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        let page = monthPageStateIfLoaded(for: normalizedMonthStart) ?? monthPageState(for: normalizedMonthStart)
        return buildMonthSummary(from: page)
    }

    func buildMonthSummary(from page: MonthPage) -> MonthSummarySheetData {
        let cal = Calendar.current
        let monthStart = cal.startOfDay(for: page.monthStart)
        let totalDays = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let activeDays = activeDayCount(in: page.dayMap)
        let previous = previousMonthPage(for: monthStart)
        let previousActiveDays = previous.map { activeDayCount(in: $0.dayMap) }
        let activeDaysDelta = previousActiveDays.map { activeDays - $0 }
        let readSecondsDelta = previous.map { page.summary.totalReadSeconds - $0.summary.totalReadSeconds }
        let noteCountDelta = previous.map { page.summary.noteCount - $0.summary.noteCount }
        let peakSlot = peakTimeSlot(in: page.summary)
        let hasDurationRankingFallback = page.readingDurationTopBooks.contains { book in
            page.rankingBarColorsByBookId[book.bookId]?.state == .failed
        }

        return MonthSummarySheetData(
            monthStart: monthStart,
            activeDays: activeDays,
            totalDays: totalDays,
            longestStreak: longestActiveStreak(in: page.dayMap, calendar: cal),
            monthSummary: page.summary,
            activeDaysDelta: activeDaysDelta,
            readSecondsDelta: readSecondsDelta,
            noteCountDelta: noteCountDelta,
            peakTimeSlot: peakSlot?.slot,
            peakTimeSlotRatio: peakSlot?.ratio,
            durationTopBooks: page.readingDurationTopBooks,
            rankingBarColorsByBookId: page.rankingBarColorsByBookId,
            hasDurationRankingFallback: hasDurationRankingFallback
        )
    }

    func activeDayCount(in dayMap: [Date: ReadCalendarDay]) -> Int {
        dayMap.values.filter { !$0.books.isEmpty || $0.isReadDoneDay }.count
    }

    func previousMonthPage(for monthStart: Date) -> MonthPage? {
        guard let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: monthStart) else {
            return nil
        }
        return monthPageStateIfLoaded(for: Calendar.current.startOfDay(for: previousMonth))
    }

    func peakTimeSlot(in summary: ReadCalendarMonthSummary) -> (slot: ReadCalendarTimeSlot, ratio: Int)? {
        let total = summary.timeSlotReadSeconds.values.reduce(0, +)
        guard total > 0 else { return nil }
        guard let (slot, value) = summary.timeSlotReadSeconds.max(by: { $0.value < $1.value }),
              value > 0 else {
            return nil
        }
        let ratio = Int((Double(value) / Double(total) * 100).rounded())
        return (slot, ratio)
    }

    func longestActiveStreak(
        in dayMap: [Date: ReadCalendarDay],
        calendar cal: Calendar
    ) -> Int {
        let activeDates = dayMap
            .values
            .filter { !$0.books.isEmpty || $0.isReadDoneDay }
            .map { cal.startOfDay(for: $0.date) }
            .sorted()
        guard !activeDates.isEmpty else { return 0 }

        var best = 1
        var current = 1
        for index in 1..<activeDates.count {
            let prev = activeDates[index - 1]
            let now = activeDates[index]
            let diff = cal.dateComponents([.day], from: prev, to: now).day ?? 0
            if diff == 1 {
                current += 1
            } else if diff > 1 {
                current = 1
            }
            best = max(best, current)
        }
        return best
    }

    func evaluateStreakHintIfNeeded() {
        guard props.rootContentState == .content,
              props.displayMode == .activityEvent,
              props.isStreakHintEnabled,
              let activePage = activeMonthPage else {
            return
        }

        guard let selectedDate = activePage.selectedDate else { return }
        let streak = activePage.streakLengthEnding(at: selectedDate)
        let milestones = [3, 7, 14, 21, 30]
        guard let milestone = milestones.first(where: { $0 == streak }) else { return }

        var shown = shownStreakMilestonesByMonth[activePage.monthStart] ?? []
        guard !shown.contains(milestone) else { return }
        shown.insert(milestone)
        shownStreakMilestonesByMonth[activePage.monthStart] = shown

        let message = streakMilestoneText(milestone)
        streakHintTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) {
            streakHintMessage = message
        }
        streakHintTask = Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) {
                streakHintMessage = nil
            }
        }
    }

    func streakMilestoneText(_ streak: Int) -> String {
        switch streak {
        case 3:
            return "已连续阅读 3 天"
        case 7:
            return "已连续阅读 7 天"
        case 14:
            return "已连续阅读 14 天"
        case 21:
            return "已连续阅读 21 天"
        default:
            return "已连续阅读 \(streak) 天"
        }
    }

    var pagerSelectionBinding: Binding<Date> {
        Binding(
            get: { props.pagerSelection },
            set: { newValue in
                guard newValue != props.pagerSelection else { return }
                withAnimation(.snappy(duration: 0.32)) {
                    onPagerSelectionChanged(newValue)
                }
            }
        )
    }

    var integratedCalendarContainer: some View {
        VStack(spacing: shouldShowWeekdayHeader ? Layout.headerToGridSpacing : 0) {
            if shouldShowWeekdayHeader {
                ReadCalendarWeekdayHeader(minHeight: Layout.weekdayHeaderHeight)
                    .zIndex(1)
            }
            contentContainer
                .zIndex(0)
        }
        .padding(.top, Layout.calendarInnerTopPadding)
        .padding(.bottom, Layout.calendarInnerBottomPadding + interactiveBottomInset)
    }

    var contentContainer: some View {
        ZStack(alignment: .top) {
            switch props.rootContentState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .empty:
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .content:
                activeContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(.top, shouldShowWeekdayHeader ? Layout.gridTopInset : 0)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay {
            GeometryReader { proxy in
                if shouldMountSummaryFloatingButton {
                    ReadCalendarSummaryFloatingButton(
                        iconSystemName: summaryFloatingButtonIconName,
                        accessibilityLabel: summaryFloatingButtonAccessibilityLabel,
                        action: openSummaryManually
                    )
                    .padding(.trailing, Layout.summaryFloatingButtonTrailing)
                    .padding(.bottom, floatingButtonBottomPadding(safeAreaBottom: proxy.safeAreaInsets.bottom))
                    .opacity(shouldShowSummaryFloatingButton ? 1 : 0)
                    .scaleEffect(shouldShowSummaryFloatingButton ? 1 : summaryFloatingButtonHiddenScale)
                    .offset(y: shouldShowSummaryFloatingButton ? 0 : summaryFloatingButtonHiddenOffsetY)
                    .allowsHitTesting(shouldShowSummaryFloatingButton)
                    .accessibilityHidden(!shouldShowSummaryFloatingButton)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
    }

    @ViewBuilder
    var activeContent: some View {
        if isHeatmapMode {
            heatmapYearContent
        } else {
            calendarPager
        }
    }

    var shouldShowWeekdayHeader: Bool {
        props.displayMode != .heatmap
    }

    var interactiveBottomInset: CGFloat {
        Layout.interactiveBottomInset
    }

    var immersiveScrollTailInset: CGFloat {
        Layout.contentBleedBottomInset
    }

    func floatingButtonBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        let resolvedSafeAreaBottom = max(safeAreaBottom, Spacing.contentEdge)
        return Layout.summaryFloatingButtonBottomBase + resolvedSafeAreaBottom
    }

    var calendarPager: some View {
        TabView(selection: pagerSelectionBinding) {
            ForEach(props.availableMonths, id: \.self) { monthStart in
                monthPage(for: monthStart)
                    .tag(monthStart)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .contentMargins(.top, 0, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.32), value: props.pagerSelection)
    }

    @ViewBuilder
    var heatmapYearContent: some View {
        if isCurrentYearHeatmapLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Layout.yearHeatmapGridSpacing) {
                    if let selectedYearErrorMessage = props.selectedYearErrorMessage,
                       props.selectedYearLoadState == .failed {
                        ReadCalendarInlineErrorBanner(
                            message: selectedYearErrorMessage,
                            onRetry: onRetry
                        )
                        .padding(.horizontal, Layout.yearHeatmapErrorBannerHorizontalInset)
                        .padding(.bottom, Layout.yearHeatmapErrorBannerBottomInset)
                    }

                    let columns = [
                        GridItem(.flexible(), spacing: Layout.yearHeatmapGridSpacing),
                        GridItem(.flexible(), spacing: Layout.yearHeatmapGridSpacing)
                    ]
                    LazyVGrid(columns: columns, spacing: Layout.yearHeatmapGridSpacing) {
                        ForEach(heatmapYearMonthPages) { page in
                            yearHeatmapMonthCard(for: page)
                        }
                    }
                    .padding(.horizontal, Spacing.screenEdge)

                    yearHeatmapLegend
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Layout.yearHeatmapLegendTopPadding)
                }
                .padding(.bottom, immersiveScrollTailInset)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onScrollPhaseChange { _, phase in
                guard phase.isScrolling else { return }
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
                )
            }
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(.container, edges: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.snappy(duration: 0.24), value: props.selectedYear)
        }
    }

    func yearHeatmapMonthCard(for page: MonthPage) -> some View {
        let monthTitle = yearHeatmapMonthTitle(page.monthStart)
        return Button {
            openMonthSummaryFromYearCard(for: page.monthStart)
        } label: {
            VStack(alignment: .leading, spacing: Layout.yearHeatmapMonthCardSpacing) {
                Text(monthTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(height: Layout.yearHeatmapMonthCardTitleHeight, alignment: .topLeading)

                if page.isLoading && page.isDayMapEmpty {
                    yearHeatmapLoadingGrid
                } else {
                    ReadCalendarMonthGrid(
                        weeks: yearCompactWeeks(for: page),
                        laneLimit: props.laneLimit,
                        displayMode: .heatmapYearCompact,
                        selectedDate: nil,
                        isHapticsEnabled: false,
                        dayPayloadProvider: { date in
                            page.payload(for: date)
                        },
                        onSelectDay: { _ in }
                    )
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(Layout.yearHeatmapMonthCardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(
                    cornerRadius: Layout.yearHeatmapMonthCardCornerRadius,
                    style: .continuous
                )
                .fill(Color.contentBackground.opacity(0.96))
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: Layout.yearHeatmapMonthCardCornerRadius,
                    style: .continuous
                )
                // 年热力图月卡使用弱边框，避免与内容色块争夺视觉焦点。
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
        }
        .buttonStyle(.plain)
    }

    func monthPage(for monthStart: Date) -> some View {
        let pageState = monthPageState(for: monthStart)

        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .top) {
                if pageState.isLoading && pageState.isDayMapEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                        .transition(.opacity)
                } else {
                    calendarWeeks(for: pageState, allowsDateSelection: true)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(.opacity.combined(with: .scale(scale: 0.99)))
                }
            }
            .padding(.bottom, immersiveScrollTailInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onScrollPhaseChange { _, phase in
            guard phase.isScrolling else { return }
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(.smooth(duration: 0.24), value: pageState.loadState)
    }

    func calendarWeeks(for page: MonthPage, allowsDateSelection: Bool) -> some View {
        ReadCalendarMonthGrid(
            weeks: page.weeks,
            laneLimit: props.laneLimit,
            displayMode: allowsDateSelection ? mapGridDisplayMode(props.displayMode) : .heatmap,
            selectedDate: allowsDateSelection ? page.selectedDate : nil,
            isHapticsEnabled: allowsDateSelection ? props.isHapticsEnabled : false,
            dayPayloadProvider: { date in
                page.payload(for: date)
            },
            onSelectDay: { date in
                guard allowsDateSelection else { return }
                markSummaryFloatingButtonInteraction()
                withAnimation(.smooth(duration: 0.22)) {
                    if let selectedDate = page.selectedDate,
                       Calendar.current.isDate(selectedDate, inSameDayAs: date) {
                        onSelectDate(nil)
                    } else {
                        onSelectDate(date)
                    }
                }
            }
        )
    }

    var emptyState: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.brand.opacity(0.8))

            if let errorMessage = props.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.feedbackWarning)
                    .multilineTextAlignment(.center)

                Button("重试", action: onRetry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brand)
            } else {
                Text(isHeatmapMode ? "暂无可展示的年度数据" : "暂无可展示的阅读月份")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight)
    }

    func monthPageState(for monthStart: Date) -> MonthPage {
        if let page = props.monthPages.first(where: { $0.monthStart == monthStart }) {
            return page
        }

        return MonthPage(
            monthStart: monthStart,
            weeks: [],
            dayMap: [:],
            readingDurationTopBooks: [],
            summary: .empty,
            rankingBarColorsByBookId: [:],
            selectedDate: nil,
            todayStart: Calendar.current.startOfDay(for: Date()),
            laneLimit: props.laneLimit,
            isDayMapEmpty: true,
            loadState: .loading,
            errorMessage: nil
        )
    }

    func mapGridDisplayMode(_ mode: DisplayMode) -> ReadCalendarMonthGrid.DisplayMode {
        switch mode {
        case .heatmap:
            return .heatmap
        case .activityEvent:
            return .activityEvent
        case .bookCover:
            return .bookCover
        }
    }

    func openMonthSummaryFromYearCard(for monthStart: Date) {
        let normalized = Calendar.current.startOfDay(for: monthStart)
        withAnimation(.snappy(duration: 0.28)) {
            onPagerSelectionChanged(normalized)
        }
        summarySheetMonthStart = normalized
        isSummaryFloatingButtonVisible = false
        isSummarySheetPresented = true
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    func openMonthSummaryAfterAuxSheetDismiss(monthStart: Date) {
        let normalized = Calendar.current.startOfDay(for: monthStart)
        summarySheetMonthStart = normalized
        isYearSummarySheetPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !isYearSummarySheetPresented else { return }
            isSummarySheetPresented = true
        }
    }

    func yearHeatmapMonthTitle(_ monthStart: Date) -> String {
        let month = Calendar.current.component(.month, from: monthStart)
        return "\(month)月"
    }

    func yearCompactWeeks(for page: MonthPage) -> [ReadCalendarMonthGrid.WeekData] {
        var weeks = Array(page.weeks.prefix(Layout.yearHeatmapCompactWeekCount))
        let emptyDays = Array<Date?>(repeating: nil, count: 7)
        let cal = Calendar.current
        if weeks.isEmpty {
            weeks.append(
                ReadCalendarMonthGrid.WeekData(
                    weekStart: cal.startOfDay(for: page.monthStart),
                    days: emptyDays,
                    segments: []
                )
            )
        }
        var cursor = weeks.last?.weekStart ?? cal.startOfDay(for: page.monthStart)

        while weeks.count < Layout.yearHeatmapCompactWeekCount {
            cursor = cal.date(byAdding: .day, value: 7, to: cursor).map { cal.startOfDay(for: $0) } ?? cursor
            weeks.append(
                ReadCalendarMonthGrid.WeekData(
                    weekStart: cursor,
                    days: emptyDays,
                    segments: []
                )
            )
        }

        return weeks
    }

    var yearHeatmapLoadingGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<Layout.yearHeatmapCompactWeekCount, id: \.self) { _ in
                HStack(spacing: Layout.yearHeatmapLoadingCellSpacing) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                            .fill(Color.readCalendarSelectionFill.opacity(0.42))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    var yearHeatmapLegend: some View {
        HStack(spacing: Spacing.half) {
            Text("少")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            ForEach(HeatmapLevel.allCases.filter { $0 != .none }, id: \.rawValue) { level in
                RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                    .fill(level.color)
                    .frame(width: Layout.yearHeatmapLegendSquare, height: Layout.yearHeatmapLegendSquare)
            }

            Text("多")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ReadCalendarContentView(
        props: .init(
            monthTitle: "2026年2月",
            yearTitle: "2026年",
            availableMonths: [Calendar.current.startOfDay(for: Date())],
            availableYears: [2026],
            pagerSelection: Calendar.current.startOfDay(for: Date()),
            selectedYear: 2026,
            displayMode: .activityEvent,
            laneLimit: 4,
            isHapticsEnabled: true,
            isStreakHintEnabled: true,
            rootContentState: .loading,
            errorMessage: nil,
            monthPages: [],
            heatmapYearMonthPages: [],
            selectedYearLoadState: .idle,
            selectedYearErrorMessage: nil,
            yearSummary: .init(
                year: 2026,
                activeDays: 0,
                totalReadSeconds: 0,
                noteCount: 0,
                finishedBookCount: 0,
                activeDaysDelta: nil,
                readSecondsDelta: nil,
                noteCountDelta: nil,
                topBooks: [],
                rankingBarColorsByBookId: [:],
                monthContributions: [],
                isLoading: false,
                errorMessage: nil
            )
        ),
        onDisplayModeChanged: { _ in },
        onPagerSelectionChanged: { _ in },
        onYearSelectionChanged: { _ in },
        onSelectDate: { _ in },
        onRetry: {}
    )
    .padding(.horizontal, Spacing.screenEdge)
    .padding(.bottom, Spacing.base)
    .background(Color.windowBackground)
}
