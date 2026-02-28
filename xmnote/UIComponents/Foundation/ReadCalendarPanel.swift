/**
 * [INPUT]: 依赖 CalendarMonthStepperBar/ReadCalendarMonthGrid/CardContainer 复用组件与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供 ReadCalendarPanel（完整阅读日历控件：月份切换 + weekday + 分页月网格 + 状态反馈）
 * [POS]: UIComponents/Foundation 的阅读日历完整控件，供业务页面以纯展示驱动方式复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct ReadCalendarPanel: View {
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

    struct DayPayload: Hashable {
        let isReadDoneDay: Bool
        let overflowCount: Int
        let isToday: Bool
        let isSelected: Bool
        let isFuture: Bool

        func asGridPayload() -> ReadCalendarMonthGrid.DayPayload {
            ReadCalendarMonthGrid.DayPayload(
                isReadDoneDay: isReadDoneDay,
                overflowCount: overflowCount,
                isToday: isToday,
                isSelected: isSelected,
                isFuture: isFuture
            )
        }
    }

    struct MonthPage: Identifiable, Hashable {
        let monthStart: Date
        let weeks: [ReadCalendarMonthGrid.WeekData]
        let dayPayloads: [Date: DayPayload]
        let isDayMapEmpty: Bool
        let loadState: MonthLoadState
        let errorMessage: String?

        var id: Date { monthStart }

        var isLoading: Bool {
            loadState == .loading
        }

        func payload(for date: Date) -> ReadCalendarMonthGrid.DayPayload {
            let normalized = Calendar.current.startOfDay(for: date)
            if let payload = dayPayloads[normalized] {
                return payload.asGridPayload()
            }

            let isFuture = normalized > Calendar.current.startOfDay(for: Date())
            return ReadCalendarMonthGrid.DayPayload(
                isReadDoneDay: false,
                overflowCount: 0,
                isToday: false,
                isSelected: false,
                isFuture: isFuture
            )
        }
    }

    struct Props: Hashable {
        let monthTitle: String
        let availableMonths: [Date]
        let pagerSelection: Date
        let laneLimit: Int
        let rootContentState: RootContentState
        let errorMessage: String?
        let monthPages: [MonthPage]
        let canGoPrevMonth: Bool
        let canGoNextMonth: Bool
    }

    private enum Layout {
        static let weekdayHeaderHeight: CGFloat = 34
        static let switcherTopPadding: CGFloat = 8
        static let switcherBottomPadding: CGFloat = 12
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerHorizontalPadding: CGFloat = 12
        static let calendarInnerTopPadding: CGFloat = 10
        static let calendarInnerBottomPadding: CGFloat = 12
        static let headerToGridSpacing: CGFloat = 7
        static let gridTopInset: CGFloat = 3
    }

    let props: Props
    let onStepMonth: (Int) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onSelectDate: (Date) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            monthSwitcher
                .padding(.top, Layout.switcherTopPadding)
                .padding(.bottom, Layout.switcherBottomPadding)

            integratedCalendarContainer

            if let errorMessage = props.errorMessage,
               props.rootContentState == .content {
                inlineError(errorMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: props.rootContentState)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: props.errorMessage)
    }
}

// MARK: - Subviews

private extension ReadCalendarPanel {
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
        .padding(.horizontal, Layout.calendarInnerHorizontalPadding)
        .padding(.top, Layout.calendarInnerTopPadding)
        .padding(.bottom, Layout.calendarInnerBottomPadding)
        .background(Color.readCalendarCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.calendarCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.calendarCard, style: .continuous)
                .stroke(Color.readCalendarCardStroke.opacity(0.72), lineWidth: CardStyle.borderWidth)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 7)
        .shadow(color: Color.black.opacity(0.025), radius: 3, x: 0, y: 1)
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
        .clipped()
    }

    var monthSwitcher: some View {
        CalendarMonthStepperBar(
            title: props.monthTitle,
            canGoPrev: props.canGoPrevMonth,
            canGoNext: props.canGoNextMonth,
            onPrev: {
                withAnimation(.snappy(duration: 0.3)) {
                    onStepMonth(-1)
                }
            },
            onNext: {
                withAnimation(.snappy(duration: 0.3)) {
                    onStepMonth(1)
                }
            }
        )
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
        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .top)
        .animation(.snappy(duration: 0.32), value: props.pagerSelection)
    }

    func monthPage(for monthStart: Date) -> some View {
        let pageState = monthPageState(for: monthStart)

        return ZStack(alignment: .top) {
            if pageState.isLoading && pageState.isDayMapEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                    .transition(.opacity)
            } else {
                calendarWeeks(for: pageState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.24), value: pageState.loadState)
    }

    func calendarWeeks(for page: MonthPage) -> some View {
        ReadCalendarMonthGrid(
            weeks: page.weeks,
            laneLimit: props.laneLimit,
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
        CardContainer {
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

            Button("重试", action: onRetry)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brand)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Color.readCalendarSelectionFill.opacity(0.62))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
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
            dayPayloads: [:],
            isDayMapEmpty: true,
            loadState: .idle,
            errorMessage: nil
        )
    }
}

#Preview {
    ReadCalendarPanel(
        props: .init(
            monthTitle: "2026年2月",
            availableMonths: [Calendar.current.startOfDay(for: Date())],
            pagerSelection: Calendar.current.startOfDay(for: Date()),
            laneLimit: 4,
            rootContentState: .loading,
            errorMessage: nil,
            monthPages: [],
            canGoPrevMonth: true,
            canGoNextMonth: false
        ),
        onStepMonth: { _ in },
        onPagerSelectionChanged: { _ in },
        onSelectDate: { _ in },
        onRetry: {}
    )
    .padding(.horizontal, Spacing.screenEdge)
    .padding(.bottom, Spacing.base)
    .background(Color.windowBackground)
}
