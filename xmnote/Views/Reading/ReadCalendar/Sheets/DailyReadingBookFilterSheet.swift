/**
 * [INPUT]: 依赖 DailyReadingBookSummary、XMBookCover、当前书籍筛选值与选择回调
 * [OUTPUT]: 对外提供 DailyReadingBookFilterSheet，以系统列表完成当天书籍范围选择
 * [POS]: ReadCalendar 当日阅读轨迹页面私有业务 Sheet，由顶部更多菜单按需打开
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 当天书籍范围选择 Sheet；点击任一行立即应用选项并关闭。
struct DailyReadingBookFilterSheet: View {
    let books: [DailyReadingBookSummary]
    let selectedBookID: Int64?
    let onSelectBook: (Int64?) -> Void

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var coverWidth = 30.0

    var body: some View {
        XMSheetScaffold(
            title: "筛选书籍",
            onClose: { dismiss() }
        ) {
            XMSettingsGroup(horizontalPadding: Spacing.none, verticalPadding: Spacing.none) {
                LazyVStack(spacing: Spacing.none) {
                selectionButton(
                    title: "全部书籍",
                    coverURL: nil,
                    bookID: nil
                )

                if !books.isEmpty {
                    XMSettingsDivider()
                        .padding(.leading, Spacing.contentEdge)
                }

                ForEach(books.enumerated(), id: \.element.id) { index, summary in
                    selectionButton(
                        title: summary.book.name,
                        coverURL: summary.book.coverURL,
                        bookID: summary.id
                    )

                    if index < books.count - 1 {
                        XMSettingsDivider()
                            .padding(.leading, Spacing.contentEdge)
                    }
                }
            }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    /// 使用真实书籍主键判断选中状态；nil 专门代表“全部书籍”。
    private func isSelected(_ bookID: Int64?) -> Bool {
        selectedBookID == bookID
    }

    /// 组装书籍选择行；封面只用于 Sheet 内识别，不进入阅读轨迹内容层。
    private func selectionButton(
        title: String,
        coverURL: String?,
        bookID: Int64?
    ) -> some View {
        let selected = isSelected(bookID)

        return Button {
            applySelection(bookID)
        } label: {
            HStack(spacing: Spacing.base) {
                if let coverURL {
                    XMBookCover.fixedWidth(
                        coverWidth,
                        urlString: coverURL,
                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline)
                    )
                } else {
                    Image(systemName: "books.vertical")
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(selected ? Color.selectionAccent : Color.iconSecondary)
                        .frame(width: coverWidth, height: coverWidth / 0.7)
                }

                Text(title.isEmpty ? "未命名书籍" : title)
                    .font(AppTypography.body)
                    .foregroundStyle(selected ? Color.selectionAccent : Color.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: Spacing.base)

                if selected {
                    Image(systemName: "checkmark")
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.appTint)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.isEmpty ? "未命名书籍" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 在主 Actor 的下一次调度应用筛选并关闭，避免 Sheet 移除与同一次触摸结束事件竞争。
    /// 任务不跨越页面生命周期持有外部资源；Sheet 被系统提前关闭时，幂等 dismiss 不产生额外状态写入。
    private func applySelection(_ bookID: Int64?) {
        Task { @MainActor in
            await Task.yield()
            onSelectBook(bookID)
            dismiss()
        }
    }
}
