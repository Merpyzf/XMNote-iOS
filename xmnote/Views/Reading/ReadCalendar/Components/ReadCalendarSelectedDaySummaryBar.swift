/**
 * [INPUT]: 依赖 ReadCalendarDay 当日聚合数据、ReadDurationFormatter 时长格式化能力与 ReadCalendarTextStyle/ReadCalendarTheme/DesignTokens
 * [OUTPUT]: 对外提供 ReadCalendarSelectedDaySummary 与 ReadCalendarSelectedDaySummaryBar，以单层 Liquid Glass 展示事件模式选中日的自适应两行摘要与可选详情入口
 * [POS]: ReadCalendar 页面私有底部摘要组件，由 ReadCalendarContentView 通过 safeAreaBar 挂载
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 选中日摘要的轻量展示模型，把领域计数收敛为底部栏需要的紧凑事实。
struct ReadCalendarSelectedDaySummary: Identifiable, Hashable {
    let date: Date
    let dateText: String
    let factsText: String
    let compactFactsText: String
    let hasActivity: Bool
    let canOpenDetail: Bool

    var id: Date { date }

    /// 从现有单日聚合数据生成展示快照；空日期仍保留明确的无活动反馈。
    static func make(date: Date, day: ReadCalendarDay?) -> ReadCalendarSelectedDaySummary {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        guard let day else {
            return ReadCalendarSelectedDaySummary(
                date: normalizedDate,
                dateText: formattedDate(normalizedDate),
                factsText: "当日无阅读活动",
                compactFactsText: "当日无阅读活动",
                hasActivity: false,
                canOpenDetail: false
            )
        }

        let bookCount = day.books.count
        let checkInCount = max(day.checkInCount, day.checkInAmount)
        let hasActivity = bookCount > 0
            || day.readDoneCount > 0
            || day.readSeconds > 0
            || day.noteCount > 0
            || day.contentActivityCount > 0
            || checkInCount > 0
            || day.checkInSeconds > 0
        var facts: [String] = []
        if day.readDoneCount > 0 {
            facts.append("读完\(day.readDoneCount)本")
        }
        facts.append("\(bookCount)本书")
        if day.readSeconds > 0 {
            facts.append(ReadDurationFormatter.format(seconds: Int64(day.readSeconds)))
        }
        if day.noteCount > 0 {
            facts.append("\(day.noteCount)条书摘")
        }
        if checkInCount > 0 {
            facts.append("\(checkInCount)次打卡")
        }

        return ReadCalendarSelectedDaySummary(
            date: normalizedDate,
            dateText: formattedDate(normalizedDate),
            factsText: hasActivity ? facts.joined(separator: " · ") : "当日无阅读活动",
            compactFactsText: hasActivity ? facts.prefix(2).joined(separator: " · ") : "当日无阅读活动",
            hasActivity: hasActivity,
            canOpenDetail: hasActivity && bookCount > 0
        )
    }

    /// 使用本地化日期样式生成月、日与星期信息，避免在 View 刷新期间重复创建格式化器。
    private static func formattedDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .locale(Locale(identifier: "zh_Hans_CN"))
                .month(.wide)
                .day(.defaultDigits)
                .weekday(.abbreviated)
        )
    }
}

/// 阅读日历事件模式的底部选中日摘要，使用单层 Liquid Glass 承载事实与详情入口。
struct ReadCalendarSelectedDaySummaryBar: View {
    let summary: ReadCalendarSelectedDaySummary
    let onOpenDetail: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumBarHeight = 64

    private var visibleFactsText: String {
        dynamicTypeSize.isAccessibilitySize ? summary.compactFactsText : summary.factsText
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            summaryContent
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: CornerRadius.containerMedium)
                )
        } else {
            summaryContent
                .background(.regularMaterial, in: summaryShape)
                .overlay {
                    summaryShape
                        .stroke(
                            ReadCalendarTheme.selectionStroke.opacity(0.52),
                            lineWidth: 0.5
                        )
                }
        }
    }

    private var summaryContent: some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(summary.dateText)
                    .font(ReadCalendarTextStyle.selectedDayTitleFont)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text(visibleFactsText)
                    .font(ReadCalendarTextStyle.selectedDayFactsFont)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(summary.dateText)，\(summary.factsText)")

            if summary.canOpenDetail {
                Button(action: onOpenDetail) {
                    HStack(spacing: Spacing.tiny) {
                        Text("查看详情")
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                    }
                    .font(ReadCalendarTextStyle.selectedDayActionFont)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.textPrimary)
                    .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开当天的阅读轨迹")
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.half)
        .frame(maxWidth: .infinity, minHeight: minimumBarHeight)
    }

    private var summaryShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: CornerRadius.containerMedium,
            style: .continuous
        )
    }
}
