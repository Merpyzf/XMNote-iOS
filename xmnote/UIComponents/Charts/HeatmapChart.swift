import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 HeatmapDay/HeatmapLevel 领域模型，依赖 DesignTokens 颜色令牌，依赖 ScrollViewReader 程序化滚动
 * [OUTPUT]: 对外提供 HeatmapChart（GitHub 风格阅读热力图组件，右侧固定星期标签 + 顶部月/年标签 + 程序化滚动）
 * [POS]: UIComponents/Charts 的热力图组件，供在读页/统计页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 常量

private enum HeatmapConst {
    static let squareSize: CGFloat = 13
    static let squareSpacing: CGFloat = 3
    static let squareRadius: CGFloat = 2.5
    static let rowCount = 7
    static let defaultWeeks = 20
    static let monthLabelHeight: CGFloat = 16
}

private struct HeatmapViewportWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HeatmapWeekColumn: Identifiable {
    enum Kind {
        case real(week: [Date], previousWeek: [Date]?)
        case padding
    }

    let id: String
    let kind: Kind
}

// MARK: - 公开接口

struct HeatmapChart: View {
    let days: [Date: HeatmapDay]
    let earliestDate: Date?
    var scrollToMonth: String?
    var onDayTap: ((HeatmapDay) -> Void)?

    @State private var gridViewportWidth: CGFloat = 0

    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    gridContent
                        .padding(.vertical, Spacing.half)
                }
                .defaultScrollAnchor(.trailing)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: HeatmapViewportWidthPreferenceKey.self,
                            value: geo.size.width
                        )
                    }
                }
                .onPreferenceChange(HeatmapViewportWidthPreferenceKey.self) { width in
                    guard abs(width - gridViewportWidth) > 0.5 else { return }
                    gridViewportWidth = width
                }
                .onChange(of: scrollToMonth) { _, target in
                    guard let target else { return }
                    withAnimation(.snappy) {
                        proxy.scrollTo(target, anchor: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            weekdayLabels
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, Spacing.half)
        }
    }
}

// MARK: - 网格范围计算

private extension HeatmapChart {

    /// 网格起始日期：earliestDate 对齐到所在周的周日，或今天前推 defaultWeeks 周
    var gridStartDate: Date {
        let base: Date
        if let earliest = earliestDate {
            base = calendar.startOfDay(for: earliest)
        } else {
            base = calendar.date(
                byAdding: .weekOfYear, value: -HeatmapConst.defaultWeeks,
                to: calendar.startOfDay(for: Date())
            )!
        }
        // 对齐到所在周的周日（weekday=1）
        let weekday = calendar.component(.weekday, from: base)
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: base)!
    }

    /// 网格结束日期：今天所在周的周六
    var gridEndDate: Date {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        return calendar.date(byAdding: .day, value: 7 - weekday, to: today)!
    }

    /// 按列（周）组织的日期二维数组，每列 7 天
    var weekColumns: [[Date]] {
        var columns: [[Date]] = []
        var current = gridStartDate
        let end = gridEndDate

        while current <= end {
            var week: [Date] = []
            for _ in 0..<7 {
                week.append(current)
                current = calendar.date(byAdding: .day, value: 1, to: current)!
            }
            columns.append(week)
        }
        return columns
    }
}

// MARK: - 星期标签列

private extension HeatmapChart {

    var weekdayLabelColumnWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: 9)
        let labels = [1, 3, 5].map(shortWeekday)
        let maxTextWidth = labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(maxTextWidth + 2)
    }

    var weekdayLabels: some View {
        VStack(spacing: HeatmapConst.squareSpacing) {
            Color.clear.frame(height: HeatmapConst.monthLabelHeight)
            ForEach(0..<7, id: \.self) { row in
                if row == 1 || row == 3 || row == 5 {
                    Text(shortWeekday(row))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.textHint)
                        .frame(
                            width: weekdayLabelColumnWidth,
                            height: HeatmapConst.squareSize
                        )
                } else {
                    Color.clear.frame(
                        width: weekdayLabelColumnWidth,
                        height: HeatmapConst.squareSize
                    )
                }
            }
        }
    }

    func shortWeekday(_ row: Int) -> String {
        calendar.veryShortWeekdaySymbols[row % 7]
    }
}

// MARK: - 网格内容

private extension HeatmapChart {

    func minimumVisibleWeekCount(for viewportWidth: CGFloat) -> Int {
        guard viewportWidth > 0 else { return 0 }
        let columnUnit = HeatmapConst.squareSize + HeatmapConst.squareSpacing
        let rawCount = (viewportWidth + HeatmapConst.squareSpacing) / columnUnit
        return max(Int(ceil(rawCount)), 1)
    }

    func displayedWeekColumns() -> [HeatmapWeekColumn] {
        let realColumns = weekColumns
        let realItems: [HeatmapWeekColumn] = realColumns.enumerated().map { index, week in
            HeatmapWeekColumn(
                id: "real-\(index)-\(Int(week[0].timeIntervalSince1970))",
                kind: .real(week: week, previousWeek: index > 0 ? realColumns[index - 1] : nil)
            )
        }

        // padding 列插入左侧：配合 .defaultScrollAnchor(.trailing)，
        // 用户默认看到右侧真实数据，左滑才看到空白填充
        let minCount = minimumVisibleWeekCount(for: gridViewportWidth)
        let paddingCount = max(0, minCount - realColumns.count)
        let paddingItems = (0..<paddingCount).map { index in
            HeatmapWeekColumn(id: "padding-\(index)", kind: .padding)
        }
        return paddingItems + realItems
    }

    var gridContent: some View {
        let columns = displayedWeekColumns()
        let today = calendar.startOfDay(for: Date())

        return VStack(alignment: .leading, spacing: 0) {
            monthLabelsRow(columns)
            HStack(spacing: HeatmapConst.squareSpacing) {
                ForEach(columns) { column in
                    renderedWeekColumn(column, today: today)
                }
            }
        }
        .frame(minWidth: gridViewportWidth, alignment: .leading)
    }

    func weekColumn(_ week: [Date], today: Date) -> some View {
        VStack(spacing: HeatmapConst.squareSpacing) {
            ForEach(week, id: \.self) { date in
                squareView(date: date, isToday: date == today, isFuture: date > today)
            }
        }
    }

    func paddingWeekColumn() -> some View {
        VStack(spacing: HeatmapConst.squareSpacing) {
            ForEach(0..<HeatmapConst.rowCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: HeatmapConst.squareRadius)
                    .fill(HeatmapLevel.none.color)
                    .frame(width: HeatmapConst.squareSize, height: HeatmapConst.squareSize)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    func renderedWeekColumn(_ column: HeatmapWeekColumn, today: Date) -> some View {
        switch column.kind {
        case let .real(week, previousWeek):
            let anchorId = monthId(week: week, previousWeek: previousWeek)
            if let anchorId {
                weekColumn(week, today: today).id(anchorId)
            } else {
                weekColumn(week, today: today)
            }
        case .padding:
            paddingWeekColumn()
        }
    }
}

// MARK: - 月份标签行

private extension HeatmapChart {

    func monthLabelsRow(_ columns: [HeatmapWeekColumn]) -> some View {
        HStack(spacing: HeatmapConst.squareSpacing) {
            ForEach(columns) { column in
                monthLabel(for: column)
            }
        }
        .frame(height: HeatmapConst.monthLabelHeight)
    }

    /// 月份变化时返回 "yyyy-M" ID，否则 nil（仅用于滚动锚点，不等于显示文本）
    func monthId(week: [Date], previousWeek: [Date]?) -> String? {
        let firstDay = week[0]
        guard let prev = previousWeek else { return monthKey(firstDay) }
        let monthChanged = calendar.component(.month, from: firstDay) != calendar.component(.month, from: prev[0])
            || calendar.component(.year, from: firstDay) != calendar.component(.year, from: prev[0])
        return monthChanged ? monthKey(firstDay) : nil
    }

    /// 每列首日（周日）月份变化时显示月份，跨年时补充年份
    func monthLabel(for week: [Date], previousWeek: [Date]?) -> some View {
        let firstDay = week[0]

        return Group {
            if let label = headerLabelText(for: week, previousWeek: previousWeek) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textHint)
                    .fixedSize()
            } else {
                Color.clear.frame(width: HeatmapConst.squareSize)
            }
        }
        .frame(height: HeatmapConst.monthLabelHeight, alignment: .leading)
    }

    @ViewBuilder
    func monthLabel(for column: HeatmapWeekColumn) -> some View {
        switch column.kind {
        case let .real(week, previousWeek):
            monthLabel(for: week, previousWeek: previousWeek)
        case .padding:
            Color.clear
                .frame(width: HeatmapConst.squareSize, height: HeatmapConst.monthLabelHeight)
        }
    }

    func monthKey(_ date: Date) -> String {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        return "\(y)-\(m)"
    }

    func monthText(_ date: Date) -> String {
        let month = calendar.component(.month, from: date)
        let symbols = calendar.shortMonthSymbols
        if month > 0, month <= symbols.count {
            return symbols[month - 1]
        }
        return "\(month)月"
    }

    func headerLabelText(for week: [Date], previousWeek: [Date]?) -> String? {
        let firstDay = week[0]
        guard let previousWeek else {
            return monthKey(firstDay)
        }

        let previousDay = previousWeek[0]
        let monthChanged = calendar.component(.month, from: firstDay) != calendar.component(.month, from: previousDay)
        let yearChanged = calendar.component(.year, from: firstDay) != calendar.component(.year, from: previousDay)

        guard monthChanged else { return nil }
        return yearChanged ? monthKey(firstDay) : monthText(firstDay)
    }
}

// MARK: - 方格子视图

private extension HeatmapChart {

    func squareView(date: Date, isToday: Bool, isFuture: Bool) -> some View {
        let day = days[date]
        let level = day?.level ?? .none

        return RoundedRectangle(cornerRadius: HeatmapConst.squareRadius)
            .fill(isFuture ? Color.clear : level.color)
            .frame(width: HeatmapConst.squareSize, height: HeatmapConst.squareSize)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: HeatmapConst.squareRadius)
                        .strokeBorder(Color.brand, lineWidth: 1.5)
                }
            }
            .onTapGesture {
                guard !isFuture, let day else { return }
                onDayTap?(day)
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: day?.id)
            .accessibilityLabel(accessibilityText(date: date, day: day))
    }

    func accessibilityText(date: Date, day: HeatmapDay?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: date)
        guard let day else { return "\(dateStr)，\(HeatmapLevel.none.accessibilityText)" }
        let readMinutes = day.readSeconds / 60
        return "\(dateStr)，阅读\(readMinutes)分钟，打卡\(day.checkInCount)次，\(day.level.accessibilityText)"
    }
}

// MARK: - 图例

extension HeatmapChart {

    /// 颜色图例条（少 → 多），可在外部组合使用
    static var legend: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(.system(size: 9))
                .foregroundStyle(Color.textHint)
            ForEach(HeatmapLevel.allCases, id: \.rawValue) { level in
                RoundedRectangle(cornerRadius: HeatmapConst.squareRadius)
                    .fill(level.color)
                    .frame(width: 10, height: 10)
            }
            Text("多")
                .font(.system(size: 9))
                .foregroundStyle(Color.textHint)
        }
    }
}

// MARK: - Preview

#Preview("空数据") {
    HeatmapChart(days: [:], earliestDate: nil)
        .padding()
}

#Preview("示例数据") {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    var days: [Date: HeatmapDay] = [:]
    for i in 0..<90 {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        if Int.random(in: 0...2) > 0 {
            days[date] = HeatmapDay(
                id: date,
                readSeconds: Int.random(in: 0...5000),
                noteCount: Int.random(in: 0...15),
                checkInCount: 0,
                checkInSeconds: 0
            )
        }
    }
    let earliest = cal.date(byAdding: .day, value: -89, to: today)!
    return HeatmapChart(days: days, earliestDate: earliest)
        .padding()
}
