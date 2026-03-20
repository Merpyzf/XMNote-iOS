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
    enum DisplayMode: String, CaseIterable, Hashable, Codable {
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

        var isPlaceholder: Bool {
            loadState == .idle
                && errorMessage == nil
                && dayMap.isEmpty
                && readingDurationTopBooks.isEmpty
                && summary == .empty
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
        static let horizontalPagerProgrammaticDuration: CGFloat = 0.24
        static let weekdayHeaderHeight: CGFloat = 32
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerTopPadding: CGFloat = Spacing.cozy
        static let calendarInnerBottomPadding: CGFloat = 0
        static let contentBleedBottomInset: CGFloat = 0
        static let interactiveBottomInset: CGFloat = 0
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
        static let coverComponentVisibleLimit = 5
        static let coverBusinessCollapsedLimit = 5
    }

    let props: Props
    let monthPageProvider: (Date) -> MonthPage
    let onDisplayModeChanged: (DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onYearSelectionChanged: (Int) -> Void
    let onSelectDate: (Date?) -> Void
    let onRetry: () -> Void
    let onBookCoverFullscreenPresentationChanged: (Bool) -> Void
    @State private var streakHintMessage: String?
    @State private var streakHintTask: Task<Void, Never>?
    @State private var shownStreakMilestonesByMonth: [Date: Set<Int>] = [:]
    @State private var isSummarySheetPresented = false
    @State private var summarySheetMonthStart: Date?
    @State private var isYearSummarySheetPresented = false

    // MARK: - Summary Floating Button State
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
    @State private var topControlBarFrameInGlobal: CGRect = .zero
    @State private var lastLoggedTopControlBarFrameForDebug: CGRect = .zero
    @State private var lastLoggedCalendarViewportSignatureForDebug = ""
    @State private var rootLoadingGate = LoadingGate()
    @State private var heatmapYearLoadingGate = LoadingGate()

    var body: some View {
        bodyContainer
    }
}

/// ReadCalendarTopControlBarFramePreferenceKey 回传顶部控制栏在全局坐标系中的 frame。
private struct ReadCalendarTopControlBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    /// 合并顶部控制栏最新 frame，忽略零值占位，保证后续沉浸偏移动画基于真实位置。
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero else { return }
        value = next
    }
}

// MARK: - Subviews

private extension ReadCalendarContentView {
    var isBookCoverFullscreenPresented: Bool {
        bookCoverFullscreenPayload != nil
    }

    var bodyContainer: some View {
        baseCalendarStack
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: props.errorMessage)
            .onAppear {
                onBookCoverFullscreenPresentationChanged(isBookCoverFullscreenPresented)
                evaluateStreakHintIfNeeded()
                syncRootLoadingVisibility()
                syncHeatmapYearLoadingVisibility()
                if props.rootContentState == .content {
                    applySummaryFloatingButtonInitialPolicyIfNeeded()
                }
            }
            .onChange(of: isBookCoverFullscreenPresented) { _, isPresented in
                onBookCoverFullscreenPresentationChanged(isPresented)
            }
            .onChange(of: props.rootContentState) { _, state in
                syncRootLoadingVisibility()
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
                syncHeatmapYearLoadingVisibility()
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
                )
            }
            .onChange(of: props.selectedYearLoadState) { _, _ in
                syncHeatmapYearLoadingVisibility()
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
                rootLoadingGate.hideImmediately()
                heatmapYearLoadingGate.hideImmediately()
                bookCoverStackFramesByDate = [:]
                closeBookCoverFullscreen(animated: false)
                cancelCoverEntryCue()
                onBookCoverFullscreenPresentationChanged(false)
            }
            .onPreferenceChange(ReadCalendarTopControlBarFramePreferenceKey.self) { frame in
                topControlBarFrameInGlobal = frame
                logTopControlBarFrameIfNeeded(frame)
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

    /// 在调试模式下输出顶部控制栏 frame，辅助排查沉浸滚动与全屏浮层的锚点问题。
    func logTopControlBarFrameIfNeeded(_ frame: CGRect) {
#if DEBUG
        let normalized = CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.size.width.rounded(),
            height: frame.size.height.rounded()
        )
        guard normalized != lastLoggedTopControlBarFrameForDebug else { return }
        lastLoggedTopControlBarFrameForDebug = normalized
        print(
            "[ReadCalendar][TopControlBarFrame] x=\(Int(normalized.minX)) y=\(Int(normalized.minY)) w=\(Int(normalized.width)) h=\(Int(normalized.height)) maxY=\(Int(normalized.maxY))"
        )
#endif
    }

    /// 在调试模式下输出日历视口高度和安全区，辅助间距审计与布局压缩排查。
    func logCalendarViewportIfNeeded(contentHeight: CGFloat, viewportSafeBottom: CGFloat) {
#if DEBUG
        let signature = "contentH=\(Int(contentHeight.rounded())) safeBottom=\(Int(viewportSafeBottom.rounded()))"
        guard signature != lastLoggedCalendarViewportSignatureForDebug else { return }
        lastLoggedCalendarViewportSignatureForDebug = signature
        print("[ReadCalendar][CalendarViewport] \(signature)")
#endif
    }
    
    var baseCalendarStack: some View {
        VStack(spacing: Spacing.none) {
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
                Color.surfacePage.opacity(Layout.topControlBackgroundOpacity)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: ReadCalendarTopControlBarFramePreferenceKey.self,
                            value: proxy.frame(in: .global)
                        )
                }
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
                topControlBarFrameInGlobal: topControlBarFrameInGlobal,
                onClose: { closeBookCoverFullscreen() }
            )
            .zIndex(Layout.bookCoverFullscreenOverlayZIndex)
            .transition(.opacity)
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
        // 源数据由 monthStartsForYear 按自然月序构建，无需额外排序
        props.heatmapYearMonthPages
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
        let page = monthPageProvider(monthStart)
        return page.isPlaceholder ? nil : page
    }

    /// 为单月预构建日期 -> 封面条目映射，避免日格渲染期间重复排序与对象创建。
    func buildCoverItemsByDate(for page: MonthPage) -> [Date: [ReadCalendarCoverFanStack.Item]] {
        var result: [Date: [ReadCalendarCoverFanStack.Item]] = [:]
        result.reserveCapacity(page.dayMap.count)
        for (date, dayData) in page.dayMap where !dayData.books.isEmpty {
            // 与事件模式保持同源顺序：沿用仓储输出顺序（firstEventTime 升序）。
            result[date] = dayData.books.enumerated().map { index, book in
                ReadCalendarCoverFanStack.Item(
                    id: "book-\(book.id)-\(book.firstEventTime)-\(index)",
                    coverURL: book.coverURL
                )
            }
        }
        return result
    }

    /// 读取指定日期的封面条目，统一做 startOfDay 归一化避免 key 漂移。
    func coverItems(for date: Date, in coverItemsByDate: [Date: [ReadCalendarCoverFanStack.Item]]) -> [ReadCalendarCoverFanStack.Item] {
        let normalized = Calendar.current.startOfDay(for: date)
        return coverItemsByDate[normalized] ?? []
    }

    /// 返回书籍封面模式样式：与封面堆叠测试页保持一致的参数基线。
    func bookCoverStyle(for _: Int) -> ReadCalendarCoverFanStack.Style {
        return ReadCalendarCoverFanStack.Style(
            secondaryRotation: -8,
            tertiaryRotation: -15,
            secondaryOffsetXRatio: -0.34,
            tertiaryOffsetXRatio: -0.66,
            secondaryOffsetYRatio: -0.03,
            tertiaryOffsetYRatio: 0.14,
            shadowOpacity: 0.28,
            shadowRadius: 7,
            shadowX: 0.5,
            shadowY: 5,
            collapsedVisibleCount: Layout.coverBusinessCollapsedLimit,
            jitterDegree: 1.8,
            jitterOffsetRatio: 0.05,
            fullscreenMaxRotation: 14
        )
    }

    /// 打开书籍封面全屏浮层。
    func openBookCoverFullscreen(
        for date: Date,
        coverItemsByDate: [Date: [ReadCalendarCoverFanStack.Item]]
    ) {
        let items = coverItems(for: date, in: coverItemsByDate)
        guard !items.isEmpty else { return }
        let normalized = Calendar.current.startOfDay(for: date)
        triggerCoverEntryCue(for: normalized)
        let style = bookCoverStyle(for: items.count)
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
        let page = monthPageProvider(normalizedMonthStart)
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

        // 裁剪缓存：仅保留当前月 ±3 窗口，避免无限膨胀
        if shownStreakMilestonesByMonth.count > 12 {
            let current = activePage.monthStart
            let cal = Calendar.current
            shownStreakMilestonesByMonth = shownStreakMilestonesByMonth.filter { key, _ in
                guard let distance = cal.dateComponents([.month], from: key, to: current).month else { return false }
                return abs(distance) <= 3
            }
        }

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

    var integratedCalendarContainer: some View {
        GeometryReader { proxy in
            let headerHeight = shouldShowWeekdayHeader ? Layout.weekdayHeaderHeight : 0
            let spacing = shouldShowWeekdayHeader ? Layout.headerToGridSpacing : 0
            let viewportSafeBottom = max(0, proxy.safeAreaInsets.bottom)
            let contentHeight = max(0, proxy.size.height - headerHeight - spacing)

            VStack(spacing: spacing) {
                if shouldShowWeekdayHeader {
                    ReadCalendarWeekdayHeader(minHeight: Layout.weekdayHeaderHeight)
                        .frame(height: Layout.weekdayHeaderHeight)
                        .background(Color.surfacePage)
                        .zIndex(1)
                }

                contentContainer()
                    .frame(height: contentHeight, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .onAppear {
                logCalendarViewportIfNeeded(contentHeight: contentHeight, viewportSafeBottom: viewportSafeBottom)
            }
            .onChange(of: contentHeight) { _, _ in
                logCalendarViewportIfNeeded(contentHeight: contentHeight, viewportSafeBottom: viewportSafeBottom)
            }
            .onChange(of: viewportSafeBottom) { _, _ in
                logCalendarViewportIfNeeded(contentHeight: contentHeight, viewportSafeBottom: viewportSafeBottom)
            }
        }
        .padding(.top, Layout.calendarInnerTopPadding)
        .padding(.bottom, Layout.calendarInnerBottomPadding + interactiveBottomInset)
    }

    /// 根据根状态切换加载、空态和内容区，并承载悬浮总结按钮。
    func contentContainer() -> some View {
        ZStack(alignment: .top) {
            switch props.rootContentState {
            case .loading:
                Group {
                    if rootLoadingGate.isVisible {
                        LoadingStateView("正在加载阅读日历…")
                    } else {
                        Color.clear
                    }
                }
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
        .padding(.top, shouldShowWeekdayHeader ? Layout.gridTopInset : Spacing.none)
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

    var pagerSelection: Binding<Date?> {
        Binding(
            get: { props.pagerSelection },
            set: { newValue in
                guard let newValue else { return }
                let normalized = Calendar.current.startOfDay(for: newValue)
                guard normalized != props.pagerSelection else { return }
                onPagerSelectionChanged(normalized)
            }
        )
    }

    var calendarPager: some View {
        HorizontalPagingHost(
            ids: props.availableMonths,
            selection: pagerSelection,
            windowAnchorID: props.pagerSelection,
            windowing: .radius(3),
            programmaticScrollAnimation: .snappy(duration: Layout.horizontalPagerProgrammaticDuration)
        ) { monthStart in
            monthPage(for: monthStart)
        }
    }

    @ViewBuilder
    var heatmapYearContent: some View {
        if isCurrentYearHeatmapLoading {
            Group {
                if heatmapYearLoadingGate.isVisible {
                    LoadingStateView("正在整理年度热力图…")
                } else {
                    Color.clear
                }
            }
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
            .readCalendarBottomImmersiveStyle()
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
                    .font(ReadCalendarTypography.yearHeatmapMonthTitleFont)
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
                .fill(Color.surfaceNested)
            )
        }
        .buttonStyle(.plain)
    }

    /// 渲染单月分页内容（加载态、日历网格与滚动交互）。
    func monthPage(for monthStart: Date) -> some View {
        let pageState = monthPageProvider(monthStart)

        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .top) {
                if pageState.isLoading && pageState.isDayMapEmpty {
                    LoadingStateView()
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
        .scrollClipDisabled(false)
        .onScrollPhaseChange { _, phase in
            guard phase.isScrolling else { return }
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .readCalendarBottomImmersiveStyle()
        .animation(.smooth(duration: 0.24), value: pageState.loadState)
    }

    private func syncRootLoadingVisibility() {
        let intent: LoadingIntent = props.rootContentState == .loading ? .read : .none
        rootLoadingGate.update(intent: intent)
    }

    private func syncHeatmapYearLoadingVisibility() {
        let intent: LoadingIntent = isCurrentYearHeatmapLoading ? .read : .none
        heatmapYearLoadingGate.update(intent: intent)
    }

    /// 渲染单月周网格，并处理日期选中/取消选中交互。
    func calendarWeeks(for page: MonthPage, allowsDateSelection: Bool) -> some View {
        let coverItemsByDate = props.displayMode == .bookCover
            ? buildCoverItemsByDate(for: page)
            : [:]
        return ReadCalendarMonthGrid(
            weeks: page.weeks,
            laneLimit: props.laneLimit,
            displayMode: allowsDateSelection ? mapGridDisplayMode(props.displayMode) : .heatmap,
            selectedDate: allowsDateSelection ? page.selectedDate : nil,
            isHapticsEnabled: allowsDateSelection ? props.isHapticsEnabled : false,
            dayPayloadProvider: { date in
                page.payload(for: date)
            },
            coverItemsProvider: { date in
                coverItems(for: date, in: coverItemsByDate)
            },
            bookCoverStyleProvider: { date in
                bookCoverStyle(for: coverItems(for: date, in: coverItemsByDate).count)
            },
            coverComponentVisibleLimit: Layout.coverComponentVisibleLimit,
            coverBusinessVisibleLimit: Layout.coverBusinessCollapsedLimit,
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
                openBookCoverFullscreen(for: date, coverItemsByDate: coverItemsByDate)
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
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.feedbackWarning)
                    .multilineTextAlignment(.center)

                Button("重试", action: onRetry)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.brand)
            } else {
                Text(isHeatmapMode ? "暂无可展示的年度数据" : "暂无可展示的阅读月份")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight)
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
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, !isYearSummarySheetPresented else { return }
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
        VStack(spacing: Spacing.compact) {
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
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)

            ForEach(HeatmapLevel.allCases.filter { $0 != .none }, id: \.rawValue) { level in
                RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                    .fill(level.color)
                    .frame(width: Layout.yearHeatmapLegendSquare, height: Layout.yearHeatmapLegendSquare)
            }

            Text("多")
                .font(AppTypography.caption)
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

    private enum PhaseTransitionDirection {
        case toGrid
    }

    private enum DismissSource {
        case dragGesture
        case backdropTap
        case closeButton
    }

    private struct LayoutDebugSnapshot: Equatable {
        let overlayMinY: Int
        let screenHeight: Int
        let safeTop: Int
        let relativeSafeTop: Int
        let safeBottom: Int
        let topControlMaxY: Int
        let headerTopInset: Int
        let topChromeHeight: Int
        let rawBottomChromeHeight: Int
        let stageBottomChromeHeight: Int
        let availableStageHeight: Int
        let panelHeight: Int
        let fittedPanelHeight: Int
        let phase: String
        let stackedBaselineState: String
        let showHint: Bool
        let showToggle: Bool
    }

    private struct StackedLayoutBaselineSignature: Equatable {
        let overlayWidth: Int
        let overlayHeight: Int
        let overlayMinY: Int
        let safeTop: Int
        let safeBottom: Int
        let topControlMaxY: Int
    }

    private struct StackedLayoutBaseline: Equatable {
        let signature: StackedLayoutBaselineSignature
        let panelHeight: CGFloat
        let fittedPanelHeight: CGFloat
        let panelInnerSize: CGSize
        let coverSize: CGSize
        let stageBottomChromeHeight: CGFloat
    }

    private struct StagePanelLayoutMetrics {
        let panelHeight: CGFloat
        let fittedPanelHeight: CGFloat
        let panelInnerSize: CGSize
        let coverSize: CGSize
        let usesStackedBaseline: Bool
    }

    private struct StackedBaselineCaptureSnapshot: Equatable {
        let signature: StackedLayoutBaselineSignature
        let phase: ReadCalendarCoverFullscreenDeckStage.Phase
        let panelHeight: Int
        let fittedPanelHeight: Int
        let panelInnerWidth: Int
        let panelInnerHeight: Int
        let coverWidth: Int
        let coverHeight: Int
        let stageBottomChromeHeight: Int
    }

    private enum Layout {
        static let backdropMaxOpacity: CGFloat = 0.46
        static let backdropMaterialOpacity: CGFloat = 0.42
        static let dismissDragThreshold: CGFloat = 108
        static let closeButtonSymbolSize: CGFloat = 24
        static let closeButtonOpacity: CGFloat = 0.74
        static let autoGridDelayNanoseconds: UInt64 = 520_000_000
        static let switchToGridResponse: CGFloat = 0.36
        static let switchToGridDamping: CGFloat = 0.84
        static let switchToStackResponse: CGFloat = 0.30
        static let switchToStackDamping: CGFloat = 0.86
        static let panelShadowBaseOpacity: CGFloat = 0.028
        static let panelShadowExtraOpacity: CGFloat = 0.022
        static let panelShadowBaseRadius: CGFloat = 10
        static let panelShadowExtraRadius: CGFloat = 4
        static let panelShadowYOffset: CGFloat = 3
        static let hintShadowOpacity: CGFloat = 0.45
        static let hintShadowRadius: CGFloat = 2
        static let hintShadowYOffset: CGFloat = 1
        static let previewLimit = 12
        static let switchSettleNanoseconds: UInt64 = 430_000_000
        static let toggleButtonHorizontalPadding: CGFloat = 16
        static let toggleButtonVerticalPadding: CGFloat = 10
        static let toggleButtonBottomInsetExtra: CGFloat = 6
        static let toggleButtonBackgroundOpacity: CGFloat = 0.26
        static let toggleButtonStrokeOpacity: CGFloat = 0.18
        static let toggleButtonShadowOpacity: CGFloat = 0.14
        static let toggleButtonShadowRadius: CGFloat = 14
        static let toggleButtonEstimatedHeight: CGFloat = 42
        static let headerTopSafeAreaInset: CGFloat = 8
        static let headerTopMaxInset: CGFloat = 132
        static let headerToTopControlGap: CGFloat = 6
        static let headerHorizontalInset: CGFloat = Spacing.screenEdge
        static let headerEstimatedHeight: CGFloat = 30
        static let headerBottomGap: CGFloat = 14
        static let stageBottomInsetExtra: CGFloat = 12
        static let countHintEstimatedHeight: CGFloat = 20
        static let bottomChromeSpacing: CGFloat = Spacing.half
        static let stageMinHeight: CGFloat = 240
    }

    let payload: ReadCalendarContentView.BookCoverFullscreenPayload
    let isHapticsEnabled: Bool
    let topControlBarFrameInGlobal: CGRect
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var dragOffsetY: CGFloat = 0
    @State private var layoutPhase: ReadCalendarCoverFullscreenDeckStage.Phase = .stacked
    @State private var phaseToken = 0
    @State private var hasAutoTransitioned = false
    @State private var hasCollapsedBackToStack = false
    @State private var autoGridTask: Task<Void, Never>?
    @State private var transitionPhase: ReadCalendarCoverTransitionPhase = .idle
    @State private var transitionProgress: CGFloat = 0
    @State private var transitionTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    @State private var isClosing = false
    @State private var phaseTransitionDirection: PhaseTransitionDirection?
    @State private var phaseTransitionTask: Task<Void, Never>?
    @State private var isDeferringGridConstraint = false
    @State private var stageFrameInGlobal: CGRect = .zero
    @State private var lastLayoutDebugSnapshot: LayoutDebugSnapshot?
    @State private var stackedLayoutBaseline: StackedLayoutBaseline?
    @State private var lastReusedStackedBaselineSignature: StackedLayoutBaselineSignature?
    @State private var hapticPlayer: ReadCalendarOverlayHapticPlayer?

    var isAnimated: Bool { true }

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

    var shouldEnableGridPhase: Bool {
        payload.items.count > 1
    }

    var shouldAutoExpandToGridPhase: Bool {
        shouldEnableGridPhase
    }

    var shouldShowCountHint: Bool {
        shouldEnableGridPhase && layoutPhase == .grid
    }

    var shouldShowToggleButton: Bool {
        guard shouldEnableGridPhase else { return false }
        if layoutPhase == .grid {
            return true
        }
        return hasCollapsedBackToStack
    }

    var shouldConstrainStagePanel: Bool {
        layoutPhase == .grid
            && !isDeferringGridConstraint
            && phaseTransitionDirection != .toGrid
    }

    var sourceCoverAspectRatio: CGFloat {
        let sourceSize = payload.transitionSession.sourceCoverSize
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return 1.46
        }
        return sourceSize.height / sourceSize.width
    }

    var body: some View {
        GeometryReader { proxy in
            let overlayFrameInGlobal = proxy.frame(in: .global)
            let baselineSignature = makeStackedLayoutBaselineSignature(
                overlayFrameInGlobal: overlayFrameInGlobal,
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets
            )
            let stackedBaseline = stackedLayoutBaselineIfValid(for: baselineSignature)
            let livePanelHeight = resolvedPanelHeight(
                in: proxy.size,
                canScrollGrid: shouldEnableGridPhase
            )
            let headerTopInset = resolvedHeaderTopInset(
                safeAreaTop: proxy.safeAreaInsets.top,
                overlayFrameInGlobal: overlayFrameInGlobal
            )
            let toggleBottomInset = max(
                Spacing.base,
                proxy.safeAreaInsets.bottom + Layout.toggleButtonBottomInsetExtra + Layout.stageBottomInsetExtra
            )
            let topChromeHeight = headerTopInset + Layout.headerEstimatedHeight + Layout.headerBottomGap
            let countHintHeight = shouldShowCountHint ? Layout.countHintEstimatedHeight : 0
            let toggleButtonHeight = shouldShowToggleButton ? Layout.toggleButtonEstimatedHeight : 0
            let bottomChromeSpacing = (shouldShowCountHint && shouldShowToggleButton)
                ? Layout.bottomChromeSpacing
                : 0
            let rawBottomChromeHeight = toggleBottomInset + countHintHeight + toggleButtonHeight + bottomChromeSpacing
            let stageBottomChromeHeight = resolvedStageBottomChromeHeight(
                rawBottomChromeHeight: rawBottomChromeHeight,
                stackedBaseline: stackedBaseline
            )
            let availableStageHeight = max(
                Layout.stageMinHeight,
                proxy.size.height - topChromeHeight - stageBottomChromeHeight
            )
            let liveFittedPanelHeight = min(livePanelHeight, availableStageHeight)
            let livePanelInnerSize = CGSize(
                width: max(0, proxy.size.width - Spacing.screenEdge * 2 - Spacing.double * 2),
                height: max(0, liveFittedPanelHeight - Spacing.base * 2)
            )
            let liveCoverSize = resolvedCoverSize(in: livePanelInnerSize)
            let stageLayout = resolvedStagePanelLayoutMetrics(
                stackedBaseline: stackedBaseline,
                livePanelHeight: livePanelHeight,
                liveFittedPanelHeight: liveFittedPanelHeight,
                livePanelInnerSize: livePanelInnerSize,
                liveCoverSize: liveCoverSize
            )
            let baselineCaptureSnapshot = makeStackedBaselineCaptureSnapshot(
                signature: baselineSignature,
                phase: layoutPhase,
                panelHeight: livePanelHeight,
                fittedPanelHeight: liveFittedPanelHeight,
                panelInnerSize: livePanelInnerSize,
                coverSize: liveCoverSize,
                stageBottomChromeHeight: stageBottomChromeHeight
            )
            let debugSnapshot = makeLayoutDebugSnapshot(
                overlayFrameInGlobal: overlayFrameInGlobal,
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                headerTopInset: headerTopInset,
                topChromeHeight: topChromeHeight,
                rawBottomChromeHeight: rawBottomChromeHeight,
                stageBottomChromeHeight: stageBottomChromeHeight,
                availableStageHeight: availableStageHeight,
                panelHeight: stageLayout.panelHeight,
                fittedPanelHeight: stageLayout.fittedPanelHeight,
                usesStackedBaseline: stageLayout.usesStackedBaseline
            )

            ZStack(alignment: .top) {
                ZStack {
                    Color.black.opacity(Layout.backdropMaxOpacity * transitionChannels.backdropOpacity)
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(Layout.backdropMaterialOpacity * transitionChannels.backdropOpacity)
                }
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss(source: .backdropTap)
                }

                heroGhostLayer(
                    coverSize: stageLayout.coverSize,
                    overlayGlobalFrame: overlayFrameInGlobal
                )
                .opacity(Double(transitionChannels.ghostOpacity))

                stageDeckPanel(
                    coverSize: stageLayout.coverSize,
                    panelInnerSize: stageLayout.panelInnerSize
                )
                .frame(height: stageLayout.fittedPanelHeight)
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
                        shouldConstrainStagePanel
                            ? (
                                Layout.panelShadowBaseOpacity
                                + Layout.panelShadowExtraOpacity * transitionChannels.deckOpacity
                            )
                            : 0
                    ),
                    radius: shouldConstrainStagePanel
                        ? (Layout.panelShadowBaseRadius + Layout.panelShadowExtraRadius * transitionChannels.deckOpacity)
                        : 0,
                    x: 0,
                    y: Layout.panelShadowYOffset
                )
                .opacity(Double(transitionChannels.deckOpacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, topChromeHeight)
                .padding(.bottom, stageBottomChromeHeight)
                .offset(y: stageOffsetY)
                .scaleEffect(stageScale)

                header
                    .padding(.horizontal, Layout.headerHorizontalInset)
                    .padding(.top, headerTopInset)
                    .opacity(Double(transitionChannels.chromeOpacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack(spacing: Layout.bottomChromeSpacing) {
                    if shouldShowCountHint {
                        Text("当日共 \(payload.items.count) 本")
                            .font(AppTypography.footnoteSemibold)
                            .foregroundStyle(Color.white.opacity(0.9))
                            .opacity(Double(transitionChannels.chromeOpacity))
                            .shadow(
                                color: Color.black.opacity(Layout.hintShadowOpacity),
                                radius: Layout.hintShadowRadius,
                                x: 0,
                                y: Layout.hintShadowYOffset
                            )
                    }

                    if shouldShowToggleButton {
                        toggleButton
                            .opacity(Double(transitionChannels.chromeOpacity))
                    }
                }
                .padding(.bottom, toggleBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                Color.clear
                    .onAppear {
                        syncStackedLayoutBaselineIfNeeded(using: baselineCaptureSnapshot)
                        logStackedBaselineReuseIfNeeded(
                            signature: baselineSignature,
                            usesStackedBaseline: stageLayout.usesStackedBaseline
                        )
                        logLayoutSnapshotIfNeeded(debugSnapshot)
                    }
                    .onChange(of: baselineCaptureSnapshot) { _, newValue in
                        syncStackedLayoutBaselineIfNeeded(using: newValue)
                    }
                    .onChange(of: debugSnapshot) { _, newValue in
                        logStackedBaselineReuseIfNeeded(
                            signature: baselineSignature,
                            usesStackedBaseline: newValue.stackedBaselineState == "reused"
                        )
                        logLayoutSnapshotIfNeeded(newValue)
                    }
            }
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)
            .onAppear {
                handleAppear()
            }
            .onDisappear {
                cancelAutoGridTransition()
                cancelCloseTask()
                cancelPhaseTransitionTask()
                cancelTransitionTask()
                isClosing = false
                hapticPlayer?.shutdown()
                hapticPlayer = nil
            }
        }
    }

    var phaseHintText: String {
        "当日共 \(payload.items.count) 本"
    }

    var toggleButton: some View {
        let isStacked = layoutPhase == .stacked
        return Button {
            toggleLayoutPhase()
        } label: {
            HStack(spacing: Spacing.half) {
                Image(systemName: isStacked ? "square.grid.2x2" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(isStacked ? "展开" : "收起")
                    .font(AppTypography.subheadlineSemibold)
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, Layout.toggleButtonHorizontalPadding)
            .padding(.vertical, Layout.toggleButtonVerticalPadding)
            .background(
                Color.black.opacity(Layout.toggleButtonBackgroundOpacity),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(Layout.toggleButtonStrokeOpacity), lineWidth: CardStyle.borderWidth)
            }
            .shadow(color: Color.black.opacity(Layout.toggleButtonShadowOpacity), radius: Layout.toggleButtonShadowRadius, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStacked ? "展开封面列表" : "收起封面列表")
    }

    var header: some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(formattedDate(payload.date))
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.white.opacity(0.96))
                Text(formattedWeekday(payload.date))
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            Spacer(minLength: 0)

            Button {
                dismiss(source: .closeButton)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Layout.closeButtonSymbolSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(Layout.closeButtonOpacity))
            }
            .accessibilityLabel("关闭当日书籍封面全屏浮层")
        }
    }

    @ViewBuilder
    /// 把全屏封面舞台包装成独立面板层，供外层统一控制过渡和遮罩。
    func stageDeckPanel(
        coverSize: CGSize,
        panelInnerSize: CGSize
    ) -> some View {
        fullscreenDeckStage(
            coverSize: coverSize,
            panelInnerSize: panelInnerSize
        )
    }

    var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragOffsetY = value.translation.height * 0.6
            }
            .onEnded { value in
                if value.translation.height > Layout.dismissDragThreshold {
                    dismiss(source: .dragGesture)
                    return
                }
                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                    dragOffsetY = 0
                }
            }
    }

    private func makeLayoutDebugSnapshot(
        overlayFrameInGlobal: CGRect,
        size: CGSize,
        safeAreaInsets: EdgeInsets,
        headerTopInset: CGFloat,
        topChromeHeight: CGFloat,
        rawBottomChromeHeight: CGFloat,
        stageBottomChromeHeight: CGFloat,
        availableStageHeight: CGFloat,
        panelHeight: CGFloat,
        fittedPanelHeight: CGFloat,
        usesStackedBaseline: Bool
    ) -> LayoutDebugSnapshot {
        let relativeSafeTop = max(0, safeAreaInsets.top - overlayFrameInGlobal.minY)
        return LayoutDebugSnapshot(
            overlayMinY: Int(overlayFrameInGlobal.minY.rounded()),
            screenHeight: Int(size.height.rounded()),
            safeTop: Int(safeAreaInsets.top.rounded()),
            relativeSafeTop: Int(relativeSafeTop.rounded()),
            safeBottom: Int(safeAreaInsets.bottom.rounded()),
            topControlMaxY: Int(topControlBarFrameInGlobal.maxY.rounded()),
            headerTopInset: Int(headerTopInset.rounded()),
            topChromeHeight: Int(topChromeHeight.rounded()),
            rawBottomChromeHeight: Int(rawBottomChromeHeight.rounded()),
            stageBottomChromeHeight: Int(stageBottomChromeHeight.rounded()),
            availableStageHeight: Int(availableStageHeight.rounded()),
            panelHeight: Int(panelHeight.rounded()),
            fittedPanelHeight: Int(fittedPanelHeight.rounded()),
            phase: layoutPhase == .stacked ? "stacked" : "grid",
            stackedBaselineState: usesStackedBaseline ? "reused" : "live",
            showHint: shouldShowCountHint,
            showToggle: shouldShowToggleButton
        )
    }

    private func logLayoutSnapshotIfNeeded(_ snapshot: LayoutDebugSnapshot) {
#if DEBUG
        guard snapshot != lastLayoutDebugSnapshot else { return }
        lastLayoutDebugSnapshot = snapshot
        print(
            "[ReadCalendar][OverlayLayout] phase=\(snapshot.phase) overlayMinY=\(snapshot.overlayMinY) screenH=\(snapshot.screenHeight) safeTop=\(snapshot.safeTop) relativeSafeTop=\(snapshot.relativeSafeTop) safeBottom=\(snapshot.safeBottom) topControlMaxY=\(snapshot.topControlMaxY) headerTop=\(snapshot.headerTopInset) topChrome=\(snapshot.topChromeHeight) rawBottomChrome=\(snapshot.rawBottomChromeHeight) stageBottomChrome=\(snapshot.stageBottomChromeHeight) availableStage=\(snapshot.availableStageHeight) panel=\(snapshot.panelHeight) fittedPanel=\(snapshot.fittedPanelHeight) stackedBaseline=\(snapshot.stackedBaselineState) hint=\(snapshot.showHint) toggle=\(snapshot.showToggle)"
        )
#endif
    }

    /// 依据顶部控制栏底边锚点计算日期/关闭栏顶部 inset，确保其贴近模式切换控件下方。
    func resolvedHeaderTopInset(
        safeAreaTop: CGFloat,
        overlayFrameInGlobal: CGRect
    ) -> CGFloat {
        let relativeSafeTop = max(0, safeAreaTop - overlayFrameInGlobal.minY)
        let minInset = max(
            Spacing.base,
            relativeSafeTop + Layout.headerTopSafeAreaInset
        )
        guard topControlBarFrameInGlobal != .zero else {
            return minInset
        }
        let anchoredInset = topControlBarFrameInGlobal.maxY
            - overlayFrameInGlobal.minY
            + Layout.headerToTopControlGap
        return min(
            Layout.headerTopMaxInset,
            max(minInset, anchoredInset)
        )
    }

    /// 根据当前舞台可用空间和源封面宽高比计算全屏封面尺寸。
    func resolvedCoverSize(in panelInnerSize: CGSize) -> CGSize {
        let aspect = min(1.55, max(1.35, sourceCoverAspectRatio))
        return ReadCalendarCoverFullscreenDeckStage.resolveAdaptiveCoverSize(
            containerSize: panelInnerSize,
            visibleCount: payload.stackedVisibleCount,
            sourceAspectRatio: aspect
        )
    }

    /// 依据屏幕高度和滚动能力计算全屏封面面板高度，避免堆叠态与网格态相互挤压。
    func resolvedPanelHeight(in size: CGSize, canScrollGrid: Bool) -> CGFloat {
        let lowerBound: CGFloat = canScrollGrid ? 360 : 340
        let upperBound = max(lowerBound, size.height * (canScrollGrid ? 0.82 : 0.78))
        let preferred = size.height * (canScrollGrid ? 0.74 : 0.66)
        return min(max(preferred, lowerBound), upperBound)
    }

    private func makeStackedLayoutBaselineSignature(
        overlayFrameInGlobal: CGRect,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> StackedLayoutBaselineSignature {
        StackedLayoutBaselineSignature(
            overlayWidth: Int(size.width.rounded()),
            overlayHeight: Int(size.height.rounded()),
            overlayMinY: Int(overlayFrameInGlobal.minY.rounded()),
            safeTop: Int(safeAreaInsets.top.rounded()),
            safeBottom: Int(safeAreaInsets.bottom.rounded()),
            topControlMaxY: Int(topControlBarFrameInGlobal.maxY.rounded())
        )
    }

    private func stackedLayoutBaselineIfValid(
        for signature: StackedLayoutBaselineSignature
    ) -> StackedLayoutBaseline? {
        guard let baseline = stackedLayoutBaseline else { return nil }
        guard baseline.signature == signature else { return nil }
        return baseline
    }

    private func resolvedStageBottomChromeHeight(
        rawBottomChromeHeight: CGFloat,
        stackedBaseline: StackedLayoutBaseline?
    ) -> CGFloat {
        guard layoutPhase == .stacked, let stackedBaseline else {
            return rawBottomChromeHeight
        }
        return stackedBaseline.stageBottomChromeHeight
    }

    private func resolvedStagePanelLayoutMetrics(
        stackedBaseline: StackedLayoutBaseline?,
        livePanelHeight: CGFloat,
        liveFittedPanelHeight: CGFloat,
        livePanelInnerSize: CGSize,
        liveCoverSize: CGSize
    ) -> StagePanelLayoutMetrics {
        guard layoutPhase == .stacked, let stackedBaseline else {
            return StagePanelLayoutMetrics(
                panelHeight: livePanelHeight,
                fittedPanelHeight: liveFittedPanelHeight,
                panelInnerSize: livePanelInnerSize,
                coverSize: liveCoverSize,
                usesStackedBaseline: false
            )
        }
        return StagePanelLayoutMetrics(
            panelHeight: stackedBaseline.panelHeight,
            fittedPanelHeight: stackedBaseline.fittedPanelHeight,
            panelInnerSize: stackedBaseline.panelInnerSize,
            coverSize: stackedBaseline.coverSize,
            usesStackedBaseline: true
        )
    }

    private func makeStackedBaselineCaptureSnapshot(
        signature: StackedLayoutBaselineSignature,
        phase: ReadCalendarCoverFullscreenDeckStage.Phase,
        panelHeight: CGFloat,
        fittedPanelHeight: CGFloat,
        panelInnerSize: CGSize,
        coverSize: CGSize,
        stageBottomChromeHeight: CGFloat
    ) -> StackedBaselineCaptureSnapshot {
        StackedBaselineCaptureSnapshot(
            signature: signature,
            phase: phase,
            panelHeight: Int(panelHeight.rounded()),
            fittedPanelHeight: Int(fittedPanelHeight.rounded()),
            panelInnerWidth: Int(panelInnerSize.width.rounded()),
            panelInnerHeight: Int(panelInnerSize.height.rounded()),
            coverWidth: Int(coverSize.width.rounded()),
            coverHeight: Int(coverSize.height.rounded()),
            stageBottomChromeHeight: Int(stageBottomChromeHeight.rounded())
        )
    }

    private func syncStackedLayoutBaselineIfNeeded(
        using snapshot: StackedBaselineCaptureSnapshot
    ) {
#if DEBUG
        if let currentBaseline = stackedLayoutBaseline,
           currentBaseline.signature != snapshot.signature {
            print(
                "[ReadCalendar][StackedBaseline] reset from=\(describeStackedLayoutBaselineSignature(currentBaseline.signature)) to=\(describeStackedLayoutBaselineSignature(snapshot.signature))"
            )
            stackedLayoutBaseline = nil
            lastReusedStackedBaselineSignature = nil
        }
#else
        if let currentBaseline = stackedLayoutBaseline,
           currentBaseline.signature != snapshot.signature {
            stackedLayoutBaseline = nil
            lastReusedStackedBaselineSignature = nil
        }
#endif

        guard snapshot.phase == .stacked else { return }
        guard stackedLayoutBaseline == nil else { return }

        let captured = StackedLayoutBaseline(
            signature: snapshot.signature,
            panelHeight: CGFloat(snapshot.panelHeight),
            fittedPanelHeight: CGFloat(snapshot.fittedPanelHeight),
            panelInnerSize: CGSize(
                width: CGFloat(snapshot.panelInnerWidth),
                height: CGFloat(snapshot.panelInnerHeight)
            ),
            coverSize: CGSize(
                width: CGFloat(snapshot.coverWidth),
                height: CGFloat(snapshot.coverHeight)
            ),
            stageBottomChromeHeight: CGFloat(snapshot.stageBottomChromeHeight)
        )
        stackedLayoutBaseline = captured
        lastReusedStackedBaselineSignature = nil
#if DEBUG
        print(
            "[ReadCalendar][StackedBaseline] captured signature=\(describeStackedLayoutBaselineSignature(snapshot.signature)) fittedPanel=\(snapshot.fittedPanelHeight) coverW=\(snapshot.coverWidth)"
        )
#endif
    }

    private func logStackedBaselineReuseIfNeeded(
        signature: StackedLayoutBaselineSignature,
        usesStackedBaseline: Bool
    ) {
#if DEBUG
        guard usesStackedBaseline else { return }
        guard lastReusedStackedBaselineSignature != signature else { return }
        lastReusedStackedBaselineSignature = signature
        print(
            "[ReadCalendar][StackedBaseline] reused signature=\(describeStackedLayoutBaselineSignature(signature))"
        )
#endif
    }

    private func describeStackedLayoutBaselineSignature(
        _ signature: StackedLayoutBaselineSignature
    ) -> String {
        "w\(signature.overlayWidth)-h\(signature.overlayHeight)-minY\(signature.overlayMinY)-safeTop\(signature.safeTop)-safeBottom\(signature.safeBottom)-topMaxY\(signature.topControlMaxY)"
    }

    @ViewBuilder
    /// 构建全屏封面舞台主体，并注入当前阶段、布局算法和栅格策略。
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
            isAnimated: isAnimated,
            layoutSeed: payload.stackedSeed,
            stackedVisibleCount: payload.stackedVisibleCount,
            previewLimit: Layout.previewLimit,
            shouldClipGrid: shouldConstrainStagePanel,
            matchedTransitionStyle: .staggered,
            stackedLayoutAlgorithm: .editorialDeskScatter,
            coverSizingMode: .panelAwareBalanced,
            sourceCoverAspectRatio: sourceCoverAspectRatio,
            gridColumnLayoutMode: .fixed(count: 3, degradeForSmallItemCount: true)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.double)
        .padding(.vertical, Spacing.base)
        deckContainer
    }

    /// 处理浮层首次出现：初始化阶段、触发触感并启动自动切换任务。
    func handleAppear() {
        let player = ReadCalendarOverlayHapticPlayer()
        hapticPlayer = player
        player.playOpenHaptic(isHapticsEnabled: isHapticsEnabled, reduceMotion: accessibilityReduceMotion)
        layoutPhase = .stacked
        hasAutoTransitioned = false
        hasCollapsedBackToStack = false
        isClosing = false
        cancelPhaseTransitionTask()
        startEnterTransition()
    }

    /// 在书籍数量超过阈值时，延迟自动切到列表态，提升可浏览性。
    func scheduleAutoGridTransitionIfNeeded() {
        cancelAutoGridTransition()
        guard transitionPhase == .steady else { return }
        guard shouldAutoExpandToGridPhase else { return }
        autoGridTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.autoGridDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isClosing else { return }
                guard !hasAutoTransitioned else { return }
                switchLayoutPhase(to: .grid, source: .automatic)
            }
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

    /// 手动切换堆叠态与列表态，用于过渡评估与对比观察。
    func toggleLayoutPhase() {
        let target: ReadCalendarCoverFullscreenDeckStage.Phase = layoutPhase == .stacked ? .grid : .stacked
        switchLayoutPhase(to: target, source: .manual)
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
        cancelPhaseTransitionTask(resetState: false)
        if target == .grid {
            hapticPlayer?.playExpandHaptic(isHapticsEnabled: isHapticsEnabled, reduceMotion: accessibilityReduceMotion)
            hasCollapsedBackToStack = false
            if isAnimated {
                phaseTransitionDirection = .toGrid
                isDeferringGridConstraint = true
            } else {
                phaseTransitionDirection = nil
                isDeferringGridConstraint = false
            }
        } else {
            hapticPlayer?.playCollapseHaptic(isHapticsEnabled: isHapticsEnabled, reduceMotion: accessibilityReduceMotion)
            hasCollapsedBackToStack = true
            phaseTransitionDirection = nil
            isDeferringGridConstraint = false
        }
        guard isAnimated else {
            layoutPhase = target
            phaseToken += 1
            return
        }
        let animationResponse = target == .grid
            ? Layout.switchToGridResponse
            : Layout.switchToStackResponse
        let animationDamping = target == .grid
            ? Layout.switchToGridDamping
            : Layout.switchToStackDamping
        withAnimation(
            .spring(
                response: animationResponse,
                dampingFraction: animationDamping
            )
        ) {
            layoutPhase = target
            phaseToken += 1
        }
        if target == .grid {
            schedulePhaseTransitionSettle()
        }
    }

    /// 在阶段切换后延迟收束过渡状态，避免动画尚未结束时过早恢复约束。
    func schedulePhaseTransitionSettle() {
        phaseTransitionTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.switchSettleNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                phaseTransitionDirection = nil
                isDeferringGridConstraint = false
                phaseTransitionTask = nil
            }
        }
    }

    /// 取消阶段切换收束任务，并按需重置过渡方向和约束延迟状态。
    func cancelPhaseTransitionTask(resetState: Bool = true) {
        phaseTransitionTask?.cancel()
        phaseTransitionTask = nil
        guard resetState else { return }
        phaseTransitionDirection = nil
        isDeferringGridConstraint = false
    }

    @ViewBuilder
    /// 渲染封面从日历堆栈飞入全屏舞台的 ghost 图层，补齐真实源位和目标位之间的连续感。
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

    /// 将日期格式化为封面全屏详情使用的“月日”文案。
    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 将日期转换为中文星期文案，供全屏封面详情展示。
    func formattedWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func dismiss(source: DismissSource) {
        guard !isClosing else { return }
        cancelAutoGridTransition()
        cancelTransitionTask()
        cancelCloseTask()
        cancelPhaseTransitionTask()
        if source == .dragGesture {
            dragOffsetY = max(0, dragOffsetY)
        } else {
            withAnimation(.smooth(duration: 0.2)) {
                dragOffsetY = 0
            }
        }
        isClosing = true
        runDismissTransition(source: source)
    }

    private func runDismissTransition(source _: DismissSource) {
        transitionPhase = .exiting
        guard isAnimated else {
            isClosing = false
            onClose()
            return
        }
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

    /// 启动封面全屏入场过渡，并在动画结束后衔接自动回网格流程。
    func startEnterTransition() {
        cancelTransitionTask()
        transitionPhase = .entering
        transitionProgress = 0
        guard isAnimated else {
            transitionProgress = 1
            transitionPhase = .steady
            scheduleAutoGridTransitionIfNeeded()
            return
        }
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
                scheduleAutoGridTransitionIfNeeded()
            }
        }
    }

    /// 取消当前入场过渡任务，避免重复切换时残留旧动画回调。
    func cancelTransitionTask() {
        transitionTask?.cancel()
        transitionTask = nil
    }

    /// 将秒数转换为 `Task.sleep` 需要的纳秒值，并对负值做安全钳制。
    func nanoseconds(from seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// 在两个标量之间做线性插值，统一封面过渡中的比例计算。
    func lerp(_ min: CGFloat, _ max: CGFloat, _ progress: CGFloat) -> CGFloat {
        min + (max - min) * progress
    }
}

private extension View {
    /// 预留底部沉浸样式扩展点；当前不应用模糊与边缘特效。
    func readCalendarBottomImmersiveStyle() -> some View {
        self
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
        monthPageProvider: { monthStart in
            ReadCalendarContentView.MonthPage(
                monthStart: monthStart,
                weeks: [],
                dayMap: [:],
                readingDurationTopBooks: [],
                summary: .empty,
                rankingBarColorsByBookId: [:],
                selectedDate: nil,
                todayStart: Calendar.current.startOfDay(for: Date()),
                laneLimit: 4,
                isDayMapEmpty: true,
                loadState: .idle,
                errorMessage: nil
            )
        },
        onDisplayModeChanged: { _ in },
        onPagerSelectionChanged: { _ in },
        onYearSelectionChanged: { _ in },
        onSelectDate: { _ in },
        onRetry: {},
        onBookCoverFullscreenPresentationChanged: { _ in }
    )
    .padding(.horizontal, Spacing.screenEdge)
    .padding(.bottom, Spacing.base)
    .background(Color.surfacePage)
}
