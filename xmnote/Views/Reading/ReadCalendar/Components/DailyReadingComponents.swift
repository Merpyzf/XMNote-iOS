/**
 * [INPUT]: 依赖 DailyReadingSummary/DailyReadingBookSummary、XMBookCover、CardContainer 与设计令牌
 * [OUTPUT]: 对外提供 DailyReadingSummaryCard 与 DailyReadingBookCard，当日阅读二级页复用
 * [POS]: ReadCalendar 页面私有组件，承接 Android 信息结构的 iOS 原生卡片表达
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 当日阅读总览卡，展示动态主结论、最多三项指标与最多五本封面。
struct DailyReadingSummaryCard: View {
    let headline: String
    let metrics: [DailyReadingMetric]
    let books: [DailyReadingBookSummary]

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            HStack(spacing: Spacing.screenEdge) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text(headline)
                        .font(AppTypography.semantic(.title2, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    if !metrics.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.half) {
                                ForEach(metrics) { metric in
                                    DailyReadingMetricPill(metric: metric)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DailyReadingCoverStack(books: Array(books.prefix(5)))
            }
            .padding(Spacing.contentEdge)
        }
    }
}

/// 当日单书摘要卡，点击进入该书当天的三级记录流，菜单保留打开书籍入口。
struct DailyReadingBookCard: View {
    let summary: DailyReadingBookSummary
    let onOpenReadingDetail: () -> Void
    let onOpenBook: () -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            HStack(spacing: Spacing.screenEdge) {
                Button(action: onOpenReadingDetail) {
                    HStack(spacing: Spacing.screenEdge) {
                        XMBookCover.fixedWidth(
                            60,
                            urlString: summary.book.coverURL,
                            border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                        )

                        VStack(alignment: .leading, spacing: Spacing.cozy) {
                            Text(summary.book.name)
                                .font(AppTypography.headline)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            DailyReadingBookMetrics(summary: summary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button("打开书籍", systemImage: "book") {
                        onOpenBook()
                    }
                    Button("阅读详情", systemImage: "chart.bar.xaxis") {
                        onOpenReadingDetail()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(summary.book.name)更多操作")
            }
            .padding(Spacing.contentEdge)
        }
    }
}

private struct DailyReadingMetricPill: View {
    let metric: DailyReadingMetric

    var body: some View {
        HStack(spacing: Spacing.tiny) {
            Text(metric.value)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)
            Text(metric.label)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.compact)
        .background(Color.controlFillSecondary, in: Capsule())
        .overlay { Capsule().stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth) }
    }
}

private struct DailyReadingCoverStack: View {
    let books: [DailyReadingBookSummary]

    var body: some View {
        let visible = Array(books.prefix(5))
        ZStack(alignment: .leading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                XMBookCover.fixedWidth(
                    38,
                    urlString: item.book.coverURL,
                    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                )
                .rotationEffect(.degrees(rotation(for: index, count: visible.count)))
                .offset(x: CGFloat(index) * 14, y: verticalOffset(for: index))
                .zIndex(Double(visible.count - index))
            }
        }
        .frame(width: max(38, 38 + CGFloat(max(0, visible.count - 1)) * 14), height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当天阅读了\(visible.count)本书")
    }

    private func rotation(for index: Int, count: Int) -> Double {
        let rotations: [Double]
        switch count {
        case 1: rotations = [0]
        case 2: rotations = [-4, 2.5]
        case 3: rotations = [-5, 1.5, 5]
        case 4: rotations = [-6, -2, 2.5, 5.5]
        default: rotations = [-6, -3, 0, 3, 6]
        }
        return rotations.indices.contains(index) ? rotations[index] : 0
    }

    private func verticalOffset(for index: Int) -> CGFloat {
        [2, -2, -3, 2, 3].indices.contains(index) ? [2, -2, -3, 2, 3][index] : 0
    }
}

private struct DailyReadingBookMetrics: View {
    let summary: DailyReadingBookSummary

    var body: some View {
        let texts = metricTexts
        if !texts.isEmpty {
            FlowLayout(spacing: Spacing.half) {
                ForEach(texts, id: \.self) { text in
                    Text(text)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(Color.controlFillSecondary, in: Capsule())
                }
            }
        }
    }

    private var metricTexts: [String] {
        var values: [String] = []
        if summary.readSeconds > 0 {
            values.append(ReadDurationFormatter.format(seconds: Int64(summary.readSeconds)))
        }
        if summary.noteCount > 0 { values.append("\(summary.noteCount)条书摘") }
        if summary.reviewCount > 0 { values.append("\(summary.reviewCount)篇书评") }
        if summary.relevantCount > 0 { values.append("\(summary.relevantCount)条相关") }
        if summary.checkInCount > 0 { values.append("\(summary.checkInCount)次打卡") }
        if summary.readDoneCount > 0 { values.append("今日读完") }
        return values
    }
}

/// 简单换行布局，保证动态字体下指标不会横向裁切。
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > width {
                cursor.x = 0
                cursor.y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(cursor)
            cursor.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, cursor.x - spacing)
        }
        return (CGSize(width: min(width, contentWidth), height: cursor.y + rowHeight), points)
    }
}
