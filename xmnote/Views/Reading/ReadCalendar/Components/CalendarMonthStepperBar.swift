/**
 * [INPUT]: 依赖 ReadCalendarTheme 次级文字色、ReadCalendarTextStyle 顶部标题与 DesignSystem 圆角、边框、间距令牌
 * [OUTPUT]: 对外提供 CalendarMonthStepperBar（月视图顶部年月选择 Sheet 触发器）
 * [POS]: ReadCalendar 页面私有子视图，服务阅读日历顶部月份切换交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读日历顶部月份切换条，只负责打开统一年月选择 Sheet。
struct CalendarMonthStepperBar: View {
    private enum Layout {
        static let barMinHeight: CGFloat = InteractionMetrics.minimumTouchTarget
        static let expandedBarMinHeight: CGFloat = 48
    }

    private enum Motion {
        static let monthValue = Animation.snappy(duration: 0.24)
    }

    let title: String
    let selectedMonth: Date
    let onRequestPicker: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var chevronSymbolSize = 10

    var body: some View {
        monthQuickPicker
            .frame(
                maxWidth: .infinity,
                minHeight: usesExpandedTextLayout ? Layout.expandedBarMinHeight : Layout.barMinHeight,
                alignment: .leading
            )
    }

    private var monthQuickPicker: some View {
        Button {
            onRequestPicker()
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(title)
                    .font(ReadCalendarTextStyle.topControlTitleFont)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.monthValue, value: selectedMonth)
                    .lineLimit(usesExpandedTextLayout ? 2 : 1)
                    .minimumScaleFactor(usesExpandedTextLayout ? 1 : 0.9)
                    .multilineTextAlignment(.leading)
    
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSymbolSize, weight: .semibold))
                    .foregroundStyle(ReadCalendarTheme.subtleText)
                    .offset(y: 0.5)
            }
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择年月")
        .accessibilityValue(title)
    }

    var usesExpandedTextLayout: Bool {
        dynamicTypeSize >= .accessibility1
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
            selectedMonth: availableMonths.last ?? Date(),
            onRequestPicker: {}
        )
        .padding(Spacing.screenEdge)
    }
}
