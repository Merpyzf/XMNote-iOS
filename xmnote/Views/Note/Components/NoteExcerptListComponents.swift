/**
 * [INPUT]: 依赖 NoteExcerptListItem/RelatedListItem 展示模型、XMKeywordHighlighting、DesignTokens、XMBookCover、CardContainer、LoadingGate 与 Reduce Motion 环境
 * [OUTPUT]: 对外提供带关键字高亮的 NoteExcerptListRow、RelatedListRow 与可选稳定叠层阶段过渡的 NoteListPhaseHost 等笔记二级页私有组件
 * [POS]: Note/Components 的二级列表视觉组件集合，复用当前 iOS 阅读排版、搜索高亮和卡片语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘二级列表卡片；正文、想法与附图是主体，书籍来源只在弱页脚提供上下文。
struct NoteExcerptListRow: View {
    let item: NoteExcerptListItem
    let searchKeyword: String
    let hiddenTagID: Int64?
    let isSelecting: Bool
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CardContainer(showsBorder: true, borderColor: Color.surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                contentPreview
                if !item.plainIdea.isEmpty {
                    ideaPreview
                        .transition(.opacity)
                }
                if !item.imageURLs.isEmpty {
                    imagePreview
                        .transition(.opacity)
                }
                if !visibleTags.isEmpty {
                    tagRow
                        .transition(.opacity)
                }
                footer
            }
            .padding(Spacing.contentEdge)
        }
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(AppTypography.title3)
                    .foregroundStyle(isSelected ? Color.brand : Color.textHint)
                    .padding(Spacing.base)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale.combined(with: .opacity)
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelecting ? (isSelected ? "已选择" : "未选择") : "")
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.plainContent.isEmpty {
            Text("（无正文）")
                .font(NoteExcerptTypography.body)
                .foregroundStyle(Color.textHint)
        } else {
            XMKeywordHighlighting.text(
                item.plainContent,
                keyword: searchKeyword,
                baseFont: NoteExcerptTypography.body,
                highlightFont: NoteExcerptTypography.body,
                baseColor: Color.textPrimary
            )
                .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                .lineLimit(5)
                .contentTransition(.opacity)
        }
    }

    private var ideaPreview: some View {
        XMKeywordHighlighting.text(
            item.plainIdea,
            keyword: searchKeyword,
            baseFont: NoteExcerptTypography.idea,
            highlightFont: NoteExcerptTypography.idea,
            baseColor: Color.textSecondary
        )
            .lineSpacing(NoteExcerptTypography.ideaLineSpacing)
            .lineLimit(4)
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.cozy)
            .background(
                Color.surfaceAnnotation,
                in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
            )
    }

    private var imagePreview: some View {
        ContentImageWall(
            imageURLs: item.imageURLs,
            prefix: "note-list-\(item.id)"
        )
        .accessibilityLabel("书摘附图，共 \(item.imageURLs.count) 张")
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.cozy) {
                ForEach(visibleTags) { tag in
                    Text(tag.title)
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Spacing.cozy)
                        .frame(minHeight: 24)
                        .background(
                            Color.tagBackground,
                            in: Capsule()
                        )
                }
            }
        }
        .scrollClipDisabled()
    }

    private var footer: some View {
        HStack(spacing: Spacing.cozy) {
            Text(item.bookTitle.isEmpty ? "未知书籍" : "《\(item.bookTitle)》")
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Spacing.compact)

            if let positionText = NotePositionUnitFormatter.footerText(
                position: item.position,
                unit: item.positionUnit
            ) {
                Text(positionText)
            }
            if item.includeTime, item.createdDate > 0 {
                Text(formattedDate(item.createdDate))
            }
        }
        .font(NoteExcerptTypography.footer)
        .foregroundStyle(Color.textSecondary)
        .contentTransition(.opacity)
    }

    private var visibleTags: [NoteExcerptTagItem] {
        guard let hiddenTagID else { return item.tags }
        return item.tags.filter { $0.id != hiddenTagID }
    }

    private var accessibilityLabel: String {
        [item.bookTitle, item.chapterTitle, item.plainContent, item.plainIdea]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    private func formattedDate(_ timestamp: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            .formatted(date: .abbreviated, time: .omitted)
    }
}

/// 相关混排卡片；普通内容保持文本层级，相关书籍必须统一通过 XMBookCover 渲染。
struct RelatedListRow: View {
    let item: RelatedListItem

    var body: some View {
        CardContainer(showsBorder: true, borderColor: Color.surfaceBorderSubtle) {
            switch item {
            case .content(let content):
                contentRow(content)
            case .book(let book):
                bookRow(book)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func contentRow(_ content: RelatedContentListItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.cozy) {
                Label(content.categoryTitle, systemImage: "link")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.brand)
                Spacer(minLength: Spacing.compact)
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }

            Text(content.title.isEmpty ? "相关内容" : content.title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            let plainText = RichTextPlainTextExtractor.plainText(from: content.contentHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                Text(plainText)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(4)
            }

            HStack(spacing: Spacing.cozy) {
                Text(content.sourceBookTitle)
                if !content.imageURLs.isEmpty {
                    Label("\(content.imageURLs.count)", systemImage: "photo")
                }
                Spacer(minLength: Spacing.compact)
                Text(formattedDate(content.createdDate))
            }
            .font(NoteExcerptTypography.footer)
            .foregroundStyle(Color.textSecondary)
        }
        .padding(Spacing.contentEdge)
    }

    private func bookRow(_ book: RelatedBookListItem) -> some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedHeight(
                60,
                urlString: book.coverURL,
                placeholderIconSize: .small
            )

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Label("相关书籍", systemImage: "books.vertical")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.brand)

                Text(book.title)
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }

                Text("来自《\(book.sourceBookTitle)》")
                    .font(NoteExcerptTypography.footer)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)
            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .padding(Spacing.contentEdge)
    }

    private func formattedDate(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            .formatted(date: .abbreviated, time: .omitted)
    }
}

/// 二级页面阶段宿主，统一应用读取延迟门闩、空态和可重试错误态。
struct NoteListPhaseHost<Content: View>: View {
    let isLoading: Bool
    let isEmpty: Bool
    let errorMessage: String?
    let loadingMessage: String
    let emptyMessage: String
    let emptyIcon: String
    let animatesEmptyContentTransition: Bool
    let onRetry: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadingGate = LoadingGate()

    /// 构建统一阶段宿主；默认维持既有硬切，仅由需要解释筛选结果变化的列表开启空态过渡。
    init(
        isLoading: Bool,
        isEmpty: Bool,
        errorMessage: String?,
        loadingMessage: String,
        emptyMessage: String,
        emptyIcon: String,
        animatesEmptyContentTransition: Bool = false,
        onRetry: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.errorMessage = errorMessage
        self.loadingMessage = loadingMessage
        self.emptyMessage = emptyMessage
        self.emptyIcon = emptyIcon
        self.animatesEmptyContentTransition = animatesEmptyContentTransition
        self.onRetry = onRetry
        self.content = content()
    }

    var body: some View {
        Group {
            if loadingGate.isVisible {
                LoadingStateView(loadingMessage, style: .card)
                    .padding(Spacing.screenEdge)
            } else if isLoading {
                Color.clear
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("暂时无法加载", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试", action: onRetry)
                }
            } else {
                successContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: syncLoadingGate)
        .onChange(of: isLoading) { _, _ in syncLoadingGate() }
        .onDisappear { loadingGate.hideImmediately() }
    }

    /// 需要过渡时让列表与空态短暂共享稳定父层，避免先卸载列表导致最后一行硬切。
    @ViewBuilder
    private var successContent: some View {
        if animatesEmptyContentTransition {
            ZStack {
                content
                    .opacity(isEmpty ? 0 : 1)
                    .allowsHitTesting(!isEmpty)
                    .accessibilityHidden(isEmpty)

                EmptyStateView(icon: emptyIcon, message: emptyMessage)
                    .opacity(isEmpty ? 1 : 0)
                    .allowsHitTesting(isEmpty)
                    .accessibilityHidden(!isEmpty)
            }
            .animation(emptyContentAnimation, value: isEmpty)
        } else if isEmpty {
            EmptyStateView(icon: emptyIcon, message: emptyMessage)
        } else {
            content
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: isLoading ? .read : .none)
    }

    private var emptyContentAnimation: Animation? {
        guard animatesEmptyContentTransition else { return nil }
        return .easeOut(duration: reduceMotion ? 0.10 : 0.16)
    }
}
