import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarContentView.MonthSummarySheetData 提供月度汇总数据，依赖 DesignTokens 提供视觉语义
 * [OUTPUT]: 对外提供 ReadCalendarMonthSummarySheet（月度阅读总结弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，负责月份切换、指标卡片与阅读时长排行展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 月度总结弹层，负责聚合月份切换、指标卡和阅读时长排行展示。
struct ReadCalendarMonthSummarySheet: View {
    private enum Layout {
        static let summarySheetTopInset: CGFloat = 30
        static let summarySheetBottomInset: CGFloat = 28
        static let summarySheetHorizontalInset: CGFloat = 22
        static let summarySheetSectionSpacing: CGFloat = 16
        static let summaryContentTopInset: CGFloat = Spacing.base
        static let summaryStickyHeaderBottomSpacing: CGFloat = summarySheetSectionSpacing
        static let summarySheetMonthSwitcherBottomSpacing: CGFloat = 10
        static let summarySheetHeaderBottomSpacing: CGFloat = 14
        static let summaryMonthSwitcherButtonSize: CGFloat = 32
        static let summaryMetricsGridSpacing: CGFloat = 14
        static let summaryMetricCardHeight: CGFloat = 62
        static let summaryDurationBarSoftenRatio: CGFloat = 0.50
        static let summaryDurationRankingLoadingFallbackMinHeight: CGFloat = 136
        static let summaryDurationRankingTransitionDuration: CGFloat = 0.22
        static let summaryDurationRankingLoadingDelay: Duration = .milliseconds(180)
        static let summaryDurationSkeletonDefaultRows: [CGFloat] = [1, 0.74, 0.52]
        static let summaryDurationSkeletonMinimumRowCount: Int = 3
        static let summaryDurationSkeletonSectionSpacing: CGFloat = 16
        static let summaryDurationSkeletonHeaderHeight: CGFloat = 30
        static let summaryDurationSkeletonHeaderTitleWidthRatio: CGFloat = 0.26
        static let summaryDurationSkeletonHeaderInsightWidthRatio: CGFloat = 0.72
        static let summaryDurationSkeletonHeaderTitleMinWidth: CGFloat = 74
        static let summaryDurationSkeletonHeaderInsightMinWidth: CGFloat = 144
        static let summaryDurationSkeletonHeaderTitleMaxWidth: CGFloat = 96
        static let summaryDurationSkeletonHeaderInsightMaxWidth: CGFloat = 260
        static let summaryDurationSkeletonRowHeight: CGFloat = 56
        static let summaryDurationSkeletonBarHeight: CGFloat = 48
        static let summaryDurationSkeletonBarCornerRadius: CGFloat = CornerRadius.inlaySmall
        static let summaryDurationSkeletonBarLabelSpacing: CGFloat = 0
        static let summaryDurationSkeletonRowSpacing: CGFloat = Spacing.cozy
        static let summaryDurationSkeletonCoverHeight: CGFloat = summaryDurationSkeletonBarHeight
        static let summaryDurationSkeletonCoverWidth: CGFloat = summaryDurationSkeletonCoverHeight * 24 / 34
        static let summaryDurationSkeletonCoverLeadingCompensation: CGFloat = summaryDurationSkeletonBarCornerRadius * 0.55
        static let summaryDurationSkeletonInfoBaseRatio: CGFloat = 0.40
        static let summaryDurationSkeletonInfoAdaptiveBonusRatio: CGFloat = 0.38
        static let summaryDurationSkeletonInfoMaxWidth: CGFloat = 320
        static let summaryDurationSkeletonInfoMinReadableWidth: CGFloat = 118
        static let summaryDurationSkeletonTitleLineHeight: CGFloat = 14
        static let summaryDurationSkeletonSubtitleLineHeight: CGFloat = 10
        static let summaryDurationSkeletonBookTitleHeight: CGFloat = 11
        static let summaryDurationSkeletonDurationHeight: CGFloat = 8
        static let summaryDurationSkeletonLineSpacing: CGFloat = 4
        static let summaryDurationSkeletonMinBarRatio: CGFloat = 0.16
        static let summaryDurationFallbackHintTopSpacing: CGFloat = 2
        static let summaryDurationShimmerDuration: CGFloat = 1.05
        static let summaryDurationShimmerRotation: CGFloat = 16
        static let summaryDurationShimmerBandWidthRatio: CGFloat = 0.56
        static let summaryDurationShimmerMinBandWidth: CGFloat = 100
    }

    /// SummaryMetricSpec 定义月总结指标卡的数据结构。
    struct SummaryMetricSpec: Identifiable {
        /// DeltaTrend 表示环比趋势方向（上升/下降/持平）。
        enum DeltaTrend {
            case up
            case down
            case flat
        }

        /// DeltaPresentation 定义环比文案和趋势。
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

    /// SummaryDurationInsight 定义阅读时长洞察文案结构。
    struct SummaryDurationInsight {
        let prefix: String
        let delta: SummaryMetricSpec.DeltaPresentation?
        let suffix: String
    }

    /// MonthFeedbackState 表示月度反馈状态（空/部分/活跃）。
    enum MonthFeedbackState {
        case empty
        case partial
        case active
    }

    /// MonthPhase 表示当前月份所处阶段（前期/中期/后期/历史）。
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isRankingLoadingVisible = false
    @State private var rankingLoadingVisibilityTask: Task<Void, Never>?
    @State private var loadingShimmerPhase: CGFloat = -1

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Layout.summarySheetSectionSpacing) {
                VStack(alignment: .leading, spacing: Layout.summarySheetSectionSpacing) {
                    summaryHeader
                    summaryMetricsGrid
                }
                .padding(.horizontal, Layout.summarySheetHorizontalInset)

                summaryDurationRanking
            }
            .padding(.top, Layout.summaryContentTopInset)
            .padding(.bottom, Layout.summarySheetBottomInset)
        }
        // 使用系统 safeAreaBar 承载顶部切换区，滚动时由系统提供备忘录式边缘模糊过渡。
        .safeAreaBar(edge: .top, spacing: Spacing.none) {
            summaryStickyHeader
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(.snappy(duration: 0.24), value: sheet)
        .onAppear {
            syncRankingLoadingVisibility(isReady: isDurationRankingReady)
        }
        .onChange(of: isDurationRankingReady) { _, isReady in
            syncRankingLoadingVisibility(isReady: isReady)
        }
        .onChange(of: isRankingLoadingVisible) { _, isVisible in
            if isVisible {
                startLoadingShimmerIfNeeded()
            } else {
                stopLoadingShimmer()
            }
        }
        .onChange(of: accessibilityReduceMotion) { _, _ in
            startLoadingShimmerIfNeeded()
        }
        .onDisappear {
            rankingLoadingVisibilityTask?.cancel()
            rankingLoadingVisibilityTask = nil
            stopLoadingShimmer()
        }
    }
}

private extension ReadCalendarMonthSummarySheet {
    var summaryStickyHeader: some View {
        VStack(spacing: Spacing.none) {
            summaryMonthSwitcher
                .padding(.horizontal, Layout.summarySheetHorizontalInset)
                .padding(.top, Layout.summarySheetTopInset)
                .padding(.bottom, Layout.summaryStickyHeaderBottomSpacing)
        }
    }

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

    /// 渲染月份切换按钮并处理可点击态样式。
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
                        .fill(isEnabled ? Color.surfaceNested : Color.controlFillSecondary)
                )
                .overlay {
                    Circle()
                        .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
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

    /// 将阅读时段枚举转换为中文标题。
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

    /// 渲染月总结指标卡（图标、主值与环比副文案）。
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
        .padding(.vertical, Spacing.cozy)
        .frame(maxWidth: .infinity, minHeight: Layout.summaryMetricCardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceNested)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                // 二级指标卡降低描边存在感，保留层级同时不压过数据本身。
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    /// 根据指标角色返回图标底板渐变色阶。
    func summaryGradientStops(for role: ReadCalendarSummaryGradientRole) -> [Gradient.Stop] {
        let spec = Color.readCalendarSummaryGradientSpec(for: role)
        let opacity: CGFloat = colorScheme == .dark ? 0.96 : 1.0
        return [
            .init(color: spec.start.opacity(opacity), location: 0),
            .init(color: spec.mid.opacity(opacity), location: 0.52),
            .init(color: spec.end.opacity(opacity), location: 1)
        ]
    }

    /// 渲染指标卡左侧图标底板与符号。
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
        Group {
            if isDurationRankingReady {
                summaryDurationRankingContent
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else if isRankingLoadingVisible {
                summaryDurationRankingLoading
                    .transition(.opacity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: summaryDurationRankingLoadingPlaceholderHeight)
            }
        }
        .animation(.smooth(duration: Layout.summaryDurationRankingTransitionDuration), value: isDurationRankingReady)
        .animation(.smooth(duration: Layout.summaryDurationRankingTransitionDuration), value: isRankingLoadingVisible)
        // 约束月份总结排行区的过渡位移范围，避免 transition 帧外溢到组件外。
        .clipped()
        .padding(.horizontal, Layout.summarySheetHorizontalInset)
    }

    var summaryDurationRankingContent: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ReadingDurationRankingChart(
                title: "阅读时长",
                insightText: summaryDurationInsightText(summaryDurationInsight),
                emptyText: "这个月还没有阅读时长。",
                items: readingDurationRankingItems,
                animationIdentity: summaryDurationRankingAnimationIdentity,
                onBookTap: nil
            )

            if sheet.hasDurationRankingFallback {
                Text("网络不稳定，已使用默认配色")
                    .font(.caption2)
                    .foregroundStyle(Color.textHint)
                    .padding(.top, Layout.summaryDurationFallbackHintTopSpacing)
            }
        }
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

    var isDurationRankingReady: Bool {
        guard !sheet.durationTopBooks.isEmpty else { return true }
        return !sheet.durationTopBooks.contains { book in
            guard let color = sheet.rankingBarColorsByBookId[book.bookId] else { return true }
            return color.state == .pending
        }
    }

    var summaryDurationRankingAnimationIdentity: String {
        let monthStamp = Int64(sheet.monthStart.timeIntervalSince1970)
        let bookIDs = sheet.durationTopBooks.map { String($0.bookId) }.joined(separator: ",")
        return "\(monthStamp)|\(bookIDs)"
    }

    var summaryDurationRankingLoading: some View {
        ZStack(alignment: .topLeading) {
            summaryDurationSkeletonContent(fillColor: summaryDurationSkeletonBaseColor)
            summaryDurationSkeletonContent(fillColor: summaryDurationSkeletonHighlightColor)
                .mask(summaryDurationShimmerOverlay)
                .opacity(accessibilityReduceMotion ? 0 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: summaryDurationRankingLoadingPlaceholderHeight, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 渲染时长排行骨架屏整体结构。
    @ViewBuilder
    /// 组合骨架屏头部与多行排行占位，复用到基础层与高光层。
    func summaryDurationSkeletonContent(fillColor: Color) -> some View {
        VStack(alignment: .leading, spacing: Layout.summaryDurationSkeletonSectionSpacing) {
            summaryDurationSkeletonHeader(fillColor: fillColor)

            LazyVStack(spacing: Layout.summaryDurationSkeletonRowSpacing) {
                ForEach(Array(summaryDurationSkeletonRowRatios.enumerated()), id: \.offset) { _, ratio in
                    summaryDurationSkeletonRow(widthRatio: ratio, fillColor: fillColor)
                }
            }
        }
    }

    /// 渲染排行骨架屏头部占位。
    @ViewBuilder
    /// 渲染排行骨架屏头部占位，模拟标题与洞察文案的版式比例。
    func summaryDurationSkeletonHeader(fillColor: Color) -> some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let titleWidth = max(
                Layout.summaryDurationSkeletonHeaderTitleMinWidth,
                min(width * Layout.summaryDurationSkeletonHeaderTitleWidthRatio, Layout.summaryDurationSkeletonHeaderTitleMaxWidth)
            )
            let subtitleWidth = max(
                Layout.summaryDurationSkeletonHeaderInsightMinWidth,
                min(width * Layout.summaryDurationSkeletonHeaderInsightWidthRatio, Layout.summaryDurationSkeletonHeaderInsightMaxWidth)
            )

            VStack(alignment: .leading, spacing: Spacing.half) {
                RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                    .fill(fillColor)
                    .frame(width: titleWidth, height: Layout.summaryDurationSkeletonTitleLineHeight)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(fillColor.opacity(0.90))
                    .frame(width: subtitleWidth, height: Layout.summaryDurationSkeletonSubtitleLineHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Layout.summaryDurationSkeletonHeaderHeight)
    }

    /// 渲染排行骨架屏单行占位条。
    @ViewBuilder
    /// 渲染单行书籍排行骨架，根据宽度比例模拟条形图长度差异。
    func summaryDurationSkeletonRow(widthRatio: CGFloat, fillColor: Color) -> some View {
        let normalizedRatio = min(1, max(Layout.summaryDurationSkeletonMinBarRatio, widthRatio))
        GeometryReader { proxy in
            let rowWidth = max(0, proxy.size.width)
            let infoWidth = summaryDurationSkeletonInfoWidth(rowWidth: rowWidth, displayedRatio: normalizedRatio)
            let barAvailableWidth = max(0, rowWidth - infoWidth - Layout.summaryDurationSkeletonBarLabelSpacing)
            let barWidth = max(0, min(barAvailableWidth, barAvailableWidth * normalizedRatio))
            let infoOffsetX = min(
                max(0, barWidth + Layout.summaryDurationSkeletonBarLabelSpacing - Layout.summaryDurationSkeletonCoverLeadingCompensation),
                max(0, rowWidth - infoWidth)
            )

            ZStack(alignment: .leading) {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: Layout.summaryDurationSkeletonBarCornerRadius,
                        bottomLeading: Layout.summaryDurationSkeletonBarCornerRadius,
                        bottomTrailing: CornerRadius.none,
                        topTrailing: CornerRadius.none
                    ),
                    style: .continuous
                )
                .fill(fillColor)
                .frame(width: barWidth, height: Layout.summaryDurationSkeletonBarHeight)

                summaryDurationSkeletonInfo(width: infoWidth, fillColor: fillColor)
                    .offset(x: infoOffsetX)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Layout.summaryDurationSkeletonRowHeight)
    }

    /// 渲染骨架行内封面与文本占位区。
    func summaryDurationSkeletonInfo(width: CGFloat, fillColor: Color) -> some View {
        let textAreaWidth = max(0, width - Layout.summaryDurationSkeletonCoverWidth - Spacing.half)
        let titleWidth = max(42, textAreaWidth * 0.58)
        let durationWidth = max(32, titleWidth * 0.42)

        return HStack(spacing: Spacing.half) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(fillColor)
                .frame(
                    width: Layout.summaryDurationSkeletonCoverWidth,
                    height: Layout.summaryDurationSkeletonCoverHeight
                )

            VStack(alignment: .leading, spacing: Layout.summaryDurationSkeletonLineSpacing) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(fillColor)
                    .frame(width: titleWidth, height: Layout.summaryDurationSkeletonBookTitleHeight)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(fillColor.opacity(0.90))
                    .frame(width: durationWidth, height: Layout.summaryDurationSkeletonDurationHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
    }

    /// 按行宽和条形比例计算骨架信息区宽度。
    func summaryDurationSkeletonInfoWidth(rowWidth: CGFloat, displayedRatio: CGFloat) -> CGFloat {
        let normalizedRatio = min(1, max(0, displayedRatio))
        let adaptiveRatio = Layout.summaryDurationSkeletonInfoBaseRatio
            + (1 - normalizedRatio) * Layout.summaryDurationSkeletonInfoAdaptiveBonusRatio
        let adaptiveWidth = rowWidth * adaptiveRatio
        let cappedWidth = min(Layout.summaryDurationSkeletonInfoMaxWidth, adaptiveWidth)
        let readableFloor = min(Layout.summaryDurationSkeletonInfoMinReadableWidth, rowWidth)
        return min(rowWidth, max(readableFloor, cappedWidth))
    }

    var summaryDurationSkeletonBaseColor: Color {
        let opacity: CGFloat = colorScheme == .dark ? 0.48 : 0.34
        return Color.readCalendarEventPendingBase.opacity(opacity)
    }

    var summaryDurationSkeletonHighlightColor: Color {
        let opacity: CGFloat = colorScheme == .dark ? 0.34 : 0.58
        return Color.white.opacity(opacity)
    }

    var summaryDurationSkeletonRowRatios: [CGFloat] {
        let minCount = Layout.summaryDurationSkeletonMinimumRowCount
        guard !sheet.durationTopBooks.isEmpty else {
            return Array(Layout.summaryDurationSkeletonDefaultRows.prefix(minCount))
        }

        let maxReadSeconds = max(1, sheet.durationTopBooks.map(\.readSeconds).max() ?? 1)
        var ratios = sheet.durationTopBooks.map { book in
            let raw = CGFloat(book.readSeconds) / CGFloat(maxReadSeconds)
            return min(1, max(Layout.summaryDurationSkeletonMinBarRatio, raw))
        }

        if ratios.count < minCount {
            var fallbackIndex = 0
            while ratios.count < minCount {
                let fallback = Layout.summaryDurationSkeletonDefaultRows[
                    min(fallbackIndex, Layout.summaryDurationSkeletonDefaultRows.count - 1)
                ]
                ratios.append(fallback)
                fallbackIndex += 1
            }
        }
        return ratios
    }

    var summaryDurationRankingLoadingPlaceholderHeight: CGFloat {
        let rowCount = summaryDurationSkeletonRowRatios.count
        let rowsHeight = CGFloat(rowCount) * Layout.summaryDurationSkeletonRowHeight
        let rowsSpacing = CGFloat(max(0, rowCount - 1)) * Layout.summaryDurationSkeletonRowSpacing
        let skeletonHeight = Layout.summaryDurationSkeletonHeaderHeight
            + Layout.summaryDurationSkeletonSectionSpacing
            + rowsHeight
            + rowsSpacing
        return max(Layout.summaryDurationRankingLoadingFallbackMinHeight, skeletonHeight)
    }

    var summaryDurationShimmerOverlay: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let shimmerWidth = max(width * Layout.summaryDurationShimmerBandWidthRatio, Layout.summaryDurationShimmerMinBandWidth)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.5),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: shimmerWidth)
            .rotationEffect(.degrees(Layout.summaryDurationShimmerRotation))
            .offset(x: loadingShimmerPhase * (width + shimmerWidth))
        }
        .opacity(accessibilityReduceMotion ? 0 : 1)
        .allowsHitTesting(false)
    }

    /// 根据排行数据是否就绪，控制骨架加载态的显隐时机。
    func syncRankingLoadingVisibility(isReady: Bool) {
        rankingLoadingVisibilityTask?.cancel()
        rankingLoadingVisibilityTask = nil

        guard !isReady else {
            withAnimation(.smooth(duration: 0.16)) {
                isRankingLoadingVisible = false
            }
            return
        }

        isRankingLoadingVisible = false
        stopLoadingShimmer()

        rankingLoadingVisibilityTask = Task {
            try? await Task.sleep(for: Layout.summaryDurationRankingLoadingDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isDurationRankingReady else { return }
                withAnimation(.smooth(duration: 0.16)) {
                    isRankingLoadingVisible = true
                }
            }
        }
    }

    /// 当骨架可见且允许动画时，启动排行骨架 shimmer 动效。
    func startLoadingShimmerIfNeeded() {
        guard isRankingLoadingVisible else {
            stopLoadingShimmer()
            return
        }
        guard !accessibilityReduceMotion else {
            stopLoadingShimmer()
            return
        }
        loadingShimmerPhase = -1
        withAnimation(.linear(duration: Layout.summaryDurationShimmerDuration).repeatForever(autoreverses: false)) {
            loadingShimmerPhase = 1
        }
    }

    /// 停止排行骨架 shimmer 动效并重置相位。
    func stopLoadingShimmer() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            loadingShimmerPhase = -1
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

    /// 将时长洞察结构拼装为带趋势着色的 Text。
    func summaryDurationInsightText(_ insight: SummaryDurationInsight) -> Text {
        let baseStyle = Text(insight.prefix)
            .foregroundStyle(Color.textSecondary)
        guard let delta = insight.delta else {
            return Text("\(baseStyle)\(Text(insight.suffix).foregroundStyle(Color.textSecondary))")
        }
        return Text("\(baseStyle)\(Text(delta.text).foregroundStyle(deltaColor(delta.trend)))\(Text(insight.suffix).foregroundStyle(Color.textSecondary))")
    }

    /// 把整数环比转换为“增减/持平”展示文案。
    func deltaPresentation(_ delta: Int, unit: String) -> SummaryMetricSpec.DeltaPresentation {
        if delta > 0 { return .init(text: "+\(delta)\(unit)", trend: .up) }
        if delta < 0 { return .init(text: "-\(abs(delta))\(unit)", trend: .down) }
        return .init(text: "持平", trend: .flat)
    }

    /// 把时长环比秒数转换为展示文案与趋势。
    func durationDeltaPresentation(_ delta: Int) -> SummaryMetricSpec.DeltaPresentation {
        if delta > 0 { return .init(text: "+\(summaryDurationTextAllowZero(delta))", trend: .up) }
        if delta < 0 { return .init(text: "-\(summaryDurationTextAllowZero(abs(delta)))", trend: .down) }
        return .init(text: "持平", trend: .flat)
    }

    /// 根据趋势返回环比文案颜色。
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

    /// 返回排行条颜色与状态（占位/已解析/回退）。
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

    /// 对封面提取色做柔化处理，避免条形色过于刺眼。
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

    /// 把阅读秒数格式化为“小时/分钟/秒”文案。
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

    /// 把秒数格式化为可显示 0 的时长文案。
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

    /// 根据偏移量返回可切换的相邻月份。
    func adjacentMonth(offset: Int) -> Date? {
        guard let index = availableMonths.firstIndex(of: sheet.monthStart) else { return nil }
        let target = index + offset
        guard availableMonths.indices.contains(target) else { return nil }
        return availableMonths[target]
    }

    /// 格式化月总结标题文本。
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
