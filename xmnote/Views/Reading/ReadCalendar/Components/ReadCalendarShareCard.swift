/**
 * [INPUT]: 依赖 ReadCalendarShareSnapshot/Template、XMBookCover 与 DesignTokens
 * [OUTPUT]: 对外提供 ReadCalendarShareCard，渲染年度热力图、月活动和月书单三类可导出卡片
 * [POS]: ReadCalendar 分享页私有成品组件，屏幕预览与图片导出共用同一渲染树
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 分享成品卡；固定 4:5 画布，预览和导出复用以避免所见与所得不一致。
struct ReadCalendarShareCard: View {
    let type: ReadCalendarShareType
    let template: ReadCalendarShareTemplate
    let snapshot: ReadCalendarShareSnapshot
    let rankingBooks: [ReadCalendarMonthlyDurationBook]
    let excludedBookIDs: Set<Int64>
    let doneMarkerStyle: ReadCalendarDoneMarkerStyle
    let doneEmojiAssetName: String

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            Divider().overlay(accent.opacity(0.3))

            switch type {
            case .yearHeatmap:
                yearHeatmap
            case .monthEvent:
                monthEvent
            case .monthCover:
                monthCover
            }

            Spacer(minLength: Spacing.half)
            footer
        }
        .padding(Spacing.double)
        .frame(width: 360, height: 450, alignment: .topLeading)
        .background(background)
        .foregroundStyle(primaryText)
        .environment(\.colorScheme, isDarkPalette ? .dark : .light)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(type == .yearHeatmap ? "(selectedYear) 阅读日历" : monthTitle)
                    .font(AppTypography.title2)
                Text(type.title)
                    .font(AppTypography.caption)
                    .foregroundStyle(secondaryText)
            }
            Spacer()
            Text("XMNote")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(accent)
        }
    }

    private var footer: some View {
        HStack {
            Text("阅读留下痕迹，时间自有回声")
                .font(AppTypography.caption2)
                .foregroundStyle(secondaryText)
            Spacer()
            Circle().fill(accent).frame(width: 6, height: 6)
        }
    }

    private var monthCover: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            monthMetrics(summary: snapshot.monthData.summary)

            if !hasVisibleMonthActivity {
                emptyCardMessage
            } else {
                monthBookGrid(snapshot.monthData)
            }

            rankingList
        }
    }

    private var monthEvent: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            monthMetrics(summary: snapshot.monthData.summary)
            monthGrid(snapshot.monthData)
            rankingList
        }
    }

    private var yearHeatmap: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.half), count: 3)
        return LazyVGrid(columns: columns, spacing: Spacing.half) {
            ForEach(snapshot.yearMonths, id: \.monthStart) { month in
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text("\(calendar.component(.month, from: month.monthStart))月")
                        .font(AppTypography.caption2)
                        .foregroundStyle(secondaryText)
                    compactMonthGrid(month)
                }
            }
        }
    }

    private func metrics(summary: ReadCalendarMonthSummary) -> some View {
        HStack(spacing: Spacing.double) {
            metric(value: "\(summary.activeDays)", label: "活跃天")
            metric(value: durationText(summary.totalReadSeconds), label: "阅读时长")
            metric(value: "\(summary.noteCount)", label: "书摘")
            metric(value: "\(summary.finishedBookCount)", label: "读完")
        }
    }

    /// 月分享对齐 Android 指标口径：本月书籍、活跃天、读完和书摘。
    private func monthMetrics(summary: ReadCalendarMonthSummary) -> some View {
        HStack(spacing: Spacing.double) {
            metric(value: "\(summary.uniqueReadBookCount)", label: "书籍")
            metric(value: "\(summary.activeDays)", label: "活跃天")
            metric(value: "\(summary.finishedBookCount)", label: "读完")
            metric(value: "\(summary.noteCount)", label: "书摘")
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(value)
                .font(AppTypography.title3Semibold)
                .foregroundStyle(accent)
                .monospacedDigit()
            Text(label)
                .font(AppTypography.caption2)
                .foregroundStyle(secondaryText)
        }
    }

    private var rankingList: some View {
        VStack(spacing: Spacing.half) {
            ForEach(Array(rankingBooks.enumerated()), id: \.element.id) { index, book in
                HStack(spacing: Spacing.half) {
                    Text("\(index + 1)")
                        .font(AppTypography.caption2)
                        .foregroundStyle(secondaryText)
                        .frame(width: 14, alignment: .trailing)
                    Text(book.name)
                        .font(AppTypography.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(durationText(book.readSeconds))
                        .font(AppTypography.caption2)
                        .foregroundStyle(secondaryText)
                        .monospacedDigit()
                }
            }
        }
    }

    private var emptyCardMessage: some View {
        Text("这个月还没有阅读记录")
            .font(AppTypography.body)
            .foregroundStyle(secondaryText)
            .frame(maxWidth: .infinity, minHeight: 110)
    }

    private var hasVisibleMonthActivity: Bool {
        snapshot.monthData.days.values.contains { day in
            day.books.contains { !excludedBookIDs.contains($0.id) }
        }
    }

    /// 月度书单按自然月网格展示每天的活跃书封；排行仍只使用阅读时长，二者口径互不混淆。
    private func monthBookGrid(_ month: ReadCalendarMonthData) -> some View {
        let cells = monthCells(for: month.monthStart)
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.tiny), count: 7)
        return LazyVGrid(columns: columns, spacing: Spacing.tiny) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                if let date {
                    let data = month.days[calendar.startOfDay(for: date)]
                    let books = data?.books.filter { !excludedBookIDs.contains($0.id) } ?? []
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                            .fill(accent.opacity(books.isEmpty ? 0.06 : 0.12))
                        if let book = books.first {
                            XMBookCover.fixedWidth(
                                18,
                                urlString: book.coverURL,
                                border: .init(color: accent.opacity(0.18), width: CardStyle.borderWidth)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                        Text("\(calendar.component(.day, from: date))")
                            .font(AppTypography.caption2)
                            .foregroundStyle(books.isEmpty ? secondaryText : accent)
                            .padding(2)
                        if books.count > 1 {
                            Text("+\(books.count - 1)")
                                .font(AppTypography.caption2)
                                .foregroundStyle(background)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(accent, in: Capsule())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(2)
                        }
                    }
                    .frame(height: 31)
                } else {
                    Color.clear.frame(height: 31)
                }
            }
        }
    }

    private func monthGrid(_ month: ReadCalendarMonthData) -> some View {
        let cells = monthCells(for: month.monthStart)
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.tiny), count: 7)
        return LazyVGrid(columns: columns, spacing: Spacing.tiny) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                if let date {
                    let data = month.days[calendar.startOfDay(for: date)]
                    RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                        .fill(heatColor(data?.heatmapLevel ?? .none))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .topTrailing) {
                            if data?.isReadDoneDay == true {
                                doneMarker(size: 8)
                            }
                        }
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
    }

    private func compactMonthGrid(_ month: ReadCalendarMonthData) -> some View {
        let cells = monthCells(for: month.monthStart)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 1.5), count: 7)
        return LazyVGrid(columns: columns, spacing: 1.5) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                let level = date.flatMap { month.days[calendar.startOfDay(for: $0)]?.heatmapLevel } ?? .none
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(date == nil ? Color.clear : heatColor(level))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    @ViewBuilder
    private func doneMarker(size: CGFloat) -> some View {
        if doneMarkerStyle == .emoji {
            Image(doneEmojiAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(accent)
        }
    }

    private func monthCells(for monthStart: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday + 5) % 7
        var result = Array<Date?>(repeating: nil, count: leading)
        result.append(contentsOf: range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }.map(Optional.some))
        return result
    }

    private func heatColor(_ level: HeatmapLevel) -> Color {
        guard level != .none else { return accent.opacity(0.10) }
        let opacity = 0.25 + Double(level.rawValue) * 0.15
        return accent.opacity(min(opacity, 0.9))
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = max(0, seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h\(minutes % 60)m" : "\(minutes)m"
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: snapshot.selectedMonth)
    }

    private var selectedYear: Int { calendar.component(.year, from: snapshot.selectedMonth) }
    private var background: Color { Color(hex: UInt(template.palette.backgroundARGB & 0x00FF_FFFF)) }
    private var accent: Color { Color(hex: UInt(template.palette.accentARGB & 0x00FF_FFFF)) }
    private var primaryText: Color { isDarkPalette ? Color.white.opacity(0.96) : Color.black.opacity(0.84) }
    private var secondaryText: Color { isDarkPalette ? Color.white.opacity(0.70) : Color.black.opacity(0.56) }

    private var isDarkPalette: Bool {
        let value = template.palette.backgroundARGB
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        return red * 0.299 + green * 0.587 + blue * 0.114 < 128
    }
}
