import SwiftUI

/**
 * [INPUT]: 依赖 ReadingYearSummary 提供年度已读聚合数据，依赖 XMBookCover 与 ReadDurationFormatter 渲染书籍条目
 * [OUTPUT]: 对外提供 ReadingYearSummarySheet（首页年度已读摘要弹层）
 * [POS]: Reading/Sheets 业务弹层，负责展示年度已读书籍列表与年度目标编辑入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingYearSummarySheet 展示年度已读清单和目标完成度，并提供继续跳转书籍详情与调整目标的出口。
struct ReadingYearSummarySheet: View {
    let summary: ReadingYearSummary
    let onBookTap: (Int64) -> Void
    let onEditGoal: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if summary.books.isEmpty {
                    EmptyStateView(icon: "books.vertical", message: "这一年还没有已读书籍")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.base) {
                            summaryHeader

                            ForEach(summary.books) { book in
                                Button {
                                    dismiss()
                                    onBookTap(book.id)
                                } label: {
                                    yearBookRow(book)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.base)
                        .padding(.bottom, Spacing.section)
                    }
                }
            }
            .background(Color.windowBackground)
            .navigationTitle("\(summary.year) 年已读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("调整目标", action: onEditGoal)
                }
            }
        }
    }

    private var summaryHeader: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(alignment: .leading, spacing: Spacing.half) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                    Text("已读 \(summary.readCount) 本")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("目标 \(summary.targetCount) 本")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Text(ReadingDashboardFormatting.yearSummarySubtitle(summary: summary))
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Spacing.base)
        }
    }

    /// 生成单本年度已读书籍行，复用首页摘要后的明细展示语义。
    private func yearBookRow(_ book: ReadingYearReadBook) -> some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge) {
            HStack(spacing: Spacing.base) {
                XMBookCover.fixedSize(
                    width: 54,
                    height: 78,
                    urlString: book.coverURL,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth)
                )

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text(book.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    Text(ReadDurationFormatter.format(seconds: Int64(book.totalReadSeconds)))
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    if book.readDoneCount > 1 {
                        Text("读完 \(book.readDoneCount) 次")
                            .font(.caption2)
                            .foregroundStyle(Color.textHint)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textHint)
            }
            .padding(Spacing.base)
        }
    }
}
