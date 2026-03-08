/**
 * [INPUT]: 依赖 HorizonCalendar 的 CalendarViewRepresentable/CalendarViewProxy，依赖 TimelineEvent/TimelineSection 领域模型与时间线卡片组件
 * [OUTPUT]: 对外提供 ReadingTimelineView（首页时间线模块：日历与事件列表联动）
 * [POS]: Reading 模块正式时间线页面，承载月份切换、日期选择、分类过滤与按日时间线渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import HorizonCalendar
import SwiftUI

/// 首页在读模块的正式时间线页面。
struct ReadingTimelineView: View {
    @StateObject private var calendarProxy = CalendarViewProxy()
    @State private var selectedCategory: TimelineEventCategory = .all
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var displayedMonthStart: Date = Calendar.current.startOfDay(for: Date())
    @State private var markerCache: [String: [Date: TimelineDayMarkerMock]] = [:]
    @State private var markerRevision: Int = 0
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

    init() {
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
        _displayedMonthStart = State(initialValue: Self.monthStart(of: today, using: cal))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                calendarPanelCard
                categoryPicker
                timelineList
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .onAppear {
            preloadMarkers(around: displayedMonthStart)
            DispatchQueue.main.async {
                jumpToDate(calendar.startOfDay(for: Date()), animated: false)
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            markerCache.removeAll()
            markerRevision &+= 1
            preloadMarkers(around: displayedMonthStart)
        }
    }
}

// MARK: - UI

private extension ReadingTimelineView {
    var calendarPanelCard: some View {
        CardContainer {
            VStack(spacing: Spacing.base) {
                HStack(alignment: .lastTextBaseline, spacing: Spacing.base) {
                    Menu {
                        ForEach(availableMonthStarts.reversed(), id: \.self) { monthStart in
                            Button {
                                jumpToDate(monthStart, animated: true)
                            } label: {
                                if calendar.isDate(monthStart, equalTo: displayedMonthStart, toGranularity: .month) {
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

                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.readCalendarSubtleText)
                                .offset(y: 0.5)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
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
                            selectedDate: selectedDate,
                            selectedCategory: selectedCategory,
                            markerRevision: markerRevision
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
                        let isSelected = dayDate.map { calendar.isDate($0, inSameDayAs: selectedDate) } ?? false
                        let marker = dayDate.flatMap(markerForDate)
                        TimelineCalendarDayCell(
                            dayNumber: day.day,
                            marker: marker,
                            isSelected: isSelected,
                            dayNumberFont: TimelineCalendarStyle.dayNumberFont
                        )
                    }
                    .onDaySelection { day in
                        guard let date = date(for: day) else { return }
                        selectedDate = date
                        let monthStart = Self.monthStart(of: date, using: calendar)
                        applyDisplayedMonth(monthStart, animated: false)
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
                            for: displayedMonthStart,
                            availableWidth: proxy.size.width,
                            animated: false
                        )
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        updateCalendarHeight(
                            for: displayedMonthStart,
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

    var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.half) {
                ForEach(TimelineEventCategory.allCases) { category in
                    Button(category.rawValue) {
                        withAnimation(monthTransitionAnimation) {
                            selectedCategory = category
                        }
                    }
                    .font(TimelineCalendarStyle.categoryChipFont)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedCategory == category ? Color.brand : Color.bgSecondary)
                    .foregroundStyle(selectedCategory == category ? Color.white : Color.textPrimary)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    var timelineList: some View {
        let sections = TimelineCalendarMockData.sections(
            for: selectedDate,
            category: selectedCategory,
            calendar: calendar
        )

        return Group {
            if sections.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", message: "当日没有匹配事件")
                    .padding(.vertical, Spacing.double)
            } else {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        TimelineSectionView(
                            section: section,
                            isLast: index == sections.count - 1
                        )
                    }
                }
            }
        }
    }

    var displayedMonthTitleText: some View {
        let components = calendar.dateComponents([.year, .month], from: displayedMonthStart)
        let year = components.year ?? calendar.component(.year, from: displayedMonthStart)
        let month = components.month ?? calendar.component(.month, from: displayedMonthStart)
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(verbatim: String(year))
                .font(TimelineCalendarStyle.monthNumberFont)
                .foregroundStyle(TimelineCalendarStyle.monthNumberColor)
                .contentTransition(.numericText())
            Text(" 年 ")
                .font(TimelineCalendarStyle.monthUnitFont)
                .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
            Text(verbatim: String(month))
                .font(TimelineCalendarStyle.monthNumberFont)
                .foregroundStyle(TimelineCalendarStyle.monthNumberColor)
                .contentTransition(.numericText())
            Text(" 月")
                .font(TimelineCalendarStyle.monthUnitFont)
                .foregroundStyle(TimelineCalendarStyle.monthUnitColor)
        }
    }

    @ViewBuilder
    var selectedDateOffsetText: some View {
        let today = calendar.startOfDay(for: Date())
        let dayOffset = calendar.dateComponents([.day], from: selectedDate, to: today).day ?? 0
        if dayOffset == 0 {
            Text("今天")
                .font(TimelineCalendarStyle.relativeUnitFont)
                .foregroundStyle(TimelineCalendarStyle.relativeUnitColor)
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(verbatim: String(abs(dayOffset)))
                    .font(TimelineCalendarStyle.relativeNumberFont)
                    .foregroundStyle(TimelineCalendarStyle.relativeNumberColor)
                    .contentTransition(.numericText())
                Text(dayOffset > 0 ? "天前" : "天后")
                    .font(TimelineCalendarStyle.relativeUnitFont)
                    .foregroundStyle(TimelineCalendarStyle.relativeUnitColor)
            }
        }
    }
}

// MARK: - Data / Marker

private extension ReadingTimelineView {
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

    func markerForDate(_ date: Date) -> TimelineDayMarkerMock? {
        let monthKey = Self.monthKey(for: date, using: calendar)
        let normalized = calendar.startOfDay(for: date)
        return markerCache[monthKey]?[normalized]
    }

    func preloadMarkers(around monthStart: Date) {
        let anchor = Self.monthStart(of: monthStart, using: calendar)
        let offsets = [-1, 0, 1]
        var didUpdate = false

        for offset in offsets {
            guard let month = calendar.date(byAdding: .month, value: offset, to: anchor) else { continue }
            let normalizedMonth = Self.monthStart(of: month, using: calendar)
            let key = Self.monthKey(for: normalizedMonth, using: calendar)
            guard markerCache[key] == nil else { continue }
            markerCache[key] = TimelineCalendarMockData.markers(
                for: normalizedMonth,
                category: selectedCategory,
                calendar: calendar
            )
            didUpdate = true
        }

        if didUpdate {
            markerRevision &+= 1
        }
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

        preloadMarkers(around: fromMonthStart)
        preloadMarkers(around: toMonthStart)

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
        if !calendar.isDate(monthStart, equalTo: displayedMonthStart, toGranularity: .month) {
            displayedMonthStart = monthStart
            preloadMarkers(around: monthStart)
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
        let monthDistance = Self.monthDistance(from: displayedMonthStart, to: targetMonthStart, using: calendar)
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
            preloadMarkers(around: displayedMonthStart)
            preloadMarkers(around: targetMonthStart)
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
        let isMonthChanged = !calendar.isDate(monthStart, equalTo: displayedMonthStart, toGranularity: .month)

        if animated {
            withAnimation(monthTransitionAnimation) {
                selectedDate = selectedDay
                if isMonthChanged {
                    displayedMonthStart = monthStart
                }
            }
        } else {
            selectedDate = selectedDay
            if isMonthChanged {
                displayedMonthStart = monthStart
            }
        }

        if isMonthChanged {
            preloadMarkers(around: monthStart)
        }

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
    let marker: TimelineDayMarkerMock?
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

// MARK: - Mock Models

private struct CalendarDependencyToken: Hashable {
    let selectedDate: Date
    let selectedCategory: TimelineEventCategory
    let markerRevision: Int
}

private struct TimelineDayMarkerMock: Hashable {
    let isActive: Bool
    let readingProgress: Int

    var progressRatio: Double {
        let clamped = min(100, max(0, readingProgress))
        return Double(clamped) / 100.0
    }
}

private enum TimelineCalendarMockData {
    static func markers(
        for monthStart: Date,
        category: TimelineEventCategory,
        calendar: Calendar
    ) -> [Date: TimelineDayMarkerMock] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { return [:] }
        let categorySeed = categorySeedValue(for: category)
        var result: [Date: TimelineDayMarkerMock] = [:]

        for day in dayRange {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let normalized = calendar.startOfDay(for: date)
            let activeFlag = ((day + categorySeed) % 3 == 0) || ((day + categorySeed) % 5 == 0)
            guard activeFlag else { continue }

            let rawProgress = ((day * 11) + categorySeed * 17) % 118
            let progress = rawProgress >= 100 ? 100 : rawProgress
            let adjustedProgress = progress == 0 ? 0 : max(1, progress)
            result[normalized] = TimelineDayMarkerMock(isActive: true, readingProgress: adjustedProgress)
        }

        return result
    }

    static func sections(
        for date: Date,
        category: TimelineEventCategory,
        calendar: Calendar
    ) -> [TimelineSection] {
        let start = calendar.startOfDay(for: date)
        let daySeed = calendar.component(.day, from: start)
        if daySeed % 4 == 0 {
            return []
        }

        let baseTimestamp = Int64(start.timeIntervalSince1970 * 1000)
        let allEvents: [TimelineEvent] = [
            TimelineEvent(
                id: "note-\(daySeed)",
                kind: .note(TimelineNoteEvent(
                    content: "通过迭代验证，时间线日历交互已覆盖核心使用场景。",
                    idea: "先保证交互闭环，再逐步替换为真实数据源。",
                    bookTitle: "架构演进实践"
                )),
                timestamp: baseTimestamp + 36_000_000,
                bookName: "架构演进实践",
                bookAuthor: "工程组",
                bookCover: ""
            ),
            TimelineEvent(
                id: "timing-\(daySeed)",
                kind: .readTiming(TimelineReadTimingEvent(
                    elapsedSeconds: Int64(1800 + daySeed * 45),
                    startTime: baseTimestamp + 30_600_000,
                    endTime: baseTimestamp + 34_200_000,
                    fuzzyReadDate: 0
                )),
                timestamp: baseTimestamp + 30_600_000,
                bookName: "可维护 iOS 体系",
                bookAuthor: "Merpy",
                bookCover: ""
            ),
            TimelineEvent(
                id: "status-\(daySeed)",
                kind: .readStatus(TimelineReadStatusEvent(
                    statusId: Int64((daySeed % 5) + 1),
                    readDoneCount: Int64((daySeed % 3) + 1),
                    bookScore: 40
                )),
                timestamp: baseTimestamp + 27_000_000,
                bookName: "阅读方法论",
                bookAuthor: "产品组",
                bookCover: ""
            ),
            TimelineEvent(
                id: "checkin-\(daySeed)",
                kind: .checkIn(TimelineCheckInEvent(amount: Int64((daySeed % 4) + 1))),
                timestamp: baseTimestamp + 64_800_000,
                bookName: "目标管理",
                bookAuthor: "研发团队",
                bookCover: ""
            ),
            TimelineEvent(
                id: "review-\(daySeed)",
                kind: .review(TimelineReviewEvent(
                    title: "本次阅读复盘",
                    content: "日期选择、月份切换与筛选联动均可用，后续可平滑切到真实数据。",
                    bookScore: 45
                )),
                timestamp: baseTimestamp + 57_600_000,
                bookName: "团队复盘",
                bookAuthor: "团队",
                bookCover: ""
            ),
            TimelineEvent(
                id: "relevant-\(daySeed)",
                kind: .relevant(TimelineRelevantEvent(
                    title: "API 对照",
                    content: "onDaySelection / onDragEnd / scrollToMonth",
                    url: "https://github.com/airbnb/HorizonCalendar",
                    categoryTitle: "技术对齐"
                )),
                timestamp: baseTimestamp + 54_000_000,
                bookName: "技术选型",
                bookAuthor: "平台组",
                bookCover: ""
            ),
            TimelineEvent(
                id: "relevant-book-\(daySeed)",
                kind: .relevantBook(TimelineRelevantBookEvent(
                    contentBookName: "iOS 架构实践",
                    contentBookAuthor: "某作者",
                    contentBookCover: "",
                    categoryTitle: "延伸阅读"
                )),
                timestamp: baseTimestamp + 50_400_000,
                bookName: "技术选型",
                bookAuthor: "平台组",
                bookCover: ""
            ),
        ]

        let filtered = allEvents.filter { event in
            switch (category, event.kind) {
            case (.all, _): true
            case (.note, .note): true
            case (.readTiming, .readTiming): true
            case (.readStatus, .readStatus): true
            case (.checkIn, .checkIn): true
            case (.review, .review): true
            case (.relevant, .relevant), (.relevant, .relevantBook): true
            default: false
            }
        }
        .sorted(by: { $0.timestamp > $1.timestamp })

        guard !filtered.isEmpty else { return [] }
        return [TimelineSection(id: Self.dayID(start, calendar: calendar), date: start, events: filtered)]
    }

    private static func categorySeedValue(for category: TimelineEventCategory) -> Int {
        switch category {
        case .all: 1
        case .note: 2
        case .readStatus: 3
        case .relevant: 4
        case .review: 5
        case .readTiming: 6
        case .checkIn: 7
        }
    }

    private static func dayID(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

#Preview {
    NavigationStack {
        ReadingTimelineView()
    }
}
