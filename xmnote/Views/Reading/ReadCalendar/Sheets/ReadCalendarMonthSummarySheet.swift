import SwiftUI

/**
 * [INPUT]: 依赖 MonthSummarySheetData、SummaryFilterState、ReadCalendarTheme、月度洞察私有排版与阅读日历统计页面私有组件
 * [OUTPUT]: 对外提供 ReadCalendarMonthSummarySheet（月度阅读总结弹层）
 * [POS]: ReadCalendar 业务 Sheet，负责月份切换、六项指标与月度阅读时长排行展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 月度总结洞察中分段数值与单位的页面私有层级。
private enum ReadCalendarMonthSummaryTypography {
    static let insightNumber = AppTypography.subheadlineSemibold
    static let insightUnit = AppTypography.captionMedium
}

/// 月度总结弹层以统一摘要为唯一指标来源，并按当前设置隐藏不应展示的统计。
struct ReadCalendarMonthSummarySheet: View {
    private enum Layout {
        static let topInset: CGFloat = 30
        static let bottomInset: CGFloat = 28
        static let horizontalInset: CGFloat = 22
        static let sectionSpacing: CGFloat = 20
        static let switcherVisualSize: CGFloat = 32
        static let switcherHitSize: CGFloat = InteractionMetrics.minimumTouchTarget
    }

    private enum Motion {
        static let monthChange = Animation.snappy(duration: 0.24)
    }

    let sheet: ReadCalendarContentView.MonthSummarySheetData
    let availableMonths: [Date]
    let filterState: ReadCalendarContentView.SummaryFilterState
    let onSwitchMonth: (Date) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "月度总结",
            onClose: { dismiss() },
            scrollEdgePresentation: .overlaySoft,
            contentTopBar: {
                monthSwitcher
                    .padding(.horizontal, Layout.horizontalInset)
                    .padding(.bottom, Spacing.base)
            }
        ) {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                ReadCalendarSummaryMetricSection(
                    metrics: summaryMetrics,
                    isLoading: isInitialLoading
                )

                durationRanking
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, Spacing.base)
            .padding(.bottom, Layout.bottomInset)
        }
        .animation(reduceMotion ? nil : Motion.monthChange, value: sheet)
    }
}

private extension ReadCalendarMonthSummarySheet {
    var monthSwitcher: some View {
        let previousMonth = adjacentMonth(offset: -1)
        let nextMonth = adjacentMonth(offset: 1)

        return HStack(spacing: Spacing.base) {
            monthSwitchButton(
                systemName: "chevron.left",
                hitAlignment: .leading,
                isEnabled: previousMonth != nil
            ) {
                guard let previousMonth else { return }
                onSwitchMonth(previousMonth)
            }

            Spacer(minLength: 0)

            Text(SummaryFormatter.monthTitle.string(from: sheet.monthStart))
                .font(AppTypography.title3Semibold)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 0)

            monthSwitchButton(
                systemName: "chevron.right",
                hitAlignment: .trailing,
                isEnabled: nextMonth != nil
            ) {
                guard let nextMonth else { return }
                onSwitchMonth(nextMonth)
            }
        }
    }

    /// 渲染月份切换按钮，禁用态不响应并降低对比度。
    func monthSwitchButton(
        systemName: String,
        hitAlignment: Alignment,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(isEnabled ? Color.textPrimary : Color.textHint.opacity(0.85))
                .frame(width: Layout.switcherVisualSize, height: Layout.switcherVisualSize)
                .background(isEnabled ? Color.surfaceNested : Color.controlFillSecondary, in: Circle())
                .overlay {
                    Circle().stroke(Color.surfaceBorderDefault, lineWidth: StrokeWidth.hairline)
                }
                .frame(
                    width: Layout.switcherHitSize,
                    height: Layout.switcherHitSize,
                    alignment: hitAlignment
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    var summaryMetrics: [ReadCalendarSummaryMetric] {
        let summary = sheet.monthSummary
        return [
            .init(
                id: "activeDays",
                title: "阅读天数",
                icon: "calendar",
                gradientRole: .activity,
                value: summary.activeDays > 0 ? .quantity(summary.activeDays, unit: "天") : .text("未开始"),
                delta: summary.activeDaysDelta.map { .make(prefix: comparisonLabel, delta: $0, unit: "天") }
            ),
            .init(
                id: "streak",
                title: "最长连续",
                icon: "flame",
                gradientRole: .momentum,
                value: summary.longestStreak > 0 ? .quantity(summary.longestStreak, unit: "天") : .text("未形成"),
                delta: nil
            ),
            .init(
                id: "booksRead",
                title: "阅读书籍",
                icon: "books.vertical",
                gradientRole: .completion,
                value: summary.uniqueReadBookCount > 0 ? .quantity(summary.uniqueReadBookCount, unit: "本") : .text("暂无"),
                delta: summary.uniqueReadBookCountDelta.map { .make(prefix: comparisonLabel, delta: $0, unit: "本") }
            ),
            .init(
                id: "booksFinished",
                title: "读完书籍",
                icon: "checkmark.seal",
                gradientRole: .completion,
                value: hiddenValue(
                    isHidden: filterState.excludeReadDone,
                    count: summary.finishedBookCount,
                    unit: "本"
                ),
                delta: filterState.excludeReadDone ? nil : summary.finishedBookCountDelta.map {
                    .make(prefix: comparisonLabel, delta: $0, unit: "本")
                }
            ),
            .init(
                id: "notes",
                title: "书摘记录",
                icon: "text.quote",
                gradientRole: .trend,
                value: hiddenValue(
                    isHidden: filterState.excludeNote,
                    count: summary.noteCount,
                    unit: "条"
                ),
                delta: filterState.excludeNote ? nil : summary.noteCountDelta.map {
                    .make(prefix: comparisonLabel, delta: $0, unit: "条")
                }
            ),
            .init(
                id: "timeSlot",
                title: "主要阅读时段",
                icon: "clock",
                gradientRole: .momentum,
                value: timeSlotValue,
                delta: nil
            )
        ]
    }

    /// 设置关闭时用明确隐藏态替代零值，否则按计数输出数量或“暂无”。
    func hiddenValue(isHidden: Bool, count: Int, unit: String) -> ReadCalendarSummaryValue {
        if isHidden { return .text("已按日历设置隐藏") }
        return count > 0 ? .quantity(count, unit: unit) : .text("暂无")
    }

    var timeSlotValue: ReadCalendarSummaryValue {
        guard !filterState.excludeReadTime else { return .text("已按日历设置隐藏") }
        guard let slot = sheet.monthSummary.peakTimeSlot,
              let ratio = sheet.monthSummary.peakTimeSlotRatio else {
            return .text("时段还没形成")
        }
        let slotTitle = timeSlotTitle(slot)
        return .init(
            parts: [
                .init(text: "\(slotTitle) · ", role: .text),
                .init(text: String(ratio), role: .number),
                .init(text: "%", role: .unit)
            ],
            accessibilityLabel: "主要阅读时段\(slotTitle)，占比\(ratio)%"
        )
    }

    var durationRanking: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ReadingDurationRankingChart(
                title: "阅读时长排行",
                insight: durationInsight,
                emptyText: durationEmptyText,
                items: rankingItems,
                animationIdentity: "month-\(sheet.monthStart.timeIntervalSinceReferenceDate)-\(rankingItems.count)",
                onBookTap: nil
            )
            .redacted(reason: isInitialLoading ? .placeholder : [])

            if sheet.hasDurationRankingFallback, !filterState.excludeReadTime, !isInitialLoading {
                Text("网络不稳定，已使用默认配色")
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textHint)
            }
        }
    }

    var durationInsight: ReadingDurationRankingChart.Insight? {
        if isInitialLoading {
            return .init(label: "本月累计", content: Text("正在统计"), accessibilityLabel: "本月累计，正在统计")
        }
        if filterState.excludeReadTime {
            return .init(
                label: nil,
                content: Text("已按日历设置隐藏").foregroundStyle(Color.textSecondary),
                accessibilityLabel: "阅读时长已按日历设置隐藏"
            )
        }

        let totalSeconds = sheet.monthSummary.totalReadSeconds
        guard totalSeconds > 0 else {
            return .init(
                label: "本月累计",
                content: Text("暂无阅读时长").foregroundStyle(Color.textSecondary),
                accessibilityLabel: "本月累计，暂无阅读时长"
            )
        }

        let totalText = segmentedDurationText(totalSeconds, numberColor: ReadCalendarTheme.summaryDurationAccent)
        guard let delta = sheet.monthSummary.readSecondsDelta else {
            return .init(
                label: "本月累计",
                content: totalText,
                accessibilityLabel: "本月累计\(durationText(totalSeconds))"
            )
        }

        let comparison = Text("  \(comparisonLabel)").foregroundStyle(Color.textSecondary)
        let deltaText = segmentedDeltaDurationText(delta)
        return .init(
            label: "本月累计",
            content: Text("\(totalText)\(comparison)\(deltaText)"),
            accessibilityLabel: "本月累计\(durationText(totalSeconds))，\(durationDeltaAccessibility(delta))"
        )
    }

    var durationEmptyText: String? {
        guard !isInitialLoading, !filterState.excludeReadTime else { return nil }
        return sheet.durationTopBooks.isEmpty ? "暂无阅读时长排行" : nil
    }

    var rankingItems: [ReadingDurationRankingChart.Item] {
        if filterState.excludeReadTime { return [] }
        if isInitialLoading {
            return [
                loadingRankingItem(id: -1, seconds: 3600),
                loadingRankingItem(id: -2, seconds: 2400),
                loadingRankingItem(id: -3, seconds: 1200)
            ]
        }
        return sheet.durationTopBooks.map { book in
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

    /// 创建与最终排行结构一致的加载占位行。
    func loadingRankingItem(id: Int64, seconds: Int) -> ReadingDurationRankingChart.Item {
        .init(
            id: id,
            title: "阅读书籍",
            coverURL: "",
            durationSeconds: seconds,
            barTint: ReadCalendarTheme.eventPendingBase,
            barState: .placeholder
        )
    }

    /// 返回排行条颜色与解析状态。
    func durationBarPresentation(bookId: Int64) -> (
        color: Color,
        state: ReadingDurationRankingChart.Item.BarState
    ) {
        guard let color = sheet.rankingBarColorsByBookId[bookId] else {
            return (ReadCalendarTheme.eventPendingBase, .placeholder)
        }
        switch color.state {
        case .pending:
            return (ReadCalendarTheme.eventPendingBase, .placeholder)
        case .resolved:
            return (softenedBarColor(from: color), .resolved)
        case .failed:
            return (softenedBarColor(from: color), .fallback)
        }
    }

    /// 柔化封面提取色，避免大面积排行条过饱和。
    func softenedBarColor(from color: ReadCalendarSegmentColor) -> Color {
        let red = CGFloat((color.backgroundRGBAHex >> 24) & 0xFF) / 255
        let green = CGFloat((color.backgroundRGBAHex >> 16) & 0xFF) / 255
        let blue = CGFloat((color.backgroundRGBAHex >> 8) & 0xFF) / 255
        let alpha = CGFloat(color.backgroundRGBAHex & 0xFF) / 255
        let soften: CGFloat = 0.5
        return Color.xmSRGB(
            red: red + (1 - red) * soften,
            green: green + (1 - green) * soften,
            blue: blue + (1 - blue) * soften,
            opacity: alpha
        )
    }

    var isInitialLoading: Bool {
        sheet.loadState != .loaded && !sheet.hasActivity
    }

    var comparisonLabel: String {
        let calendar = Calendar.current
        return calendar.isDate(sheet.monthStart, equalTo: Date(), toGranularity: .month)
            ? "较上月同期"
            : "较上月"
    }

    /// 将时段枚举转换为本地化中文标题。
    func timeSlotTitle(_ slot: ReadCalendarTimeSlot) -> String {
        switch slot {
        case .morning: "早晨"
        case .afternoon: "下午"
        case .evening: "晚上"
        case .lateNight: "深夜"
        }
    }

    /// 构造时长数字与单位的分段文本。
    func segmentedDurationText(_ seconds: Int, numberColor: Color) -> Text {
        durationParts(seconds).reduce(Text("")) { result, part in
            let font = part.isNumber
                ? ReadCalendarMonthSummaryTypography.insightNumber
                : ReadCalendarMonthSummaryTypography.insightUnit
            let color = part.isNumber ? numberColor : Color.textSecondary
            let fragment = Text(part.text).font(font).foregroundStyle(color)
            return Text("\(result)\(fragment)")
        }
    }

    /// 构造环比时长文本，仅变化数字使用趋势色，单位保持次级色。
    func segmentedDeltaDurationText(_ delta: Int) -> Text {
        guard delta != 0 else {
            return Text(" 持平").foregroundStyle(ReadCalendarTheme.summaryDeltaFlat)
        }
        let color = delta > 0 ? ReadCalendarTheme.summaryDeltaUp : ReadCalendarTheme.summaryDeltaDown
        let sign = delta > 0 ? "+" : "−"
        return durationParts(abs(delta)).reduce(Text(sign).foregroundStyle(color)) { result, part in
            let font = part.isNumber
                ? ReadCalendarMonthSummaryTypography.insightNumber
                : ReadCalendarMonthSummaryTypography.insightUnit
            let partColor = part.isNumber ? color : Color.textSecondary
            let fragment = Text(part.text).font(font).foregroundStyle(partColor)
            return Text("\(result)\(fragment)")
        }
    }

    /// 将秒数拆成可独立着色的数字与单位。
    func durationParts(_ seconds: Int) -> [(text: String, isNumber: Bool)] {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            var parts: [(String, Bool)] = [(String(hours), true), ("小时", false)]
            if minutes > 0 {
                parts.append((String(minutes), true))
                parts.append(("分", false))
            }
            return parts
        }
        if minutes > 0 { return [(String(minutes), true), ("分", false)] }
        return [(String(max(1, seconds)), true), ("秒", false)]
    }

    /// 格式化完整时长，供 VoiceOver 使用。
    func durationText(_ seconds: Int) -> String {
        durationParts(seconds).map(\.text).joined()
    }

    /// 格式化环比完整读法，避免 VoiceOver 逐片段停顿。
    func durationDeltaAccessibility(_ delta: Int) -> String {
        if delta == 0 { return "\(comparisonLabel)持平" }
        return "\(comparisonLabel)\(delta > 0 ? "增加" : "减少")\(durationText(abs(delta)))"
    }

    /// 根据偏移量返回可切换的相邻月份。
    func adjacentMonth(offset: Int) -> Date? {
        guard let index = availableMonths.firstIndex(of: sheet.monthStart) else { return nil }
        let target = index + offset
        guard availableMonths.indices.contains(target) else { return nil }
        return availableMonths[target]
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
