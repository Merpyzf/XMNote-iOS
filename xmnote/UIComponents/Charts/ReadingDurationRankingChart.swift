import SwiftUI

/**
 * [INPUT]: 依赖 SwiftUI 视图系统与阅读日历统计设计令牌提供时长排行视觉语义
 * [OUTPUT]: 对外提供 ReadingDurationRankingChart、Item 与结构化 Insight 数据输入模型
 * [POS]: UIComponents/Charts 跨模块复用组件，承载月度/年度阅读时长排行展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingDurationRankingChart 以封面 + 横向条形宽度展示阅读时长排行，供月度和年度总结共用。
struct ReadingDurationRankingChart: View {
    /// Insight 允许调用方组合标签胶囊与分段着色文本，同时提供完整无障碍读法。
    struct Insight {
        let label: String?
        let content: Text
        let accessibilityLabel: String
    }

    /// Item 定义阅读时长排行单行数据模型。
    struct Item: Identifiable, Hashable {
        /// BarState 表示排行条颜色状态（占位/解析成功/回退色）。
        enum BarState: Hashable {
            case placeholder
            case resolved
            case fallback
        }

        let id: Int64
        let title: String
        let coverURL: String
        let durationSeconds: Int
        let barTint: Color
        let barState: BarState
    }

    private enum Layout {
        static let sectionSpacing: CGFloat = 16
        static let barLabelSpacing: CGFloat = 0
        static let rowHeight: CGFloat = 56
        static let barHeight: CGFloat = 48
        static let rowClipTrailingInset: CGFloat = 1.5
        static let coverCornerRadius: CGFloat = CornerRadius.inlaySmall
        static let barCornerRadius: CGFloat = coverCornerRadius
        static let infoBaseRatio: CGFloat = 0.40
        static let infoAdaptiveBonusRatio: CGFloat = 0.38
        static let infoMaxWidth: CGFloat = 320
        static let infoMinReadableWidth: CGFloat = 118
        static let shortRangeUpperBound: CGFloat = 0.18
        static let shortRangeGamma: CGFloat = 0.78
        static let shortRangeMinRatioFactor: CGFloat = 0.65
        static let minVisualBarWidth: CGFloat = 14
        static let coverLeadingCompensation: CGFloat = coverCornerRadius * 0.55
        static let coverShadowOpacity: CGFloat = 0.10
        static let coverShadowRadius: CGFloat = 1.8
        static let coverShadowYOffset: CGFloat = 0.9
        static let coverHeight: CGFloat = barHeight
    }

    let title: String
    let insight: Insight?
    let emptyText: String?
    let items: [Item]
    let animationIdentity: String
    let onBookTap: ((Int64) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var barRatiosByBookId: [Int64: CGFloat] = [:]
    @State private var barAnimationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text(title)
                    .font(ReadCalendarSummaryTypography.sectionTitle)
                    .foregroundStyle(Color.textPrimary)

                if let insight {
                    insightView(insight)
                }
            }

            if items.isEmpty, let emptyText {
                Text(emptyText)
                    .font(ReadCalendarSummaryTypography.insightMeta)
                    .foregroundStyle(Color.textHint)
            } else {
                LazyVStack(spacing: Spacing.cozy) {
                    ForEach(items) { item in
                        rankingRowContainer(item: item, maxDurationSeconds: maxDurationSeconds)
                    }
                }
            }
        }
        .onAppear {
            animateBars(for: items)
        }
        .onChange(of: animationIdentity) { _, _ in
            animateBars(for: items)
        }
        .onDisappear {
            barAnimationTask?.cancel()
            barAnimationTask = nil
            barRatiosByBookId = [:]
        }
    }
}

private extension ReadingDurationRankingChart {
    var maxDurationSeconds: Int {
        items.map(\.durationSeconds).max() ?? 0
    }

    /// 按是否提供点击回调包装排行行容器。
    @ViewBuilder
    /// 根据是否可点击选择按钮或纯展示容器，避免调用方重复包装交互层。
    func rankingRowContainer(
        item: Item,
        maxDurationSeconds: Int
    ) -> some View {
        if let onBookTap {
            Button {
                onBookTap(item.id)
            } label: {
                rankingRow(item: item, maxDurationSeconds: maxDurationSeconds)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            rankingRow(item: item, maxDurationSeconds: maxDurationSeconds)
        }
    }

    /// 渲染单条排行项并计算条宽与信息区位置。
    func rankingRow(
        item: Item,
        maxDurationSeconds: Int
    ) -> some View {
        let fallbackRawRatio = durationRatio(durationSeconds: item.durationSeconds, maxDurationSeconds: maxDurationSeconds)
        let rawRatio = barRatiosByBookId[item.id] ?? fallbackRawRatio

        return GeometryReader { proxy in
            let rowWidth = max(0, proxy.size.width)
            let infoWidth = infoWidth(rowWidth: rowWidth, displayedRatio: rawRatio)
            let barAvailableWidth = max(0, rowWidth - infoWidth - Layout.barLabelSpacing)
            let visualRatio = visualRatio(rawRatio: rawRatio, barAvailableWidth: barAvailableWidth)
            let displayedBarWidth = max(0, min(barAvailableWidth, barAvailableWidth * visualRatio))
            let infoOffsetMax = max(0, rowWidth - infoWidth - Layout.rowClipTrailingInset)
            let infoOffsetX = min(
                max(0, displayedBarWidth + Layout.barLabelSpacing - Layout.coverLeadingCompensation),
                infoOffsetMax
            )

            ZStack(alignment: .leading) {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: Layout.barCornerRadius,
                        bottomLeading: Layout.barCornerRadius,
                        bottomTrailing: CornerRadius.none,
                        topTrailing: CornerRadius.none
                    ),
                    style: .continuous
                )
                .fill(barTint(for: item))
                .frame(width: displayedBarWidth, height: Layout.barHeight)

                rankingInfoView(item: item, width: infoWidth)
                    .offset(x: infoOffsetX)
            }
            .frame(width: rowWidth, height: Layout.rowHeight, alignment: .leading)
            // 约束排行行内容只在本行区域内绘制，避免切换与增长动画在边缘帧越界。
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.title)，阅读时长\(durationText(item.durationSeconds))")
        }
        .frame(height: Layout.rowHeight)
    }

    /// 渲染排行项封面右侧的书名与时长信息。
    func rankingInfoView(item: Item, width: CGFloat) -> some View {
        HStack(spacing: Spacing.half) {
            rankingCover(urlString: item.coverURL)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(item.title)
                    .font(ReadCalendarSummaryTypography.rankingTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .allowsTightening(true)
                durationValue(item.durationSeconds)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
    }

    /// 将排行行内时长拆成数字与单位，保持和指标卡一致的文本颜色层级。
    func durationValue(_ durationSeconds: Int) -> some View {
        let parts = durationParts(durationSeconds)
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.hairline) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part.text)
                    .font(part.isNumber ? ReadCalendarSummaryTypography.rankingNumber : ReadCalendarSummaryTypography.rankingUnit)
                    .foregroundStyle(part.isNumber ? Color.textPrimary : Color.textSecondary)
            }
        }
    }

    /// 返回用于行内分段排版的时长片段。
    func durationParts(_ durationSeconds: Int) -> [(text: String, isNumber: Bool)] {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        if hours > 0 {
            var parts: [(String, Bool)] = [(String(hours), true), ("小时", false)]
            if minutes > 0 {
                parts.append((String(minutes), true))
                parts.append(("分", false))
            }
            return parts
        }
        if minutes > 0 {
            return [(String(minutes), true), ("分", false)]
        }
        return [(String(max(1, durationSeconds)), true), ("秒", false)]
    }

    /// 渲染排行项封面（含占位图与边框阴影）。
    func rankingCover(urlString: String) -> some View {
        XMBookCover.fixedHeight(
            Layout.coverHeight,
            urlString: urlString,
            border: .init(color: .white.opacity(0.14), width: 0.5),
            placeholderIconSize: .small
        )
        .shadow(
            color: Color.black.opacity(Layout.coverShadowOpacity),
            radius: Layout.coverShadowRadius,
            x: 0,
            y: Layout.coverShadowYOffset
        )
    }

    /// 按行宽和条形比例计算信息区宽度。
    func infoWidth(rowWidth: CGFloat, displayedRatio: CGFloat) -> CGFloat {
        let normalizedRatio = min(1, max(0, displayedRatio))
        let adaptiveRatio = Layout.infoBaseRatio
            + (1 - normalizedRatio) * Layout.infoAdaptiveBonusRatio
        let adaptiveWidth = rowWidth * adaptiveRatio
        let cappedWidth = min(Layout.infoMaxWidth, adaptiveWidth)
        let readableFloor = min(Layout.infoMinReadableWidth, rowWidth)
        return min(rowWidth, max(readableFloor, cappedWidth))
    }

    /// 将原始比例映射到视觉比例，提升短条可见性。
    func visualRatio(rawRatio: CGFloat, barAvailableWidth: CGFloat) -> CGFloat {
        let normalizedRaw = min(1, max(0, rawRatio))
        guard normalizedRaw > 0 else { return 0 }

        let upperBound = Layout.shortRangeUpperBound
        guard normalizedRaw < upperBound else { return normalizedRaw }

        let minVisualRatio = minVisualRatio(barAvailableWidth: barAvailableWidth)
        guard minVisualRatio < upperBound else { return upperBound }

        let t = normalizedRaw / upperBound
        let eased = CGFloat(pow(Double(t), Double(Layout.shortRangeGamma)))
        let mapped = minVisualRatio + (upperBound - minVisualRatio) * eased
        return min(upperBound, max(minVisualRatio, mapped))
    }

    /// 计算短条最小可见比例，防止小数据条消失。
    func minVisualRatio(barAvailableWidth: CGFloat) -> CGFloat {
        guard barAvailableWidth > 0 else { return 0 }
        let widthRatio = Layout.minVisualBarWidth / barAvailableWidth
        let cap = Layout.shortRangeUpperBound * Layout.shortRangeMinRatioFactor
        return min(cap, max(0, widthRatio))
    }

    /// 按最大时长归一化单项时长比例。
    func durationRatio(durationSeconds: Int, maxDurationSeconds: Int) -> CGFloat {
        guard durationSeconds > 0, maxDurationSeconds > 0 else { return 0 }
        return min(1, max(0, CGFloat(durationSeconds) / CGFloat(maxDurationSeconds)))
    }

    /// 把阅读秒数格式化为时长文案。
    func durationText(_ durationSeconds: Int) -> String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时"
        }
        if minutes > 0 {
            return "\(minutes)分"
        }
        return "\(max(1, durationSeconds))秒"
    }

    /// 根据条形状态返回最终渲染颜色。
    func barTint(for item: Item) -> Color {
        switch item.barState {
        case .placeholder:
            return item.barTint.opacity(0.78)
        case .resolved:
            return item.barTint
        case .fallback:
            return item.barTint.opacity(0.92)
        }
    }

    /// 触发排行条从 0 到目标比例的分批动画。
    func animateBars(for items: [Item]) {
        barAnimationTask?.cancel()
        barAnimationTask = nil
        guard !items.isEmpty else {
            barRatiosByBookId = [:]
            return
        }

        let maxDurationSeconds = items.map(\.durationSeconds).max() ?? 0
        let targets = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, durationRatio(durationSeconds: item.durationSeconds, maxDurationSeconds: maxDurationSeconds))
        })

        barRatiosByBookId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, CGFloat.zero) })
        if accessibilityReduceMotion {
            barRatiosByBookId = targets
            return
        }

        barAnimationTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                for (index, item) in items.enumerated() {
                    let target = targets[item.id] ?? 0
                    withAnimation(.snappy(duration: 0.42, extraBounce: 0.04).delay(Double(index) * 0.05)) {
                        barRatiosByBookId[item.id] = target
                    }
                }
            }
        }
    }
}
    /// 渲染标签胶囊和分段洞察文本，并将视觉片段合并为一条 VoiceOver 语句。
private func insightView(_ insight: ReadingDurationRankingChart.Insight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
            if let label = insight.label {
                Text(label)
                    .font(ReadCalendarSummaryTypography.insightLabel)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Spacing.half)
                    .padding(.vertical, Spacing.compact)
                    .background(Color.controlFillSecondary, in: Capsule())
            }

            insight.content
                .font(ReadCalendarSummaryTypography.insightMeta)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(insight.accessibilityLabel)
    }
