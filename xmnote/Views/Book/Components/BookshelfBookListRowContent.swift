/**
 * [INPUT]: 依赖 BookshelfBookListItem、BookshelfSortCriteria、BookshelfTitleText、XMBookCover 与书架封面角标组件
 * [OUTPUT]: 对外提供 BookshelfBookListRowContent 及复用共享封面状态语义的列表行信息、阅读元信息、标签、排序辅助展示组件
 * [POS]: Book 模块页面私有列表行展示组件，被默认书架与二级书籍列表复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍列表行主体内容，只负责渲染书籍展示信息，不持有菜单、选择、拖拽等外壳交互。
struct BookshelfBookListRowContent: View {
    let book: BookshelfBookListItem
    let showsNoteCount: Bool
    let sortCriteria: BookshelfSortCriteria
    let titleDisplayMode: BookshelfTitleDisplayMode
    let searchKeyword: String
    var showsChevron = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            HStack(alignment: .top, spacing: Spacing.base) {
                BookshelfBookCoverBadgeLayer(
                    book: book,
                    showsNoteCount: showsNoteCount
                )

                BookshelfBookInfoStack(
                    book: book,
                    titleDisplayMode: titleDisplayMode,
                    searchKeyword: searchKeyword
                )

                Spacer(minLength: Spacing.compact)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                        .padding(.top, Spacing.base)
                }
            }
            .padding(Spacing.base)
            .background(
                Color.surfaceCard,
                in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }

            if let sortAuxiliaryText {
                BookshelfSortHintLine(text: sortAuxiliaryText)
            }
        }
    }

    private var sortAuxiliaryText: String? {
        book.sortAuxiliaryText(for: sortCriteria)
    }
}

/// 统一封面上的阅读状态、置顶和书摘数角标，内部继续使用 XMBookCover。
struct BookshelfBookCoverBadgeLayer: View {
    let book: BookshelfBookListItem
    let showsNoteCount: Bool

    private let coverWidth: CGFloat = 60
    private let coverCornerRadius = CornerRadius.inlaySmall

    var body: some View {
        XMBookCover.fixedWidth(
            coverWidth,
            urlString: book.cover,
            cornerRadius: coverCornerRadius,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .small,
            surfaceStyle: .spine
        )
        .overlay {
            ZStack {
                if book.pinned {
                    BookshelfCoverPinBadge(cornerRadius: coverCornerRadius)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let statusBadge {
                    BookshelfCoverTextBadge(
                        text: statusBadge.title,
                        placement: .topTrailing,
                        tone: .status(statusBadge.color),
                        cornerRadius: coverCornerRadius,
                        accessibilityLabel: "阅读状态\(statusBadge.title)"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if showsNoteCount, book.noteCount > 0 {
                    BookshelfCoverTextBadge(
                        text: "\(book.noteCount)",
                        placement: .bottomTrailing,
                        tone: .dark,
                        cornerRadius: coverCornerRadius,
                        accessibilityLabel: "\(book.noteCount)条书摘"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    private var statusBadge: BookshelfBookListStatusBadge? {
        guard let status = BookEntryReadingStatus(rawValue: book.readStatusId) else { return nil }
        let title = book.readStatusBadgeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return BookshelfBookListStatusBadge(
            title: title.isEmpty ? status.title : title,
            color: status.coverBadgeColor
        )
    }
}

/// 列表封面阅读状态角标载荷。
private struct BookshelfBookListStatusBadge {
    let title: String
    let color: Color
}

/// 统一标题、评分、基础信息、阅读信息和标签的垂直信息栈。
struct BookshelfBookInfoStack: View {
    let book: BookshelfBookListItem
    let titleDisplayMode: BookshelfTitleDisplayMode
    let searchKeyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            BookshelfTitleText(
                text: book.title,
                mode: titleDisplayMode,
                style: .bodyMedium,
                color: .textPrimary,
                highlightKeyword: searchKeyword
            )

            if book.score > 0 {
                BookshelfBookRatingLine(score: book.score)
            }

            if !book.bookListBasicMetadataText.isEmpty {
                XMKeywordHighlighting.text(
                    book.bookListBasicMetadataText,
                    keyword: searchKeyword,
                    baseFont: AppTypography.caption,
                    highlightFont: AppTypography.caption,
                    baseColor: Color.textSecondary
                )
                .lineLimit(1)
            }

            if book.hasBookListReadingMetadata {
                BookshelfBookReadingMetaRow(
                    bookmarkText: book.bookListBookmarkText,
                    totalReadingTimeText: book.bookListReadingDurationText,
                    readingProgressText: book.readingProgressText
                )
            }

            if !book.tags.isEmpty {
                BookshelfBookTagStrip(tags: book.tags)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 列表评分行，有评分才展示，位置固定在标题后、基础信息前。
struct BookshelfBookRatingLine: View {
    let score: Int64

    var body: some View {
        HStack(spacing: Spacing.half) {
            XMRatingBar(score: score, preset: .listSmall)
            Text(String(format: "%.1f", Double(score) / 10.0))
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("评分\(String(format: "%.1f", Double(score) / 10.0))")
    }
}

/// 统一书签页码、阅读时长和阅读进度的图标加文本表达。
struct BookshelfBookReadingMetaRow: View {
    let bookmarkText: String
    let totalReadingTimeText: String
    let readingProgressText: String

    var body: some View {
        HStack(spacing: Spacing.base) {
            if !bookmarkText.isEmpty {
                BookshelfBookIconMeta(systemImage: "bookmark", text: bookmarkText)
            }
            if !totalReadingTimeText.isEmpty {
                BookshelfBookIconMeta(systemImage: "clock", text: totalReadingTimeText)
            }
            if !readingProgressText.isEmpty {
                BookshelfBookIconMeta(systemImage: "arrow.right.circle", text: readingProgressText)
            }
        }
        .lineLimit(1)
    }
}

/// 列表行内的图标和文本辅助信息。
private struct BookshelfBookIconMeta: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: Spacing.micro) {
            Image(systemName: systemImage)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
            Text(text)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 统一标签展示，列表默认最多展示三个标签并用 +N 收束溢出。
struct BookshelfBookTagStrip: View {
    let tags: [BookshelfBookListTag]

    var body: some View {
        HStack(spacing: Spacing.half) {
            ForEach(visibleTags) { tag in
                BookshelfBookTagChip(text: tag.name)
            }

            if hiddenCount > 0 {
                BookshelfBookTagChip(text: "+\(hiddenCount)", isOverflow: true)
            }
        }
        .lineLimit(1)
    }

    private var visibleTags: [BookshelfBookListTag] {
        Array(tags.prefix(3))
    }

    private var hiddenCount: Int {
        max(0, tags.count - visibleTags.count)
    }
}

/// 书籍列表轻量标签胶囊。
private struct BookshelfBookTagChip: View {
    let text: String
    var isOverflow = false

    var body: some View {
        Text(text)
            .font(AppTypography.caption2Medium)
            .foregroundStyle(isOverflow ? Color.textHint : Color.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.micro)
            .background(Color.surfaceNested, in: Capsule())
    }
}

/// 创建、修改、读完时间排序时的弱辅助行，不挤压主卡片信息层级。
struct BookshelfSortHintLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.caption2)
            .foregroundStyle(Color.textHint)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Spacing.base)
    }
}

extension BookshelfBookListItem {
    /// 按 Android 列表顺序组合作者、出版时间和出版社，供列表行渲染与可访问性复用。
    nonisolated var bookListBasicMetadataText: String {
        [author, pubDateText, press]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// 仅在存在有效书签页码时输出，避免空值挤出无意义图标。
    nonisolated var bookListBookmarkText: String {
        bookmarkText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 阅读总时长大于 0 时才展示 Android 同源时长文案。
    nonisolated var bookListReadingDurationText: String {
        totalReadingTime > 0 ? totalReadingTimeText : ""
    }

    /// 控制阅读信息行是否出现，确保三个字段全空时整行隐藏。
    nonisolated var hasBookListReadingMetadata: Bool {
        !bookListBookmarkText.isEmpty
            || !bookListReadingDurationText.isEmpty
            || !readingProgressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 评分的可访问性文案，零分按列表展示规则隐藏。
    nonisolated var bookListRatingAccessibilityText: String {
        guard score > 0 else { return "" }
        return "评分\(String(format: "%.1f", Double(score) / 10.0))"
    }

    /// 阅读信息的可访问性文案，顺序与视觉展示保持一致。
    nonisolated var bookListReadingAccessibilityText: String {
        [bookListBookmarkText, bookListReadingDurationText, readingProgressText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}
