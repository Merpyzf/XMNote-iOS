import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入统计仓储，依赖 ReadCalendarViewModel 提供月历状态与事件条布局
 * [OUTPUT]: 对外提供 ReadCalendarView（阅读日历页面，支持分页滑动切月与跨周连续事件条）
 * [POS]: Reading 模块核心页面，承接热力图与个人页“阅读日历”入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarView: View {
    private enum Layout {
        static let weekdayHeaderHeight: CGFloat = 32
        static let dayHeaderHeight: CGFloat = 24
        static let laneTopInset: CGFloat = 5
        static let laneBottomInset: CGFloat = 6
        static let laneBarHeight: CGFloat = 14
        static let laneSpacing: CGFloat = 3
        static let segmentHorizontalInset: CGFloat = 2
        static let switcherTopPadding: CGFloat = 6
        static let switcherBottomPadding: CGFloat = 10
        static let contentSpacing: CGFloat = 10
        static let pageMinHeight: CGFloat = 240
        static let calendarCornerRadius: CGFloat = 14
        static let calendarInnerHorizontalPadding: CGFloat = 8
        static let calendarInnerTopPadding: CGFloat = 6
        static let calendarInnerBottomPadding: CGFloat = 8
    }

    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: ReadCalendarViewModel
    @State private var pagerSelectionTask: Task<Void, Never>?

    init(date: Date?) {
        _viewModel = State(initialValue: ReadCalendarViewModel(initialDate: date))
    }

    var body: some View {
        ZStack {
            Color.windowBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                monthSwitcher
                    .padding(.top, Layout.switcherTopPadding)
                    .padding(.bottom, Layout.switcherBottomPadding)

                integratedCalendarContainer

                if let errorMessage = viewModel.errorMessage,
                   viewModel.rootContentState == .content {
                    inlineError(errorMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.base)
            .animation(.smooth(duration: 0.3), value: viewModel.rootContentState)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: viewModel.errorMessage)
        }
        .navigationTitle("阅读日历")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadIfNeeded(using: repositories.statisticsRepository)
        }
        .onChange(of: viewModel.pagerSelection) { _, monthStart in
            pagerSelectionTask?.cancel()
            pagerSelectionTask = Task {
                await viewModel.handlePagerSelectionChange(
                    to: monthStart,
                    using: repositories.statisticsRepository
                )
            }
        }
        .onDisappear {
            pagerSelectionTask?.cancel()
            pagerSelectionTask = nil
        }
    }
}

// MARK: - Subviews

private extension ReadCalendarView {
    var integratedCalendarContainer: some View {
        VStack(spacing: 0) {
            weekdayHeader
                .padding(.horizontal, Layout.calendarInnerHorizontalPadding)
                .padding(.top, Layout.calendarInnerTopPadding)
            Color.divider
                .frame(height: 0.5)
                .padding(.horizontal, Layout.calendarInnerHorizontalPadding)
            contentContainer
                .padding(.horizontal, Layout.calendarInnerHorizontalPadding)
                .padding(.bottom, Layout.calendarInnerBottomPadding)
        }
        .background(Color.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: Layout.calendarCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Layout.calendarCornerRadius, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        }
    }

    var contentContainer: some View {
        ZStack(alignment: .top) {
            switch viewModel.rootContentState {
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
        .frame(maxWidth: .infinity, alignment: .top)
    }

    var monthSwitcher: some View {
        CalendarMonthStepperBar(
            title: viewModel.monthTitle,
            canGoPrev: viewModel.canGoPrevMonth,
            canGoNext: viewModel.canGoNextMonth,
            onPrev: {
                withAnimation(.snappy(duration: 0.3)) {
                    viewModel.stepPager(offset: -1)
                }
            },
            onNext: {
                withAnimation(.snappy(duration: 0.3)) {
                    viewModel.stepPager(offset: 1)
                }
            }
        )
    }

    var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                Text(weekday)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.weekdayHeaderHeight)
            }
        }
    }

    var calendarPager: some View {
        TabView(selection: $viewModel.pagerSelection) {
            ForEach(viewModel.availableMonths, id: \.self) { monthStart in
                monthPage(for: monthStart)
                    .tag(monthStart)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .contentMargins(.top, 0, for: .scrollContent)
        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .top)
        .animation(.snappy(duration: 0.32), value: viewModel.pagerSelection)
    }

    func monthPage(for monthStart: Date) -> some View {
        let pageState = viewModel.monthState(for: monthStart)
        return ZStack(alignment: .top) {
            if pageState.isLoading && pageState.dayMap.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                    .transition(.opacity)
            } else {
                calendarWeeks(for: monthStart, weeks: pageState.weeks)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.24), value: pageState.loadState)
    }

    func calendarWeeks(for monthStart: Date, weeks: [ReadCalendarViewModel.WeekRowData]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                if index > 0 {
                    Color.divider.frame(height: 0.5)
                }
                ReadCalendarWeekRowView(
                    week: week,
                    laneLimit: viewModel.laneLimit,
                    dayHeaderHeight: Layout.dayHeaderHeight,
                    laneTopInset: Layout.laneTopInset,
                    laneBottomInset: Layout.laneBottomInset,
                    laneBarHeight: Layout.laneBarHeight,
                    laneSpacing: Layout.laneSpacing,
                    segmentHorizontalInset: Layout.segmentHorizontalInset,
                    dayPayloadProvider: { date in
                        viewModel.dayPayload(for: date, in: monthStart)
                    },
                    overflowCountProvider: { date in
                        viewModel.overflowCount(for: date, in: monthStart)
                    },
                    isToday: { date in
                        viewModel.isToday(date)
                    },
                    isSelected: { date in
                        viewModel.isSelected(date)
                    },
                    isFuture: { date in
                        viewModel.isFutureDate(date)
                    },
                    onSelectDay: { date in
                        viewModel.selectDate(date)
                    }
                )
            }
        }
    }

    var emptyState: some View {
        CardContainer {
            VStack(spacing: Spacing.base) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.brand.opacity(0.8))

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(Color.feedbackWarning)
                        .multilineTextAlignment(.center)

                    Button("重试") {
                        Task { await viewModel.reload(using: repositories.statisticsRepository) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brand)
                } else {
                    Text("暂无可展示的阅读月份")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(.horizontal, Spacing.double)
        }
    }

    func inlineError(_ message: String) -> some View {
        HStack(spacing: Spacing.base) {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.feedbackWarning)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("重试") {
                Task { await viewModel.retryDisplayedMonth(using: repositories.statisticsRepository) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.brand)
        }
    }
}

private struct ReadCalendarWeekRowView: View {
    let week: ReadCalendarViewModel.WeekRowData
    let laneLimit: Int
    let dayHeaderHeight: CGFloat
    let laneTopInset: CGFloat
    let laneBottomInset: CGFloat
    let laneBarHeight: CGFloat
    let laneSpacing: CGFloat
    let segmentHorizontalInset: CGFloat
    let dayPayloadProvider: (Date) -> ReadCalendarDay?
    let overflowCountProvider: (Date) -> Int
    let isToday: (Date) -> Bool
    let isSelected: (Date) -> Bool
    let isFuture: (Date) -> Bool
    let onSelectDay: (Date?) -> Void

    private var rowHeight: CGFloat {
        dayHeaderHeight
            + laneTopInset
            + laneBottomInset
            + CGFloat(laneLimit) * laneBarHeight
            + CGFloat(max(0, laneLimit - 1)) * laneSpacing
    }

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let cellWidth = totalWidth / 7

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                            .frame(width: cellWidth, height: rowHeight)
                    }
                }

                ForEach(week.segments) { segment in
                    segmentView(segment, cellWidth: cellWidth)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func dayCell(_ day: Date?) -> some View {
        let hasDate = day != nil
        let date = day ?? Date.distantPast
        let future = hasDate ? isFuture(date) : false
        let payload = hasDate ? dayPayloadProvider(date) : nil
        let overflowCount = hasDate ? overflowCountProvider(date) : 0
        let readDone = payload?.isReadDoneDay == true

        return ZStack(alignment: .topLeading) {
            Color.contentBackground

            if let day {
                let today = isToday(day)
                let selected = isSelected(day)
                let dayNum = Calendar.current.component(.day, from: day)

                VStack(spacing: 1) {
                    HStack(spacing: 2) {
                        ZStack {
                            if selected {
                                Circle()
                                    .fill(Color.brand)
                                    .frame(width: 22, height: 22)
                            }
                            Text("\(dayNum)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    selected ? .white :
                                    future ? Color.textHint : Color.textPrimary
                                )
                        }

                        if readDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color(red: 1, green: 0xB6/255, blue: 0))
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: dayHeaderHeight, alignment: .center)

                    if today && !selected {
                        Circle()
                            .fill(Color.brand)
                            .frame(width: 4, height: 4)
                            .offset(y: -2)
                    }

                    Spacer(minLength: 0)

                    if overflowCount > 0 {
                        Text("+\(overflowCount)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.textHint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let day, !future else { return }
            onSelectDay(day)
        }
        .opacity(future ? 0.55 : 1)
    }

    private func segmentView(_ segment: ReadCalendarEventSegment, cellWidth: CGFloat) -> some View {
        let startOffset = dayOffset(for: segment.segmentStartDate, weekStart: segment.weekStart)
        let endOffset = dayOffset(for: segment.segmentEndDate, weekStart: segment.weekStart)
        let segmentWidth = CGFloat(endOffset - startOffset + 1) * cellWidth - segmentHorizontalInset * 2
        let x = CGFloat(startOffset) * cellWidth + segmentHorizontalInset
        let y = dayHeaderHeight + laneTopInset + CGFloat(segment.laneIndex) * (laneBarHeight + laneSpacing)

        let fillColor = color(for: segment.bookId)
        let showText = segmentWidth >= 42

        let leftRadius: CGFloat = segment.continuesFromPrevWeek ? 0 : 4
        let rightRadius: CGFloat = segment.continuesToNextWeek ? 0 : 4

        return ZStack(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: leftRadius,
                bottomLeadingRadius: leftRadius,
                bottomTrailingRadius: rightRadius,
                topTrailingRadius: rightRadius
            )
            .fill(fillColor.opacity(0.84))

            if showText {
                Text(segment.bookName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: max(0, segmentWidth), height: laneBarHeight)
        .offset(x: x, y: y)
    }

    private func dayOffset(for date: Date, weekStart: Date) -> Int {
        let start = Calendar.current.startOfDay(for: weekStart)
        let target = Calendar.current.startOfDay(for: date)
        let offset = Calendar.current.dateComponents([.day], from: start, to: target).day ?? 0
        return min(6, max(0, offset))
    }

    private static let palette: [Color] = [
        Color(red: 0x5B/255, green: 0x9B/255, blue: 0xD5/255),
        Color(red: 0xF4/255, green: 0xA2/255, blue: 0x61/255),
        Color(red: 0x7E/255, green: 0xC8/255, blue: 0xA0/255),
        Color(red: 0xE0/255, green: 0x7A/255, blue: 0x7A/255),
        Color(red: 0x9B/255, green: 0x8E/255, blue: 0xC5/255),
        Color(red: 0xD4/255, green: 0xA5/255, blue: 0x74/255),
        Color(red: 0x6B/255, green: 0xBF/255, blue: 0xCF/255),
        Color(red: 0xC9/255, green: 0xA0/255, blue: 0xDC/255),
    ]

    private func color(for bookId: Int64) -> Color {
        Self.palette[abs(Int(bookId)) % Self.palette.count]
    }
}

#Preview {
    NavigationStack {
        ReadCalendarView(date: Date())
            .environment(RepositoryContainer(databaseManager: try! DatabaseManager()))
    }
}
