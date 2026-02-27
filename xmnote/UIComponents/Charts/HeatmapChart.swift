import SwiftUI
import UIKit
#if DEBUG
import os
#endif

/**
 * [INPUT]: 依赖 HeatmapDay/HeatmapLevel/HeatmapStatisticsDataType 领域模型，依赖 DesignTokens 颜色令牌，依赖 ScrollViewReader 程序化滚动，DEBUG 下依赖 os.Logger 输出布局诊断日志
 * [OUTPUT]: 对外提供 HeatmapChart（GitHub 风格阅读热力图组件，右侧固定星期标签 + 顶部月/年标签 + 程序化滚动 + 分段方格）
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
    static let axisGap: CGFloat = 8
    static let outerInset: CGFloat = 8
    static let headerFontSize: CGFloat = 9
    static let headerTextLineHeight: CGFloat = ceil(UIFont.systemFont(ofSize: headerFontSize).lineHeight)
    static let monthLabelHeight: CGFloat = headerTextLineHeight + axisGap
    static let headerExtraSpacingFactor: CGFloat = 0.2
}

private struct HeatmapWeekColumn: Identifiable {
    let id: String
    let week: [Date]
    let previousWeek: [Date]?
}

private struct HeatmapHeaderToken: Identifiable {
    let id: String
    let text: String
    let x: CGFloat
}

#if DEBUG
private enum HeatmapDebug {
    static let logger = Logger(subsystem: "xmnote", category: "HeatmapChartLayout")
}
#endif

// MARK: - 公开接口

struct HeatmapChart: View {
    let days: [Date: HeatmapDay]
    let earliestDate: Date?
    var latestDate: Date? = nil
    var statisticsDataType: HeatmapStatisticsDataType = .all
    var scrollToMonth: String?
    var onDayTap: ((HeatmapDay) -> Void)?

    @State private var gridViewportWidth: CGFloat = 0
    @State private var headerRowWidth: CGFloat = 0
    @State private var gridRowWidth: CGFloat = 0

    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .top, spacing: HeatmapConst.axisGap) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    gridContent
                }
                .defaultScrollAnchor(.trailing)
                .onGeometryChange(for: CGFloat.self) { geo in
                    geo.size.width
                } action: { width in
                    guard abs(width - gridViewportWidth) > 0.5 else { return }
                    gridViewportWidth = width
                    debugLogViewport(width: width)
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
        }
        .padding(HeatmapConst.outerInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func debugLogViewport(width: CGFloat) {
#if DEBUG
        let minCount = minimumVisibleWeekCount(for: width)
        let realCount = weekColumns.count
        let paddingCount = max(0, minCount - realCount)
        HeatmapDebug.logger.debug(
            "viewportWidth=\(Double(width), privacy: .public) weekdayLabelWidth=\(Double(weekdayLabelColumnWidth), privacy: .public) axisGap=\(Double(HeatmapConst.axisGap), privacy: .public) minVisibleWeekCount=\(minCount, privacy: .public) realWeekCount=\(realCount, privacy: .public) paddingWeekCount=\(paddingCount, privacy: .public)"
        )
#endif
    }

    func debugLogWidthGapIfNeeded() {
#if DEBUG
        guard headerRowWidth > 0, gridRowWidth > 0 else { return }
        let delta = headerRowWidth - gridRowWidth
        HeatmapDebug.logger.debug(
            "headerRowWidth=\(Double(headerRowWidth), privacy: .public) gridRowWidth=\(Double(gridRowWidth), privacy: .public) headerMinusGrid=\(Double(delta), privacy: .public)"
        )
#endif
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

    /// 网格结束日期：latestDate（默认今天）所在周的周六
    var gridEndDate: Date {
        let endBase = calendar.startOfDay(for: latestDate ?? Date())
        let weekday = calendar.component(.weekday, from: endBase)
        return calendar.date(byAdding: .day, value: 7 - weekday, to: endBase)!
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
        let labels = [0, 2, 4, 6].map(shortWeekday)
        let maxTextWidth = labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(maxTextWidth + 2)
    }

    var weekdayLabels: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: HeatmapConst.monthLabelHeight)
            VStack(spacing: HeatmapConst.squareSpacing) {
                ForEach(0..<7, id: \.self) { row in
                    ZStack {
                        if row % 2 == 0 {
                            Text(shortWeekday(row))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .frame(width: weekdayLabelColumnWidth, height: HeatmapConst.squareSize)
                }
            }
        }
    }

    func shortWeekday(_ row: Int) -> String {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        return symbols[row % 7]
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
        let baseColumns = weekColumns
        let minCount = minimumVisibleWeekCount(for: gridViewportWidth)
        let syntheticWeekCount = max(0, minCount - baseColumns.count)

        let effectiveStartDate = calendar.date(
            byAdding: .day,
            value: -(syntheticWeekCount * HeatmapConst.rowCount),
            to: gridStartDate
        )!

        let columns = buildWeekColumns(start: effectiveStartDate, end: gridEndDate)

        let items: [HeatmapWeekColumn] = columns.enumerated().map { index, week in
            HeatmapWeekColumn(
                id: "real-\(index)-\(Int(week[0].timeIntervalSince1970))",
                week: week,
                previousWeek: index > 0 ? columns[index - 1] : nil
            )
        }

        debugLogSyntheticWeeks(
            syntheticWeekCount: syntheticWeekCount,
            effectiveWeekCount: columns.count,
            effectiveStartDate: effectiveStartDate
        )
        return items
    }

    var gridContent: some View {
        let columns = displayedWeekColumns()
        let today = calendar.startOfDay(for: Date())

        return VStack(alignment: .leading, spacing: 0) {
            monthLabelsRow(columns)
                .onGeometryChange(for: CGFloat.self) { geo in
                    geo.size.width
                } action: { width in
                    guard abs(width - headerRowWidth) > 0.5 else { return }
                    headerRowWidth = width
                    debugLogWidthGapIfNeeded()
                }
            HStack(spacing: HeatmapConst.squareSpacing) {
                ForEach(columns) { column in
                    let anchorId = monthId(week: column.week, previousWeek: column.previousWeek)
                    if let anchorId {
                        weekColumn(column.week, today: today).id(anchorId)
                    } else {
                        weekColumn(column.week, today: today)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.width
            } action: { width in
                guard abs(width - gridRowWidth) > 0.5 else { return }
                gridRowWidth = width
                debugLogWidthGapIfNeeded()
            }
        }
        .frame(minWidth: gridViewportWidth, alignment: .trailing)
    }

    func weekColumn(_ week: [Date], today: Date) -> some View {
        VStack(spacing: HeatmapConst.squareSpacing) {
            ForEach(week, id: \.self) { date in
                squareView(date: date, isToday: date == today, isFuture: date > today)
            }
        }
    }

    func buildWeekColumns(start: Date, end: Date) -> [[Date]] {
        var columns: [[Date]] = []
        var current = start

        while current <= end {
            var week: [Date] = []
            for _ in 0..<HeatmapConst.rowCount {
                week.append(current)
                current = calendar.date(byAdding: .day, value: 1, to: current)!
            }
            columns.append(week)
        }
        return columns
    }

    func debugLogSyntheticWeeks(syntheticWeekCount: Int, effectiveWeekCount: Int, effectiveStartDate: Date) {
#if DEBUG
        guard syntheticWeekCount > 0 else { return }
        HeatmapDebug.logger.debug(
            "syntheticWeekCount=\(syntheticWeekCount, privacy: .public) effectiveWeekCount=\(effectiveWeekCount, privacy: .public) effectiveStartDate=\(effectiveStartDate.formatted(date: .abbreviated, time: .omitted), privacy: .public)"
        )
#endif
    }
}

// MARK: - 月份标签行

private extension HeatmapChart {

    func monthLabelsRow(_ columns: [HeatmapWeekColumn]) -> some View {
        let tokens = monthHeaderTokens(columns)
        let totalRowWidth = rowWidth(columnCount: columns.count)

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: totalRowWidth, height: HeatmapConst.headerTextLineHeight)
                ForEach(tokens) { token in
                    Text(token.text)
                        .font(.system(size: HeatmapConst.headerFontSize))
                        .foregroundStyle(Color.textHint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: token.x, y: 0)
                }
            }
            Color.clear.frame(width: totalRowWidth, height: HeatmapConst.axisGap)
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

    /// 按 Android HistoryChart 的“月份优先 + 年份次级 + overflow 衰减”规则生成顶部标题 token。
    func monthHeaderTokens(_ columns: [HeatmapWeekColumn]) -> [HeatmapHeaderToken] {
        var tokens: [HeatmapHeaderToken] = []
        var previousMonth = ""
        var previousYear = ""
        var headerOverflow: CGFloat = 0
        let columnAdvance = HeatmapConst.squareSize + HeatmapConst.squareSpacing
        let font = UIFont.systemFont(ofSize: HeatmapConst.headerFontSize)

        for (index, column) in columns.enumerated() {
            let firstDay = column.week[0]
            let month = monthText(firstDay)
            let year = yearText(firstDay)
            var text: String?

            // 与 Android HistoryChart 一致：优先月变化，其次年变化；年状态仅在绘制年标签时更新。
            if month != previousMonth {
                previousMonth = month
                text = month
            } else if year != previousYear {
                previousYear = year
                text = year
            }

            if let text {
                let drawX = CGFloat(index) * columnAdvance + headerOverflow
                let textWidth = headerTextWidth(text, font: font)
                tokens.append(
                    HeatmapHeaderToken(
                        id: "header-\(index)-\(text)",
                        text: text,
                        x: drawX
                    )
                )
                debugLogHeaderToken(
                    index: index,
                    text: text,
                    drawX: drawX,
                    overflowBeforeDecay: headerOverflow,
                    textWidth: textWidth
                )
                headerOverflow += textWidth + columnAdvance * HeatmapConst.headerExtraSpacingFactor
            }
            headerOverflow = max(0, headerOverflow - columnAdvance)
        }

        return tokens
    }

    func rowWidth(columnCount: Int) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        let spacingCount = max(columnCount - 1, 0)
        return CGFloat(columnCount) * HeatmapConst.squareSize + CGFloat(spacingCount) * HeatmapConst.squareSpacing
    }

    func headerTextWidth(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func yearText(_ date: Date) -> String {
        String(calendar.component(.year, from: date))
    }

    func monthText(_ date: Date) -> String {
        "\(calendar.component(.month, from: date))月"
    }

    func debugLogHeaderToken(index: Int, text: String, drawX: CGFloat, overflowBeforeDecay: CGFloat, textWidth: CGFloat) {
#if DEBUG
        HeatmapDebug.logger.debug(
            "headerToken index=\(index, privacy: .public) text=\(text, privacy: .public) drawX=\(Double(drawX), privacy: .public) overflowBeforeDecay=\(Double(overflowBeforeDecay), privacy: .public) textWidth=\(Double(textWidth), privacy: .public)"
        )
#endif
    }

    func monthKey(_ date: Date) -> String {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        return "\(y)-\(m)"
    }
}

// MARK: - 方格子视图

private extension HeatmapChart {

    func squareView(date: Date, isToday: Bool, isFuture: Bool) -> some View {
        let day = days[date] ?? .empty(for: date)
        let segmentColors = day.segmentColors(for: statisticsDataType)

        return RoundedRectangle(cornerRadius: HeatmapConst.squareRadius)
            .fill(Color.clear)
            .frame(width: HeatmapConst.squareSize, height: HeatmapConst.squareSize)
            .overlay {
                if !isFuture {
                    segmentedFill(colors: segmentColors)
                        .clipShape(RoundedRectangle(cornerRadius: HeatmapConst.squareRadius))
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: HeatmapConst.squareRadius)
                        .strokeBorder(Color.brand, lineWidth: 1.5)
                }
            }
            .onTapGesture {
                guard !isFuture else { return }
                onDayTap?(day)
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: day.id)
            .accessibilityLabel(accessibilityText(date: date, day: day))
    }

    @ViewBuilder
    func segmentedFill(colors: [Color]) -> some View {
        GeometryReader { geo in
            let count = max(colors.count, 1)
            VStack(spacing: 0) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    color
                        .frame(height: geo.size.height / CGFloat(count))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    func accessibilityText(date: Date, day: HeatmapDay) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: date)
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
            ForEach(HeatmapLevel.allCases.filter { $0 != .none }, id: \.rawValue) { level in
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
