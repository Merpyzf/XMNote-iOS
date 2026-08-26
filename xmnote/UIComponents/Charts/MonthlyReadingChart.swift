import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 SwiftUI、UIKit 文本测量、DesignTokens 的排版/间距/圆角语义，并接收月份数据、展开月份集合与外部配色
 * [OUTPUT]: 对外提供 MonthlyReadingChart、MonthlyReadingChartStyle 及月份/每日稳定输入模型
 * [POS]: UIComponents/Charts 跨模块复用组件，1:1 承载 Android 月度阅读统计条的展开、收起、文本排版与联动缩放
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 月度阅读图表的局部排版 owner，确保 SwiftUI 渲染字体与 UIKit 宽高测量使用同一来源。
private enum MonthlyReadingChartTypography {
    static let collapsedSummary: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        minimumPointSize: 12
    )
    static let expandedSummary: Font = AppTypography.fixed(
        baseSize: 10.8,
        relativeTo: .caption2,
        minimumPointSize: 10.8
    )
    static let arrow: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .caption,
        minimumPointSize: 14
    )
    static let dailyDate: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        minimumPointSize: 12
    )
    static let dailyDuration: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        weight: .medium,
        minimumPointSize: 12
    )

    static let uiCollapsedSummary: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        minimumPointSize: 12
    )
    static let uiExpandedSummary: UIFont = AppTypography.uiFixed(
        baseSize: 10.8,
        textStyle: .caption2,
        minimumPointSize: 10.8
    )
    static let uiDailyDate: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        minimumPointSize: 12
    )
    static let uiDailyDuration: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        weight: .medium,
        minimumPointSize: 12
    )
}

extension EnvironmentValues {
    /// 调试与预览可强制覆盖系统 Reduce Motion，生产调用默认继续跟随系统设置。
    @Entry var monthlyReadingChartReduceMotionOverride: Bool? = nil
}

/// 月度阅读图表以月份摘要为入口，在原位展开每日阅读时长条并支持多月份同时展开。
struct MonthlyReadingChart: View {
    /// 月份稳定标识，使用自然年月避免数据刷新时丢失展开状态。
    struct MonthID: Hashable, Sendable {
        let year: Int
        let month: Int
    }

    /// 单个月份的不可变展示数据，摘要由调用方按业务规则生成。
    struct Month: Identifiable, Equatable, Sendable {
        let id: MonthID
        let summaryText: String
        let days: [Day]

        var totalDurationSeconds: Int64 {
            days.reduce(into: Int64.zero) { total, day in
                total += max(0, day.durationSeconds)
            }
        }
    }

    /// 单日阅读时长输入，稳定 ID 用于在数据替换和动画中保持视图身份。
    struct Day: Identifiable, Equatable, Sendable {
        let id: Int64
        let dateText: String
        let durationSeconds: Int64
    }

    let months: [Month]
    @Binding var expandedMonthIDs: Set<MonthID>
    let style: MonthlyReadingChartStyle

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.monthlyReadingChartReduceMotionOverride) private var reduceMotionOverride

    /// 注入不可变月份数据、可写展开集合与页面主题样式。
    init(
        months: [Month],
        expandedMonthIDs: Binding<Set<MonthID>>,
        style: MonthlyReadingChartStyle
    ) {
        self.months = months
        self._expandedMonthIDs = expandedMonthIDs
        self.style = style
    }

    var body: some View {
        let shouldReduceMotion = reduceMotionOverride ?? accessibilityReduceMotion
        let metrics = MonthlyReadingChartMetrics(months: months)
        let maximumMonthDuration = maximumMonthDuration
        let maximumExpandedDayDuration = maximumExpandedDayDuration

        VStack(spacing: Spacing.none) {
            ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                MonthlyReadingMonthSection(
                    month: month,
                    expandedMonthIDs: $expandedMonthIDs,
                    style: style,
                    headerHeight: metrics.headerHeight,
                    minimumHeaderWidth: metrics.minimumHeaderWidth,
                    dailyRowHeight: metrics.dailyRowHeight,
                    minimumDailyWidth: metrics.minimumDailyWidth(for: month),
                    maximumMonthDuration: maximumMonthDuration,
                    maximumExpandedDayDuration: maximumExpandedDayDuration,
                    accessibilityReduceMotion: shouldReduceMotion
                )

                if index < months.count - 1 {
                    Spacer(minLength: MonthlyReadingChartLayout.barsSpacing)
                        .frame(height: MonthlyReadingChartLayout.barsSpacing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

private extension MonthlyReadingChart {
    var maximumMonthDuration: Int64 {
        let hasExpandedMonth = months.contains { expandedMonthIDs.contains($0.id) }
        guard !hasExpandedMonth else { return 0 }
        return months.map(\.totalDurationSeconds).max() ?? 0
    }

    var maximumExpandedDayDuration: Int64 {
        months
            .filter { expandedMonthIDs.contains($0.id) }
            .flatMap(\.days)
            .map { max(0, $0.durationSeconds) }
            .max() ?? 0
    }
}

/// 月度图表的视觉注入参数，调用方负责把封面主题色转换为组件所需色阶。
struct MonthlyReadingChartStyle {
    let monthTrackColor: Color
    let monthBarColors: [Color]
    let collapsedSummaryColor: Color
    let expandedSummaryColor: Color
    let collapsedArrowColor: Color
    let expandedArrowColor: Color
    let dailyBarColors: [Color]
    let dailyDateColor: Color
    let dailyDurationColor: Color

    /// 创建不包含业务取色逻辑的月度图表样式。
    init(
        monthTrackColor: Color,
        monthBarColors: [Color],
        collapsedSummaryColor: Color,
        expandedSummaryColor: Color,
        collapsedArrowColor: Color,
        expandedArrowColor: Color,
        dailyBarColors: [Color],
        dailyDateColor: Color,
        dailyDurationColor: Color
    ) {
        self.monthTrackColor = monthTrackColor
        self.monthBarColors = monthBarColors
        self.collapsedSummaryColor = collapsedSummaryColor
        self.expandedSummaryColor = expandedSummaryColor
        self.collapsedArrowColor = collapsedArrowColor
        self.expandedArrowColor = expandedArrowColor
        self.dailyBarColors = dailyBarColors
        self.dailyDateColor = dailyDateColor
        self.dailyDurationColor = dailyDurationColor
    }
}

/// 单个月份区块负责头部状态、每日内容裁切以及 50ms 柱体启动门闩。
private struct MonthlyReadingMonthSection: View {
    let month: MonthlyReadingChart.Month
    @Binding var expandedMonthIDs: Set<MonthlyReadingChart.MonthID>
    let style: MonthlyReadingChartStyle
    let headerHeight: CGFloat
    let minimumHeaderWidth: CGFloat
    let dailyRowHeight: CGFloat
    let minimumDailyWidth: CGFloat
    let maximumMonthDuration: Int64
    let maximumExpandedDayDuration: Int64
    let accessibilityReduceMotion: Bool

    @State private var barDurationsByDayID: [Int64: Int64] = [:]
    @State private var barAnimationTask: Task<Void, Never>?

    private var isExpanded: Bool {
        expandedMonthIDs.contains(month.id)
    }

    private var dailyContentHeight: CGFloat {
        MonthlyReadingChartMetrics.dailyContentHeight(
            dayCount: month.days.count,
            rowHeight: dailyRowHeight
        )
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            MonthlyReadingMonthHeader(
                summaryText: month.summaryText,
                isExpanded: isExpanded,
                totalDuration: month.totalDurationSeconds,
                maximumDuration: maximumMonthDuration,
                minimumBarWidth: minimumHeaderWidth,
                height: headerHeight,
                style: style,
                accessibilityReduceMotion: accessibilityReduceMotion,
                onToggle: toggleExpansion
            )

            MonthlyReadingDailyGroup(
                days: month.days,
                barDurationsByDayID: barDurationsByDayID,
                rowHeight: dailyRowHeight,
                minimumBarWidth: minimumDailyWidth,
                maximumDuration: maximumExpandedDayDuration,
                style: style,
                accessibilityReduceMotion: accessibilityReduceMotion
            )
            .frame(height: dailyContentHeight, alignment: .topLeading)
            .monthlyReadingVisibilityLayout(
                progress: isExpanded ? 1 : 0,
                fullHeight: dailyContentHeight
            )
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .animation(visibilityAnimation, value: isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .onChange(of: isExpanded, initial: true) { _, expanded in
            synchronizeBarDurations(isExpanded: expanded)
        }
        .onChange(of: month.days) { _, _ in
            synchronizeBarDurations(isExpanded: isExpanded)
        }
        .onChange(of: accessibilityReduceMotion) { _, isReduceMotionEnabled in
            guard isReduceMotionEnabled else { return }
            barAnimationTask?.cancel()
            barAnimationTask = nil
            setBarDurations(
                isExpanded ? targetBarDurations : zeroBarDurations,
                disablesAnimations: true
            )
        }
        .onDisappear {
            barAnimationTask?.cancel()
            barAnimationTask = nil
        }
    }
}

private extension MonthlyReadingMonthSection {
    var visibilityAnimation: Animation? {
        accessibilityReduceMotion ? nil : MonthlyReadingChartMotion.visibility
    }

    var zeroBarDurations: [Int64: Int64] {
        month.days.reduce(into: [:]) { values, day in
            values[day.id] = 0
        }
    }

    var targetBarDurations: [Int64: Int64] {
        month.days.reduce(into: [:]) { values, day in
            values[day.id] = max(0, day.durationSeconds)
        }
    }

    /// 切换当前月份；集合写入保持多选语义，不关闭其他已展开月份。
    func toggleExpansion() {
        if isExpanded {
            expandedMonthIDs.remove(month.id)
        } else {
            expandedMonthIDs.insert(month.id)
        }
    }

    /// 在主线程同步柱体动画值；时长文本始终使用真实数据，避免收起期间暴露内部归零状态。
    func synchronizeBarDurations(isExpanded: Bool) {
        barAnimationTask?.cancel()
        barAnimationTask = nil

        guard isExpanded else {
            setBarDurations(
                zeroBarDurations,
                disablesAnimations: accessibilityReduceMotion
            )
            return
        }

        guard !accessibilityReduceMotion else {
            setBarDurations(targetBarDurations, disablesAnimations: true)
            return
        }

        setBarDurations(zeroBarDurations, disablesAnimations: true)
        let durations = targetBarDurations
        barAnimationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            setBarDurations(durations, disablesAnimations: false)
            barAnimationTask = nil
        }
    }

    /// 写入每行柱体动画秒数；Reduce Motion 和初始化归零通过禁用事务避免产生残余补间。
    func setBarDurations(
        _ durations: [Int64: Int64],
        disablesAnimations: Bool
    ) {
        guard barDurationsByDayID != durations else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = disablesAnimations
        withTransaction(transaction) {
            barDurationsByDayID = durations
        }
    }
}

/// 每日内容的裁切布局逐帧向父容器报告当前高度，确保兄弟月份与后续内容连续位移。
private struct MonthlyReadingVisibilityLayout: Layout {
    var progress: CGFloat
    let fullHeight: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let measuredSize = subview.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: fullHeight)
        )
        let width = proposal.width ?? measuredSize.width
        return CGSize(
            width: max(0, width),
            height: max(0, fullHeight * min(max(progress, 0), 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - fullHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: fullHeight)
        )
    }
}

private extension View {
    func monthlyReadingVisibilityLayout(
        progress: CGFloat,
        fullHeight: CGFloat
    ) -> some View {
        MonthlyReadingVisibilityLayout(
            progress: progress,
            fullHeight: fullHeight
        ) {
            self
        }
    }
}

/// 月份头部使用收起层与展开层交叉淡变，并把箭头和渐变宽度限制在自身动画语义内。
private struct MonthlyReadingMonthHeader: View {
    let summaryText: String
    let isExpanded: Bool
    let totalDuration: Int64
    let maximumDuration: Int64
    let minimumBarWidth: CGFloat
    let height: CGFloat
    let style: MonthlyReadingChartStyle
    let accessibilityReduceMotion: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            GeometryReader { proxy in
                let targetBarWidth = targetBarWidth(containerWidth: proxy.size.width)

                ZStack(alignment: .leading) {
                    collapsedLayer(targetBarWidth: targetBarWidth)
                        .opacity(isExpanded ? 0 : 1)
                    expandedLayer
                        .opacity(isExpanded ? 1 : 0)
                }
                .frame(
                    width: max(0, proxy.size.width),
                    height: height,
                    alignment: .leading
                )
            }
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .compositingGroup()
        .clipShape(
            RoundedRectangle(
                cornerRadius: MonthlyReadingChartLayout.cornerRadius,
                style: .continuous
            )
        )
        .animation(crossfadeAnimation, value: isExpanded)
        .accessibilityLabel(Text(summaryText))
        .accessibilityValue(isExpanded ? Text("已展开") : Text("已收起"))
        .accessibilityHint(isExpanded ? Text("双击收起每日阅读时长") : Text("双击展开每日阅读时长"))
    }
}

private extension MonthlyReadingMonthHeader {
    func collapsedLayer(targetBarWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(style.monthTrackColor)

            RoundedRectangle(
                cornerRadius: MonthlyReadingChartLayout.cornerRadius,
                style: .continuous
            )
            .fill(monthGradient)
            .frame(width: targetBarWidth, height: height)
            .animation(barWidthAnimation, value: targetBarWidth)

            Text(summaryText)
                .font(MonthlyReadingChartTypography.collapsedSummary)
                .foregroundStyle(style.collapsedSummaryColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, MonthlyReadingChartLayout.monthHorizontalPadding)

            arrow(color: style.collapsedArrowColor)
        }
        .frame(height: height)
    }

    func targetBarWidth(containerWidth: CGFloat) -> CGFloat {
        let fraction: CGFloat
        if maximumDuration == 0 {
            fraction = 1
        } else {
            fraction = CGFloat(max(0, totalDuration)) / CGFloat(maximumDuration)
        }
        return max(minimumBarWidth, max(0, containerWidth) * max(0, fraction))
    }

    var expandedLayer: some View {
        ZStack(alignment: .leading) {
            Color.clear

            Text(summaryText)
                .font(MonthlyReadingChartTypography.expandedSummary)
                .foregroundStyle(style.expandedSummaryColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, MonthlyReadingChartLayout.monthHorizontalPadding)

            arrow(color: style.expandedArrowColor)
        }
        .frame(height: height)
    }

    var monthGradient: LinearGradient {
        LinearGradient(
            colors: style.monthBarColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var crossfadeAnimation: Animation? {
        accessibilityReduceMotion
            ? MonthlyReadingChartMotion.reducedFade
            : MonthlyReadingChartMotion.crossfade
    }

    var barWidthAnimation: Animation? {
        accessibilityReduceMotion ? nil : MonthlyReadingChartMotion.barWidth
    }

    var arrowAnimation: Animation? {
        accessibilityReduceMotion ? nil : MonthlyReadingChartMotion.arrow
    }

    /// 渲染覆盖在头部最右侧的箭头，两套 Crossfade 图层共享同一旋转目标以保留 Android 重影。
    func arrow(color: Color) -> some View {
        Image(systemName: "chevron.right")
            .font(MonthlyReadingChartTypography.arrow)
            .foregroundStyle(color)
            .frame(
                width: MonthlyReadingChartLayout.arrowSize,
                height: MonthlyReadingChartLayout.arrowSize
            )
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(arrowAnimation, value: isExpanded)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.horizontal, MonthlyReadingChartLayout.monthHorizontalPadding)
    }
}

/// 每日内容组保持常驻，收起时保留真实文本并随父级裁切透明度渐隐。
private struct MonthlyReadingDailyGroup: View {
    let days: [MonthlyReadingChart.Day]
    let barDurationsByDayID: [Int64: Int64]
    let rowHeight: CGFloat
    let minimumBarWidth: CGFloat
    let maximumDuration: Int64
    let style: MonthlyReadingChartStyle
    let accessibilityReduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MonthlyReadingChartLayout.barsSpacing) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                MonthlyReadingDailyBar(
                    day: day,
                    barDurationSeconds: barDurationsByDayID[day.id] ?? 0,
                    index: index,
                    rowHeight: rowHeight,
                    minimumBarWidth: minimumBarWidth,
                    maximumDuration: maximumDuration,
                    style: style,
                    accessibilityReduceMotion: accessibilityReduceMotion
                )
            }
        }
        .padding(.top, MonthlyReadingChartLayout.barsSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 每日阅读条以真实文本布局承载日期和时长，并仅对宽度使用 Android 同款时长曲线。
private struct MonthlyReadingDailyBar: View {
    let day: MonthlyReadingChart.Day
    let barDurationSeconds: Int64
    let index: Int
    let rowHeight: CGFloat
    let minimumBarWidth: CGFloat
    let maximumDuration: Int64
    let style: MonthlyReadingChartStyle
    let accessibilityReduceMotion: Bool

    private var durationText: String {
        MonthlyReadingCompactDurationFormatter.string(from: day.durationSeconds)
    }

    private func targetBarWidth(containerWidth: CGFloat) -> CGFloat {
        let fraction: CGFloat
        if maximumDuration == 0 {
            fraction = 0
        } else {
            fraction = CGFloat(max(0, barDurationSeconds)) / CGFloat(maximumDuration)
        }
        return max(minimumBarWidth, max(0, containerWidth) * max(0, fraction))
    }

    var body: some View {
        GeometryReader { proxy in
            let targetBarWidth = targetBarWidth(containerWidth: proxy.size.width)

            HStack(spacing: Spacing.none) {
                Text(day.dateText)
                    .font(MonthlyReadingChartTypography.dailyDate)
                    .foregroundStyle(style.dailyDateColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)

                Text(durationText)
                    .font(MonthlyReadingChartTypography.dailyDuration)
                    .foregroundStyle(style.dailyDurationColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, MonthlyReadingChartLayout.dailyHorizontalPadding)
            .frame(width: targetBarWidth, height: rowHeight)
            .background(dailyGradient)
            .compositingGroup()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MonthlyReadingChartLayout.cornerRadius,
                    style: .continuous
                )
            )
            .animation(barAnimation, value: targetBarWidth)
        }
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(day.dateText)，\(durationText)"))
    }
}

private extension MonthlyReadingDailyBar {
    var dailyGradient: LinearGradient {
        LinearGradient(
            colors: style.dailyBarColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var barAnimation: Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return MonthlyReadingChartMotion.dailyBar(index: index)
    }
}

/// 组件布局常量严格对应详情页中的 Android 实际调用参数。
private enum MonthlyReadingChartLayout {
    static let monthVerticalPadding: CGFloat = 5
    static let monthHorizontalPadding: CGFloat = 6
    static let dailyVerticalPadding: CGFloat = 5
    static let dailyHorizontalPadding: CGFloat = 10
    static let dailyTextSpacing: CGFloat = 20
    static let barsSpacing: CGFloat = 12
    static let arrowSize: CGFloat = 20
    static let cornerRadius: CGFloat = CornerRadius.blockSmall
}

/// 组件动效常量集中映射 Compose 的 FastOutSlowIn 与临界阻尼 Spring。
private enum MonthlyReadingChartMotion {
    static let barWidth = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.5)
    static let crossfade = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)
    static let reducedFade = Animation.easeOut(duration: 0.08)
    static let arrow = Animation.interpolatingSpring(
        mass: 1,
        stiffness: 1_500,
        damping: 77.4597,
        initialVelocity: 0
    )
    static let visibility = Animation.interpolatingSpring(
        mass: 1,
        stiffness: 400,
        damping: 40,
        initialVelocity: 0
    )

    /// 返回第 n 行柱体动画；所有行同时启动，仅持续时间随索引增加。
    static func dailyBar(index: Int) -> Animation {
        .timingCurve(
            0.4,
            0,
            0.2,
            1,
            duration: 0.5 + Double(max(0, index)) * 0.05
        )
    }
}

/// 图表度量在业务数据变化时重新计算，统一复用渲染字体对应的 UIKit 字体。
private struct MonthlyReadingChartMetrics {
    let headerHeight: CGFloat
    let minimumHeaderWidth: CGFloat
    let dailyRowHeight: CGFloat

    /// 扫描全部月份摘要，建立统一头部高度和最小宽度基线。
    init(months: [MonthlyReadingChart.Month]) {
        let summaryFont = MonthlyReadingChartTypography.uiCollapsedSummary
        let widestSummary = months
            .map { Self.textWidth($0.summaryText, font: summaryFont) }
            .max() ?? 0

        headerHeight = ceil(summaryFont.lineHeight)
            + MonthlyReadingChartLayout.monthVerticalPadding * 2
        minimumHeaderWidth = widestSummary
            + MonthlyReadingChartLayout.monthHorizontalPadding * 2
        dailyRowHeight = ceil(
            max(
                MonthlyReadingChartTypography.uiDailyDate.lineHeight,
                MonthlyReadingChartTypography.uiDailyDuration.lineHeight
            )
        ) + MonthlyReadingChartLayout.dailyVerticalPadding * 2
    }

    /// 计算单个月份所有最终文本都能容纳的每日柱体最小宽度。
    func minimumDailyWidth(for month: MonthlyReadingChart.Month) -> CGFloat {
        let widestContent = month.days.map { day in
            Self.textWidth(
                day.dateText,
                font: MonthlyReadingChartTypography.uiDailyDate
            )
            + MonthlyReadingChartLayout.dailyTextSpacing
            + Self.textWidth(
                MonthlyReadingCompactDurationFormatter.string(from: day.durationSeconds),
                font: MonthlyReadingChartTypography.uiDailyDuration
            )
            + MonthlyReadingChartLayout.dailyHorizontalPadding * 2
        }.max() ?? 0
        return max(1, ceil(widestContent))
    }

    /// 计算每日区域完整高度；空月份仍保留 Android 端的顶部 12pt 间隔。
    static func dailyContentHeight(dayCount: Int, rowHeight: CGFloat) -> CGFloat {
        let rowsHeight = CGFloat(max(0, dayCount)) * rowHeight
        let rowSpacersHeight = CGFloat(max(0, dayCount - 1))
            * MonthlyReadingChartLayout.barsSpacing
        return MonthlyReadingChartLayout.barsSpacing + rowsHeight + rowSpacersHeight
    }

    /// 使用传入 UIFont 测量单行文本宽度，保证计算与 SwiftUI 渲染字体同源。
    static func textWidth(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Android 兼容的紧凑时长格式：分钟存在时省略秒，小时与分钟之间不插入空格。
private enum MonthlyReadingCompactDurationFormatter {
    /// 把秒数转换为图表行内文案，负值按零处理。
    static func string(from durationSeconds: Int64) -> String {
        let seconds = max(0, durationSeconds)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return minutes > 0
                ? "\(hours)小时\(minutes)分钟"
                : "\(hours)小时"
        }
        if minutes > 0 {
            return "\(minutes)分钟"
        }
        return "\(remainingSeconds)秒"
    }
}
