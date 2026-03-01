import SwiftUI

/**
 * [INPUT]: 依赖月份与显示模式状态，依赖回调驱动页面壳层进行状态更新
 * [OUTPUT]: 对外提供 ReadCalendarTopControlBar（阅读日历顶部控制区）
 * [POS]: ReadCalendar 业务内复用组件，承载月份切换与显示模式切换
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
    let onDisplayModeChanged: (ReadCalendarContentView.DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Layout.topControlSpacing) {
            monthSwitcher
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

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

    var modeSwitcher: some View {
        Picker("阅读日历显示模式", selection: displayModeBinding) {
            ForEach(ReadCalendarContentView.DisplayMode.allCases, id: \.self) { mode in
                Image(systemName: mode.iconName(isSelected: mode == displayMode))
                    .font(.system(size: 14, weight: .medium))
                    .tag(mode)
                    .accessibilityLabel(mode.title)
            }
        }
        .pickerStyle(.segmented)
        .tint(Color.brand)
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
