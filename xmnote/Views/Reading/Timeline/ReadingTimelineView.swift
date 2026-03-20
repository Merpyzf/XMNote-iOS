/**
 * [INPUT]: 依赖 HorizonCalendar 的 CalendarViewRepresentable/CalendarViewProxy，依赖 TimelineViewModel 提供事件与日历标记数据，依赖外部跳转回调承接内容查看与书籍详情
 * [OUTPUT]: 对外提供 ReadingTimelineView（首页时间线模块：日历与事件列表联动）
 * [POS]: Reading 模块正式时间线页面，承载月份切换、日期选择、分类过滤、按日时间线渲染与事件点击跳转
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import HorizonCalendar
import SwiftUI
import UIKit

private let readingTimelineScrollCoordinateSpaceName = "reading-timeline-scroll-space"

/// 首页在读模块的正式时间线页面（外壳）。
struct ReadingTimelineView: View {
    let viewModel: TimelineViewModel?
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenBookDetail: (Int64) -> Void

    /// 注入内容查看与书籍详情跳转回调，承接时间线事件点击。
    init(
        viewModel: TimelineViewModel? = nil,
        onOpenContentViewer: @escaping (ContentViewerSourceContext, ContentViewerItemID) -> Void = { _, _ in },
        onOpenBookDetail: @escaping (Int64) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onOpenContentViewer = onOpenContentViewer
        self.onOpenBookDetail = onOpenBookDetail
    }

    var body: some View {
        Group {
            if let viewModel {
                ReadingTimelineContentView(
                    viewModel: viewModel,
                    onOpenContentViewer: onOpenContentViewer,
                    onOpenBookDetail: onOpenBookDetail
                )
            } else {
                ReadingTimelineBootstrapShellView()
            }
        }
    }
}

/// 时间线首开静态壳层，在容器尚未注入状态源或首屏快照未就绪前提供稳定结构。
private struct ReadingTimelineBootstrapShellView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineBootstrapCalendarPanel()
                TimelineBootstrapListShell()
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.base)
        }
        .coordinateSpace(name: readingTimelineScrollCoordinateSpaceName)
    }
}

// MARK: - Content View

/// 时间线页面内容视图，只负责容器组合，避免列表与日历共享同一观察热区。
private struct ReadingTimelineContentView: View {
    @Environment(SceneStateStore.self) private var sceneStateStore
    @Bindable var viewModel: TimelineViewModel
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenBookDetail: (Int64) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineCalendarPanel(viewModel: viewModel)
                TimelineListContainer(
                    viewModel: viewModel,
                    onOpenContentViewer: onOpenContentViewer,
                    onOpenBookDetail: onOpenBookDetail
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.base)
        }
        .coordinateSpace(name: readingTimelineScrollCoordinateSpaceName)
        .onAppear {
            sceneStateStore.updateTimeline(viewModel.sceneSnapshot)
        }
        .onChange(of: viewModel.selectedDate) { _, _ in
            sceneStateStore.updateTimeline(viewModel.sceneSnapshot)
        }
        .onChange(of: viewModel.displayedMonthStart) { _, _ in
            sceneStateStore.updateTimeline(viewModel.sceneSnapshot)
        }
        .onChange(of: viewModel.selectedCategory) { _, _ in
            sceneStateStore.updateTimeline(viewModel.sceneSnapshot)
        }
    }
}

/// 时间线首开日历壳层，使用静态网格保持卡片高度与头部节奏稳定。
private struct TimelineBootstrapCalendarPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let calendar: Calendar
    private let monthStart: Date

    init() {
        var calendar = Calendar.current
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.firstWeekday = 1
        self.calendar = calendar
        self.monthStart = Self.monthStart(of: Date(), using: calendar)
    }

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.panelCornerRadius) {
            VStack(spacing: Spacing.base) {
                bootstrapHeader
                    .padding(.horizontal, Spacing.contentEdge)
                    .padding(.top, Spacing.contentEdge)

                VStack(spacing: 8) {
                    weekdayRow
                    calendarGrid
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.bottom, Spacing.contentEdge)
            }
        }
        .allowsHitTesting(false)
    }
}

private extension TimelineBootstrapCalendarPanel {
    var bootstrapHeader: some View {
        Group {
            if dynamicTypeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    bootstrapMonthTitle
                    Text("今天")
                        .font(TimelineCalendarStyle.relativeUnitFont)
                        .foregroundStyle(TimelineCalendarStyle.relativeUnitColor)
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: Spacing.base) {
                    bootstrapMonthTitle
                    Spacer(minLength: 0)
                    Text("今天")
                        .font(TimelineCalendarStyle.relativeUnitFont)
                        .foregroundStyle(TimelineCalendarStyle.relativeUnitColor)
                    bootstrapTodayButton
                }
            }
        }
    }

    var bootstrapMonthTitle: some View {
        let components = calendar.dateComponents([.year, .month], from: monthStart)
        let year = components.year ?? 0
        let month = components.month ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
            Text(verbatim: String(year))
                .font(TimelineCalendarStyle.monthNumberFont)
                .foregroundStyle(TimelineCalendarStyle.monthNumberColor)
                .monospacedDigit()
                .brandVerticalTrim(TimelineCalendarStyle.monthNumberVerticalTrim, edges: [.top, .bottom])
            Text(" 年 ")
                .font(TimelineCalendarStyle.monthUnitFont)
                .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
            Text(verbatim: String(month))
                .font(TimelineCalendarStyle.monthNumberFont)
                .foregroundStyle(TimelineCalendarStyle.monthNumberColor)
                .monospacedDigit()
                .brandVerticalTrim(TimelineCalendarStyle.monthNumberVerticalTrim, edges: [.top, .bottom])
            Text(" 月")
                .font(TimelineCalendarStyle.monthUnitFont)
                .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
        }
    }

    var bootstrapTodayButton: some View {
        Text("今")
            .font(TimelineCalendarStyle.actionButtonFont)
            .foregroundStyle(Color.brandDeep.opacity(0.55))
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.half)
            .background(Color.brand.opacity(0.08))
            .overlay(
                Capsule()
                    .stroke(Color.brand.opacity(0.18), lineWidth: CardStyle.borderWidth)
            )
            .clipShape(Capsule())
    }

    var weekdayRow: some View {
        HStack(spacing: 8) {
            ForEach(calendar.veryShortStandaloneWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(TimelineCalendarStyle.weekdayFont)
                    .foregroundStyle(TimelineCalendarStyle.weekdayTextColor)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    var calendarGrid: some View {
        let today = calendar.startOfDay(for: Date())
        let days = daySlots

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7),
            spacing: 8
        ) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    TimelineCalendarDayCell(
                        dayNumber: day,
                        marker: nil,
                        isSelected: calendar.isDate(
                            calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? today,
                            inSameDayAs: today
                        ),
                        dayNumberFont: TimelineCalendarStyle.dayNumberFont
                    )
                } else {
                    Color.clear
                        .frame(width: TimelineCalendarStyle.dayCellSize, height: TimelineCalendarStyle.dayCellSize)
                }
            }
        }
    }

    var daySlots: [Int?] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { return Array(repeating: nil, count: 42) }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = max(0, weekday - calendar.firstWeekday)
        let leadingSlots = Array(repeating: Optional<Int>.none, count: leading)
        let dayValues = dayRange.map(Optional.some)
        return leadingSlots + dayValues
    }

    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }
}

// MARK: - Calendar Panel

/// 日历面板子树，隔离 sections/bootstrapPhase 变化对 HorizonCalendar 桥接层的影响。
private struct TimelineCalendarPanel: View {
    @Bindable var viewModel: TimelineViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var calendarProxy = CalendarViewProxy()
    @State private var calendarHeight: CGFloat = 320
    @State private var calendarViewportWidth: CGFloat = 0
    @State private var hasPerformedInitialViewportSync = false
    @State private var isUserPagingInFlight = false
    @State private var isProgrammaticLongJump = false
    @State private var markerPreloadTask: Task<Void, Never>?
    @State private var lastMarkerPreloadRequest: TimelineMarkerPreloadRequest?

    private let calendar: Calendar
    private let visibleDateRange: ClosedRange<Date>
    private let monthFormatter: DateFormatter
    private let monthHeaderHeight: CGFloat = 0.1
    private let interMonthSpacing: CGFloat = 0
    private let horizontalDayMargin: CGFloat = 8
    private let verticalDayMargin: CGFloat = 8
    private let dayOfWeekAspectRatio: CGFloat = 0.58
    private let monthDayInsets = NSDirectionalEdgeInsets.zero
    private let monthTransitionAnimation = Animation.easeInOut(duration: 0.22)
    private let longJumpMonthThreshold: Int = 2

    init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel

        var cal = Calendar.current
        cal.timeZone = .current
        cal.locale = Locale(identifier: "zh_Hans_CN")
        cal.firstWeekday = 1
        self.calendar = cal

        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .month, value: -24, to: today) ?? today
        let end = cal.date(byAdding: .month, value: 2, to: today) ?? today
        self.visibleDateRange = (cal.startOfDay(for: start)...cal.startOfDay(for: end))

        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = cal.locale
        formatter.dateFormat = "yyyy 年 M 月"
        self.monthFormatter = formatter
    }

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.panelCornerRadius) {
            VStack(spacing: Spacing.base) {
                calendarHeader
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.top, Spacing.contentEdge)

                GeometryReader { proxy in
                    CalendarViewRepresentable(
                        calendar: calendar,
                        visibleDateRange: visibleDateRange,
                        monthsLayout: .horizontal(options: .init(
                            maximumFullyVisibleMonths: 1,
                            scrollingBehavior: .paginatedScrolling(.init(
                                restingPosition: .atLeadingEdgeOfEachMonth,
                                restingAffinity: .atPositionsAdjacentToPrevious
                            ))
                        )),
                        dataDependency: CalendarDependencyToken(
                            selectedDate: viewModel.selectedDate,
                            selectedCategory: viewModel.selectedCategory,
                            markerRevision: viewModel.markerRevision
                        ),
                        proxy: calendarProxy
                    )
                    .backgroundColor(.clear)
                    .interMonthSpacing(interMonthSpacing)
                    .verticalDayMargin(verticalDayMargin)
                    .horizontalDayMargin(horizontalDayMargin)
                    .dayOfWeekAspectRatio(dayOfWeekAspectRatio)
                    .monthDayInsets(monthDayInsets)
                    .monthHeaders { _ in
                        Color.clear
                            .frame(height: monthHeaderHeight)
                    }
                    .dayOfWeekHeaders { _, weekdayIndex in
                        Text(weekdaySymbol(for: weekdayIndex))
                            .font(TimelineCalendarStyle.weekdayFont)
                            .foregroundStyle(TimelineCalendarStyle.weekdayTextColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .days { day in
                        let dayDate = date(for: day)
                        let isSelected = dayDate.map { calendar.isDate($0, inSameDayAs: viewModel.selectedDate) } ?? false
                        let marker = dayDate.flatMap { viewModel.marker(for: $0) }
                        TimelineCalendarDayCell(
                            dayNumber: day.day,
                            marker: marker,
                            isSelected: isSelected,
                            dayNumberFont: TimelineCalendarStyle.dayNumberFont
                        )
                    }
                    .onDaySelection { day in
                        guard let date = date(for: day) else { return }
                        let monthStart = Self.monthStart(of: date, using: calendar)
                        commitHeaderState(
                            selectedDay: date,
                            monthStart: monthStart,
                            animated: false
                        )
                    }
                    .onHorizontalMonthPagingProgress { progressContext in
                        handleMonthPagingProgress(progressContext)
                    }
                    .onScroll { _, isUserDragging in
                        if isUserDragging, !isUserPagingInFlight {
                            isUserPagingInFlight = true
                        }
                    }
                    .onDragEnd { visibleRange, willDecelerate in
                        guard !willDecelerate else { return }
                        if isUserPagingInFlight {
                            isUserPagingInFlight = false
                        }
                        settleMonthAfterPaging(visibleRange)
                    }
                    .onDeceleratingEnd { visibleRange in
                        if isUserPagingInFlight {
                            isUserPagingInFlight = false
                        }
                        settleMonthAfterPaging(visibleRange)
                    }
                    .onAppear {
                        updateCalendarHeight(
                            for: viewModel.displayedMonthStart,
                            availableWidth: proxy.size.width,
                            animated: false
                        )
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        updateCalendarHeight(
                            for: viewModel.displayedMonthStart,
                            availableWidth: width,
                            animated: false
                        )
                    }
                }
                .frame(height: calendarHeight)
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.bottom, Spacing.contentEdge)
            }
        }
        .allowsHitTesting(viewModel.bootstrapPhase == .ready && !viewModel.isRefreshing)
        .onAppear {
            performInitialViewportSyncIfNeeded()
        }
        .onDisappear {
            markerPreloadTask?.cancel()
            markerPreloadTask = nil
            lastMarkerPreloadRequest = nil
        }
    }
}

private extension TimelineCalendarPanel {
    /// 仅在面板首次挂载时同步日历视口到当前状态，不能在每次重新出现时重置到今天。
    func performInitialViewportSyncIfNeeded() {
        guard !hasPerformedInitialViewportSync else { return }
        hasPerformedInitialViewportSync = true

        let targetMonth = Self.monthStart(of: viewModel.displayedMonthStart, using: calendar)
        let targetDay = calendar.startOfDay(for: viewModel.selectedDate)
        DispatchQueue.main.async {
            applyDisplayedMonth(targetMonth, animated: false)
            calendarProxy.scrollToMonth(
                containing: targetMonth,
                scrollPosition: .firstFullyVisiblePosition,
                animated: false
            )
            if calendar.isDate(targetDay, equalTo: targetMonth, toGranularity: .month) {
                calendarProxy.scrollToDay(
                    containing: targetDay,
                    scrollPosition: .centered,
                    animated: false
                )
            }
        }
    }

    @ViewBuilder
    var calendarHeader: some View {
        if usesExpandedHeaderLayout {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                HStack(alignment: .lastTextBaseline, spacing: Spacing.base) {
                    monthPicker
                    Spacer(minLength: 0)
                    todayButton
                }

                selectedDateOffsetText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .lastTextBaseline, spacing: Spacing.base) {
                monthPicker

                Spacer()

                selectedDateOffsetText
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                todayButton
            }
        }
    }

    var monthPicker: some View {
        Menu {
            ForEach(availableMonthStarts.reversed(), id: \.self) { monthStart in
                Button {
                    jumpToDate(monthStart, animated: true)
                } label: {
                    if calendar.isDate(monthStart, equalTo: viewModel.displayedMonthStart, toGranularity: .month) {
                        Label(monthFormatter.string(from: monthStart), systemImage: "checkmark")
                            .foregroundStyle(.primary)
                    } else {
                        Text(monthFormatter.string(from: monthStart))
                    }
                }
            }
        } label: {
            HStack(alignment: .lastTextBaseline, spacing: Spacing.compact) {
                displayedMonthTitleText
                    .lineLimit(1)
                .minimumScaleFactor(0.9)
            }
        }
        .tint(nil)
        .buttonStyle(.plain)
    }

    var todayButton: some View {
        Button("今") {
            jumpToDate(calendar.startOfDay(for: Date()), animated: true)
        }
        .font(TimelineCalendarStyle.actionButtonFont)
        .foregroundStyle(Color.brandDeep)
        .padding(.horizontal, Spacing.tight)
        .padding(.vertical, Spacing.half)
        .background(Color.brand.opacity(0.14))
        .overlay(
            Capsule()
                .stroke(Color.brand.opacity(0.28), lineWidth: CardStyle.borderWidth)
        )
        .clipShape(Capsule())
    }

    var availableMonthStarts: [Date] {
        let lowerMonth = Self.monthStart(of: visibleDateRange.lowerBound, using: calendar)
        let upperMonth = Self.monthStart(of: visibleDateRange.upperBound, using: calendar)
        var result: [Date] = []
        var cursor = lowerMonth
        while cursor <= upperMonth {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = Self.monthStart(of: next, using: calendar)
        }
        return result
    }

    var displayedMonthTitleText: some View {
        let components = calendar.dateComponents([.year, .month], from: viewModel.displayedMonthStart)
        let year = components.year ?? calendar.component(.year, from: viewModel.displayedMonthStart)
        let month = components.month ?? calendar.component(.month, from: viewModel.displayedMonthStart)
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
            brandNumberText(
                String(year),
                font: TimelineCalendarStyle.monthNumberFont,
                color: TimelineCalendarStyle.monthNumberColor,
                trim: TimelineCalendarStyle.monthNumberVerticalTrim
            )
            Text(" 年 ")
                .font(TimelineCalendarStyle.monthUnitFont)
                .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
            brandNumberText(
                String(month),
                font: TimelineCalendarStyle.monthNumberFont,
                color: TimelineCalendarStyle.monthNumberColor,
                trim: TimelineCalendarStyle.monthNumberVerticalTrim
            )
            Text(" 月")
                .font(TimelineCalendarStyle.monthUnitFont)
                .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
        }
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.24), value: viewModel.displayedMonthStart)
    }

    var selectedDateOffsetText: some View {
        let today = calendar.startOfDay(for: Date())
        let dayOffset = calendar.dateComponents([.day], from: viewModel.selectedDate, to: today).day ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
            if dayOffset != 0 {
                brandNumberText(
                    String(abs(dayOffset)),
                    font: TimelineCalendarStyle.relativeNumberFont,
                    color: TimelineCalendarStyle.relativeNumberColor,
                    trim: TimelineCalendarStyle.relativeNumberVerticalTrim
                )
                .contentTransition(.numericText())
            }
            Text(dayOffset == 0 ? "今天" : (dayOffset > 0 ? "天前" : "天后"))
                .font(TimelineCalendarStyle.relativeUnitFont)
                .foregroundStyle(TimelineCalendarStyle.relativeUnitColor)
                .contentTransition(.numericText())
        }
        .animation(.snappy(duration: 0.24), value: dayOffset)
        .lineLimit(usesExpandedHeaderLayout ? 2 : 1)
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func brandNumberText(
        _ value: String,
        font: Font,
        color: Color,
        trim: BrandTypography.VerticalTrim
    ) -> some View {
        Text(verbatim: value)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .brandVerticalTrim(trim, edges: [.top, .bottom])
    }

    /// 分页结束后根据首个可见日期回写当前月份标题，避免头部与实际可见月份脱节。
    func settleMonthAfterPaging(_ visibleRange: DayComponentsRange) {
        guard let firstVisibleDate = date(for: visibleRange.lowerBound) else { return }
        let monthStart = Self.monthStart(of: firstVisibleDate, using: calendar)
        applyDisplayedMonth(monthStart, animated: false)
    }

    /// 跟随用户横向翻月进度插值日历高度，并提前预热相邻月份标记。
    func handleMonthPagingProgress(_ context: HorizontalMonthPagingProgressContext) {
        guard calendarViewportWidth > 0 else { return }
        guard !isProgrammaticLongJump else { return }
        guard context.isUserDragging || isUserPagingInFlight else { return }
        guard
            let fromMonthStart = monthStart(for: context.fromMonth),
            let toMonthStart = monthStart(for: context.toMonth)
        else {
            return
        }

        scheduleMarkerPreload(for: [fromMonthStart, toMonthStart])

        let fromHeight = monthContentHeight(for: fromMonthStart, availableWidth: calendarViewportWidth)
        let toHeight = monthContentHeight(for: toMonthStart, availableWidth: calendarViewportWidth)
        guard fromHeight > 0, toHeight > 0 else { return }

        let progress = min(1, max(0, context.progress))
        let interpolatedHeight = fromHeight + (toHeight - fromHeight) * progress
        guard interpolatedHeight > 0 else { return }
        guard abs(calendarHeight - interpolatedHeight) > 0.5 else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            calendarHeight = interpolatedHeight
        }
    }

    /// 把新月份写回页面状态，并同步刷新日历容器高度。
    func applyDisplayedMonth(_ monthStart: Date, animated: Bool) {
        let normalizedMonth = Self.monthStart(of: monthStart, using: calendar)
        if normalizedMonth != viewModel.displayedMonthStart {
            viewModel.displayedMonthStart = normalizedMonth
            scheduleMarkerPreload(for: [normalizedMonth])
        }
        updateCalendarHeight(
            for: normalizedMonth,
            availableWidth: calendarViewportWidth,
            animated: animated
        )
    }

    /// 跳转到指定日期所在月份，远距离跳月时改走无动画长跳，避免分页动画拖影。
    func jumpToDate(_ date: Date, animated: Bool) {
        let normalized = calendar.startOfDay(for: date)
        let clamped = min(max(normalized, visibleDateRange.lowerBound), visibleDateRange.upperBound)
        let targetMonthStart = Self.monthStart(of: clamped, using: calendar)
        let monthDistance = Self.monthDistance(from: viewModel.displayedMonthStart, to: targetMonthStart, using: calendar)
        let shouldUseLongJump = animated && abs(monthDistance) > longJumpMonthThreshold

        if shouldUseLongJump {
            isProgrammaticLongJump = true
            if isUserPagingInFlight {
                isUserPagingInFlight = false
            }
            commitHeaderState(
                selectedDay: clamped,
                monthStart: targetMonthStart,
                animated: true
            )
            calendarProxy.scrollToMonth(
                containing: targetMonthStart,
                scrollPosition: .firstFullyVisiblePosition,
                animated: false
            )
            DispatchQueue.main.async {
                isProgrammaticLongJump = false
            }
            return
        }

        if animated {
            scheduleMarkerPreload(for: [viewModel.displayedMonthStart, targetMonthStart])
            if !isUserPagingInFlight {
                isUserPagingInFlight = true
            }
            commitHeaderState(
                selectedDay: clamped,
                monthStart: targetMonthStart,
                animated: true
            )
            calendarProxy.scrollToMonth(
                containing: targetMonthStart,
                scrollPosition: .firstFullyVisiblePosition,
                animated: true
            )
            return
        }

        commitHeaderState(
            selectedDay: clamped,
            monthStart: targetMonthStart,
            animated: false
        )
        calendarProxy.scrollToMonth(
            containing: targetMonthStart,
            scrollPosition: .firstFullyVisiblePosition,
            animated: false
        )
    }

    /// 统一提交头部选中日与月份状态，保证标题、列表和日历指针在同一事务里更新。
    func commitHeaderState(selectedDay: Date, monthStart: Date, animated: Bool) {
        let normalizedDay = calendar.startOfDay(for: selectedDay)
        let normalizedMonth = Self.monthStart(of: monthStart, using: calendar)
        let isMonthChanged = normalizedMonth != viewModel.displayedMonthStart
        let isDayChanged = normalizedDay != viewModel.selectedDate

        if isMonthChanged {
            viewModel.displayedMonthStart = normalizedMonth
            scheduleMarkerPreload(for: [normalizedMonth])
        }

        if isDayChanged {
            if animated {
                withAnimation(monthTransitionAnimation) {
                    viewModel.selectedDate = normalizedDay
                }
            } else {
                viewModel.selectedDate = normalizedDay
            }

            Task {
                await viewModel.loadEvents()
            }
        }

        updateCalendarHeight(
            for: normalizedMonth,
            availableWidth: calendarViewportWidth,
            animated: animated
        )
    }

    /// 依据当前月份周数重算日历高度，避免横向翻月时容器跳变。
    func updateCalendarHeight(for monthStart: Date, availableWidth: CGFloat, animated: Bool) {
        guard availableWidth > 0 else { return }
        calendarViewportWidth = availableWidth
        let targetHeight = monthContentHeight(
            for: monthStart,
            availableWidth: availableWidth
        )
        guard targetHeight > 0 else { return }
        guard abs(calendarHeight - targetHeight) > 0.5 else { return }

        if animated {
            withAnimation(monthTransitionAnimation) {
                calendarHeight = targetHeight
            }
        } else {
            calendarHeight = targetHeight
        }
    }

    /// 计算指定月份在当前宽度下的完整内容高度，供分页插值和静态布局复用。
    func monthContentHeight(for monthStart: Date, availableWidth: CGFloat) -> CGFloat {
        let monthWidth = max(0, availableWidth - interMonthSpacing)
        let insetWidth = monthWidth - monthDayInsets.leading - monthDayInsets.trailing
        guard insetWidth > 0 else { return 0 }

        let dayWidth = (insetWidth - (horizontalDayMargin * 6)) / 7
        guard dayWidth > 0 else { return 0 }

        let dayHeight = dayWidth
        let dayOfWeekHeight = dayWidth * dayOfWeekAspectRatio
        let weekRows = CGFloat(Self.monthWeekRowCount(for: monthStart, using: calendar))

        let daysOfWeekRowHeight = dayOfWeekHeight + verticalDayMargin
        let dayContentHeight = dayHeight * weekRows + verticalDayMargin * max(0, weekRows - 1)
        let totalHeight = monthHeaderHeight + monthDayInsets.top + daysOfWeekRowHeight + dayContentHeight + monthDayInsets.bottom
        return ceil(totalHeight)
    }

    /// 按月份去重后串行预加载日历标记，避免同一轮滚动里重复发起仓储请求。
    func scheduleMarkerPreload(for months: [Date]) {
        let normalizedMonths = months
            .map { Self.monthStart(of: $0, using: calendar) }
            .reduce(into: [Date]()) { result, month in
                if !result.contains(month) {
                    result.append(month)
                }
            }
        guard !normalizedMonths.isEmpty else { return }

        let request = TimelineMarkerPreloadRequest(
            months: normalizedMonths,
            category: viewModel.selectedCategory
        )
        guard request != lastMarkerPreloadRequest else { return }

        lastMarkerPreloadRequest = request
        markerPreloadTask?.cancel()
        markerPreloadTask = Task {
            for month in request.months {
                guard !Task.isCancelled else { return }
                await viewModel.preloadMarkers(around: month)
            }
        }
    }

    /// 将 HorizonCalendar 的 `DayComponents` 归一成自然日 `Date`。
    func date(for day: DayComponents) -> Date? {
        guard let date = calendar.date(from: day.components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// 将 HorizonCalendar 的 `MonthComponents` 转成对应月份首日。
    func monthStart(for month: MonthComponents) -> Date? {
        let components = DateComponents(era: month.era, year: month.year, month: month.month, day: 1)
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// 读取本地化超短星期文案，供日历周标题展示。
    func weekdaySymbol(for index: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }

    /// 把任意日期折叠到月份首日，作为分页和缓存 key 的统一基准。
    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }

    /// 计算两个日期所在月份的距离，供时间线分页与月份切换动画复用。
    static func monthDistance(from: Date, to: Date, using calendar: Calendar) -> Int {
        let fromMonth = monthStart(of: from, using: calendar)
        let toMonth = monthStart(of: to, using: calendar)
        return calendar.dateComponents([.month], from: fromMonth, to: toMonth).month ?? 0
    }

    /// 估算指定月份需要展示的周行数，保证时间线月历占位高度稳定。
    static func monthWeekRowCount(for monthDate: Date, using calendar: Calendar) -> Int {
        let normalizedMonthStart = Self.monthStart(of: monthDate, using: calendar)
        guard
            let monthDays = calendar.range(of: .day, in: .month, for: normalizedMonthStart)?.count,
            let firstDayDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: normalizedMonthStart),
            let lastDayDate = calendar.date(byAdding: .day, value: monthDays - 1, to: firstDayDate)
        else {
            return 6
        }

        let firstWeekday = calendar.component(.weekday, from: firstDayDate)
        let lastWeekday = calendar.component(.weekday, from: lastDayDate)
        let weekStart = calendar.firstWeekday

        let preDiff: Int
        switch weekStart {
        case 1:
            preDiff = firstWeekday - 1
        case 2:
            preDiff = firstWeekday == 1 ? 6 : firstWeekday - 2
        default:
            preDiff = firstWeekday == 7 ? 0 : firstWeekday
        }

        let endDiff: Int
        switch weekStart {
        case 1:
            endDiff = 7 - lastWeekday
        case 2:
            endDiff = lastWeekday == 1 ? 0 : 7 - lastWeekday + 1
        default:
            endDiff = lastWeekday == 7 ? 6 : 7 - lastWeekday - 1
        }

        return (preDiff + monthDays + endDiff) / 7
    }

    var usesExpandedHeaderLayout: Bool {
        dynamicTypeSize >= .accessibility1
    }
}

// MARK: - Timeline List

/// 时间线列表子树，隔离日历月份和 markerRevision 变化对列表 diff 的影响。
private struct TimelineListContainer: View {
    @Bindable var viewModel: TimelineViewModel
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenBookDetail: (Int64) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var timelineListMinY: CGFloat = .zero
    @State private var prewarmWidthBucket: Int = 0
    @State private var prewarmTask: Task<Void, Never>?

    var body: some View {
        TimelineListContent(
            sections: viewModel.sections,
            sectionsRevision: viewModel.sectionsRevision,
            bootstrapPhase: viewModel.bootstrapPhase,
            isRefreshing: viewModel.isRefreshing,
            sourceContext: viewModel.currentViewerSourceContext(),
            onOpenContentViewer: onOpenContentViewer,
            onOpenBookDetail: onOpenBookDetail
        )
        .equatable()
        .overlay(alignment: .topTrailing) {
            TimelineCategoryFilterMenu(
                selectedCategory: viewModel.selectedCategory,
                onCategorySelected: { category in
                    Task { await viewModel.selectCategory(category) }
                }
            )
            .disabled(viewModel.bootstrapPhase != .ready || viewModel.isRefreshing)
            .padding(.top, Spacing.cozy)
            .offset(y: max(0, -timelineListMinY))
            .zIndex(1)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .named(readingTimelineScrollCoordinateSpaceName)).minY
        } action: { minY in
            guard abs(minY - timelineListMinY) > 0.5 else { return }
            timelineListMinY = minY
        }
        .onGeometryChange(for: Int.self) { geometry in
            Int((geometry.size.width * max(displayScale, 1)).rounded())
        } action: { widthBucket in
            guard widthBucket != prewarmWidthBucket else { return }
            prewarmWidthBucket = widthBucket
        }
        .onAppear {
            schedulePrewarm(for: prewarmRequest)
        }
        .onChange(of: prewarmRequest) { _, request in
            schedulePrewarm(for: request)
        }
        .onDisappear {
            prewarmTask?.cancel()
            prewarmTask = nil
        }
    }
}

private extension TimelineListContainer {
    var prewarmEntries: [TimelineRichTextPrewarmEntry] {
        var entries: [TimelineRichTextPrewarmEntry] = []
        entries.reserveCapacity(8)

        for section in viewModel.sections {
            for event in section.events {
                switch event.kind {
                case .note(let note):
                    appendPrewarmEntry(
                        html: note.content,
                        style: .primary,
                        into: &entries
                    )
                    appendPrewarmEntry(
                        html: note.idea,
                        style: .secondary,
                        into: &entries
                    )
                case .review(let review):
                    appendPrewarmEntry(
                        html: review.content,
                        style: .primary,
                        into: &entries
                    )
                case .relevant(let relevant):
                    appendPrewarmEntry(
                        html: relevant.content,
                        style: .primary,
                        into: &entries
                    )
                default:
                    break
                }

                if entries.count >= 8 {
                    return entries
                }
            }
        }

        return entries
    }

    var prewarmRequest: TimelineRichTextPrewarmRequest? {
        guard viewModel.bootstrapPhase == .ready else { return nil }
        guard !viewModel.isRefreshing else { return nil }
        guard prewarmWidthBucket > 0 else { return nil }
        guard !prewarmEntries.isEmpty else { return nil }

        return TimelineRichTextPrewarmRequest(
            entries: prewarmEntries,
            widthBucket: prewarmWidthBucket,
            displayScale: max(displayScale, 1),
            userInterfaceStyle: colorScheme.userInterfaceStyle,
            preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory
        )
    }

    /// 异步预热时间线富文本收起态布局，降低首次滚入笔记/书评卡时的排版抖动。
    func schedulePrewarm(for request: TimelineRichTextPrewarmRequest?) {
        prewarmTask?.cancel()
        guard let request else {
            prewarmTask = nil
            return
        }

        prewarmTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }

            let traitCollection = UITraitCollection { mutableTraits in
                mutableTraits.userInterfaceStyle = request.userInterfaceStyle
                mutableTraits.preferredContentSizeCategory = request.preferredContentSizeCategory
            }
            let width = CGFloat(request.widthBucket) / request.displayScale

            for entry in request.entries {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    RichText.prewarmPreviewLayoutSnapshot(
                        html: entry.html,
                        baseFont: TimelineTypography.eventRichTextBaseFont,
                        textColor: entry.style.textColor,
                        lineSpacing: TimelineTypography.eventRichTextLineSpacing,
                        maxLines: TimelineRichTextPrewarmRequest.defaultMaxLines,
                        width: width,
                        traitCollection: traitCollection,
                        screenScale: request.displayScale
                    )
                }
                await Task.yield()
            }
        }
    }

    /// 过滤空白 HTML 并追加到预热队列，控制单次预热数量避免抢占首屏资源。
    func appendPrewarmEntry(
        html: String,
        style: TimelineRichTextPrewarmStyle,
        into entries: inout [TimelineRichTextPrewarmEntry]
    ) {
        guard entries.count < 8 else { return }
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(TimelineRichTextPrewarmEntry(html: trimmed, style: style))
    }
}

private struct TimelineListContent: View, Equatable {
    let sections: [TimelineSection]
    let sectionsRevision: Int
    let bootstrapPhase: TimelineViewModel.BootstrapPhase
    let isRefreshing: Bool
    let sourceContext: ContentViewerSourceContext
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenBookDetail: (Int64) -> Void

    static func == (lhs: TimelineListContent, rhs: TimelineListContent) -> Bool {
        lhs.sectionsRevision == rhs.sectionsRevision &&
        lhs.bootstrapPhase == rhs.bootstrapPhase &&
        lhs.isRefreshing == rhs.isRefreshing &&
        lhs.sourceContext == rhs.sourceContext
    }

    var body: some View {
        Group {
            if bootstrapPhase == .bootstrapping {
                TimelineBootstrapListPlaceholder()
                    .padding(.vertical, Spacing.cozy)
            } else if sections.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", message: "当日没有匹配事件")
                    .padding(.vertical, Spacing.double)
            } else {
                ZStack(alignment: .topTrailing) {
                    LazyVStack(spacing: Spacing.none, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            TimelineSectionView(
                                section: section,
                                isLast: section.id == sections.last?.id,
                                trailingPlaceholderWidth: TimelineFilterHostStyle.controlWidth,
                                sourceContext: sourceContext,
                                onOpenContentViewer: onOpenContentViewer,
                                onOpenBookDetail: onOpenBookDetail
                            )
                        }
                    }

                    if isRefreshing {
                        TimelineRefreshHint()
                            .padding(.top, Spacing.cozy)
                    }
                }
            }
        }
    }
}

/// 时间线首开列表壳层，使用静态版式占位稳定首屏节奏，不暴露加载中的中间状态。
private struct TimelineBootstrapListShell: View {
    var body: some View {
        TimelineBootstrapListPlaceholder()
            .overlay(alignment: .topTrailing) {
                TimelineCategoryFilterMenu(selectedCategory: .all, onCategorySelected: { _ in })
                    .disabled(true)
                    .padding(.top, Spacing.cozy)
            }
    }
}

/// 时间线首开列表静态占位，保留 section header 与卡片高度节奏，避免首屏塌缩。
private struct TimelineBootstrapListPlaceholder: View {
    private let sectionDates: [Date] = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return [today, yesterday]
    }()

    var body: some View {
        LazyVStack(spacing: Spacing.none, pinnedViews: [.sectionHeaders]) {
            ForEach(Array(sectionDates.enumerated()), id: \.offset) { index, date in
                TimelineBootstrapSection(date: date, cardCount: index == 0 ? 2 : 1)
            }
        }
    }
}

/// 时间线静态 section，占位阶段沿用真实 section header 结构，减少首开布局跳变。
private struct TimelineBootstrapSection: View {
    let date: Date
    let cardCount: Int

    var body: some View {
        Section {
            VStack(spacing: Spacing.none) {
                ForEach(0..<cardCount, id: \.self) { index in
                    TimelineBootstrapEventRow(isLast: index == cardCount - 1)
                }
            }
        } header: {
            TimelineSectionHeader(
                date: date,
                trailingPlaceholderWidth: TimelineFilterHostStyle.controlWidth
            )
        }
    }
}

/// 时间线静态单行占位，保持左侧连接线与右侧卡片体量稳定。
private struct TimelineBootstrapEventRow: View {
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            TimelineBootstrapConnector(isLastEvent: isLast)
                .stroke(
                    Color.textHint.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 5])
                )
                .frame(width: 18)
                .padding(.leading, 2)

            TimelineBootstrapCardPlaceholder()
        }
        .padding(.bottom, Spacing.base)
    }
}

/// 时间线占位连接线，复刻真实时间线左侧装饰列的高度节奏。
private struct TimelineBootstrapConnector: SwiftUI.Shape {
    let isLastEvent: Bool

    func path(in rect: CGRect) -> SwiftUI.Path {
        var path = SwiftUI.Path()
        let centerX = rect.midX
        let circleDiameter: CGFloat = 8
        let circleRect = CGRect(
            x: centerX - circleDiameter / 2,
            y: 10,
            width: circleDiameter,
            height: circleDiameter
        )
        path.addEllipse(in: circleRect)

        let lineStart = circleRect.maxY + 4
        let lineEnd = isLastEvent ? rect.minY + 30 : rect.maxY
        path.move(to: CGPoint(x: centerX, y: lineStart))
        path.addLine(to: CGPoint(x: centerX, y: max(lineStart, lineEnd)))
        return path
    }
}

/// 时间线静态卡片占位，仅保留排版骨架，不使用 shimmer 或全局 loading。
private struct TimelineBootstrapCardPlaceholder: View {
    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(spacing: Spacing.cozy) {
                    placeholderBar(width: 124, height: 12)
                    Spacer(minLength: 0)
                    placeholderBar(width: 52, height: 12)
                }

                placeholderBar(width: nil, height: 18)
                placeholderBar(width: nil, height: 18)
                placeholderBar(width: 168, height: 18)
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    private func placeholderBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(Color.textHint.opacity(0.12))
            .frame(width: width, height: height)
    }
}

/// 保留真实内容在位时，用极轻提示表达“列表正在刷新”，避免回退到整块 loading。
private struct TimelineRefreshHint: View {
    var body: some View {
        Text("正在更新")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.surfaceCard.opacity(0.92), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Cell

private struct TimelineCalendarDayCell: View {
    let dayNumber: Int
    let marker: TimelineDayMarker?
    let isSelected: Bool
    let dayNumberFont: Font

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Color.brand)
                    .frame(
                        width: TimelineCalendarStyle.selectedCircleSize,
                        height: TimelineCalendarStyle.selectedCircleSize
                    )
            } else if let marker {
                if marker.readingProgress > 0 {
                    ZStack {
                        Circle()
                            .stroke(
                                TimelineCalendarStyle.progressTrackColor,
                                lineWidth: TimelineCalendarStyle.progressRingLineWidth
                            )
                        Circle()
                            .trim(from: 0, to: CGFloat(marker.progressRatio))
                            .stroke(
                                Color.brand,
                                style: StrokeStyle(
                                    lineWidth: TimelineCalendarStyle.progressRingLineWidth,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(
                        width: TimelineCalendarStyle.progressRingSize,
                        height: TimelineCalendarStyle.progressRingSize
                    )
                } else if marker.isActive {
                    Circle()
                        .fill(Color.brand)
                        .frame(
                            width: TimelineCalendarStyle.markerDotSize,
                            height: TimelineCalendarStyle.markerDotSize
                        )
                        .offset(y: TimelineCalendarStyle.markerDotOffsetY)
                }
            }

            Text("\(dayNumber)")
                .font(dayNumberFont)
                .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
        }
        .frame(width: TimelineCalendarStyle.dayCellSize, height: TimelineCalendarStyle.dayCellSize)
    }
}

// MARK: - Calendar Dependency

private struct CalendarDependencyToken: Hashable {
    let selectedDate: Date
    let selectedCategory: TimelineEventCategory
    let markerRevision: Int
}

private struct TimelineMarkerPreloadRequest: Equatable {
    let months: [Date]
    let category: TimelineEventCategory
}

private struct TimelineRichTextPrewarmEntry: Equatable {
    let html: String
    let style: TimelineRichTextPrewarmStyle
}

private struct TimelineRichTextPrewarmRequest: Equatable {
    static let defaultMaxLines = 3

    let entries: [TimelineRichTextPrewarmEntry]
    let widthBucket: Int
    let displayScale: CGFloat
    let userInterfaceStyle: UIUserInterfaceStyle
    let preferredContentSizeCategory: UIContentSizeCategory
}

private enum TimelineRichTextPrewarmStyle: Int, Equatable {
    case primary
    case secondary

    var textColor: UIColor {
        switch self {
        case .primary:
            return .label
        case .secondary:
            return .secondaryLabel
        }
    }
}

/// 时间线筛选入口样式常量，约束占位宽度与胶囊最小宽度保持一致。
private enum TimelineFilterHostStyle {
    static let controlWidth: CGFloat = 76
}

/// 时间线分类筛选菜单，全页只创建一个实例并吸顶承载。
private struct TimelineCategoryFilterMenu: View {
    let selectedCategory: TimelineEventCategory
    let onCategorySelected: (TimelineEventCategory) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var chevronSymbolSize = 8

    var body: some View {
        Menu {
            ForEach(TimelineEventCategory.allCases) { category in
                Button {
                    onCategorySelected(category)
                } label: {
                    if category == selectedCategory {
                        Label(category.rawValue, systemImage: "checkmark")
                            .foregroundStyle(.primary)
                    } else {
                        Text(category.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(selectedCategory.rawValue)
                    .font(TimelineCalendarStyle.sectionFilterFont)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)

                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSymbolSize, weight: .bold))
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .frame(minWidth: TimelineFilterHostStyle.controlWidth)
            .contentShape(Rectangle())
        }
        .tint(nil)
        .buttonStyle(.plain)
    }
}

private extension ColorScheme {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark:
            return .dark
        default:
            return .light
        }
    }
}

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall:
            return .extraSmall
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .xLarge:
            return .extraLarge
        case .xxLarge:
            return .extraExtraLarge
        case .xxxLarge:
            return .extraExtraExtraLarge
        case .accessibility1:
            return .accessibilityMedium
        case .accessibility2:
            return .accessibilityLarge
        case .accessibility3:
            return .accessibilityExtraLarge
        case .accessibility4:
            return .accessibilityExtraExtraLarge
        case .accessibility5:
            return .accessibilityExtraExtraExtraLarge
        @unknown default:
            return .large
        }
    }
}

#Preview {
    NavigationStack {
        ReadingTimelineView()
            .environment(RepositoryContainer(databaseManager: try! DatabaseManager()))
    }
}
