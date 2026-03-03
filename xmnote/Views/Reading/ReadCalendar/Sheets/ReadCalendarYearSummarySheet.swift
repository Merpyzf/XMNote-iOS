import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarContentView.YearSummarySheetData 提供年度汇总数据，依赖 ReadingDurationRankingChart 渲染年度时长排行
 * [OUTPUT]: 对外提供 ReadCalendarYearSummarySheet（年度阅读总结弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，负责年度核心指标、年度 Top 榜单与月份贡献下钻入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarYearSummarySheet: View {
    private enum Layout {
        static let containerTopInset: CGFloat = 30
        static let containerBottomInset: CGFloat = 28
        static let containerHorizontalInset: CGFloat = 22
        static let sectionSpacing: CGFloat = 16
        static let metricsGridSpacing: CGFloat = 12
        static let metricCardHeight: CGFloat = 78
        static let monthContributionBarHeight: CGFloat = 8
        static let monthContributionBarMinWidthRatio: CGFloat = 0.06
        static let monthContributionSectionTopPadding: CGFloat = 2
        static let monthContributionItemSpacing: CGFloat = Spacing.cozy
        static let monthContributionRowTrailingSpacing: CGFloat = Spacing.half
    }

    struct YearMetricSpec: Identifiable {
        let id: String
        let title: String
        let value: String
        let iconName: String
        let gradientRole: ReadCalendarSummaryGradientRole
    }

    let sheet: ReadCalendarContentView.YearSummarySheetData
    let onSelectMonth: (Date) -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                summaryHeader
                summaryMetricGrid
                summaryTopRanking
                summaryMonthContribution
            }
            .padding(.top, Layout.containerTopInset)
            .padding(.bottom, Layout.containerBottomInset)
            .padding(.horizontal, Layout.containerHorizontalInset)
        }
        .background(
            LinearGradient(
                colors: [
                    Color.readCalendarSelectionFill.opacity(0.34),
                    Color.bgSheet
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}

private extension ReadCalendarYearSummarySheet {
    var summaryHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("\(sheet.year) 年阅读总结")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()

            Text(summarySubtitle)
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .lineSpacing(1)
                .contentTransition(.numericText())
        }
    }

    var summarySubtitle: String {
        if sheet.isLoading {
            return "正在聚合年度数据..."
        }
        if let errorMessage = sheet.errorMessage {
            return errorMessage
        }
        if sheet.activeDays == 0 && sheet.totalReadSeconds == 0 {
            return "这一年还没有产生阅读记录。"
        }
        return "共阅读 \(durationTextAllowZero(sheet.totalReadSeconds))，活跃 \(sheet.activeDays) 天。"
    }

    var summaryMetricGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Layout.metricsGridSpacing),
            GridItem(.flexible(), spacing: Layout.metricsGridSpacing)
        ]

        return LazyVGrid(columns: columns, spacing: Layout.metricsGridSpacing) {
            ForEach(summaryMetrics) { metric in
                summaryMetricCard(metric)
            }
        }
    }

    var summaryMetrics: [YearMetricSpec] {
        [
            YearMetricSpec(
                id: "activeDays",
                title: "活跃天数",
                value: "\(sheet.activeDays) 天",
                iconName: "calendar.badge.clock",
                gradientRole: .activity
            ),
            YearMetricSpec(
                id: "readDuration",
                title: "阅读时长",
                value: durationTextAllowZero(sheet.totalReadSeconds),
                iconName: "hourglass",
                gradientRole: .momentum
            ),
            YearMetricSpec(
                id: "notes",
                title: "书摘数量",
                value: "\(sheet.noteCount) 条",
                iconName: "note.text",
                gradientRole: .trend
            ),
            YearMetricSpec(
                id: "finishedBooks",
                title: "完读书籍",
                value: "\(sheet.finishedBookCount) 本",
                iconName: "checkmark.seal",
                gradientRole: .completion
            )
        ]
    }

    func summaryMetricCard(_ metric: YearMetricSpec) -> some View {
        let gradient = Color.readCalendarSummaryGradientSpec(for: metric.gradientRole)
        return HStack(alignment: .center, spacing: Spacing.cozy) {
            Image(systemName: metric.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [gradient.start, gradient.end],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    gradient.start.opacity(0.24),
                                    gradient.end.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Text(metric.value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.base)
        .frame(maxWidth: .infinity, minHeight: Layout.metricCardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(Color.contentBackground.opacity(0.97))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.cardBorder.opacity(0.82), lineWidth: CardStyle.borderWidth)
        }
    }

    var summaryTopRanking: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if let errorMessage = sheet.errorMessage {
                ReadCalendarInlineErrorBanner(message: errorMessage, onRetry: onRetry)
            }

            ReadingDurationRankingChart(
                title: "年度阅读时长 Top",
                insightText: Text(topRankingInsightText).foregroundStyle(Color.textSecondary),
                emptyText: "暂无阅读时长排行",
                items: topRankingItems,
                animationIdentity: topRankingAnimationIdentity,
                onBookTap: nil
            )

            if sheet.isLoading {
                HStack(spacing: Spacing.half) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在计算年度 Top...")
                        .font(.footnote)
                        .foregroundStyle(Color.textHint)
                }
            }
        }
    }

    var topRankingInsightText: String {
        if sheet.topBooks.isEmpty {
            return "按自然年聚合阅读时长"
        }
        return "按自然年精确聚合，共 \(sheet.topBooks.count) 本"
    }

    var topRankingItems: [ReadingDurationRankingChart.Item] {
        sheet.topBooks.map { book in
            ReadingDurationRankingChart.Item(
                id: book.bookId,
                title: book.name,
                coverURL: book.coverURL,
                durationSeconds: book.readSeconds,
                barTint: softenedTopBarTint(for: book.bookId),
                barState: .fallback
            )
        }
    }

    var topRankingAnimationIdentity: String {
        let signature = sheet.topBooks
            .map { "\($0.bookId):\($0.readSeconds)" }
            .joined(separator: ",")
        return "year-\(sheet.year)-\(signature)-\(sheet.totalReadSeconds)"
    }

    func softenedTopBarTint(for bookId: Int64) -> Color {
        let palette = Color.readCalendarEventPalette
        guard !palette.isEmpty else { return Color.readCalendarEventPendingBase.opacity(0.9) }
        let index = Int(UInt64(bitPattern: bookId) % UInt64(palette.count))
        return palette[index].opacity(0.92)
    }

    var summaryMonthContribution: some View {
        VStack(alignment: .leading, spacing: Layout.monthContributionItemSpacing) {
            Text("12 个月贡献")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            if sheet.monthContributions.isEmpty {
                Text("暂无月份贡献数据")
                    .font(.footnote)
                    .foregroundStyle(Color.textHint)
            } else {
                let maxReadSeconds = max(1, sheet.monthContributions.map(\.totalReadSeconds).max() ?? 1)
                ForEach(sheet.monthContributions) { month in
                    Button {
                        onSelectMonth(month.monthStart)
                    } label: {
                        monthContributionRow(month, maxReadSeconds: maxReadSeconds)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, Layout.monthContributionSectionTopPadding)
    }

    func monthContributionRow(
        _ month: ReadCalendarContentView.YearSummaryMonthContribution,
        maxReadSeconds: Int
    ) -> some View {
        let ratio = monthContributionRatio(month.totalReadSeconds, maxReadSeconds: maxReadSeconds)
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .center, spacing: Spacing.cozy) {
                Text(monthLabel(month.monthStart))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 34, alignment: .leading)
                    .monospacedDigit()

                Text("活跃 \(month.activeDays) 天")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(durationTextAllowZero(month.totalReadSeconds))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textHint)
                    .padding(.leading, Layout.monthContributionRowTrailingSpacing)
            }

            GeometryReader { proxy in
                let width = max(0, proxy.size.width)
                let barWidth = max(
                    width * Layout.monthContributionBarMinWidthRatio,
                    width * ratio
                )

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.readCalendarEventPendingBase.opacity(0.32))
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.brandLight, Color.brand],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: barWidth)
                }
            }
            .frame(height: Layout.monthContributionBarHeight)
        }
        .padding(.vertical, Spacing.compact)
        .contentShape(Rectangle())
    }

    func monthContributionRatio(_ value: Int, maxReadSeconds: Int) -> CGFloat {
        guard maxReadSeconds > 0, value > 0 else { return 0 }
        return min(1, max(0, CGFloat(value) / CGFloat(maxReadSeconds)))
    }

    func monthLabel(_ date: Date) -> String {
        let month = Calendar.current.component(.month, from: date)
        return "\(month)月"
    }

    func durationTextAllowZero(_ readSeconds: Int) -> String {
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
}
