import SwiftUI

/**
 * [INPUT]: 依赖 YearSummarySheetData、SummaryFilterState、年度排行与月份贡献树图组件
 * [OUTPUT]: 对外提供 ReadCalendarYearSummarySheet（年度阅读总结弹层）
 * [POS]: ReadCalendar 业务 Sheet，负责年度切换、四项指标、年度阅读时长排行与月份分布下钻
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 年度总结弹层直接消费领域层的同期比较结果，并根据日历设置隐藏对应指标。
struct ReadCalendarYearSummarySheet: View {
    private enum Layout {
        static let topInset: CGFloat = 30
        static let bottomInset: CGFloat = 28
        static let horizontalInset: CGFloat = 22
        static let sectionSpacing: CGFloat = 20
        static let switcherButtonSize: CGFloat = 32
    }

    let sheet: ReadCalendarContentView.YearSummarySheetData
    let availableYears: [Int]
    let filterState: ReadCalendarContentView.SummaryFilterState
    let onSwitchYear: (Int) -> Void
    let onSelectMonth: (Date) -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                ReadCalendarSummaryMetricSection(
                    metrics: summaryMetrics,
                    isLoading: isInitialLoading
                )

                if let errorMessage = sheet.errorMessage {
                    XMInlineStatusBanner(
                        errorMessage,
                        tone: .warning,
                        action: XMStateAction("重试", systemImage: "arrow.clockwise", perform: onRetry)
                    )
                }

                annualRanking

                ReadCalendarMonthContributionTreemap(
                    items: treemapItems,
                    onMonthTap: onSelectMonth
                )
                .redacted(reason: isInitialLoading ? .placeholder : [])
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, Spacing.base)
            .padding(.bottom, Layout.bottomInset)
        }
        .safeAreaBar(edge: .top, spacing: Spacing.none) {
            yearSwitcher
                .padding(.horizontal, Layout.horizontalInset)
                .padding(.top, Layout.topInset)
                .padding(.bottom, Spacing.base)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(.snappy(duration: 0.24), value: sheet)
    }
}

private extension ReadCalendarYearSummarySheet {
    var yearSwitcher: some View {
        let previousYear = adjacentYear(offset: -1)
        let nextYear = adjacentYear(offset: 1)

        return HStack(spacing: Spacing.base) {
            yearSwitchButton(systemName: "chevron.left", isEnabled: previousYear != nil) {
                guard let previousYear else { return }
                onSwitchYear(previousYear)
            }

            Spacer(minLength: 0)

            Text(String(sheet.year))
                .font(AppTypography.title3Semibold)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 0)

            yearSwitchButton(systemName: "chevron.right", isEnabled: nextYear != nil) {
                guard let nextYear else { return }
                onSwitchYear(nextYear)
            }
        }
    }

    /// 渲染年份切换按钮，保留系统按钮语义和禁用状态。
    func yearSwitchButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(isEnabled ? Color.textPrimary : Color.textHint.opacity(0.85))
                .frame(width: Layout.switcherButtonSize, height: Layout.switcherButtonSize)
                .background(isEnabled ? Color.surfaceNested : Color.controlFillSecondary, in: Circle())
                .overlay {
                    Circle().stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    var summaryMetrics: [ReadCalendarSummaryMetric] {
        [
            .init(
                id: "activeDays",
                title: "阅读天数",
                icon: "calendar",
                gradientRole: .activity,
                value: sheet.activeDays > 0 ? .quantity(sheet.activeDays, unit: "天") : .text("未开始"),
                delta: sheet.activeDaysDelta.map { .make(prefix: comparisonLabel, delta: $0, unit: "天") }
            ),
            .init(
                id: "readDuration",
                title: "阅读时长",
                icon: "hourglass",
                gradientRole: .momentum,
                value: annualDurationValue,
                delta: annualDurationDelta
            ),
            .init(
                id: "notes",
                title: "书摘数量",
                icon: "text.quote",
                gradientRole: .trend,
                value: hiddenCountValue(isHidden: filterState.excludeNote, count: sheet.noteCount, unit: "条"),
                delta: filterState.excludeNote ? nil : sheet.noteCountDelta.map {
                    .make(prefix: comparisonLabel, delta: $0, unit: "条")
                }
            ),
            .init(
                id: "finishedBooks",
                title: "完读书籍",
                icon: "checkmark.seal",
                gradientRole: .completion,
                value: hiddenCountValue(isHidden: filterState.excludeReadDone, count: sheet.finishedBookCount, unit: "本"),
                delta: nil
            )
        ]
    }

    var annualDurationValue: ReadCalendarSummaryValue {
        guard !filterState.excludeReadTime else { return .text("已按日历设置隐藏") }
        guard sheet.totalReadSeconds > 0 else { return .text("暂无") }
        return .init(parts: durationParts(sheet.totalReadSeconds), accessibilityLabel: durationText(sheet.totalReadSeconds))
    }

    var annualDurationDelta: ReadCalendarSummaryDelta? {
        guard !filterState.excludeReadTime, let delta = sheet.readSecondsDelta else { return nil }
        if delta == 0 {
            return .init(
                prefix: comparisonLabel,
                parts: [],
                trailingText: "持平",
                trend: .flat,
                accessibilityLabel: "\(comparisonLabel)持平"
            )
        }
        return .init(
            prefix: comparisonLabel,
            parts: signedDurationParts(delta),
            trailingText: nil,
            trend: delta > 0 ? .up : .down,
            accessibilityLabel: "\(comparisonLabel)\(delta > 0 ? "增加" : "减少")\(durationText(abs(delta)))"
        )
    }

    /// 设置关闭时展示明确隐藏文案，否则输出数量或年度空态。
    func hiddenCountValue(isHidden: Bool, count: Int, unit: String) -> ReadCalendarSummaryValue {
        if isHidden { return .text("已按日历设置隐藏") }
        return count > 0 ? .quantity(count, unit: unit) : .text("暂无")
    }

    var annualRanking: some View {
        ReadingDurationRankingChart(
            title: "年度阅读时长",
            insight: rankingInsight,
            emptyText: rankingEmptyText,
            items: rankingItems,
            animationIdentity: "year-\(sheet.year)-\(rankingItems.count)-\(sheet.totalReadSeconds)",
            onBookTap: nil
        )
        .redacted(reason: isInitialLoading ? .placeholder : [])
        .clipped()
    }

    var rankingInsight: ReadingDurationRankingChart.Insight? {
        if isInitialLoading {
            return .init(label: nil, content: Text("正在整理年度排行"), accessibilityLabel: "正在整理年度排行")
        }
        if filterState.excludeReadTime {
            return .init(
                label: nil,
                content: Text("已按日历设置隐藏").foregroundStyle(Color.textSecondary),
                accessibilityLabel: "年度阅读时长已按日历设置隐藏"
            )
        }
        if sheet.topBooks.isEmpty {
            return .init(
                label: nil,
                content: Text("暂无阅读时长排行").foregroundStyle(Color.textSecondary),
                accessibilityLabel: "暂无阅读时长排行"
            )
        }
        let message = "读得最久的 \(sheet.topBooks.count) 本书"
        return .init(
            label: nil,
            content: Text(message).foregroundStyle(Color.textSecondary),
            accessibilityLabel: message
        )
    }

    var rankingEmptyText: String? {
        nil
    }

    var rankingItems: [ReadingDurationRankingChart.Item] {
        if filterState.excludeReadTime { return [] }
        if isInitialLoading {
            return [
                loadingRankingItem(id: -11, seconds: 7200),
                loadingRankingItem(id: -12, seconds: 4800),
                loadingRankingItem(id: -13, seconds: 2400)
            ]
        }
        return sheet.topBooks.map { book in
            let bar = durationBarPresentation(bookId: book.bookId)
            return .init(
                id: book.bookId,
                title: book.name,
                coverURL: book.coverURL,
                durationSeconds: book.readSeconds,
                barTint: bar.color,
                barState: bar.state
            )
        }
    }

    /// 创建年度排行最终结构的加载占位行。
    func loadingRankingItem(id: Int64, seconds: Int) -> ReadingDurationRankingChart.Item {
        .init(
            id: id,
            title: "阅读书籍",
            coverURL: "",
            durationSeconds: seconds,
            barTint: .readCalendarEventPendingBase,
            barState: .placeholder
        )
    }

    var treemapItems: [ReadCalendarMonthContributionTreemap.Item] {
        if isInitialLoading {
            return loadingTreemapItems
        }
        return sheet.monthContributions.map {
            .init(
                monthStart: $0.monthStart,
                activeDays: $0.activeDays,
                totalReadSeconds: $0.totalReadSeconds
            )
        }
    }

    var loadingTreemapItems: [ReadCalendarMonthContributionTreemap.Item] {
        let calendar = Calendar.current
        return [5_400, 3_600, 1_800].enumerated().compactMap { index, seconds in
            guard let date = calendar.date(from: DateComponents(year: sheet.year, month: index + 1, day: 1)) else {
                return nil
            }
            return .init(monthStart: date, activeDays: 6 - index, totalReadSeconds: seconds)
        }
    }

    /// 返回年度排行条颜色与解析状态。
    func durationBarPresentation(bookId: Int64) -> (
        color: Color,
        state: ReadingDurationRankingChart.Item.BarState
    ) {
        guard let color = sheet.rankingBarColorsByBookId[bookId] else {
            return (.readCalendarEventPendingBase, .placeholder)
        }
        switch color.state {
        case .pending:
            return (.readCalendarEventPendingBase, .placeholder)
        case .resolved:
            return (softenedBarColor(from: color), .resolved)
        case .failed:
            return (softenedBarColor(from: color), .fallback)
        }
    }

    /// 柔化封面提取色，避免年度长条过饱和。
    func softenedBarColor(from color: ReadCalendarSegmentColor) -> Color {
        let red = CGFloat((color.backgroundRGBAHex >> 24) & 0xFF) / 255
        let green = CGFloat((color.backgroundRGBAHex >> 16) & 0xFF) / 255
        let blue = CGFloat((color.backgroundRGBAHex >> 8) & 0xFF) / 255
        let alpha = CGFloat(color.backgroundRGBAHex & 0xFF) / 255
        let soften: CGFloat = 0.5
        return Color(
            red: red + (1 - red) * soften,
            green: green + (1 - green) * soften,
            blue: blue + (1 - blue) * soften,
            opacity: alpha
        )
    }

    var isInitialLoading: Bool {
        sheet.isLoading
            && sheet.activeDays == 0
            && sheet.totalReadSeconds == 0
            && sheet.noteCount == 0
            && sheet.finishedBookCount == 0
            && sheet.monthContributions.isEmpty
    }

    var comparisonLabel: String {
        sheet.year == Calendar.current.component(.year, from: Date()) ? "较上年同期" : "较上年"
    }

    /// 将秒数拆成数字和单位片段，供指标主值与环比共用。
    func durationParts(_ seconds: Int) -> [ReadCalendarSummaryValue.Part] {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            var parts: [ReadCalendarSummaryValue.Part] = [
                .init(text: String(hours), role: .number),
                .init(text: "小时", role: .unit)
            ]
            if minutes > 0 {
                parts.append(.init(text: String(minutes), role: .number))
                parts.append(.init(text: "分", role: .unit))
            }
            return parts
        }
        if minutes > 0 {
            return [.init(text: String(minutes), role: .number), .init(text: "分", role: .unit)]
        }
        return [.init(text: String(max(1, seconds)), role: .number), .init(text: "秒", role: .unit)]
    }

    /// 在第一个时长数字前附加趋势符号，单位仍保持次级色。
    func signedDurationParts(_ delta: Int) -> [ReadCalendarSummaryValue.Part] {
        var parts = durationParts(abs(delta))
        guard let firstNumberIndex = parts.firstIndex(where: { $0.role == .number }) else { return parts }
        let first = parts[firstNumberIndex]
        let sign = delta > 0 ? "+" : "−"
        parts[firstNumberIndex] = .init(text: "\(sign)\(first.text)", role: .number)
        return parts
    }

    /// 格式化完整时长，供 VoiceOver 使用。
    func durationText(_ seconds: Int) -> String {
        durationParts(seconds).map(\.text).joined()
    }

    /// 根据偏移量返回可切换的相邻年份。
    func adjacentYear(offset: Int) -> Int? {
        let targetYear = sheet.year + offset
        return availableYears.contains(targetYear) ? targetYear : nil
    }
}
