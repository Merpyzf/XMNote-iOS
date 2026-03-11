import SwiftUI

/**
 * [INPUT]: 依赖 ReadingDashboardSnapshot 相关领域模型、XMBookCover、CardContainer 与 DesignTokens 提供首页卡片渲染能力
 * [OUTPUT]: 对外提供 ReadingTrendMetricsSection / ReadingFeatureCardsSection / ReadingRecentBooksCard / ReadingYearSummaryCard 等首页页面私有组件
 * [POS]: Reading/Components 页面私有子视图集合，负责在读首页各卡片区块的展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

private enum ReadingDashboardLayout {
    static let featureCardHeight: CGFloat = 188
    static let trendCardHeight: CGFloat = 146
    static let recentCoverWidth: CGFloat = 70
    static let recentCoverHeight: CGFloat = 100
}

struct ReadingDashboardInlineBanner: View {
    let message: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge) {
            HStack(spacing: Spacing.base) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button(actionTitle, action: onAction)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
            .padding(Spacing.base)
        }
    }
}

struct ReadingTrendMetricsSection: View {
    let metrics: [ReadingTrendMetric]

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            ForEach(metrics) { metric in
                ReadingTrendMetricCard(metric: metric)
            }
        }
    }
}

private struct ReadingTrendMetricCard: View {
    let metric: ReadingTrendMetric

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                Text(ReadingDashboardFormatting.totalValueText(metric: metric))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)

                ReadingMiniBarChart(points: metric.points)
            }
            .frame(maxWidth: .infinity, minHeight: ReadingDashboardLayout.trendCardHeight, alignment: .leading)
            .padding(Spacing.base)
        }
    }
}

private struct ReadingMiniBarChart: View {
    let points: [ReadingTrendMetric.Point]

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.half) {
            ForEach(points) { point in
                VStack(spacing: Spacing.half) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(point.value == 0 ? Color.surfaceBorderSubtle : Color.brand)
                        .frame(height: barHeight(for: point))
                }
                .frame(maxWidth: .infinity, maxHeight: 58, alignment: .bottom)
            }
        }
        .frame(height: 58)
    }

    private func barHeight(for point: ReadingTrendMetric.Point) -> CGFloat {
        guard let maxValue = points.map(\.value).max(), maxValue > 0 else { return 6 }
        let normalized = CGFloat(point.value) / CGFloat(maxValue)
        return max(6, 6 + normalized * 40)
    }
}

struct ReadingFeatureCardsSection: View {
    let dailyGoal: ReadingDailyGoal
    let resumeBook: ReadingResumeBook?
    let isLoading: Bool
    let onEditDailyGoal: () -> Void
    let onResumeTap: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            ReadingDailyGoalCard(
                goal: dailyGoal,
                isLoading: isLoading,
                onTap: onEditDailyGoal
            )

            ReadingResumeBookCard(
                book: resumeBook,
                isLoading: isLoading,
                onTap: onResumeTap
            )
        }
    }
}

private struct ReadingDailyGoalCard: View {
    let goal: ReadingDailyGoal
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                VStack(alignment: .center, spacing: Spacing.base) {
                    VStack(spacing: Spacing.half) {
                        Text(goal.progress >= 1 ? "目标已达成" : "今日阅读")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(goal.progress >= 1 ? "保持住这个节奏" : "点击调整目标")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    ZStack {
                        Circle()
                            .stroke(Color.surfaceBorderSubtle, lineWidth: 8)

                        Circle()
                            .trim(from: 0, to: goal.progress)
                            .stroke(
                                Color.brand,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        VStack(spacing: Spacing.tiny) {
                            Text(ReadingDashboardFormatting.clockText(seconds: goal.readSeconds))
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.textPrimary)
                                .monospacedDigit()
                            Text("目标 \(max(1, goal.targetSeconds / 60)) 分钟")
                                .font(.caption2)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .frame(width: 118, height: 118)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ReadingDashboardLayout.featureCardHeight)
                .padding(Spacing.base)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ReadingResumeBookCard: View {
    let book: ReadingResumeBook?
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("继续阅读")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    Spacer(minLength: 0)

                    if let book {
                        VStack(alignment: .leading, spacing: Spacing.cozy) {
                            HStack(alignment: .top, spacing: Spacing.base) {
                                XMBookCover.fixedWidth(
                                    72,
                                    urlString: book.coverURL,
                                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth)
                                )

                                VStack(alignment: .leading, spacing: Spacing.half) {
                                    Text(book.name)
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(2)

                                    Text(ReadingDashboardFormatting.percentText(book.progressPercent))
                                        .font(.caption)
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }

                            Text("继续补全今天的阅读轨迹")
                                .font(.caption2)
                                .foregroundStyle(Color.textHint)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.cozy) {
                            Image(systemName: "book.badge.plus")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Color.brand)

                            Text("还没有可继续的书")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)

                            Text("先添加一本书，再从这里快速返回阅读")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ReadingDashboardLayout.featureCardHeight, alignment: .topLeading)
                .padding(Spacing.base)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ReadingRecentBooksCard: View {
    let books: [ReadingRecentBook]
    let isLoading: Bool
    let onBookTap: (Int64) -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("最近在读")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)

                if books.isEmpty {
                    EmptyStateView(icon: "books.vertical", message: isLoading ? "正在整理阅读记录" : "最近没有在读记录")
                        .frame(height: 160)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Spacing.base) {
                            ForEach(books) { book in
                                Button {
                                    onBookTap(book.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: Spacing.half) {
                                        XMBookCover.fixedSize(
                                            width: ReadingDashboardLayout.recentCoverWidth,
                                            height: ReadingDashboardLayout.recentCoverHeight,
                                            urlString: book.coverURL,
                                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth)
                                        )

                                        Text(book.name)
                                            .font(.caption)
                                            .foregroundStyle(Color.textPrimary)
                                            .lineLimit(1)

                                        Text(ReadingDashboardFormatting.percentText(book.progressPercent))
                                            .font(.caption2)
                                            .foregroundStyle(Color.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: ReadingDashboardLayout.recentCoverWidth, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.base)
        }
    }
}

struct ReadingYearSummaryCard: View {
    let summary: ReadingYearSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                HStack(spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                            Text("今年已读")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text("\(summary.readCount)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.brand)
                                .monospacedDigit()
                            Text("本")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                        }

                        Text(ReadingDashboardFormatting.yearSummarySubtitle(summary: summary))
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.textHint)
                }
                .padding(Spacing.base)
            }
        }
        .buttonStyle(.plain)
    }
}
