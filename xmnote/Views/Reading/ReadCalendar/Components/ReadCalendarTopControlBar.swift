import SwiftUI

/**
 * [INPUT]: 依赖月份/年份与显示模式状态，依赖回调驱动页面壳层进行状态更新
 * [OUTPUT]: 对外提供 ReadCalendarTopControlBar（阅读日历顶部控制区）
 * [POS]: ReadCalendar 业务内复用组件，承载月份或年份切换与显示模式切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarTopControlBar: View {
    private enum Layout {
        static let topControlSpacing: CGFloat = Spacing.cozy
        static let modeSwitcherWidth: CGFloat = 116
    }

    let monthTitle: String
    let yearTitle: String
    let availableMonths: [Date]
    let availableYears: [Int]
    let pagerSelection: Date
    let selectedYear: Int
    let displayMode: ReadCalendarContentView.DisplayMode
    let onDisplayModeChanged: (ReadCalendarContentView.DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onYearSelectionChanged: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Layout.topControlSpacing) {
            leadingSwitcher
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            modeSwitcher
                .frame(width: Layout.modeSwitcherWidth)
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}

private extension ReadCalendarTopControlBar {
    @ViewBuilder
    var leadingSwitcher: some View {
        if displayMode == .heatmap {
            yearSwitcher
        } else {
            monthSwitcher
        }
    }

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

    var yearSwitcher: some View {
        Menu {
            ForEach(availableYears, id: \.self) { year in
                Button {
                    guard year != selectedYear else { return }
                    onYearSelectionChanged(year)
                } label: {
                    if year == selectedYear {
                        Label("\(year)年", systemImage: "checkmark")
                    } else {
                        Text("\(year)年")
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(yearTitle)
                    .font(ReadCalendarTypography.topControlTitleFont)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.24), value: selectedYear)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.readCalendarSubtleText)
                    .offset(y: 0.5)
            }
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("年份选择")
        .accessibilityValue("\(selectedYear)年")
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
                // 重入保护：Picker 在 SwiftUI 内部可能对同一值多次调用 setter
                guard newValue != displayMode else { return }
                withAnimation(.snappy(duration: 0.26)) {
                    onDisplayModeChanged(newValue)
                }
            }
        )
    }
}
