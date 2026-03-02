import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarContentView.MonthSummarySheetData 提供月度汇总数据，依赖 DesignTokens 提供视觉语义
 * [OUTPUT]: 对外提供 ReadCalendarMonthSummarySheet（月度阅读总结弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，负责月份切换、指标卡片与阅读时长排行展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarMonthSummarySheet: View {
    private enum Layout {
        static let summarySheetTopInset: CGFloat = 30
        static let summarySheetBottomInset: CGFloat = 28
        static let summarySheetHorizontalInset: CGFloat = 22
        static let summarySheetSectionSpacing: CGFloat = 16
        static let summarySheetMonthSwitcherBottomSpacing: CGFloat = 10
        static let summarySheetHeaderBottomSpacing: CGFloat = 14
        static let summaryMonthSwitcherButtonSize: CGFloat = 32
        static let summaryMetricsGridSpacing: CGFloat = 14
        static let summaryMetricCardHeight: CGFloat = 62
        static let summaryDurationBarSoftenRatio: CGFloat = 0.50
    }

    struct SummaryMetricSpec: Identifiable {
        enum DeltaTrend {
            case up
            case down
            case flat
        }

        struct DeltaPresentation {
            let text: String
            let trend: DeltaTrend
        }

        let id: String
        let title: String
        let primaryValue: String
        let secondaryValue: DeltaPresentation?
        let icon: String
        let gradientRole: ReadCalendarSummaryGradientRole
    }

    struct SummaryDurationInsight {
        let prefix: String
        let delta: SummaryMetricSpec.DeltaPresentation?
        let suffix: String
    }

    enum MonthFeedbackState {
        case empty
        case partial
        case active
    }

    enum MonthPhase {
        case early
        case middle
        case late
        case history
    }

    let sheet: ReadCalendarContentView.MonthSummarySheetData
    let availableMonths: [Date]
    let onSwitchMonth: (Date) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Layout.summarySheetSectionSpacing) {
                VStack(alignment: .leading, spacing: Layout.summarySheetSectionSpacing) {
                    summaryMonthSwitcher
                    summaryHeader
                    summaryMetricsGrid
                }
                .padding(.horizontal, Layout.summarySheetHorizontalInset)

                summaryDurationRanking
            }
            .padding(.top, Layout.summarySheetTopInset)
            .padding(.bottom, Layout.summarySheetBottomInset)
        }
        .background(
            LinearGradient(
                colors: [
                    Color.readCalendarSelectionFill.opacity(0.32),
                    Color.bgSheet
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .animation(.snappy(duration: 0.24), value: sheet)
    }
}

private extension ReadCalendarMonthSummarySheet {
    var summaryMonthSwitcher: some View {
        let previousMonth = adjacentMonth(offset: -1)
        let nextMonth = adjacentMonth(offset: 1)

        return HStack(spacing: Spacing.base) {
            summaryMonthSwitchButton(systemName: "chevron.left", isEnabled: previousMonth != nil) {
                guard let previousMonth else { return }
                onSwitchMonth(previousMonth)
            }

            Spacer(minLength: 0)

            Text(summaryMonthTitle(sheet.monthStart))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.24), value: sheet.monthStart)

            Spacer(minLength: 0)

            summaryMonthSwitchButton(systemName: "chevron.right", isEnabled: nextMonth != nil) {
                guard let nextMonth else { return }
                onSwitchMonth(nextMonth)
            }
        }
        .padding(.bottom, Layout.summarySheetMonthSwitcherBottomSpacing)
    }

    func summaryMonthSwitchButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.textPrimary : Color.textHint.opacity(0.85))
                .frame(width: Layout.summaryMonthSwitcherButtonSize, height: Layout.summaryMonthSwitcherButtonSize)
                .background(
                    Circle()
                        .fill(Color.contentBackground.opacity(isEnabled ? 0.96 : 0.72))
                )
                .overlay {
                    Circle()
                        .stroke(Color.cardBorder.opacity(0.8), lineWidth: CardStyle.borderWidth)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    var summaryHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("阅读总结")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            summaryHeaderSubtitleText
                .font(.footnote)
                .contentTransition(.numericText())
                .lineLimit(2)
                .lineSpacing(1)
        }
        .padding(.bottom, Layout.summarySheetHeaderBottomSpacing)
    }

    var summaryHeaderSubtitleText: Text {
        let state = monthFeedbackState
        let secondaryColor = Color.textSecondary.opacity(0.9)
        guard state != .empty else {
            return Text(emptyHeaderSubtitle).foregroundStyle(secondaryColor)
        }

        guard let activeDaysDelta = sheet.activeDaysDelta,
              let readSecondsDelta = sheet.readSecondsDelta,
              let noteCountDelta = sheet.noteCountDelta else {
            return Text("这是第一段月度记录，慢慢来就好。")
                .foregroundStyle(secondaryColor)
        }

        let activeDelta = deltaPresentation(activeDaysDelta, unit: "天")
        let durationDelta = durationDeltaPresentation(readSecondsDelta)
        let noteDelta = deltaPresentation(noteCountDelta, unit: "条")
        return Text("\(Text("比上个月：").foregroundStyle(secondaryColor))\(Text("阅读天数 ").foregroundStyle(secondaryColor))\(Text(activeDelta.text).foregroundStyle(deltaColor(activeDelta.trend)))\(Text("，时长 ").foregroundStyle(secondaryColor))\(Text(durationDelta.text).foregroundStyle(deltaColor(durationDelta.trend)))\(Text("，书摘 ").foregroundStyle(secondaryColor))\(Text(noteDelta.text).foregroundStyle(deltaColor(noteDelta.trend)))\(Text("。").foregroundStyle(secondaryColor))")
    }

    var summaryMetricsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Layout.summaryMetricsGridSpacing),
            GridItem(.flexible(), spacing: Layout.summaryMetricsGridSpacing)
        ]
        return LazyVGrid(columns: columns, spacing: Layout.summaryMetricsGridSpacing) {
            ForEach(summaryMetrics) { metric in
                summaryMetricCard(metric)
            }
        }
    }

    var summaryMetrics: [SummaryMetricSpec] {
        let isEmptyState = monthFeedbackState == .empty
        return [
            SummaryMetricSpec(
                id: "activeDays",
                title: "阅读天数",
                primaryValue: isEmptyState ? "--" : "\(sheet.activeDays)天",
                secondaryValue: isEmptyState ? nil : sheet.activeDaysDelta.map { delta in
                    let deltaDisplay = deltaPresentation(delta, unit: "天")
                    return .init(text: "比上个月 \(deltaDisplay.text)", trend: deltaDisplay.trend)
                },
                icon: "calendar",
                gradientRole: .activity
            ),
            SummaryMetricSpec(
                id: "streak",
                title: "最长连续",
                primaryValue: isEmptyState ? "--" : "\(sheet.longestStreak)天",
                secondaryValue: nil,
                icon: "flame",
                gradientRole: .momentum
            ),
            SummaryMetricSpec(
                id: "booksRead",
                title: "本月阅读书籍",
                primaryValue: isEmptyState ? "--" : "\(sheet.monthSummary.uniqueReadBookCount)本",
                secondaryValue: nil,
                icon: "books.vertical",
                gradientRole: .completion
            ),
            SummaryMetricSpec(
                id: "booksFinished",
                title: "本月读完书籍",
                primaryValue: isEmptyState ? "--" : "\(sheet.monthSummary.finishedBookCount)本",
                secondaryValue: nil,
                icon: "checkmark.seal",
                gradientRole: .completion
            ),
            SummaryMetricSpec(
                id: "notes",
                title: "书摘记录",
                primaryValue: isEmptyState ? "--" : "\(sheet.monthSummary.noteCount)条",
                secondaryValue: isEmptyState ? nil : sheet.noteCountDelta.map { delta in
                    let deltaDisplay = deltaPresentation(delta, unit: "条")
                    return .init(text: "比上个月 \(deltaDisplay.text)", trend: deltaDisplay.trend)
                },
                icon: "text.quote",
                gradientRole: .trend
            ),
            SummaryMetricSpec(
                id: "timeSlot",
                title: "主要阅读时段",
                primaryValue: summaryTimeSlotText,
                secondaryValue: nil,
                icon: "clock",
                gradientRole: .momentum
            )
        ]
    }

    var summaryTimeSlotText: String {
        guard monthFeedbackState != .empty else { return "--" }
        guard let slot = sheet.peakTimeSlot,
              let ratio = sheet.peakTimeSlotRatio else {
            return "时段还没形成"
        }
        return "\(timeSlotTitle(slot)) · \(ratio)%"
    }

    func timeSlotTitle(_ slot: ReadCalendarTimeSlot) -> String {
        switch slot {
        case .morning:
            return "早晨"
        case .afternoon:
            return "下午"
        case .evening:
            return "晚上"
        case .lateNight:
            return "深夜"
        }
    }

    func summaryMetricCard(_ metric: SummaryMetricSpec) -> some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            summaryMetricIcon(systemName: metric.icon, role: metric.gradientRole)

            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .font(.caption2)
                    .foregroundStyle(Color.readCalendarSubtleText)
                Text(metric.primaryValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                if let secondaryValue = metric.secondaryValue {
                    Text(secondaryValue.text)
                        .font(.caption2)
                        .foregroundStyle(deltaColor(secondaryValue.trend))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: Layout.summaryMetricCardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.contentBackground.opacity(0.97))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        }
    }

    func summaryGradientStops(for role: ReadCalendarSummaryGradientRole) -> [Gradient.Stop] {
        let spec = Color.readCalendarSummaryGradientSpec(for: role)
        let opacity: CGFloat = colorScheme == .dark ? 0.96 : 1.0
        return [
            .init(color: spec.start.opacity(opacity), location: 0),
            .init(color: spec.mid.opacity(opacity), location: 0.52),
            .init(color: spec.end.opacity(opacity), location: 1)
        ]
    }

    func summaryMetricIcon(systemName: String, role: ReadCalendarSummaryGradientRole) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: summaryGradientStops(for: role)),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 24, height: 24)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.96))
            }
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: Color.black.opacity(0.10), radius: 1.2, x: 0, y: 0.8)
    }

    var summaryDurationRanking: some View {
        ReadingDurationRankingChart(
            title: "阅读时长",
            insightText: summaryDurationInsightText(summaryDurationInsight),
            emptyText: "这个月还没有阅读时长。",
            items: readingDurationRankingItems,
            onBookTap: nil
        )
        .padding(.horizontal, Layout.summarySheetHorizontalInset)
    }

    var readingDurationRankingItems: [ReadingDurationRankingChart.Item] {
        sheet.durationTopBooks.map { book in
            let bar = summaryDurationBarPresentation(bookId: book.bookId)
            return ReadingDurationRankingChart.Item(
                id: book.bookId,
                title: book.name,
                coverURL: book.coverURL,
                durationSeconds: book.readSeconds,
                barTint: bar.color,
                barState: bar.state
            )
        }
    }

    var summaryDurationInsight: SummaryDurationInsight {
        if monthFeedbackState == .empty {
            if hasMeaningfulPreviousMonthRecord {
                return .init(prefix: "上个月读得很稳，这个月慢一点也没关系。", delta: nil, suffix: "")
            }
            switch monthPhase {
            case .early:
                return .init(prefix: "这个月刚开始，随时可以翻开第一页。", delta: nil, suffix: "")
            case .middle:
                return .init(prefix: "这月还没开读，今晚读十分钟也很好。", delta: nil, suffix: "")
            case .late:
                return .init(prefix: "这个月先休整，下个月再把节奏找回来。", delta: nil, suffix: "")
            case .history:
                return .init(prefix: "这个月没有留下阅读记录。", delta: nil, suffix: "")
            }
        }

        guard sheet.monthSummary.totalReadSeconds > 0 else {
            return .init(prefix: "这个月还没有阅读时长。", delta: nil, suffix: "")
        }

        let total = summaryDurationText(sheet.monthSummary.totalReadSeconds)
        let prefix = "本月累计 \(total)"
        guard let readSecondsDelta = sheet.readSecondsDelta else {
            return .init(prefix: "\(prefix)。", delta: nil, suffix: " 看看这个月你读得最多的几本书。")
        }
        let delta = durationDeltaPresentation(readSecondsDelta)
        return .init(prefix: "\(prefix)，比上个月 ", delta: delta, suffix: "。")
    }

    func summaryDurationInsightText(_ insight: SummaryDurationInsight) -> Text {
        let baseStyle = Text(insight.prefix)
            .foregroundStyle(Color.textSecondary)
        guard let delta = insight.delta else {
            return Text("\(baseStyle)\(Text(insight.suffix).foregroundStyle(Color.textSecondary))")
        }
        return Text("\(baseStyle)\(Text(delta.text).foregroundStyle(deltaColor(delta.trend)))\(Text(insight.suffix).foregroundStyle(Color.textSecondary))")
    }

    func deltaPresentation(_ delta: Int, unit: String) -> SummaryMetricSpec.DeltaPresentation {
        if delta > 0 { return .init(text: "+\(delta)\(unit)", trend: .up) }
        if delta < 0 { return .init(text: "-\(abs(delta))\(unit)", trend: .down) }
        return .init(text: "持平", trend: .flat)
    }

    func durationDeltaPresentation(_ delta: Int) -> SummaryMetricSpec.DeltaPresentation {
        if delta > 0 { return .init(text: "+\(summaryDurationTextAllowZero(delta))", trend: .up) }
        if delta < 0 { return .init(text: "-\(summaryDurationTextAllowZero(abs(delta)))", trend: .down) }
        return .init(text: "持平", trend: .flat)
    }

    func deltaColor(_ trend: SummaryMetricSpec.DeltaTrend) -> Color {
        switch trend {
        case .up:
            return Color.feedbackSuccess
        case .down:
            return Color.feedbackWarning
        case .flat:
            return Color.textSecondary
        }
    }

    func summaryDurationBarPresentation(bookId: Int64) -> (
        color: Color,
        state: ReadingDurationRankingChart.Item.BarState
    ) {
        guard let color = sheet.rankingBarColorsByBookId[bookId] else {
            return (summaryDurationPendingBarColor, .placeholder)
        }
        switch color.state {
        case .pending:
            return (summaryDurationPendingBarColor, .placeholder)
        case .resolved:
            return (softenedSummaryBarColor(from: color), .resolved)
        case .failed:
            return (softenedSummaryBarColor(from: color), .fallback)
        }
    }

    var summaryDurationPendingBarColor: Color {
        Color.readCalendarEventPendingBase
    }

    func softenedSummaryBarColor(from color: ReadCalendarSegmentColor) -> Color {
        let red = CGFloat((color.backgroundRGBAHex >> 24) & 0xFF) / 255
        let green = CGFloat((color.backgroundRGBAHex >> 16) & 0xFF) / 255
        let blue = CGFloat((color.backgroundRGBAHex >> 8) & 0xFF) / 255
        let alpha = CGFloat(color.backgroundRGBAHex & 0xFF) / 255
        let soften = Layout.summaryDurationBarSoftenRatio
        return Color(
            red: red + (1 - red) * soften,
            green: green + (1 - green) * soften,
            blue: blue + (1 - blue) * soften,
            opacity: alpha
        )
    }

    func summaryDurationText(_ readSeconds: Int) -> String {
        let hours = readSeconds / 3600
        let minutes = (readSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时"
        }
        if minutes > 0 {
            return "\(minutes)分"
        }
        return "\(max(1, readSeconds))秒"
    }

    func summaryDurationTextAllowZero(_ readSeconds: Int) -> String {
        guard readSeconds > 0 else { return "0分" }
        let hours = readSeconds / 3600
        let minutes = (readSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时"
        }
        if minutes > 0 {
            return "\(minutes)分"
        }
        return "\(readSeconds)秒"
    }

    var monthFeedbackState: MonthFeedbackState {
        if isMonthCompletelyEmpty { return .empty }
        let summary = sheet.monthSummary
        let hasPartialSignal = sheet.activeDays == 0
            || sheet.longestStreak == 0
            || summary.totalReadSeconds == 0
            || summary.uniqueReadBookCount == 0
            || summary.noteCount == 0
        return hasPartialSignal ? .partial : .active
    }

    var isMonthCompletelyEmpty: Bool {
        !sheet.hasActivity
            && sheet.monthSummary.totalReadSeconds == 0
            && sheet.monthSummary.noteCount == 0
            && sheet.monthSummary.finishedBookCount == 0
            && sheet.monthSummary.uniqueReadBookCount == 0
    }

    var monthPhase: MonthPhase {
        let cal = Calendar.current
        let now = Date()
        let nowDayStart = cal.startOfDay(for: now)
        let components = cal.dateComponents([.year, .month], from: nowDayStart)
        let currentMonthStart = cal.date(from: DateComponents(year: components.year, month: components.month, day: 1))
            .map { cal.startOfDay(for: $0) } ?? nowDayStart
        guard cal.isDate(sheet.monthStart, inSameDayAs: currentMonthStart) else { return .history }
        let day = cal.component(.day, from: now)
        if day <= 7 { return .early }
        if day <= 21 { return .middle }
        return .late
    }

    var hasMeaningfulPreviousMonthRecord: Bool {
        guard let activeDaysDelta = sheet.activeDaysDelta,
              let readSecondsDelta = sheet.readSecondsDelta,
              let noteCountDelta = sheet.noteCountDelta else {
            return false
        }
        let previousActiveDays = max(0, sheet.activeDays - activeDaysDelta)
        let previousReadSeconds = max(0, sheet.monthSummary.totalReadSeconds - readSecondsDelta)
        let previousNoteCount = max(0, sheet.monthSummary.noteCount - noteCountDelta)
        return previousActiveDays > 0 || previousReadSeconds > 0 || previousNoteCount > 0
    }

    var emptyHeaderSubtitle: String {
        if hasMeaningfulPreviousMonthRecord {
            return "上个月读得很稳，这个月慢一点也没关系。"
        }
        switch monthPhase {
        case .early:
            return "这个月刚开始，随时可以翻开第一页。"
        case .middle:
            return "这月还没开读，今晚读十分钟也很好。"
        case .late:
            return "这个月先休整，下个月再把节奏找回来。"
        case .history:
            return "这个月没有留下阅读记录。"
        }
    }

    func adjacentMonth(offset: Int) -> Date? {
        guard let index = availableMonths.firstIndex(of: sheet.monthStart) else { return nil }
        let target = index + offset
        guard availableMonths.indices.contains(target) else { return nil }
        return availableMonths[target]
    }

    func summaryMonthTitle(_ date: Date) -> String {
        SummaryFormatter.monthTitle.string(from: date)
    }
}

private enum SummaryFormatter {
    static let monthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        formatter.timeZone = .current
        return formatter
    }()
}
