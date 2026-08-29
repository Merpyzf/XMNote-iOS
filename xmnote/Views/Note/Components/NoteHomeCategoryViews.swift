/**
 * [INPUT]: 依赖 StarredChapterGroup、RelatedCategorySnapshot、BookReviewListSnapshot 只读模型，接收分类搜索词与业务操作回调，并使用 XMBookCover/ExpandableRichText/ContentImageWall/XMRatingBar/XMToastCenter 基础组件
 * [OUTPUT]: 对外提供 Note 页面私有的星标章节、相关分类与增量书评首页内容视图，以连续阅读流承载正文展开、附图浏览、轻透明紧凑书籍来源区、编辑型元信息页脚及中性上下文操作
 * [POS]: Note/Components 页面私有展示集合，仅被 NoteCollectionView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 笔记首页书评卡的局部 UIKit 排版，保持现有系统 subheadline 语义曲线。
private enum NoteHomeCategoryTypography {
    static var reviewBodyUIFont: UIFont {
        AppTypography.uiSemantic(.subheadline)
    }
}

/// 星标章节按书籍分组展示，保持 Android 的书籍摘要、目录顺序与精简章节行层级。
struct NoteStarredChapterGroupsView: View {
    let groups: [StarredChapterGroup]
    let searchKeyword: String
    let onOpenChapter: (StarredChapterItem) -> Void
    let onOpenBook: (Int64) -> Void
    let onLocateChapter: (StarredChapterItem) -> Void
    let onRemoveStar: (StarredChapterItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVStack(spacing: Spacing.base) {
            ForEach(groups) { group in
                CardContainer(showsBorder: false) {
                    VStack(spacing: Spacing.none) {
                        NoteStarredBookHeader(
                            group: group,
                            searchKeyword: searchKeyword,
                            onOpenBook: { onOpenBook(group.id) }
                        )

                        ForEach(group.chapters) { chapter in
                            Divider()
                                .opacity(0.18)
                                .padding(.horizontal, Spacing.base)
                            NoteStarredChapterRow(
                                chapter: chapter,
                                searchKeyword: searchKeyword,
                                onOpenChapter: { onOpenChapter(chapter) },
                                onOpenBook: { onOpenBook(chapter.bookID) },
                                onLocateChapter: { onLocateChapter(chapter) },
                                onRemoveStar: { onRemoveStar(chapter) }
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.base)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: groups.flatMap(\.chapters).map(\.id)
        )
    }
}

/// 星标章节书籍头只展示识别书籍与分组规模所需的信息。
private struct NoteStarredBookHeader: View {
    let group: StarredChapterGroup
    let searchKeyword: String
    let onOpenBook: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var coverWidth = 30

    var body: some View {
        Button(action: onOpenBook) {
            HStack(spacing: Spacing.tight) {
                XMBookCover.fixedWidth(
                    coverWidth,
                    urlString: group.bookCoverURL,
                    placeholderIconSize: .small
                )

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    XMKeywordHighlighting.text(
                        group.bookTitle,
                        keyword: searchKeyword,
                        baseFont: AppTypography.subheadlineMedium,
                        highlightFont: AppTypography.subheadlineSemibold,
                        baseColor: Color.textPrimary
                    )
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if !group.bookAuthor.isEmpty {
                        XMKeywordHighlighting.text(
                            group.bookAuthor,
                            keyword: searchKeyword,
                            baseFont: AppTypography.caption2,
                            highlightFont: AppTypography.caption2Semibold,
                            baseColor: Color.textSecondary
                        )
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: Spacing.cozy)

                Text("\(group.chapterCount.formatted()) 个章节")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(.numericText())
            }
            .padding(Spacing.base)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bookAccessibilityLabel)
        .accessibilityHint("打开书籍详情")
    }

    private var bookAccessibilityLabel: String {
        let author = group.bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = author.isEmpty ? group.bookTitle : "\(group.bookTitle)，\(author)"
        return "\(book)，\(group.chapterCount) 个星标章节"
    }
}

/// 单个星标章节行以星形、标题、后代书摘计数和导航箭头表达核心任务。
private struct NoteStarredChapterRow: View {
    let chapter: StarredChapterItem
    let searchKeyword: String
    let onOpenChapter: () -> Void
    let onOpenBook: () -> Void
    let onLocateChapter: () -> Void
    let onRemoveStar: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var starSize = 16

    var body: some View {
        Button(action: onOpenChapter) {
            HStack(spacing: Spacing.tight) {
                XMFluentStarIcon(size: starSize)
                    .frame(width: Spacing.section)
                    .accessibilityHidden(true)

                XMKeywordHighlighting.text(
                    chapter.title,
                    keyword: searchKeyword,
                    baseFont: AppTypography.subheadline,
                    highlightFont: AppTypography.subheadlineSemibold,
                    baseColor: Color.textPrimary
                )
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

                NoteStarredChapterCountBadge(count: chapter.descendantNoteCount)
                    .accessibilityHidden(true)

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chapter.title)，已星标，含子章节共 \(chapter.descendantNoteCount) 条书摘")
        .accessibilityHint("打开本章节及其子章节书摘")
        .accessibilityAction(named: "取消星标", onRemoveStar)
        .contextMenu {
            Button("取消星标", systemImage: "star.fill", action: onRemoveStar)
            Button("打开目录", systemImage: "list.bullet", action: onLocateChapter)
            Button("打开书籍", systemImage: "book.closed", action: onOpenBook)
        }
        .xmMenuNeutralTint()
    }
}

/// 章节后代书摘计数仅在星标列表内使用，不扩张为跨模块 Badge 基建。
private struct NoteStarredChapterCountBadge: View {
    let count: Int

    @ScaledMetric(relativeTo: .caption2) private var minimumWidth = 32

    var body: some View {
        Text("\(count.formatted()) 条")
            .font(ReadingContentTypography.metadata)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.tiny)
            .frame(minWidth: minimumWidth)
            .background(Color.controlFillSecondary.opacity(0.72), in: Capsule())
            .contentTransition(.numericText())
    }
}

/// 相关入口按 Android 信息模型呈现双列索引，仅保留分类名、数量与可进入提示。
struct NoteRelatedCategoriesView: View {
    let snapshot: RelatedCategorySnapshot
    let searchQuery: String
    let isWriting: Bool
    let onOpenCategory: (RelatedCategoryScope) -> Void
    let onUnavailableCategory: (RelatedCategoryItem) -> Void
    let onRequestDelete: (RelatedCategoryItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: NoteIndexGridLayout.rowSpacing) {
            ForEach(snapshot.items) { item in
                NoteRelatedCategoryItemView(
                    item: item,
                    searchQuery: searchQuery,
                    isWriting: isWriting,
                    onOpenCategory: onOpenCategory,
                    onUnavailableCategory: onUnavailableCategory,
                    onRequestDelete: onRequestDelete
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.base)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: snapshot.items.map(\.id)
        )
    }

    private var gridColumns: [GridItem] {
        NoteIndexGridLayout.columns(dynamicTypeSize: dynamicTypeSize)
    }
}

/// 单个相关分类索引保持稳定身份，并按内容数量决定进入提示与长按管理能力。
private struct NoteRelatedCategoryItemView: View {
    let item: RelatedCategoryItem
    let searchQuery: String
    let isWriting: Bool
    let onOpenCategory: (RelatedCategoryScope) -> Void
    let onUnavailableCategory: (RelatedCategoryItem) -> Void
    let onRequestDelete: (RelatedCategoryItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if canManage {
            categoryButton
                .contextMenu {
                    Button(
                        item.isDefault ? "清空分类内容" : "删除分类",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        onRequestDelete(item)
                    }
                    .disabled(isWriting)
                }
                .xmMenuNeutralTint()
        } else {
            categoryButton
        }
    }

    private var categoryButton: some View {
        NoteIndexGridItemButton(
            title: item.title,
            count: item.contentCount,
            searchQuery: searchQuery,
            accessibilityLabel: "\(item.title)，\(item.contentCount) 条相关内容",
            accessibilityHint: accessibilityHint
        ) {
            if item.contentCount == 0 {
                onUnavailableCategory(item)
            } else {
                onOpenCategory(item.scope)
            }
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.18),
            value: item.contentCount
        )
    }

    private var canManage: Bool {
        guard item.contentCount > 0 else { return false }
        if case .title = item.scope {
            return true
        }
        return false
    }

    private var accessibilityHint: String {
        if item.contentCount == 0 {
            return "这个分类还没有相关内容"
        }
        if item.scope == .all {
            return "打开相关内容列表"
        }
        return "打开列表；长按可管理此分类"
    }
}

/// 全量书评首页用单一阅读表面组织内容，保留增量分页但不重复宣告终点状态。
struct NoteBookReviewsView: View {
    let snapshot: BookReviewListSnapshot
    let isLoadingMore: Bool
    let loadMoreErrorMessage: String?
    let onOpenReview: (BookReviewListItem) -> Void
    let onOpenBook: (Int64) -> Void
    let onEditReview: (Int64) -> Void
    let onDeleteReview: (BookReviewListItem) -> Void
    let onRateBook: (BookReviewListItem) -> Void
    let onLoadMoreIfNeeded: (Int64) -> Void
    let onRetryLoadMore: () -> Void
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.base) {
            LazyVStack(spacing: Spacing.none) {
                ForEach(snapshot.items) { item in
                    NoteBookReviewListRow(
                        item: item,
                        showsDivider: item.id != snapshot.items.last?.id,
                        onOpenReview: { onOpenReview(item) },
                        onOpenBook: { onOpenBook(item.bookID) },
                        onRateBook: { onRateBook(item) },
                        onEditReview: { onEditReview(item.id) },
                        onCopyReview: { copyReview(item) },
                        onDeleteReview: { onDeleteReview(item) }
                    )
                    .onAppear {
                        onLoadMoreIfNeeded(item.id)
                    }
                }
            }
            .background(Color.surfaceCard)
            .compositingGroup()
            .clipShape(.rect(cornerRadius: CornerRadius.containerMedium))

            paginationFooter
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.base)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: snapshot.items.map(\.id)
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.18),
            value: isLoadingMore
        )
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if isLoadingMore {
            LoadingStateView("继续加载书评…", style: .inline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.cozy)
                .transition(.opacity)
        } else if let loadMoreErrorMessage {
            XMInlineStatusBanner(
                "继续加载书评失败：\(loadMoreErrorMessage)",
                tone: .error,
                action: XMStateAction(
                    "重试",
                    perform: onRetryLoadMore
                )
            )
            .padding(.vertical, Spacing.cozy)
            .transition(.opacity)
        }
    }

    /// 用户明确选择复制后才解析富文本，避免列表滚动时重复做 HTML 转换。
    private func copyReview(_ item: BookReviewListItem) {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = RichTextPlainTextExtractor.plainText(from: item.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = [title, content]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        toastCenter.success("已复制书评")
    }
}

/// 列表行让同一阅读表面中的书评通过弱分隔保持节奏，不再重复绘制卡片边框。
private struct NoteBookReviewListRow: View {
    let item: BookReviewListItem
    let showsDivider: Bool
    let onOpenReview: () -> Void
    let onOpenBook: () -> Void
    let onRateBook: () -> Void
    let onEditReview: () -> Void
    let onCopyReview: () -> Void
    let onDeleteReview: () -> Void

    var body: some View {
        VStack(spacing: Spacing.none) {
            NoteBookReviewCard(
                item: item,
                onOpenReview: onOpenReview,
                onOpenBook: onOpenBook,
                onRateBook: onRateBook,
                onEditReview: onEditReview,
                onCopyReview: onCopyReview,
                onDeleteReview: onDeleteReview
            )

            Divider()
                .overlay(Color.surfaceDividerSubtle)
                .padding(.horizontal, Spacing.contentEdge)
                .opacity(showsDivider ? 1 : 0)
        }
    }
}

/// 单张书评以正文为主阅读层，来源、评分和元信息仅作为内容后的轻量归因。
private struct NoteBookReviewCard: View {
    let item: BookReviewListItem
    let onOpenReview: () -> Void
    let onOpenBook: () -> Void
    let onRateBook: () -> Void
    let onEditReview: () -> Void
    let onCopyReview: () -> Void
    let onDeleteReview: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            reviewContentGroup

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                NoteBookReviewAttributionRow(item: item)

                NoteBookReviewMetadataRow(
                    wordCount: item.wordCount,
                    createdTimestamp: item.createdDate
                )
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.section)
        .contextMenu {
            Button("查看", systemImage: "doc.text.magnifyingglass", action: onOpenReview)
            Button("打开来源书籍", systemImage: "book", action: onOpenBook)
            Button("评分", systemImage: "star", action: onRateBook)
            Button("编辑", systemImage: "square.and.pencil", action: onEditReview)
            if hasCopyableText {
                Button("复制", systemImage: "doc.on.doc", action: onCopyReview)
            }
            Button("删除", systemImage: "trash", role: .destructive, action: onDeleteReview)
        }
        .xmMenuNeutralTint()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reviewTitle.isEmpty ? "书评" : reviewTitle)
        .accessibilityAction(named: "查看书评", onOpenReview)
    }

    private var reviewContentGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if !reviewTitle.isEmpty {
                Button(action: onOpenReview) {
                    Text(reviewTitle)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开完整书评")
            }

            if item.wordCount > 0 {
                ExpandableRichText(
                    html: item.contentHTML,
                    baseFont: NoteHomeCategoryTypography.reviewBodyUIFont,
                    textColor: UIColor.xmResolved(Color.textPrimary),
                    lineSpacing: ReadingContentTypography.bodyLineSpacing,
                    maxLines: 5,
                    previewTapIdentity: item.id,
                    onPreviewTap: onOpenReview
                )
                .equatable()
                .transaction { transaction in
                    if reduceMotion {
                        transaction.disablesAnimations = true
                    }
                }
            }

            if !item.imageURLs.isEmpty {
                ContentImageWall(
                    imageURLs: item.imageURLs,
                    prefix: "note-review-\(item.id)"
                )
                .accessibilityLabel("书评附图，共 \(item.imageURLs.count) 张")
            }
        }
    }

    private var reviewTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCopyableText: Bool {
        !reviewTitle.isEmpty || item.wordCount > 0
    }
}

/// 书籍来源区以轻透明紧凑表面组织封面、书名与评分；具体操作统一收纳到上下文菜单和详情页。
private struct NoteBookReviewAttributionRow: View {
    let item: BookReviewListItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var coverWidth: CGFloat = 34

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    bookIdentity
                    ratingSummary
                }
            } else {
                HStack(alignment: .center, spacing: Spacing.tight) {
                    bookCover

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        bookTitle
                        ratingSummary
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.surfaceNested.opacity(0.42),
            in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sourceAccessibilityLabel)
    }

    private var bookIdentity: some View {
        HStack(spacing: Spacing.tight) {
            bookCover
            bookTitle
        }
    }

    private var bookCover: some View {
        XMBookCover.fixedWidth(
            coverWidth,
            urlString: item.bookCoverURL,
            placeholderIconSize: .small
        )
    }

    private var bookTitle: some View {
        Text(item.bookTitle)
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var ratingSummary: some View {
        if item.bookScore > 0 {
            XMRatingBar(score: item.bookScore, preset: .listSmall)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text("未评分")
                .font(ReadingContentTypography.metadata)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var sourceAccessibilityLabel: String {
        let rating = item.bookScore > 0 ? "评分 \(formattedScore) 星" : "未评分"
        return "书籍，\(item.bookTitle)，\(rating)"
    }

    private var formattedScore: String {
        (Double(item.bookScore) / 10.0).formatted(
            .number.precision(.fractionLength(1))
        )
    }
}

/// 书评辅助信息保持最低视觉权重，不再为重复的详情提示预留操作高度。
private struct NoteBookReviewMetadataRow: View {
    let wordCount: Int
    let createdTimestamp: Int64
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize, visualDateText != nil {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    wordCountText
                    dateText
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    wordCountText

                    if visualDateText != nil {
                        Spacer(minLength: Spacing.base)
                        dateText
                    }
                }
            }
        }
        .font(ReadingContentTypography.metadata)
        .foregroundStyle(Color.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var wordCountText: some View {
        Text("\(wordCount.formatted()) 字")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var dateText: some View {
        if let visualDateText {
            Text(visualDateText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var createdDate: Date? {
        guard createdTimestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(createdTimestamp) / 1_000)
    }

    private var visualDateText: String? {
        guard let createdDate else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let includesYear = calendar.component(.year, from: createdDate)
            != calendar.component(.year, from: Date())
        if includesYear {
            return createdDate.formatted(.dateTime.year().month().day())
        }
        return createdDate.formatted(.dateTime.month().day())
    }

    private var accessibilityLabel: String {
        guard let createdDate else {
            return "\(wordCount.formatted()) 字"
        }
        let fullDate = createdDate.formatted(.dateTime.year().month().day())
        return "\(wordCount.formatted()) 字，创建于 \(fullDate)"
    }
}
