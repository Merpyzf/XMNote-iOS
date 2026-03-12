/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的颜色、圆角、边框与间距令牌
 * [OUTPUT]: 对外提供 CalendarMonthStepperBar（月视图顶部月份切换触发器，支持点击月份快速切换）
 * [POS]: ReadCalendar 页面私有子视图，服务阅读日历顶部月份切换交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读日历顶部月份切换条，支持菜单快速跳转到任意可用月份。
struct CalendarMonthStepperBar: View {
    private enum Layout {
        static let barMinHeight: CGFloat = 36
    }

    let title: String
    let availableMonths: [Date]
    let selectedMonth: Date
    let onSelectMonth: (Date) -> Void

    var body: some View {
        monthQuickPicker
            .frame(maxWidth: .infinity, minHeight: Layout.barMinHeight, alignment: .leading)
    }

    private var monthQuickPicker: some View {
        Menu {
            ForEach(availableMonths.reversed(), id: \.self) { monthStart in
                Button {
                    guard monthStart != selectedMonth else { return }
                    onSelectMonth(monthStart)
                } label: {
                    if monthStart == selectedMonth {
                        Label(monthLabel(monthStart), systemImage: "checkmark")
                    } else {
                        Text(monthLabel(monthStart))
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(title)
                    .font(ReadCalendarTypography.topControlTitleFont)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.24), value: selectedMonth)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
    
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
    }

    private func monthLabel(_ monthStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        formatter.timeZone = .current
        return formatter.string(from: monthStart)
    }
}

#Preview {
    let calendar = Calendar.current
    let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    let availableMonths = (-6...0).compactMap { offset in
        calendar.date(byAdding: .month, value: offset, to: currentMonth)
    }

    ZStack {
        Color.surfacePage.ignoresSafeArea()
        CalendarMonthStepperBar(
            title: "2026年2月",
            availableMonths: availableMonths,
            selectedMonth: availableMonths.last ?? Date(),
            onSelectMonth: { _ in }
        )
        .padding(Spacing.screenEdge)
    }
}
