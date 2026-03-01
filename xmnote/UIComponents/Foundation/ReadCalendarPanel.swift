/**
 * [INPUT]: 依赖 CalendarMonthStepperBar/ReadCalendarMonthGrid 复用组件、ReadCalendarDay 领域模型与 DesignTokens 视觉令牌（不含卡片装饰令牌）
 * [OUTPUT]: 对外提供 ReadCalendarPanel（完整阅读日历控件：模式切换 + 月份点击切换 + weekday + 分页月网格 + 状态反馈）
 * [POS]: UIComponents/Foundation 的阅读日历完整控件，供业务页面以纯展示驱动方式复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct ReadCalendarPanel: View {
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

        var iconName: String {
            switch self {
            case .heatmap:
                return "square.grid.3x3.fill"
            case .activityEvent:
                return "calendar.badge.clock"
            case .bookCover:
                return "books.vertical.fill"
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

    struct SummaryTopBook: Identifiable, Hashable {
        let bookId: Int64
        let name: String
        let activeDays: Int
        let readDoneDays: Int

        var id: Int64 { bookId }
    }

    struct MonthSummarySheetData: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalDays: Int
        let uniqueBookCount: Int
        let totalBookEvents: Int
        let readDoneCount: Int
        let longestStreak: Int
        let activeWeekLabel: String
        let activeRate: Int
        let topBooks: [SummaryTopBook]

        var id: Date { monthStart }

        var hasActivity: Bool {
            activeDays > 0
        }
    }

    private enum Layout {
        static let topControlTopPadding: CGFloat = 10
        static let topControlBottomPadding: CGFloat = 14
        static let topControlSpacing: CGFloat = Spacing.cozy
        static let modeSwitcherWidth: CGFloat = 116
        static let summaryButtonSize: CGFloat = 32
        static let weekdayHeaderHeight: CGFloat = 32
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerTopPadding: CGFloat = Spacing.cozy
        static let calendarInnerBottomPadding: CGFloat = 10
        static let headerToGridSpacing: CGFloat = Spacing.half
        static let gridTopInset: CGFloat = 2
        static let streakHintBottomPadding: CGFloat = Spacing.cozy
        static let streakHintVerticalPadding: CGFloat = 6
        static let streakHintHorizontalPadding: CGFloat = Spacing.base
        static let summaryAutoShowDelayMs: UInt64 = 420
        static let summarySheetCompactRatio: CGFloat = 0.44
        static let summaryMetricCardHeight: CGFloat = 62
    }

    let props: Props
    let onDisplayModeChanged: (DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onSelectDate: (Date?) -> Void
    let onRetry: () -> Void
    @State private var streakHintMessage: String?
    @State private var streakHintTask: Task<Void, Never>?
    @State private var shownStreakMilestonesByMonth: [Date: Set<Int>] = [:]
    @State private var summarySheet: MonthSummarySheetData?
    @State private var autoShownSummaryMonths: Set<Date> = []
    @State private var summaryAutoShowTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            topControlRow
                .padding(.top, Layout.topControlTopPadding)
                .padding(.bottom, Layout.topControlBottomPadding)

            if let streakHintMessage,
               props.rootContentState == .content,
               props.displayMode == .activityEvent,
               props.isStreakHintEnabled {
                streakHint(streakHintMessage)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.bottom, Layout.streakHintBottomPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            integratedCalendarContainer

            if let errorMessage = props.errorMessage,
               props.rootContentState == .content {
                inlineError(errorMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: props.errorMessage)
        .onAppear {
            evaluateStreakHintIfNeeded()
            scheduleAutoSummaryIfNeeded()
        }
        .onChange(of: props.pagerSelection) { _, _ in
            evaluateStreakHintIfNeeded()
            scheduleAutoSummaryIfNeeded()
        }
        .onChange(of: activeSelectedDate) { _, _ in
            evaluateStreakHintIfNeeded()
        }
        .onChange(of: activeMonthPage?.loadState) { _, _ in
            scheduleAutoSummaryIfNeeded()
        }
        .onChange(of: props.displayMode) { _, mode in
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
            summaryAutoShowTask?.cancel()
            summaryAutoShowTask = nil
        }
        .sheet(item: $summarySheet) { sheet in
            monthSummarySheet(sheet)
                .presentationDetents([.fraction(Layout.summarySheetCompactRatio), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.bgSheet)
        }
    }
}

// MARK: - Subviews

private extension ReadCalendarPanel {
    var activeMonthPage: MonthPage? {
        monthPageStateIfLoaded(for: props.pagerSelection)
    }

    var activeSelectedDate: Date? {
        activeMonthPage?.selectedDate
    }

    func monthPageStateIfLoaded(for monthStart: Date) -> MonthPage? {
        props.monthPages.first(where: { $0.monthStart == monthStart })
    }

    func scheduleAutoSummaryIfNeeded() {
        summaryAutoShowTask?.cancel()
        summaryAutoShowTask = nil

        guard props.rootContentState == .content,
              let page = activeMonthPage,
              page.loadState == .loaded else {
            return
        }

        let monthStart = Calendar.current.startOfDay(for: page.monthStart)
        guard !autoShownSummaryMonths.contains(monthStart) else { return }

        summaryAutoShowTask = Task {
            try? await Task.sleep(nanoseconds: Layout.summaryAutoShowDelayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            guard props.rootContentState == .content,
                  props.pagerSelection == monthStart,
                  let latestPage = activeMonthPage,
                  latestPage.loadState == .loaded else {
                return
            }

            let summary = buildMonthSummary(from: latestPage)
            guard summary.hasActivity else { return }
            autoShownSummaryMonths.insert(monthStart)
            withAnimation(.snappy(duration: 0.2)) {
                summarySheet = summary
            }
        }
    }

    func openMonthSummaryManually() {
        guard let page = activeMonthPage else { return }
        autoShownSummaryMonths.insert(Calendar.current.startOfDay(for: page.monthStart))
        let summary = buildMonthSummary(from: page)
        withAnimation(.snappy(duration: 0.2)) {
            summarySheet = summary
        }
    }

    func buildMonthSummary(from page: MonthPage) -> MonthSummarySheetData {
        let cal = Calendar.current
        let monthStart = cal.startOfDay(for: page.monthStart)
        let totalDays = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30

        let activityDays = page.dayMap.values.filter { !$0.books.isEmpty || $0.isReadDoneDay }
        let activeDays = activityDays.count
        let totalBookEvents = page.dayMap.values.reduce(0) { partial, day in
            partial + day.books.count
        }
        let readDoneCount = page.dayMap.values.reduce(0) { partial, day in
            partial + day.readDoneCount
        }

        var uniqueBookIds: Set<Int64> = []
        var topBookMap: [Int64: SummaryTopBook] = [:]
        for day in page.dayMap.values {
            for book in day.books {
                uniqueBookIds.insert(book.id)
                let existing = topBookMap[book.id]
                topBookMap[book.id] = SummaryTopBook(
                    bookId: book.id,
                    name: book.name,
                    activeDays: (existing?.activeDays ?? 0) + 1,
                    readDoneDays: (existing?.readDoneDays ?? 0) + (book.isReadDoneOnThisDay ? 1 : 0)
                )
            }
        }

        let topBooks = topBookMap.values
            .sorted { lhs, rhs in
                if lhs.activeDays != rhs.activeDays { return lhs.activeDays > rhs.activeDays }
                if lhs.readDoneDays != rhs.readDoneDays { return lhs.readDoneDays > rhs.readDoneDays }
                return lhs.name < rhs.name
            }
            .prefix(2)
            .map { $0 }

        return MonthSummarySheetData(
            monthStart: monthStart,
            activeDays: activeDays,
            totalDays: totalDays,
            uniqueBookCount: uniqueBookIds.count,
            totalBookEvents: totalBookEvents,
            readDoneCount: readDoneCount,
            longestStreak: longestActiveStreak(in: page.dayMap, calendar: cal),
            activeWeekLabel: activeWeekLabel(in: page, calendar: cal),
            activeRate: totalDays > 0 ? Int((Double(activeDays) / Double(totalDays) * 100).rounded()) : 0,
            topBooks: topBooks
        )
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

    func activeWeekLabel(in page: MonthPage, calendar cal: Calendar) -> String {
        var bestCount = 0
        var bestRange: (Date, Date)?
        let targetYearMonth = cal.dateComponents([.year, .month], from: page.monthStart)

        for week in page.weeks {
            let dates = week.days.compactMap { $0 }.filter {
                let components = cal.dateComponents([.year, .month], from: $0)
                return components.year == targetYearMonth.year && components.month == targetYearMonth.month
            }
            guard let start = dates.first, let end = dates.last else { continue }
            let count = dates.reduce(0) { partial, day in
                guard let dayData = page.dayMap[cal.startOfDay(for: day)] else { return partial }
                return (!dayData.books.isEmpty || dayData.isReadDoneDay) ? partial + 1 : partial
            }
            if count > bestCount {
                bestCount = count
                bestRange = (start, end)
            }
        }

        guard let bestRange else { return "暂无活跃周" }
        let startDay = cal.component(.day, from: bestRange.0)
        let endDay = cal.component(.day, from: bestRange.1)
        return "\(startDay)-\(endDay)日（\(bestCount)天）"
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

    func streakHint(_ text: String) -> some View {
        HStack(spacing: Spacing.half) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brand)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.readCalendarSubtleText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.streakHintHorizontalPadding)
        .padding(.vertical, Layout.streakHintVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.readCalendarSelectionFill.opacity(0.56))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.readCalendarSelectionStroke.opacity(0.54), lineWidth: 0.6)
        }
    }

    var displayModeBinding: Binding<DisplayMode> {
        Binding(
            get: { props.displayMode },
            set: { newValue in
                guard newValue != props.displayMode else { return }
                withAnimation(.snappy(duration: 0.26)) {
                    onDisplayModeChanged(newValue)
                }
            }
        )
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
            weekdayHeader
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
    }

    var modeSwitcher: some View {
        Picker("阅读日历显示模式", selection: displayModeBinding) {
            ForEach(DisplayMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.iconName)
                    .labelStyle(.iconOnly)
                    .tag(mode)
                    .accessibilityLabel(mode.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("阅读日历显示模式")
        .accessibilityValue(props.displayMode.title)
    }

    var monthSwitcher: some View {
        CalendarMonthStepperBar(
            title: props.monthTitle,
            availableMonths: props.availableMonths,
            selectedMonth: props.pagerSelection,
            onSelectMonth: { monthStart in
                withAnimation(.snappy(duration: 0.3)) {
                    onPagerSelectionChanged(monthStart)
                }
            }
        )
    }

    var summaryEntryButton: some View {
        Button(action: openMonthSummaryManually) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.readCalendarSubtleText)
                .frame(width: Layout.summaryButtonSize, height: Layout.summaryButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .fill(Color.readCalendarSelectionFill.opacity(0.65))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.readCalendarSelectionStroke.opacity(0.55), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("月度阅读总结")
        .disabled(props.rootContentState != .content)
        .opacity(props.rootContentState == .content ? 1 : 0.45)
    }

    var topControlRow: some View {
        HStack(alignment: .center, spacing: Layout.topControlSpacing) {
            monthSwitcher
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            summaryEntryButton

            modeSwitcher
                .frame(width: Layout.modeSwitcherWidth)
        }
        .padding(.horizontal, Spacing.screenEdge)
    }

    func monthSummarySheet(_ sheet: MonthSummarySheetData) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                summaryHeader(sheet)
                summaryMetricsGrid(sheet)
                summaryTopBooks(sheet)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.double)
        }
    }

    func summaryHeader(_ sheet: MonthSummarySheetData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("\(summaryMonthTitle(sheet.monthStart))阅读总结")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            if sheet.hasActivity {
                Text("本月有 \(sheet.activeDays) 天在阅读，阅读活跃度 \(sheet.activeRate)%")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("本月暂无阅读记录")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    func summaryMetricsGrid(_ sheet: MonthSummarySheetData) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.base),
            GridItem(.flexible(), spacing: Spacing.base)
        ]
        return LazyVGrid(columns: columns, spacing: Spacing.base) {
            summaryMetricCard(title: "阅读天数", value: "\(sheet.activeDays)/\(sheet.totalDays)")
            summaryMetricCard(title: "活跃书籍", value: "\(sheet.uniqueBookCount) 本")
            summaryMetricCard(title: "事件总量", value: "\(sheet.totalBookEvents) 条")
            summaryMetricCard(title: "完读记录", value: "\(sheet.readDoneCount) 次")
            summaryMetricCard(title: "最长连续", value: "\(sheet.longestStreak) 天")
            summaryMetricCard(title: "活跃周", value: sheet.activeWeekLabel)
        }
    }

    func summaryMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.readCalendarSubtleText)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: Layout.summaryMetricCardHeight, alignment: .leading)
        .padding(.horizontal, Spacing.base)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.contentBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        }
    }

    func summaryTopBooks(_ sheet: MonthSummarySheetData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("本月最常阅读")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            if sheet.topBooks.isEmpty {
                Text("暂无可统计的书籍数据")
                    .font(.footnote)
                    .foregroundStyle(Color.textHint)
            } else {
                ForEach(Array(sheet.topBooks.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: Spacing.half) {
                        Text("#\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandDeep)
                            .frame(width: 26, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            Text("活跃 \(item.activeDays) 天 · 完读 \(item.readDoneDays) 天")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.top, Spacing.cozy)
    }

    func summaryMonthTitle(_ date: Date) -> String {
        SummaryFormatter.monthTitle.string(from: date)
    }

    var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                Text(weekday)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readCalendarSubtleText)
                    .frame(maxWidth: .infinity, minHeight: Layout.weekdayHeaderHeight)
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

    func inlineError(_ message: String) -> some View {
        HStack(spacing: Spacing.base) {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.feedbackWarning)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("重试", action: onRetry)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brand)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.cozy)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.readCalendarSelectionFill.opacity(0.62))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.readCalendarSelectionStroke.opacity(0.62), lineWidth: CardStyle.borderWidth)
        }
        .padding(.top, Spacing.base)
    }

    func monthPageState(for monthStart: Date) -> MonthPage {
        if let page = props.monthPages.first(where: { $0.monthStart == monthStart }) {
            return page
        }

        return MonthPage(
            monthStart: monthStart,
            weeks: [],
            dayMap: [:],
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

private enum SummaryFormatter {
    static let monthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        formatter.timeZone = .current
        return formatter
    }()
}

#Preview {
    ReadCalendarPanel(
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
