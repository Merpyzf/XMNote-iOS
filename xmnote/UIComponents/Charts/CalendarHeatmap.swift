import Foundation
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 HeatmapDay/HeatmapLevel/HeatmapStatisticsDataType 领域模型、HeatmapColorPalette 调色板与 CalendarHeatmapTypography 排版令牌
 * [OUTPUT]: 对外提供 CalendarHeatmapMonth、CalendarHeatmapStyle 与 CalendarHeatmap，渲染 Android 阅读详情对齐的横向月历热力图
 * [POS]: UIComponents/Charts 的公共月历热力图基建，供阅读详情及测试中心按月份注入数据与主题色阶
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 月份输入

/// 单个月份的规范化热力数据，以本地月份首日作为稳定身份、以本地自然日作为数据键。
struct CalendarHeatmapMonth: Identifiable {
    let monthStart: Date
    let days: [Date: HeatmapDay]

    var id: Date { monthStart }

    /// 创建月份输入，并过滤不属于目标月份的数据，避免跨月脏键污染布局。
    init(monthStart: Date, days: [Date: HeatmapDay]) {
        let calendar = CalendarHeatmapCalendar.make()
        let normalizedMonthStart = calendar.normalizedMonthStart(for: monthStart)
        let targetComponents = calendar.dateComponents([.year, .month], from: normalizedMonthStart)

        self.monthStart = normalizedMonthStart
        self.days = days.reduce(into: [:]) { result, item in
            let normalizedDate = calendar.startOfDay(for: item.key)
            let components = calendar.dateComponents([.year, .month], from: normalizedDate)
            guard components.year == targetComponents.year,
                  components.month == targetComponents.month else {
                return
            }

            let day = item.value
            result[normalizedDate] = HeatmapDay(
                id: normalizedDate,
                readSeconds: day.readSeconds,
                noteCount: day.noteCount,
                checkInCount: day.checkInCount,
                checkInSeconds: day.checkInSeconds,
                bookStates: day.bookStates
            )
        }
    }
}

// MARK: - 样式

/// 月历热力图的视觉参数，默认值对应 Android 阅读详情的格子、间距和圆角规格。
struct CalendarHeatmapStyle {
    let palette: HeatmapColorPalette
    let monthTitleColor: Color
    let emptyDayTextColor: Color
    let activeDayTextColor: Color
    let cellOuterPadding: CGFloat
    let cellInnerPadding: CGFloat
    let cellCornerRadius: CGFloat
    let monthSpacing: CGFloat
    let titleGridSpacing: CGFloat

    /// 创建月历样式；页面容器背景、边框、圆角和内边距不属于该样式职责。
    init(
        palette: HeatmapColorPalette = .appDefault,
        monthTitleColor: Color = .textSecondary,
        emptyDayTextColor: Color = .textSecondary,
        activeDayTextColor: Color = .white,
        cellOuterPadding: CGFloat = 2,
        cellInnerPadding: CGFloat = 4,
        cellCornerRadius: CGFloat = 4,
        monthSpacing: CGFloat = 3,
        titleGridSpacing: CGFloat = 6
    ) {
        self.palette = palette
        self.monthTitleColor = monthTitleColor
        self.emptyDayTextColor = emptyDayTextColor
        self.activeDayTextColor = activeDayTextColor
        self.cellOuterPadding = cellOuterPadding
        self.cellInnerPadding = cellInnerPadding
        self.cellCornerRadius = cellCornerRadius
        self.monthSpacing = monthSpacing
        self.titleGridSpacing = titleGridSpacing
    }

    static let readingDetail = CalendarHeatmapStyle()
}

// MARK: - 组件

/// 按调用方顺序横向展示月份，并依据终止状态选择最早或最新月份作为首次可见位置。
struct CalendarHeatmap: View {
    private let monthLayouts: [CalendarHeatmapMonthLayout]
    private let maximumRowCount: Int
    private let statisticsDataType: HeatmapStatisticsDataType
    private let style: CalendarHeatmapStyle
    private let isScrollEnabled: Bool

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 创建月历热力图；月份顺序完全由调用方决定，空数组不渲染内建空态。
    init(
        months: [CalendarHeatmapMonth],
        statisticsDataType: HeatmapStatisticsDataType = .all,
        style: CalendarHeatmapStyle = .readingDetail,
        isScrollEnabled: Bool = true
    ) {
        let layouts = months.map(CalendarHeatmapMonthLayout.init(month:))
        self.monthLayouts = layouts
        self.maximumRowCount = layouts.map(\.rowCount).max() ?? 0
        self.statisticsDataType = statisticsDataType
        self.style = style
        self.isScrollEnabled = isScrollEnabled
    }

    @ViewBuilder
    var body: some View {
        if !monthLayouts.isEmpty {
            if isScrollEnabled {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: style.monthSpacing) {
                            ForEach(monthLayouts) { layout in
                                monthView(for: layout)
                                    .id(layout.id)
                            }
                        }
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    .id(initialScrollRequest)
                    .frame(height: contentHeight, alignment: .top)
                    .scrollBounceBehavior(.always)
                    // SwiftUI 在主线程执行滚动任务；月份策略变化会取消旧任务，request 身份保证仅最新请求定位，热度与配色刷新不会触发竞态式回跳。
                    .task(id: initialScrollRequest) {
                        guard let target = initialScrollRequest.target else { return }
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            proxy.scrollTo(
                                target,
                                anchor: initialScrollRequest.shouldShowEarliest ? .leading : .trailing
                            )
                        }
                    }
                }
            } else if let staticLayout {
                monthView(for: staticLayout)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: contentHeight, alignment: .top)
            }
        }
    }
}

private extension CalendarHeatmap {
    var typographyTraits: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory)
    }

    var cellSize: CGFloat {
        let font = CalendarHeatmapTypography.uiDay(compatibleWith: typographyTraits)
        let maximumTextWidth = (1...31).reduce(CGFloat.zero) { maximum, day in
            let size = String(day).size(withAttributes: [.font: font])
            return max(maximum, size.width)
        }
        let textExtent = max(maximumTextWidth, font.lineHeight)
        let safeExtent = textExtent
            + (1 / max(displayScale, 1))
            + style.cellOuterPadding * 2
            + style.cellInnerPadding * 2
        return ceil(safeExtent * max(displayScale, 1)) / max(displayScale, 1)
    }

    var contentHeight: CGFloat {
        let titleFont = CalendarHeatmapTypography.uiMonthTitle(
            compatibleWith: typographyTraits
        )
        return titleFont.lineHeight
            + style.titleGridSpacing
            + cellSize * CGFloat(maximumRowCount)
    }

    var initialScrollRequest: CalendarHeatmapScrollRequest {
        let shouldShowEarliest = monthLayouts.contains { layout in
            layout.days.contains { day in
                day.bookStates.contains(.readDone) || day.bookStates.contains(.abandon)
            }
        }
        return CalendarHeatmapScrollRequest(
            monthIDs: monthLayouts.map(\.id),
            shouldShowEarliest: shouldShowEarliest
        )
    }

    var staticLayout: CalendarHeatmapMonthLayout? {
        initialScrollRequest.shouldShowEarliest ? monthLayouts.first : monthLayouts.last
    }

    /// 创建单月内容；静态长图绕开 ScrollView/LazyHStack 的离屏快照空白，同时保持与交互页相同的格子算法。
    func monthView(for layout: CalendarHeatmapMonthLayout) -> some View {
        CalendarHeatmapMonthView(
            layout: layout,
            maximumRowCount: maximumRowCount,
            cellSize: cellSize,
            statisticsDataType: statisticsDataType,
            style: style,
            typographyTraits: typographyTraits
        )
    }
}

// MARK: - 月份布局

private nonisolated struct CalendarHeatmapMonthLayout: Identifiable {
    let id: Date
    let title: String
    let rowCount: Int
    let cells: [CalendarHeatmapCell]
    let days: [HeatmapDay]

    /// 把月份转换为固定七列的行优先格子，并保留 Android 的边界额外空行公式。
    init(month: CalendarHeatmapMonth) {
        let calendar = CalendarHeatmapCalendar.make()
        let components = calendar.dateComponents([.year, .month], from: month.monthStart)
        let dayRange = calendar.range(of: .day, in: .month, for: month.monthStart) ?? 1..<1
        let dayCount = dayRange.count
        let leadingSlotCount = max(calendar.component(.weekday, from: month.monthStart) - 1, 0)
        let rowCount = (leadingSlotCount + dayCount) / 7 + 1

        self.id = month.monthStart
        self.title = "\(components.year ?? 0)-\(components.month ?? 0)"
        self.rowCount = rowCount
        self.cells = (0..<(rowCount * 7)).map { slot in
            let dayNumber = slot - leadingSlotCount + 1
            guard dayNumber >= 1,
                  dayNumber <= dayCount,
                  let date = calendar.date(
                    byAdding: .day,
                    value: dayNumber - 1,
                    to: month.monthStart
                  ) else {
                return CalendarHeatmapCell(id: slot, date: nil, dayNumber: nil, day: nil)
            }

            let normalizedDate = calendar.startOfDay(for: date)
            return CalendarHeatmapCell(
                id: slot,
                date: normalizedDate,
                dayNumber: dayNumber,
                day: month.days[normalizedDate] ?? .empty(for: normalizedDate)
            )
        }
        self.days = month.days.values.map { $0 }
    }
}

private nonisolated struct CalendarHeatmapCell: Identifiable {
    let id: Int
    let date: Date?
    let dayNumber: Int?
    let day: HeatmapDay?
}

private struct CalendarHeatmapMonthView: View {
    let layout: CalendarHeatmapMonthLayout
    let maximumRowCount: Int
    let cellSize: CGFloat
    let statisticsDataType: HeatmapStatisticsDataType
    let style: CalendarHeatmapStyle
    let typographyTraits: UITraitCollection

    var body: some View {
        VStack(alignment: .leading, spacing: style.titleGridSpacing) {
            Text(layout.title)
                .font(CalendarHeatmapTypography.monthTitle(compatibleWith: typographyTraits))
                .foregroundStyle(style.monthTitleColor)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(cellSize), spacing: Spacing.none),
                    count: 7
                ),
                alignment: .leading,
                spacing: Spacing.none
            ) {
                ForEach(layout.cells) { cell in
                    CalendarHeatmapDayCell(
                        cell: cell,
                        cellSize: cellSize,
                        statisticsDataType: statisticsDataType,
                        style: style,
                        typographyTraits: typographyTraits
                    )
                }
            }
            .frame(
                width: cellSize * 7,
                height: cellSize * CGFloat(maximumRowCount),
                alignment: .topLeading
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layout.title)
    }
}

// MARK: - 日期格

private struct CalendarHeatmapDayCell: View {
    let cell: CalendarHeatmapCell
    let cellSize: CGFloat
    let statisticsDataType: HeatmapStatisticsDataType
    let style: CalendarHeatmapStyle
    let typographyTraits: UITraitCollection

    var body: some View {
        ZStack {
            segmentedFill

            if let dayNumber = cell.dayNumber {
                Text(String(dayNumber))
                    .font(CalendarHeatmapTypography.day(compatibleWith: typographyTraits))
                    .foregroundStyle(isActive ? style.activeDayTextColor : style.emptyDayTextColor)
                    .lineLimit(1)
            }
        }
        .frame(width: cellSize, height: cellSize)
        .accessibilityHidden(cell.date == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

private extension CalendarHeatmapDayCell {
    var visibleCellSize: CGFloat {
        max(cellSize - style.cellOuterPadding * 2, 1)
    }

    var colors: [Color] {
        guard let day = cell.day else { return [style.palette.none] }
        return day.segmentColors(for: statisticsDataType) { level in
            style.palette.color(for: level)
        }
    }

    var isActive: Bool {
        guard let day = cell.day else { return false }
        if !day.bookStates.isEmpty {
            return true
        }

        switch statisticsDataType {
        case .noteCount:
            return day.noteCount > 0
        case .readingTime:
            return day.readSeconds > 0
        case .all, .checkIn:
            return day.noteCount > 0 || day.readSeconds > 0 || day.checkInSeconds > 0
        }
    }

    @ViewBuilder
    var segmentedFill: some View {
        VStack(spacing: Spacing.none) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                color
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: visibleCellSize, height: visibleCellSize)
        .compositingGroup()
        .clipShape(
            RoundedRectangle(cornerRadius: style.cellCornerRadius, style: .continuous)
        )
    }

    var accessibilityText: String {
        guard let date = cell.date,
              let day = cell.day else {
            return ""
        }

        let dateText = date.formatted(.dateTime.year().month().day())
        let durationText = readingDurationText(seconds: day.readSeconds)
        let intensity = day.amountLevel(for: statisticsDataType).accessibilityText
        return "\(dateText)，阅读\(durationText)，书摘\(day.noteCount)条，打卡\(day.checkInCount)次，状态\(day.bookStateTitles)，强度\(intensity)"
    }

    /// 把秒数转换为适合 VoiceOver 连续朗读的小时、分钟和秒描述。
    func readingDurationText(seconds: Int) -> String {
        guard seconds > 0 else { return "0分钟" }
        if seconds < 60 {
            return "\(seconds)秒"
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0, minutes > 0 {
            return "\(hours)小时\(minutes)分钟"
        }
        if hours > 0 {
            return "\(hours)小时"
        }
        return "\(minutes)分钟"
    }
}

// MARK: - 初始滚动

private struct CalendarHeatmapScrollRequest: Hashable {
    let monthIDs: [Date]
    let shouldShowEarliest: Bool

    var target: Date? {
        shouldShowEarliest ? monthIDs.first : monthIDs.last
    }
}

// MARK: - 日历辅助

private enum CalendarHeatmapCalendar {
    /// 创建固定公历、固定周日首列且使用系统本地时区的计算日历。
    nonisolated static func make() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        return calendar
    }
}

private extension Calendar {
    /// 返回日期所在月份的本地首日零点，作为月份稳定身份。
    func normalizedMonthStart(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components).map(startOfDay(for:)) ?? startOfDay(for: date)
    }
}

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

#Preview("Android 阅读详情月历热力图") {
    let calendar = CalendarHeatmapCalendar.make()
    let monthStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    let readingDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 8))!
    let day = HeatmapDay(
        id: readingDate,
        readSeconds: 3_000,
        noteCount: 0,
        checkInCount: 0,
        checkInSeconds: 0,
        bookStates: [.reading]
    )

    return VStack(spacing: Spacing.cozy) {
        CalendarHeatmap(
            months: [CalendarHeatmapMonth(monthStart: monthStart, days: [readingDate: day])]
        )
        HeatmapLegend(palette: .appDefault, style: .calendarReadingDetail)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding()
}
