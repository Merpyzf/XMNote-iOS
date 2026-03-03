/**
 * [INPUT]: 依赖 CalendarMonthStepperBar/ReadCalendarMonthGrid 页面私有组件、ReadCalendarDay/ReadCalendarMonthlyDurationBook 领域模型与 DesignTokens 视觉令牌（不含卡片装饰令牌）
 * [OUTPUT]: 对外提供 ReadCalendarContentView（完整阅读日历控件：模式切换 + 月份点击切换 + weekday + 分页月网格 + 状态反馈 + 月总结排行与上月对比）
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
        let availableMonths: [Date]
        let pagerSelection: Date
        let displayMode: DisplayMode
        let laneLimit: Int
        let isHapticsEnabled: Bool
        let isStreakHintEnabled: Bool
        let rootContentState: RootContentState
        let errorMessage: String?
        let monthPages: [MonthPage]
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

    private enum Layout {
        static let topControlTopPadding: CGFloat = 10
        static let topControlBottomPadding: CGFloat = 14
        static let weekdayHeaderHeight: CGFloat = 32
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerTopPadding: CGFloat = Spacing.cozy
        static let calendarInnerBottomPadding: CGFloat = 10
        static let headerToGridSpacing: CGFloat = Spacing.half
        static let gridTopInset: CGFloat = 2
        static let streakHintBottomPadding: CGFloat = Spacing.cozy
        static let summarySheetCompactRatio: CGFloat = 0.48
        static let summaryFloatingButtonTrailing: CGFloat = Spacing.screenEdge
        static let summaryFloatingButtonBottom: CGFloat = Spacing.double
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
    }

    let props: Props
    let onDisplayModeChanged: (DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onSelectDate: (Date?) -> Void
    let onRetry: () -> Void
    @State private var streakHintMessage: String?
    @State private var streakHintTask: Task<Void, Never>?
    @State private var shownStreakMilestonesByMonth: [Date: Set<Int>] = [:]
    @State private var isSummarySheetPresented = false
    @State private var summarySheetMonthStart: Date?
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
                availableMonths: props.availableMonths,
                pagerSelection: props.pagerSelection,
                displayMode: props.displayMode,
                onDisplayModeChanged: onDisplayModeChanged,
                onPagerSelectionChanged: onPagerSelectionChanged
            )
                .padding(.top, Layout.topControlTopPadding)
                .padding(.bottom, Layout.topControlBottomPadding)

            if let streakHintMessage,
               props.rootContentState == .content,
               props.displayMode == .activityEvent,
               props.isStreakHintEnabled {
                ReadCalendarStreakHintBanner(text: streakHintMessage)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.bottom, Layout.streakHintBottomPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            integratedCalendarContainer

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
                .presentationBackground(Color.bgSheet)
        }
    }
}

// MARK: - Subviews

private extension ReadCalendarContentView {
    var shouldMountSummaryFloatingButton: Bool {
        props.rootContentState == .content
            && !isSummarySheetPresented
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

    var presentedSummarySheetData: MonthSummarySheetData {
        let monthStart = summarySheetMonthStart ?? props.pagerSelection
        return summarySheetData(for: monthStart)
    }

    func monthPageStateIfLoaded(for monthStart: Date) -> MonthPage? {
        props.monthPages.first(where: { $0.monthStart == monthStart })
    }

    func openMonthSummaryManually() {
        let normalizedMonthStart = Calendar.current.startOfDay(for: props.pagerSelection)
        summarySheetMonthStart = normalizedMonthStart
        isSummaryFloatingButtonVisible = false
        isSummarySheetPresented = true
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
        guard props.rootContentState == .content, !isSummarySheetPresented else { return }

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
        VStack(spacing: Layout.headerToGridSpacing) {
            ReadCalendarWeekdayHeader(minHeight: Layout.weekdayHeaderHeight)
                .zIndex(1)
            contentContainer
                .zIndex(0)
        }
        .padding(.top, Layout.calendarInnerTopPadding)
        .padding(.bottom, Layout.calendarInnerBottomPadding)
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
                calendarPager
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(.top, Layout.gridTopInset)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            if shouldMountSummaryFloatingButton {
                ReadCalendarSummaryFloatingButton(action: openMonthSummaryManually)
                    .padding(.trailing, Layout.summaryFloatingButtonTrailing)
                    .padding(.bottom, Layout.summaryFloatingButtonBottom)
                    .opacity(shouldShowSummaryFloatingButton ? 1 : 0)
                    .scaleEffect(shouldShowSummaryFloatingButton ? 1 : summaryFloatingButtonHiddenScale)
                    .offset(y: shouldShowSummaryFloatingButton ? 0 : summaryFloatingButtonHiddenOffsetY)
                    .allowsHitTesting(shouldShowSummaryFloatingButton)
                    .accessibilityHidden(!shouldShowSummaryFloatingButton)
            }
        }
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

    func monthPage(for monthStart: Date) -> some View {
        let pageState = monthPageState(for: monthStart)

        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .top) {
                if pageState.isLoading && pageState.isDayMapEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                        .transition(.opacity)
                } else {
                    calendarWeeks(for: pageState)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(.opacity.combined(with: .scale(scale: 0.99)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onScrollPhaseChange { _, phase in
            guard phase.isScrolling else { return }
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth(duration: 0.24), value: pageState.loadState)
    }

    func calendarWeeks(for page: MonthPage) -> some View {
        ReadCalendarMonthGrid(
            weeks: page.weeks,
            laneLimit: props.laneLimit,
            displayMode: mapGridDisplayMode(props.displayMode),
            selectedDate: page.selectedDate,
            isHapticsEnabled: props.isHapticsEnabled,
            dayPayloadProvider: { date in
                page.payload(for: date)
            },
            onSelectDay: { date in
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
                Text("暂无可展示的阅读月份")
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
}

#Preview {
    ReadCalendarContentView(
        props: .init(
            monthTitle: "2026年2月",
            availableMonths: [Calendar.current.startOfDay(for: Date())],
            pagerSelection: Calendar.current.startOfDay(for: Date()),
            displayMode: .activityEvent,
            laneLimit: 4,
            isHapticsEnabled: true,
            isStreakHintEnabled: true,
            rootContentState: .loading,
            errorMessage: nil,
            monthPages: []
        ),
        onDisplayModeChanged: { _ in },
        onPagerSelectionChanged: { _ in },
        onSelectDate: { _ in },
        onRetry: {}
    )
    .padding(.horizontal, Spacing.screenEdge)
    .padding(.bottom, Spacing.base)
    .background(Color.windowBackground)
}
