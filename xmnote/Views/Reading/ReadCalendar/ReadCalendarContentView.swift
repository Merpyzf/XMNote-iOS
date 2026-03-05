/**
 * [INPUT]: 依赖 CalendarMonthStepperBar/ReadCalendarMonthGrid/ReadCalendarCoverFanStack 页面私有组件、ReadCalendarDay/ReadCalendarMonthlyDurationBook 领域模型与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供 ReadCalendarContentView（完整阅读日历控件：模式切换 + 月份/年份切换 + 月分页/年度热力图 + 月/年总结弹层 + 书封全屏浮层）
 * [POS]: ReadCalendar 业务页面壳层组件，负责日历主内容组合、封面全量展开与业务内弹层触发
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读日历主界面组件，组织月/年切换、日历网格和总结弹层入口。
struct ReadCalendarContentView: View {
    /// DisplayMode 表示日历内容展示方式（热力图/活动事件/封面）。
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

        /// 根据展示模式和选中态返回顶部切换按钮图标。
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

    /// RootContentState 表示页面根状态（加载/空态/有内容）。
    enum RootContentState: Hashable {
        case loading
        case empty
        case content
    }

    /// MonthLoadState 表示单月分页的加载状态。
    enum MonthLoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// YearLoadState 表示年度聚合视图的加载状态。
    enum YearLoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// MonthPage 封装单月渲染快照，聚合周网格、日数据、排行与摘要。
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

        /// 把当日业务数据映射为网格单元载荷（热度、读完标记、连续阅读态）。
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

        /// 从目标日期向前统计连续活跃天数，用于连续阅读里程碑判断。
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

    /// Props 汇总页面渲染所需输入，解耦 View 与 ViewModel 的状态边界。
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

    /// MonthSummarySheetData 定义月总结弹层的数据载荷。
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

    /// YearSummaryMonthContribution 描述某月在年度里的活跃与时长贡献。
    struct YearSummaryMonthContribution: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalReadSeconds: Int

        var id: Date { monthStart }
    }

    /// YearSummarySheetData 定义年度总结弹层的数据载荷。
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

    /// BookCoverFullscreenPayload 定义封面全屏浮层的数据快照。
    struct BookCoverFullscreenPayload: Identifiable, Hashable {
        let date: Date
        let items: [ReadCalendarCoverFanStack.Item]
        let stackStyle: ReadCalendarCoverFanStack.Style
        let stackedVisibleCount: Int
        let stackedSeed: ReadCalendarCoverFanStack.LayoutSeed
        let transitionSession: ReadCalendarCoverTransitionSession

        var id: Date { date }
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
        static let bookCoverFullscreenOverlayZIndex: Double = 40
        static let coverEntryCuePeakDuration: CGFloat = 0.16
        static let coverEntryCueFadeDuration: CGFloat = 0.22
        static let coverEntryCueHoldNanoseconds: UInt64 = 220_000_000
        static let coverEntryCueCleanupNanoseconds: UInt64 = 280_000_000
        static let bookCoverGridCoordinateSpaceName = "read-calendar-book-cover-grid-space"
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
    @State private var bookCoverFullscreenPayload: BookCoverFullscreenPayload?
    @State private var bookCoverStackFramesByDate: [Date: CGRect] = [:]
    @State private var coverEntryCueDate: Date?
    @State private var coverEntryCueProgress: CGFloat = 0
    @State private var coverEntryCueTask: Task<Void, Never>?

    var body: some View {
        bodyContainer
    }
}

// MARK: - Subviews

private extension ReadCalendarContentView {
    var bodyContainer: some View {
        baseCalendarStack
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
                    closeBookCoverFullscreen(animated: false)
                }
            }
            .onChange(of: props.pagerSelection) { _, monthStart in
                evaluateStreakHintIfNeeded()
                syncSummarySheetMonthIfNeeded(monthStart: monthStart)
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
                )
                bookCoverStackFramesByDate = [:]
                closeBookCoverFullscreen(animated: false)
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
                if mode != .bookCover {
                    bookCoverStackFramesByDate = [:]
                    closeBookCoverFullscreen()
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
                bookCoverStackFramesByDate = [:]
                closeBookCoverFullscreen(animated: false)
                cancelCoverEntryCue()
            }
            .overlay {
                bookCoverFullscreenOverlay
            }
            .sheet(isPresented: $isSummarySheetPresented, onDismiss: {
                summarySheetMonthStart = nil
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonPostDismissProtection,
                    force: true
                )
            }) {
                monthSummarySheetContent
            }
            .sheet(isPresented: $isYearSummarySheetPresented, onDismiss: {
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonPostDismissProtection,
                    force: true
                )
            }) {
                yearSummarySheetContent
            }
    }

    var baseCalendarStack: some View {
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
    }

    @ViewBuilder
    var bookCoverFullscreenOverlay: some View {
        if let payload = bookCoverFullscreenPayload {
            ReadCalendarBookCoverFullscreenOverlay(
                payload: payload,
                isHapticsEnabled: props.isHapticsEnabled,
                onClose: { closeBookCoverFullscreen() }
            )
            .zIndex(Layout.bookCoverFullscreenOverlayZIndex)
        }
    }

    var monthSummarySheetContent: some View {
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

    var yearSummarySheetContent: some View {
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

    /// 读取已加载月份页面状态，避免未命中时误用占位数据。
    func monthPageStateIfLoaded(for monthStart: Date) -> MonthPage? {
        props.monthPages.first(where: { $0.monthStart == monthStart })
    }

    /// 将单日业务书籍映射为封面堆叠输入，按首个事件时间倒序确保最近书籍置顶。
    func coverItems(for date: Date, in page: MonthPage) -> [ReadCalendarCoverFanStack.Item] {
        let normalized = Calendar.current.startOfDay(for: date)
        guard let books = page.dayMap[normalized]?.books, !books.isEmpty else { return [] }

        let sorted = books.sorted { lhs, rhs in
            if lhs.firstEventTime == rhs.firstEventTime {
                return lhs.id > rhs.id
            }
            return lhs.firstEventTime > rhs.firstEventTime
        }

        return sorted.enumerated().map { index, book in
            ReadCalendarCoverFanStack.Item(
                id: "book-\(book.id)-\(book.firstEventTime)-\(index)",
                coverURL: book.coverURL
            )
        }
    }

    /// 返回书籍封面模式样式：统一采用高级杂志感参数，并固定折叠上限 6。
    func bookCoverStyle(for date: Date, in page: MonthPage) -> ReadCalendarCoverFanStack.Style {
        let normalized = Calendar.current.startOfDay(for: date)
        let count = page.dayMap[normalized]?.books.count ?? 0
        let base = ReadCalendarCoverFanStack.Style.editorial
        if count >= 10 {
            return ReadCalendarCoverFanStack.Style(
                secondaryRotation: base.secondaryRotation,
                tertiaryRotation: base.tertiaryRotation,
                secondaryOffsetXRatio: base.secondaryOffsetXRatio,
                tertiaryOffsetXRatio: base.tertiaryOffsetXRatio,
                secondaryOffsetYRatio: base.secondaryOffsetYRatio,
                tertiaryOffsetYRatio: base.tertiaryOffsetYRatio,
                shadowOpacity: base.shadowOpacity,
                shadowRadius: base.shadowRadius,
                shadowX: base.shadowX,
                shadowY: base.shadowY,
                collapsedVisibleCount: 6,
                jitterDegree: 3.8,
                jitterOffsetRatio: 0.1,
                fullscreenMaxRotation: base.fullscreenMaxRotation
            )
        }
        return base
    }

    /// 打开书籍封面全屏浮层。
    func openBookCoverFullscreen(for date: Date, in page: MonthPage) {
        let items = coverItems(for: date, in: page)
        guard !items.isEmpty else { return }
        let normalized = Calendar.current.startOfDay(for: date)
        triggerCoverEntryCue(for: normalized)
        let style = bookCoverStyle(for: normalized, in: page)
        let sourceFrame = bookCoverStackFramesByDate[normalized]
        let stackedVisibleCount = min(
            max(1, items.count),
            max(1, min(style.collapsedVisibleCount, 14))
        )
        let payload = BookCoverFullscreenPayload(
            date: normalized,
            items: items,
            stackStyle: style,
            stackedVisibleCount: stackedVisibleCount,
            stackedSeed: ReadCalendarCoverFanStack.makeLayoutSeed(
                date: normalized,
                items: items,
                mode: .collapsed
            ),
            transitionSession: ReadCalendarCoverTransitionSession(
                sourceStackFrame: sourceFrame,
                sourceCoverSize: ReadCalendarMonthGrid.sourceCoverSize
            )
        )
        bookCoverFullscreenPayload = payload
    }

    /// 关闭书籍封面全屏浮层。
    func closeBookCoverFullscreen(animated: Bool = true) {
        guard bookCoverFullscreenPayload != nil else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                bookCoverFullscreenPayload = nil
            }
        } else {
            bookCoverFullscreenPayload = nil
        }
        cancelCoverEntryCue()
    }

    /// 触发日格源位聚焦提示，给用户保留“我从哪一天进入” 的空间锚点。
    func triggerCoverEntryCue(for date: Date) {
        coverEntryCueTask?.cancel()
        coverEntryCueDate = date
        coverEntryCueProgress = 0
        withAnimation(.easeOut(duration: Layout.coverEntryCuePeakDuration)) {
            coverEntryCueProgress = 1
        }
        coverEntryCueTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.coverEntryCueHoldNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: Layout.coverEntryCueFadeDuration)) {
                    coverEntryCueProgress = 0
                }
            }
            do {
                try await Task.sleep(nanoseconds: Layout.coverEntryCueCleanupNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                coverEntryCueDate = nil
            }
        }
    }

    /// 清理源位提示状态，避免切月/切模式后遗留高亮。
    func cancelCoverEntryCue() {
        coverEntryCueTask?.cancel()
        coverEntryCueTask = nil
        coverEntryCueDate = nil
        coverEntryCueProgress = 0
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openSummaryManually() {
        if isHeatmapMode {
            openYearSummaryManually()
            return
        }
        openMonthSummaryManually()
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openMonthSummaryManually() {
        let normalizedMonthStart = Calendar.current.startOfDay(for: props.pagerSelection)
        summarySheetMonthStart = normalizedMonthStart
        isSummaryFloatingButtonVisible = false
        isSummarySheetPresented = true
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openYearSummaryManually() {
        isSummaryFloatingButtonVisible = false
        isYearSummarySheetPresented = true
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    /// 更新总结悬浮按钮的可见性策略与交互保护窗口。
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

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
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

    /// 更新总结悬浮按钮的可见性策略与交互保护窗口。
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

    /// 安排悬浮总结按钮自动隐藏任务，避免按钮长期遮挡日历内容。
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

    /// 当月份切换后同步摘要弹层目标月份，避免弹层内容与主分页错位。
    func syncSummarySheetMonthIfNeeded(monthStart: Date) {
        guard isSummarySheetPresented else { return }
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        guard summarySheetMonthStart != normalizedMonthStart else { return }
        withAnimation(.snappy(duration: 0.24)) {
            summarySheetMonthStart = normalizedMonthStart
        }
    }

    /// 更新总结悬浮按钮的可见性策略与交互保护窗口。
    func switchSummarySheetMonth(to monthStart: Date) {
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        guard normalizedMonthStart != props.pagerSelection else { return }
        withAnimation(.snappy(duration: 0.3)) {
            onPagerSelectionChanged(normalizedMonthStart)
            summarySheetMonthStart = normalizedMonthStart
        }
    }

    /// 按指定月份生成摘要弹层需要的完整数据快照。
    func summarySheetData(for monthStart: Date) -> MonthSummarySheetData {
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        let page = monthPageStateIfLoaded(for: normalizedMonthStart) ?? monthPageState(for: normalizedMonthStart)
        return buildMonthSummary(from: page)
    }

    /// 聚合月度关键指标（活跃天数、连续天数、环比差值和高峰时段）。
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

    /// 统计当月存在阅读事件或读完标记的活跃天数。
    func activeDayCount(in dayMap: [Date: ReadCalendarDay]) -> Int {
        dayMap.values.filter { !$0.books.isEmpty || $0.isReadDoneDay }.count
    }

    /// 读取上月页面状态，用于计算本月环比指标。
    func previousMonthPage(for monthStart: Date) -> MonthPage? {
        guard let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: monthStart) else {
            return nil
        }
        return monthPageStateIfLoaded(for: Calendar.current.startOfDay(for: previousMonth))
    }

    /// 计算本月阅读时长占比最高的时间段。
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

    /// 计算当月最长连续活跃阅读天数。
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

    /// 在达成连续阅读里程碑时触发提示，并在短暂展示后自动消失。
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

    /// 返回连续阅读里程碑提示文案。
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

    /// 结合安全区计算悬浮按钮底部留白，避免与系统手势区冲突。
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

    /// 渲染年度热力图中的单月卡片，并提供点击进入月总结的入口。
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

    /// 渲染单月分页内容（加载态、日历网格与滚动交互）。
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

    /// 渲染单月周网格，并处理日期选中/取消选中交互。
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
            coverItemsProvider: { date in
                coverItems(for: date, in: page)
            },
            bookCoverStyleProvider: { date in
                bookCoverStyle(for: date, in: page)
            },
            coverEntryCueDate: coverEntryCueDate,
            coverEntryCueProgress: coverEntryCueProgress,
            frameCoordinateSpaceName: Layout.bookCoverGridCoordinateSpaceName,
            onBookCoverStackFramesChange: { frames in
                guard allowsDateSelection else { return }
                let normalizedFrames = frames.reduce(into: [Date: CGRect]()) { partialResult, pair in
                    let normalizedDate = Calendar.current.startOfDay(for: pair.key)
                    partialResult[normalizedDate] = pair.value
                }
                bookCoverStackFramesByDate = normalizedFrames
            },
            onOpenBookCoverFullscreen: { date in
                guard allowsDateSelection else { return }
                openBookCoverFullscreen(for: date, in: page)
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
        .coordinateSpace(name: Layout.bookCoverGridCoordinateSpaceName)
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

    /// 返回指定月份页面状态；缺失时构造占位状态保证页面可渲染。
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

    /// 将内容展示模式映射为网格组件可识别的显示模式。
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

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
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

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openMonthSummaryAfterAuxSheetDismiss(monthStart: Date) {
        let normalized = Calendar.current.startOfDay(for: monthStart)
        summarySheetMonthStart = normalized
        isYearSummarySheetPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !isYearSummarySheetPresented else { return }
            isSummarySheetPresented = true
        }
    }

    /// 格式化年度热力图月卡标题（X月）。
    func yearHeatmapMonthTitle(_ monthStart: Date) -> String {
        let month = Calendar.current.component(.month, from: monthStart)
        return "\(month)月"
    }

    /// 将月周数据裁剪并补齐为紧凑周数组，适配年度月卡空间。
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

private struct ReadCalendarBookCoverFullscreenOverlay: View {
    private enum LayoutPhaseSource {
        case automatic
        case manual
    }

    private enum Layout {
        static let backdropMaxOpacity: CGFloat = 0.26
        static let backdropMaterialOpacity: CGFloat = 0.32
        static let chromeAutoHideDelayNanoseconds: UInt64 = 1_000_000_000
        static let chromeFadeDuration: CGFloat = 0.18
        static let chromeRestoreDuration: CGFloat = 0.12
        static let chromeIdleOpacity: CGFloat = 0.34
        static let panelCornerRadius: CGFloat = CornerRadius.containerLarge
        static let panelVerticalPadding: CGFloat = Spacing.double
        static let dismissDragThreshold: CGFloat = 110
        static let closeButtonSymbolSize: CGFloat = 24
        static let panelShadowBaseOpacity: CGFloat = 0.14
        static let panelShadowExtraOpacity: CGFloat = 0.12
        static let panelShadowBaseRadius: CGFloat = 10
        static let panelShadowExtraRadius: CGFloat = 8
        static let previewLimit = 12
        static let autoGridDelayNanoseconds: UInt64 = 900_000_000
        static let phaseSwitchResponse: CGFloat = 0.4
        static let phaseSwitchDamping: CGFloat = 0.86
        static let closeReturnToStackDelayNanoseconds: UInt64 = 180_000_000
        static let toggleButtonHorizontalPadding: CGFloat = 16
        static let toggleButtonVerticalPadding: CGFloat = 10
    }

    let payload: ReadCalendarContentView.BookCoverFullscreenPayload
    let isHapticsEnabled: Bool
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var dragOffsetY: CGFloat = 0
    @State private var transitionPhase: ReadCalendarCoverTransitionPhase = .idle
    @State private var transitionProgress: CGFloat = 0
    @State private var chromeProgress: CGFloat = 1
    @State private var transitionTask: Task<Void, Never>?
    @State private var chromeAutoHideTask: Task<Void, Never>?
    @State private var layoutPhase: ReadCalendarCoverFullscreenDeckStage.Phase = .stacked
    @State private var phaseToken = 0
    @State private var hasAutoTransitioned = false
    @State private var autoGridTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    @State private var isClosing = false
    @State private var stageFrameInGlobal: CGRect = .zero

    var motionSpec: ReadCalendarCoverTransitionSpec {
        accessibilityReduceMotion ? .reduceMotion : .immersiveElegant
    }

    var transitionChannels: ReadCalendarCoverTransitionChannels {
        ReadCalendarCoverTransitionRuntime.channels(
            phase: transitionPhase,
            progress: transitionProgress,
            spec: motionSpec
        )
    }

    var stageOpacity: CGFloat {
        transitionChannels.deckOpacity
    }

    var stageScale: CGFloat {
        ReadCalendarCoverTransitionRuntime.panelScale(
            phase: transitionPhase,
            progress: transitionProgress,
            spec: motionSpec
        )
    }

    var stageOffsetY: CGFloat {
        ReadCalendarCoverTransitionRuntime.panelOffsetY(
            phase: transitionPhase,
            progress: transitionProgress,
            spec: motionSpec
        ) + dragOffsetY
    }

    var chromeOpacity: CGFloat {
        max(Layout.chromeIdleOpacity, chromeProgress) * transitionChannels.chromeOpacity
    }

    var shouldEnableGridPhase: Bool {
        payload.items.count > 1
    }

    var body: some View {
        GeometryReader { proxy in
            let coverSize = resolvedCoverSize(in: proxy.size)
            let panelHeight = resolvedPanelHeight(
                in: proxy.size,
                coverSize: coverSize,
                canScrollGrid: shouldEnableGridPhase
            )
            let panelInnerSize = CGSize(
                width: max(0, proxy.size.width - Spacing.screenEdge * 2 - Spacing.double * 2),
                height: max(0, panelHeight - Spacing.base * 2)
            )
            let panelShape = RoundedRectangle(
                cornerRadius: Layout.panelCornerRadius,
                style: .continuous
            )
            let bottomInset = max(Spacing.base, proxy.safeAreaInsets.bottom)

            ZStack(alignment: .top) {
                ZStack {
                    Color.black.opacity(Layout.backdropMaxOpacity * transitionChannels.backdropOpacity)
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(Layout.backdropMaterialOpacity * transitionChannels.backdropOpacity)
                }
                .ignoresSafeArea()
                .onTapGesture {
                    markChromeInteraction(forceVisible: true)
                    dismiss()
                }

                heroGhostLayer(
                    coverSize: coverSize,
                    overlayGlobalFrame: proxy.frame(in: .global)
                )
                .opacity(Double(transitionChannels.ghostOpacity))

                VStack(spacing: Spacing.base) {
                    header
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Layout.panelVerticalPadding)
                        .opacity(Double(chromeOpacity))

                    Spacer(minLength: 0)

                    ZStack {
                        panelShape
                            .fill(Color.contentBackground.opacity(0.78))

                        fullscreenDeckStage(
                            coverSize: coverSize,
                            panelInnerSize: panelInnerSize
                        )
                    }
                    .clipShape(panelShape)
                    .overlay {
                        panelShape
                            .stroke(
                                Color.white.opacity(0.22 + 0.1 * transitionChannels.deckOpacity),
                                lineWidth: CardStyle.borderWidth
                            )
                    }
                    .frame(height: panelHeight)
                    .padding(.horizontal, Spacing.screenEdge)
                    .background {
                        GeometryReader { stageProxy in
                            let frame = stageProxy.frame(in: .global)
                            Color.clear
                                .onAppear {
                                    stageFrameInGlobal = frame
                                }
                                .onChange(of: frame) { _, newValue in
                                    stageFrameInGlobal = newValue
                                }
                        }
                    }
                    .shadow(
                        color: Color.black.opacity(
                            Layout.panelShadowBaseOpacity
                            + Layout.panelShadowExtraOpacity * transitionChannels.deckOpacity
                        ),
                        radius: Layout.panelShadowBaseRadius + Layout.panelShadowExtraRadius * transitionChannels.deckOpacity,
                        x: 0,
                        y: 8
                    )
                    .opacity(Double(stageOpacity))

                    Text(phaseHintText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .opacity(Double(chromeOpacity))

                    if shouldEnableGridPhase {
                        toggleButton
                            .opacity(Double(chromeOpacity))
                    }

                    Text("下滑或轻点空白处收起")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.64))
                        .opacity(Double(chromeOpacity))

                    Spacer(minLength: bottomInset)
                }
                .offset(y: stageOffsetY)
                .scaleEffect(stageScale)
            }
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)
            .onAppear {
                handleAppear()
            }
            .onDisappear {
                cancelAutoGridTransition()
                cancelCloseTask()
                cancelTransitionTask()
                cancelChromeAutoHideTask()
                isClosing = false
            }
        }
    }

    var phaseHintText: String {
        if !shouldEnableGridPhase {
            return "当日共 \(payload.items.count) 本"
        }
        switch layoutPhase {
        case .stacked:
            if hasAutoTransitioned {
                return "当日共 \(payload.items.count) 本，可切换为列表查看全部"
            }
            return "当日共 \(payload.items.count) 本，约 1 秒后自动切换列表"
        case .grid:
            return "当日共 \(payload.items.count) 本，向上滑动浏览全部"
        }
    }

    var toggleButton: some View {
        let isStacked = layoutPhase == .stacked
        return Button {
            markChromeInteraction(forceVisible: true)
            toggleLayoutPhase()
        } label: {
            HStack(spacing: Spacing.half) {
                Image(systemName: isStacked ? "list.bullet.rectangle.portrait.fill" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(isStacked ? "查看列表" : "返回堆叠")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, Layout.toggleButtonHorizontalPadding)
            .padding(.vertical, Layout.toggleButtonVerticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: CardStyle.borderWidth)
            }
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStacked ? "切换为纵向书籍列表" : "切换为封面堆叠")
    }

    var header: some View {
        HStack(spacing: Spacing.base) {
            Text(formattedDate(payload.date))
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.96))

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Layout.closeButtonSymbolSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
            }
            .accessibilityLabel("关闭当日书籍封面全屏浮层")
        }
    }

    var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                markChromeInteraction(forceVisible: true)
                dragOffsetY = value.translation.height * 0.58
            }
            .onEnded { value in
                markChromeInteraction(forceVisible: true)
                if value.translation.height > Layout.dismissDragThreshold {
                    dismiss()
                    return
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    dragOffsetY = 0
                }
            }
    }

    /// 处理浮层首次出现：初始化阶段、触发触感并启动自动切换任务。
    func handleAppear() {
        triggerOpenHapticIfNeeded()
        dragOffsetY = 0
        layoutPhase = .stacked
        phaseToken &+= 1
        hasAutoTransitioned = false
        isClosing = false
        startEnterTransition()
    }

    func resolvedCoverSize(in size: CGSize) -> CGSize {
        let width = max(52, min(92, size.width / 6.2))
        return CGSize(width: width, height: width * 1.46)
    }

    /// 根据屏幕与封面尺寸计算浮层面板高度，并在列表阶段预留足够滚动区域。
    func resolvedPanelHeight(in size: CGSize, coverSize: CGSize, canScrollGrid: Bool) -> CGFloat {
        let byCover = coverSize.height * (canScrollGrid ? 5.25 : 4.9)
        let byScreen = size.height * (canScrollGrid ? 0.72 : 0.62)
        return min(max(340, byCover), max(380, byScreen))
    }

    @ViewBuilder
    func fullscreenDeckStage(
        coverSize: CGSize,
        panelInnerSize: CGSize
    ) -> some View {
        let deckContainer = ReadCalendarCoverFullscreenDeckStage(
            items: payload.items,
            style: payload.stackStyle,
            coverSize: coverSize,
            containerSize: panelInnerSize,
            phase: layoutPhase,
            phaseToken: phaseToken,
            isAnimated: true,
            layoutSeed: payload.stackedSeed,
            stackedVisibleCount: payload.stackedVisibleCount,
            previewLimit: Layout.previewLimit
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.double)
        .padding(.vertical, Spacing.base)
        deckContainer
    }

    @ViewBuilder
    func heroGhostLayer(
        coverSize: CGSize,
        overlayGlobalFrame: CGRect
    ) -> some View {
        let sourceSize = payload.transitionSession.sourceCoverSize
        let hasValidSourceSize = sourceSize.width > 0 && sourceSize.height > 0
        let hasValidStageFrame = stageFrameInGlobal.width > 0 && stageFrameInGlobal.height > 0
        if hasValidSourceSize,
           hasValidStageFrame,
           let sourceFrame = payload.transitionSession.sourceStackFrame,
           sourceFrame.width > 0,
           sourceFrame.height > 0 {
            let travel = ReadCalendarCoverTransitionRuntime.ghostTravelProgress(
                phase: transitionPhase,
                progress: transitionProgress
            )
            let sourceCenterGlobal = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
            let targetCenterGlobal = CGPoint(x: stageFrameInGlobal.midX, y: stageFrameInGlobal.midY)
            let currentCenterGlobal = CGPoint(
                x: lerp(sourceCenterGlobal.x, targetCenterGlobal.x, travel),
                y: lerp(sourceCenterGlobal.y, targetCenterGlobal.y, travel)
            )
            let localCenter = CGPoint(
                x: currentCenterGlobal.x - overlayGlobalFrame.minX,
                y: currentCenterGlobal.y - overlayGlobalFrame.minY
            )
            let targetScale = max(1, coverSize.width / max(1, sourceSize.width))
            let scale = lerp(1, targetScale, travel)

            ReadCalendarCoverFanStack(
                items: payload.items,
                maxVisibleCount: payload.stackedVisibleCount,
                coverSize: sourceSize,
                isAnimated: false,
                style: payload.stackStyle,
                presentationMode: .collapsed,
                layoutSeed: payload.stackedSeed
            )
            .frame(
                width: sourceSize.width * 4.2,
                height: sourceSize.height * 4.2,
                alignment: .center
            )
            .scaleEffect(scale)
            .position(localCenter)
            .allowsHitTesting(false)
        }
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 手动切换堆叠态与列表态，用于过渡评估与对比观察。
    func toggleLayoutPhase() {
        let target: ReadCalendarCoverFullscreenDeckStage.Phase = layoutPhase == .stacked ? .grid : .stacked
        switchLayoutPhase(to: target, source: .manual)
    }

    /// 在书籍数量超过阈值时，延迟自动切到列表态，提升可浏览性。
    func scheduleAutoGridTransitionIfNeeded() {
        cancelAutoGridTransition()
        guard transitionPhase == .steady else { return }
        guard shouldEnableGridPhase else { return }
        autoGridTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.autoGridDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isClosing else { return }
                markChromeInteraction(forceVisible: true)
                switchLayoutPhase(to: .grid, source: .automatic)
            }
        }
    }

    /// 执行阶段切换动画，自动与手动切换统一走同一条状态机路径。
    private func switchLayoutPhase(
        to target: ReadCalendarCoverFullscreenDeckStage.Phase,
        source: LayoutPhaseSource
    ) {
        guard layoutPhase != target else { return }
        if source == .manual {
            cancelAutoGridTransition()
        }
        hasAutoTransitioned = true
        if source == .automatic, target == .grid {
            triggerAutoGridHapticIfNeeded()
        }
        withAnimation(.spring(response: Layout.phaseSwitchResponse, dampingFraction: Layout.phaseSwitchDamping)) {
            layoutPhase = target
            phaseToken &+= 1
        }
    }

    /// 取消自动切换任务，避免浮层关闭后任务回调污染当前状态。
    func cancelAutoGridTransition() {
        autoGridTask?.cancel()
        autoGridTask = nil
    }

    /// 取消关闭延迟任务，避免重复触发 onClose 导致状态竞争。
    func cancelCloseTask() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// 关闭浮层：若当前在列表态先回切堆叠态，再执行整体淡出下沉，避免跳态关闭。
    func dismiss() {
        guard !isClosing else { return }
        cancelAutoGridTransition()
        cancelTransitionTask()
        cancelCloseTask()
        cancelChromeAutoHideTask()
        withAnimation(.smooth(duration: 0.22)) {
            dragOffsetY = 0
        }
        isClosing = true
        if shouldEnableGridPhase, layoutPhase == .grid {
            switchLayoutPhase(to: .stacked, source: .manual)
            closeTask = Task {
                do {
                    try await Task.sleep(nanoseconds: Layout.closeReturnToStackDelayNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    runDismissTransition()
                }
            }
            return
        }
        runDismissTransition()
    }

    func triggerOpenHapticIfNeeded() {
        guard isHapticsEnabled else { return }
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.82)
#endif
    }

    func triggerAutoGridHapticIfNeeded() {
        guard isHapticsEnabled else { return }
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.56)
#endif
    }

    func markChromeInteraction(forceVisible: Bool = false) {
        guard !isClosing else { return }
        cancelChromeAutoHideTask()
        if forceVisible || chromeProgress < 1 {
            withAnimation(.easeOut(duration: Layout.chromeRestoreDuration)) {
                chromeProgress = 1
            }
        }
        chromeAutoHideTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.chromeAutoHideDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isClosing else { return }
                withAnimation(.easeOut(duration: Layout.chromeFadeDuration)) {
                    chromeProgress = Layout.chromeIdleOpacity
                }
            }
        }
    }

    func cancelChromeAutoHideTask() {
        chromeAutoHideTask?.cancel()
        chromeAutoHideTask = nil
    }

    func runDismissTransition() {
        transitionPhase = .exiting
        chromeProgress = 1
        withAnimation(.linear(duration: motionSpec.closeDuration)) {
            transitionProgress = 0
        }
        closeTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(from: motionSpec.closeDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isClosing = false
                onClose()
            }
        }
    }

    func startEnterTransition() {
        cancelTransitionTask()
        cancelChromeAutoHideTask()
        transitionPhase = .entering
        transitionProgress = 0
        chromeProgress = 1
        withAnimation(.linear(duration: motionSpec.openDuration)) {
            transitionProgress = 1
        }
        transitionTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(from: motionSpec.openDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                transitionPhase = .steady
                transitionTask = nil
                markChromeInteraction()
                scheduleAutoGridTransitionIfNeeded()
            }
        }
    }

    func cancelTransitionTask() {
        transitionTask?.cancel()
        transitionTask = nil
    }

    func nanoseconds(from seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    func lerp(_ min: CGFloat, _ max: CGFloat, _ progress: CGFloat) -> CGFloat {
        min + (max - min) * progress
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
