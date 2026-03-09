import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarContentView.YearSummarySheetData 提供年度汇总数据，依赖 ReadingDurationRankingChart 渲染年度时长排行，依赖可选年份集合与切换回调实现年度切换
 * [OUTPUT]: 对外提供 ReadCalendarYearSummarySheet（年度阅读总结弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，负责年度切换、核心指标同比、年度 Top 榜单与月度分布下钻入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarYearSummarySheet: View {
    private enum Layout {
        static let containerTopInset: CGFloat = 30
        static let containerBottomInset: CGFloat = 28
        static let containerHorizontalInset: CGFloat = 22
        static let sectionSpacing: CGFloat = 16
        static let contentTopInset: CGFloat = Spacing.base
        static let stickyHeaderBottomSpacing: CGFloat = sectionSpacing
        static let yearSwitcherBottomSpacing: CGFloat = 10
        static let headerBottomSpacing: CGFloat = 14
        static let yearSwitcherButtonSize: CGFloat = 32
        static let metricsGridSpacing: CGFloat = 14
        static let metricCardHeight: CGFloat = 62
        static let monthContributionBarHeight: CGFloat = 8
        static let monthContributionBarMinWidthRatio: CGFloat = 0.06
        static let monthContributionSectionTopPadding: CGFloat = 2
        static let monthContributionItemSpacing: CGFloat = Spacing.cozy
        static let monthContributionRowTrailingSpacing: CGFloat = Spacing.half
        static let summaryDurationBarSoftenRatio: CGFloat = 0.50
    }

    /// YearMetricSpec 定义年度总结指标卡的数据结构。
    struct YearMetricSpec: Identifiable {
        /// DeltaTrend 表示年度环比趋势方向。
        enum DeltaTrend {
            case up
            case down
            case flat
        }

        /// DeltaPresentation 定义年度环比展示文案。
        struct DeltaPresentation {
            let text: String
            let trend: DeltaTrend
        }

        let id: String
        let title: String
        let value: String
        let secondaryValue: DeltaPresentation?
        let iconName: String
        let gradientRole: ReadCalendarSummaryGradientRole
    }

    let sheet: ReadCalendarContentView.YearSummarySheetData
    let availableYears: [Int]
    let onSwitchYear: (Int) -> Void
    let onSelectMonth: (Date) -> Void
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    summaryHeader
                    summaryMetricGrid
                }

                summaryTopRanking
                summaryMonthContribution
            }
            .padding(.top, Layout.contentTopInset)
            .padding(.bottom, Layout.containerBottomInset)
            .padding(.horizontal, Layout.containerHorizontalInset)
        }
        // 使用系统 safeAreaBar 承载顶部切换区，滚动时由系统提供备忘录式边缘模糊过渡。
        .safeAreaBar(edge: .top, spacing: Spacing.none) {
            summaryStickyHeader
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(.snappy(duration: 0.24), value: sheet)
    }
}

private extension ReadCalendarYearSummarySheet {
    var summaryStickyHeader: some View {
        VStack(spacing: Spacing.none) {
            summaryYearSwitcher
                .padding(.horizontal, Layout.containerHorizontalInset)
                .padding(.top, Layout.containerTopInset)
                .padding(.bottom, Layout.stickyHeaderBottomSpacing)
        }
    }

    var summaryYearSwitcher: some View {
        let previousYear = adjacentYear(offset: -1)
        let nextYear = adjacentYear(offset: 1)

        return HStack(spacing: Spacing.base) {
            summaryYearSwitchButton(systemName: "chevron.left", isEnabled: previousYear != nil) {
                guard let previousYear else { return }
                onSwitchYear(previousYear)
            }

            Spacer(minLength: 0)

            Text(String(sheet.year))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.24), value: sheet.year)

            Spacer(minLength: 0)

            summaryYearSwitchButton(systemName: "chevron.right", isEnabled: nextYear != nil) {
                guard let nextYear else { return }
                onSwitchYear(nextYear)
            }
        }
        .padding(.bottom, Layout.yearSwitcherBottomSpacing)
    }

    /// 渲染年份切换按钮并处理可点击态样式。
    func summaryYearSwitchButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.textPrimary : Color.textHint.opacity(0.85))
                .frame(width: Layout.yearSwitcherButtonSize, height: Layout.yearSwitcherButtonSize)
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
            summarySubtitleText
                .font(.footnote)
                .contentTransition(.numericText())
                .lineLimit(2)
                .lineSpacing(1)
        }
        .padding(.bottom, Layout.headerBottomSpacing)
    }

    var summarySubtitleText: Text {
        let secondaryColor = Color.textSecondary.opacity(0.9)
        if sheet.isLoading {
            return Text("正在聚合年度数据...").foregroundStyle(secondaryColor)
        }
        if let errorMessage = sheet.errorMessage {
            return Text(errorMessage).foregroundStyle(Color.feedbackWarning)
        }
        if sheet.activeDays == 0 && sheet.totalReadSeconds == 0 {
            return Text("这一年还没有产生阅读记录。").foregroundStyle(secondaryColor)
        }

        guard let activeDaysDelta = sheet.activeDaysDelta,
              let readSecondsDelta = sheet.readSecondsDelta,
              let noteCountDelta = sheet.noteCountDelta else {
            return Text("这是第一段年度记录，慢慢来就好。").foregroundStyle(secondaryColor)
        }

        let activeDelta = deltaPresentation(activeDaysDelta, unit: "天")
        let durationDelta = durationDeltaPresentation(readSecondsDelta)
        let noteDelta = deltaPresentation(noteCountDelta, unit: "条")
        return Text("\(Text("比上年度：").foregroundStyle(secondaryColor))\(Text("阅读天数 ").foregroundStyle(secondaryColor))\(Text(activeDelta.text).foregroundStyle(deltaColor(activeDelta.trend)))\(Text("，时长 ").foregroundStyle(secondaryColor))\(Text(durationDelta.text).foregroundStyle(deltaColor(durationDelta.trend)))\(Text("，书摘 ").foregroundStyle(secondaryColor))\(Text(noteDelta.text).foregroundStyle(deltaColor(noteDelta.trend)))\(Text("。").foregroundStyle(secondaryColor))")
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
                title: "阅读天数",
                value: "\(sheet.activeDays)天",
                secondaryValue: sheet.activeDaysDelta.map { delta in
                    let deltaDisplay = deltaPresentation(delta, unit: "天")
                    return .init(text: "比上年度 \(deltaDisplay.text)", trend: deltaDisplay.trend)
                },
                iconName: "calendar",
                gradientRole: .activity
            ),
            YearMetricSpec(
                id: "readDuration",
                title: "阅读时长",
                value: durationTextAllowZero(sheet.totalReadSeconds),
                secondaryValue: sheet.readSecondsDelta.map { delta in
                    let deltaDisplay = durationDeltaPresentation(delta)
                    return .init(text: "比上年度 \(deltaDisplay.text)", trend: deltaDisplay.trend)
                },
                iconName: "hourglass",
                gradientRole: .momentum
            ),
            YearMetricSpec(
                id: "notes",
                title: "书摘数量",
                value: "\(sheet.noteCount)条",
                secondaryValue: sheet.noteCountDelta.map { delta in
                    let deltaDisplay = deltaPresentation(delta, unit: "条")
                    return .init(text: "比上年度 \(deltaDisplay.text)", trend: deltaDisplay.trend)
                },
                iconName: "text.quote",
                gradientRole: .trend
            ),
            YearMetricSpec(
                id: "finishedBooks",
                title: "完读书籍",
                value: "\(sheet.finishedBookCount)本",
                secondaryValue: nil,
                iconName: "checkmark.seal",
                gradientRole: .completion
            )
        ]
    }

    /// 渲染年度指标卡（图标、主值与环比副文案）。
    func summaryMetricCard(_ metric: YearMetricSpec) -> some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            summaryMetricIcon(systemName: metric.iconName, role: metric.gradientRole)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(metric.title)
                    .font(.caption2)
                    .foregroundStyle(Color.readCalendarSubtleText)
                Text(metric.value)
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
        .padding(.vertical, Spacing.cozy)
        .frame(maxWidth: .infinity, minHeight: Layout.metricCardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.contentBackground.opacity(0.97))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                // 二级指标卡降低描边存在感，保留层级同时不压过数据本身。
                .stroke(Color.surfaceBorderDefault.opacity(0.84), lineWidth: CardStyle.borderWidth)
        }
    }

    /// 返回年度指标图标渐变色阶。
    func summaryGradientStops(for role: ReadCalendarSummaryGradientRole) -> [Gradient.Stop] {
        let spec = Color.readCalendarSummaryGradientSpec(for: role)
        let opacity: CGFloat = colorScheme == .dark ? 0.96 : 1.0
        return [
            .init(color: spec.start.opacity(opacity), location: 0),
            .init(color: spec.mid.opacity(opacity), location: 0.52),
            .init(color: spec.end.opacity(opacity), location: 1)
        ]
    }

    /// 渲染年度指标图标底板与符号。
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

    var summaryTopRanking: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if let errorMessage = sheet.errorMessage {
                ReadCalendarInlineErrorBanner(message: errorMessage, onRetry: onRetry)
            }

            ReadingDurationRankingChart(
                title: "年度阅读时长 Top",
                insightText: Text(topRankingInsightText).foregroundStyle(Color.textSecondary),
                emptyText: "这一年还没有阅读时长排行",
                items: topRankingItems,
                animationIdentity: topRankingAnimationIdentity,
                onBookTap: nil
            )

            if sheet.isLoading {
                HStack(spacing: Spacing.half) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在整理年度 Top...")
                        .font(.footnote)
                        .foregroundStyle(Color.textHint)
                }
            }
        }
        // 年度 Top 区域同样裁切过渡帧，保证月/年排行动画边界表现一致。
        .clipped()
    }

    var topRankingInsightText: String {
        if sheet.isLoading {
            return "正在汇总年度阅读排行..."
        }
        if sheet.topBooks.isEmpty {
            return "这一年还没有形成阅读时长排行"
        }
        return "这一年读得最久的 \(sheet.topBooks.count) 本书"
    }

    var topRankingItems: [ReadingDurationRankingChart.Item] {
        sheet.topBooks.map { book in
            // 年度 TOP 与月度总结统一：优先使用封面取色，pending 态显示占位，失败态使用仓储回退色。
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

    var topRankingAnimationIdentity: String {
        let signature = sheet.topBooks
            .map { "\($0.bookId):\($0.readSeconds)" }
            .joined(separator: ",")
        return "year-\(sheet.year)-\(signature)-\(sheet.totalReadSeconds)"
    }

    /// 返回年度排行条颜色与状态（占位/已解析/回退）。
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

    /// 对年度排行条色做柔化，提升长列表可读性。
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

    var summaryMonthContribution: some View {
        VStack(alignment: .leading, spacing: Layout.monthContributionItemSpacing) {
            Text("月度阅读分布")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            if sheet.monthContributions.isEmpty {
                Text("暂无月度阅读分布数据")
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

    /// 渲染年度月贡献行，展示活跃天数与时长占比。
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

                Text("阅读 \(month.activeDays) 天")
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

    /// 根据偏移量返回可切换的相邻年份。
    func adjacentYear(offset: Int) -> Int? {
        let targetYear = sheet.year + offset
        return availableYears.contains(targetYear) ? targetYear : nil
    }

    /// 把年度环比整数转换为展示文案与趋势。
    func deltaPresentation(_ delta: Int, unit: String) -> YearMetricSpec.DeltaPresentation {
        if delta > 0 { return .init(text: "+\(delta)\(unit)", trend: .up) }
        if delta < 0 { return .init(text: "-\(abs(delta))\(unit)", trend: .down) }
        return .init(text: "持平", trend: .flat)
    }

    /// 把年度时长环比秒数转换为展示文案与趋势。
    func durationDeltaPresentation(_ delta: Int) -> YearMetricSpec.DeltaPresentation {
        if delta > 0 { return .init(text: "+\(durationTextAllowZero(delta))", trend: .up) }
        if delta < 0 { return .init(text: "-\(durationTextAllowZero(abs(delta)))", trend: .down) }
        return .init(text: "持平", trend: .flat)
    }

    /// 根据趋势返回年度环比文案颜色。
    func deltaColor(_ trend: YearMetricSpec.DeltaTrend) -> Color {
        switch trend {
        case .up:
            return Color.feedbackSuccess
        case .down:
            return Color.feedbackWarning
        case .flat:
            return Color.textSecondary
        }
    }

    /// 计算单月时长在年度峰值中的占比。
    func monthContributionRatio(_ value: Int, maxReadSeconds: Int) -> CGFloat {
        guard maxReadSeconds > 0, value > 0 else { return 0 }
        return min(1, max(0, CGFloat(value) / CGFloat(maxReadSeconds)))
    }

    /// 格式化月贡献列表中的月份标签。
    func monthLabel(_ date: Date) -> String {
        let month = Calendar.current.component(.month, from: date)
        return "\(month)月"
    }

    /// 把秒数格式化为允许 0 值的时长文案。
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
