import SwiftUI

/**
 * [INPUT]: 依赖月份与显示模式状态，依赖回调驱动页面壳层进行状态更新
 * [OUTPUT]: 对外提供 ReadCalendarTopControlBar（阅读日历顶部控制区）
 * [POS]: ReadCalendar 业务内复用组件，承载月份切换、月总结入口与显示模式切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarTopControlBar: View {
    private enum Layout {
        static let topControlSpacing: CGFloat = Spacing.cozy
        static let modeSwitcherWidth: CGFloat = 116
    }

    let monthTitle: String
    let availableMonths: [Date]
    let pagerSelection: Date
    let displayMode: ReadCalendarContentView.DisplayMode
    let rootContentState: ReadCalendarContentView.RootContentState
    let onDisplayModeChanged: (ReadCalendarContentView.DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onOpenSummary: () -> Void

    var body: some View {
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
}

private extension ReadCalendarTopControlBar {
    var monthSwitcher: some View {
        CalendarMonthStepperBar(
            title: monthTitle,
            availableMonths: availableMonths,
            selectedMonth: pagerSelection,
            onSelectMonth: { monthStart in
                withAnimation(.snappy(duration: 0.3)) {
                    onPagerSelectionChanged(monthStart)
                }
            }
        )
    }

    var summaryEntryButton: some View {
        Button(action: onOpenSummary) {
            TopBarActionIcon(
                systemName: "chart.bar.doc.horizontal",
                iconSize: 14,
                weight: .semibold,
                foregroundColor: Color.readCalendarSubtleText
            )
        }
        .topBarGlassButtonStyle(true)
        .accessibilityLabel("月度阅读总结")
        .disabled(rootContentState == .empty)
        .opacity(rootContentState == .empty ? 0.45 : 1)
    }

    var modeSwitcher: some View {
        Picker("阅读日历显示模式", selection: displayModeBinding) {
            ForEach(ReadCalendarContentView.DisplayMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.iconName)
                    .labelStyle(.iconOnly)
                    .tag(mode)
                    .accessibilityLabel(mode.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("阅读日历显示模式")
        .accessibilityValue(displayMode.title)
    }

    var displayModeBinding: Binding<ReadCalendarContentView.DisplayMode> {
        Binding(
            get: { displayMode },
            set: { newValue in
                guard newValue != displayMode else { return }
                withAnimation(.snappy(duration: 0.26)) {
                    onDisplayModeChanged(newValue)
                }
            }
        )
    }
}
