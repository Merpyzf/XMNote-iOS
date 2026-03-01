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
        let selectedDate: Date
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
                isToday: cal.isDate(normalized, inSameDayAs: todayStart),
                isSelected: cal.isDate(normalized, inSameDayAs: selectedDate),
                isFuture: normalized > todayStart
            )
        }
    }

    struct Props: Hashable {
        let monthTitle: String
        let availableMonths: [Date]
        let pagerSelection: Date
        let displayMode: DisplayMode
        let laneLimit: Int
        let rootContentState: RootContentState
        let errorMessage: String?
        let monthPages: [MonthPage]
    }

    private enum Layout {
        static let topControlTopPadding: CGFloat = 10
        static let topControlBottomPadding: CGFloat = 14
        static let topControlSpacing: CGFloat = Spacing.cozy
        static let modeSwitcherWidth: CGFloat = 116
        static let weekdayHeaderHeight: CGFloat = 32
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerTopPadding: CGFloat = Spacing.cozy
        static let calendarInnerBottomPadding: CGFloat = 10
        static let headerToGridSpacing: CGFloat = Spacing.half
        static let gridTopInset: CGFloat = 2
    }

    let props: Props
    let onDisplayModeChanged: (DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onSelectDate: (Date) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topControlRow
                .padding(.top, Layout.topControlTopPadding)
                .padding(.bottom, Layout.topControlBottomPadding)

            integratedCalendarContainer

            if let errorMessage = props.errorMessage,
               props.rootContentState == .content {
                inlineError(errorMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: props.errorMessage)
    }
}

// MARK: - Subviews

private extension ReadCalendarPanel {
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

    var topControlRow: some View {
        HStack(alignment: .center, spacing: Layout.topControlSpacing) {
            monthSwitcher
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            modeSwitcher
                .frame(width: Layout.modeSwitcherWidth)
        }
        .padding(.horizontal, Spacing.screenEdge)
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
            isShimmerEnabled: props.displayMode == .activityEvent,
            dayPayloadProvider: { date in
                page.payload(for: date)
            },
            onSelectDay: { date in
                withAnimation(.smooth(duration: 0.22)) {
                    onSelectDate(date)
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
            selectedDate: props.pagerSelection,
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
    ReadCalendarPanel(
        props: .init(
            monthTitle: "2026年2月",
            availableMonths: [Calendar.current.startOfDay(for: Date())],
            pagerSelection: Calendar.current.startOfDay(for: Date()),
            displayMode: .activityEvent,
            laneLimit: 4,
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
