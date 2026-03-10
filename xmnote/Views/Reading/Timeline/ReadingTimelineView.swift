/**
 * [INPUT]: 依赖 HorizonCalendar 的 CalendarViewRepresentable/CalendarViewProxy，依赖 TimelineViewModel 提供事件与日历标记数据
 * [OUTPUT]: 对外提供 ReadingTimelineView（首页时间线模块：日历与事件列表联动）
 * [POS]: Reading 模块正式时间线页面，承载月份切换、日期选择、分类过滤与按日时间线渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import HorizonCalendar
import SwiftUI

/// 首页在读模块的正式时间线页面（外壳）。
/// 通过 .task 延迟创建 ViewModel，确保 @Environment 中的 RepositoryContainer 可用。
struct ReadingTimelineView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: TimelineViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ReadingTimelineContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .task {
            guard viewModel == nil else { return }
            let vm = TimelineViewModel(repository: repositories.timelineRepository)
            viewModel = vm
            await vm.loadInitialData()
        }
    }
}

// MARK: - Content View

/// 时间线页面内容视图，持有 ViewModel 并管理日历物理状态。
private struct ReadingTimelineContentView: View {
    @Bindable var viewModel: TimelineViewModel
    @StateObject private var calendarProxy = CalendarViewProxy()
    @State private var calendarHeight: CGFloat = 320
    @State private var calendarViewportWidth: CGFloat = 0
    @State private var isUserPagingInFlight: Bool = false
    @State private var isProgrammaticLongJump: Bool = false

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
        ScrollView {
            VStack(spacing: Spacing.base) {
                calendarPanelCard
                timelineList
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.base)
        }
        .coordinateSpace(name: Self.timelineScrollCoordinateSpaceName)
        .onAppear {
            DispatchQueue.main.async {
                jumpToDate(calendar.startOfDay(for: Date()), animated: false)
            }
        }
    }
}

// MARK: - UI

private extension ReadingTimelineContentView {
    var calendarPanelCard: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.panelCornerRadius) {
            VStack(spacing: Spacing.base) {
                HStack(alignment: .lastTextBaseline, spacing: Spacing.base) {
                    Menu {
                        ForEach(availableMonthStarts.reversed(), id: \.self) { monthStart in
                            Button {
                                jumpToDate(monthStart, animated: true)
                            } label: {
                                if calendar.isDate(monthStart, equalTo: viewModel.displayedMonthStart, toGranularity: .month) {
                                    Label(monthFormatter.string(from: monthStart), systemImage: "checkmark")
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
                    .buttonStyle(.plain)

                    Spacer()

                    selectedDateOffsetText
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

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
                        applyDisplayedMonth(monthStart, animated: false)
                        Task { await viewModel.selectDate(date) }
                    }
                    .onHorizontalMonthPagingProgress { progressContext in
                        handleMonthPagingProgress(progressContext)
                    }
                    .onScroll { _, isUserDragging in
                        if isUserDragging {
                            isUserPagingInFlight = true
                        }
                    }
                    .onDragEnd { visibleRange, willDecelerate in
                        guard !willDecelerate else { return }
                        isUserPagingInFlight = false
                        settleMonthAfterPaging(visibleRange)
                    }
                    .onDeceleratingEnd { visibleRange in
                        isUserPagingInFlight = false
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
    }

    var timelineList: some View {
        TimelineListContainer(
            sections: viewModel.sections,
            isLoading: viewModel.isLoading,
            selectedCategory: viewModel.selectedCategory,
            onCategorySelected: { category in
                Task { await viewModel.selectCategory(category) }
            }
        )
    }

    var displayedMonthTitleText: some View {
        let components = calendar.dateComponents([.year, .month], from: viewModel.displayedMonthStart)
        let year = components.year ?? calendar.component(.year, from: viewModel.displayedMonthStart)
        let month = components.month ?? calendar.component(.month, from: viewModel.displayedMonthStart)
        let yearText = Text(verbatim: String(year))
            .font(TimelineCalendarStyle.monthNumberFont)
            .foregroundStyle(TimelineCalendarStyle.monthNumberColor)
        let yearUnit = Text(" 年 ")
            .font(TimelineCalendarStyle.monthUnitFont)
            .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
        let monthText = Text(verbatim: String(month))
            .font(TimelineCalendarStyle.monthNumberFont)
            .foregroundStyle(TimelineCalendarStyle.monthNumberColor)
        let monthUnit = Text(" 月")
            .font(TimelineCalendarStyle.monthUnitFont)
            .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
        return Text("\(yearText)\(yearUnit)\(monthText)\(monthUnit)")
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.24), value: viewModel.displayedMonthStart)
    }

    var selectedDateOffsetText: some View {
        let today = calendar.startOfDay(for: Date())
        let dayOffset = calendar.dateComponents([.day], from: viewModel.selectedDate, to: today).day ?? 0
        return HStack(alignment: .lastTextBaseline, spacing: Spacing.none) {
            Text(verbatim: dayOffset == 0 ? "" : String(abs(dayOffset)))
                .font(TimelineCalendarStyle.relativeNumberFont)
                .foregroundStyle(TimelineCalendarStyle.relativeNumberColor)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(dayOffset == 0 ? "今天" : (dayOffset > 0 ? "天前" : "天后"))
                .font(TimelineCalendarStyle.relativeUnitFont)
                .foregroundStyle(TimelineCalendarStyle.relativeUnitColor)
                .contentTransition(.numericText())
        }
        .animation(.snappy(duration: 0.24), value: dayOffset)
    }
}

private struct TimelineListContainer: View {
    let sections: [TimelineSection]
    let isLoading: Bool
    let selectedCategory: TimelineEventCategory
    let onCategorySelected: (TimelineEventCategory) -> Void

    @State private var timelineListMinY: CGFloat = .zero

    var body: some View {
        TimelineListContent(
            sections: sections,
            isLoading: isLoading
        )
        .overlay(alignment: .topTrailing) {
            TimelineCategoryFilterMenu(
                selectedCategory: selectedCategory,
                onCategorySelected: onCategorySelected
            )
            .disabled(isLoading)
            .padding(.top, Spacing.cozy)
            .offset(y: max(0, -timelineListMinY))
            .zIndex(1)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .named(ReadingTimelineContentView.timelineScrollCoordinateSpaceName)).minY
        } action: { minY in
            guard abs(minY - timelineListMinY) > 0.5 else { return }
            timelineListMinY = minY
        }
    }
}

private struct TimelineListContent: View {
    let sections: [TimelineSection]
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .padding(.vertical, Spacing.double)
            } else if sections.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", message: "当日没有匹配事件")
                    .padding(.vertical, Spacing.double)
            } else {
                LazyVStack(spacing: Spacing.none, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        TimelineSectionView(
                            section: section,
                            isLast: index == sections.count - 1,
                            trailingPlaceholderWidth: TimelineFilterHostStyle.controlWidth
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Data / Marker

private extension ReadingTimelineContentView {
    static var timelineScrollCoordinateSpaceName: String {
        "reading-timeline-scroll-space"
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

    func settleMonthAfterPaging(_ visibleRange: DayComponentsRange) {
        guard let firstVisibleDate = date(for: visibleRange.lowerBound) else { return }
        let monthStart = Self.monthStart(of: firstVisibleDate, using: calendar)
        applyDisplayedMonth(monthStart, animated: false)
    }

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

        Task {
            await viewModel.preloadMarkers(around: fromMonthStart)
            await viewModel.preloadMarkers(around: toMonthStart)
        }

        let fromHeight = monthContentHeight(for: fromMonthStart, availableWidth: calendarViewportWidth)
        let toHeight = monthContentHeight(for: toMonthStart, availableWidth: calendarViewportWidth)
        guard fromHeight > 0, toHeight > 0 else { return }

        let progress = min(1, max(0, context.progress))
        let interpolatedHeight = fromHeight + (toHeight - fromHeight) * progress
        guard interpolatedHeight > 0 else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            calendarHeight = interpolatedHeight
        }
    }

    func applyDisplayedMonth(_ monthStart: Date, animated: Bool) {
        if !calendar.isDate(monthStart, equalTo: viewModel.displayedMonthStart, toGranularity: .month) {
            viewModel.displayedMonthStart = monthStart
            Task { await viewModel.preloadMarkers(around: monthStart) }
        }
        updateCalendarHeight(
            for: monthStart,
            availableWidth: calendarViewportWidth,
            animated: animated
        )
    }

    func jumpToDate(_ date: Date, animated: Bool) {
        let normalized = calendar.startOfDay(for: date)
        let clamped = min(max(normalized, visibleDateRange.lowerBound), visibleDateRange.upperBound)
        let targetMonthStart = Self.monthStart(of: clamped, using: calendar)
        let monthDistance = Self.monthDistance(from: viewModel.displayedMonthStart, to: targetMonthStart, using: calendar)
        let shouldUseLongJump = animated && abs(monthDistance) > longJumpMonthThreshold

        if shouldUseLongJump {
            isProgrammaticLongJump = true
            isUserPagingInFlight = false
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
            Task {
                await viewModel.preloadMarkers(around: viewModel.displayedMonthStart)
                await viewModel.preloadMarkers(around: targetMonthStart)
            }
            isUserPagingInFlight = true
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

    func commitHeaderState(selectedDay: Date, monthStart: Date, animated: Bool) {
        let isMonthChanged = !calendar.isDate(monthStart, equalTo: viewModel.displayedMonthStart, toGranularity: .month)

        if isMonthChanged {
            viewModel.displayedMonthStart = monthStart
        }

        if animated {
            withAnimation(monthTransitionAnimation) {
                viewModel.selectedDate = selectedDay
            }
        } else {
            viewModel.selectedDate = selectedDay
        }

        if isMonthChanged {
            Task { await viewModel.preloadMarkers(around: monthStart) }
        }

        // 日期变化后异步拉取事件
        Task { await viewModel.loadEvents() }

        updateCalendarHeight(
            for: monthStart,
            availableWidth: calendarViewportWidth,
            animated: animated
        )
    }

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

    func date(for day: DayComponents) -> Date? {
        guard let date = calendar.date(from: day.components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    func monthStart(for month: MonthComponents) -> Date? {
        let components = DateComponents(era: month.era, year: month.year, month: month.month, day: 1)
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    func weekdaySymbol(for index: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }

    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }

    static func monthKey(for date: Date, using calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: monthStart(of: date, using: calendar))
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    static func monthDistance(from: Date, to: Date, using calendar: Calendar) -> Int {
        let fromMonth = monthStart(of: from, using: calendar)
        let toMonth = monthStart(of: to, using: calendar)
        return calendar.dateComponents([.month], from: fromMonth, to: toMonth).month ?? 0
    }

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

/// 时间线筛选入口样式常量，约束占位宽度与胶囊最小宽度保持一致。
private enum TimelineFilterHostStyle {
    static let controlWidth: CGFloat = 76
}

/// 时间线分类筛选菜单，全页只创建一个实例并吸顶承载。
private struct TimelineCategoryFilterMenu: View {
    let selectedCategory: TimelineEventCategory
    let onCategorySelected: (TimelineEventCategory) -> Void

    var body: some View {
        Menu {
            ForEach(TimelineEventCategory.allCases) { category in
                Button {
                    onCategorySelected(category)
                } label: {
                    if category == selectedCategory {
                        Label(category.rawValue, systemImage: "checkmark")
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
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .frame(minWidth: TimelineFilterHostStyle.controlWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        ReadingTimelineView()
            .environment(RepositoryContainer(databaseManager: try! DatabaseManager()))
    }
}
