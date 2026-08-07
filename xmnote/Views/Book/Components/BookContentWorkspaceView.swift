/**
 * [INPUT]: 依赖 NoteExcerpt、BookContentWorkspaceSnapshot、单书排序偏好与类型安全路由，复用 XMBookCover、CardContainer、LoadingGate 和设计令牌
 * [OUTPUT]: 对外提供 BookContentWorkspaceView，展示书摘、书评、相关内容及各类型排序、相关书资料编辑/新增/管理入口
 * [POS]: Book 详情页私有内容组件，以当前 iOS 设计系统重组 Android 书内四页笔记域能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍详情笔记域工作区，使用 iOS 分段选择保留书摘、书评与相关内容浏览现场。
struct BookContentWorkspaceView: View {
    let bookID: Int64
    let notes: [NoteExcerpt]
    let snapshot: BookContentWorkspaceSnapshot
    let isLoading: Bool
    let errorMessage: String?
    let isWriting: Bool
    let onRetry: () -> Void
    let onCreateRelatedContent: () -> Void
    let onAddRelatedBook: () -> Void
    let onManageCategories: () -> Void
    let onChangeSort: (BookContentSortType, BookContentSortRule) -> Void
    let onEditRelatedBook: (BookContentRelatedItem) -> Void
    let onRequestDeleteRelatedBook: (BookContentRelatedItem) -> Void
    let onOpenRelatedPlaceholder: (BookContentRelatedItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: BookContentWorkspaceTab = .notes
    @State private var loadingGate = LoadingGate()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            categoryPicker
            selectedContent
                .id(selection)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .snappy, value: displayedItemIDs)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: selection)
        .onAppear(perform: syncLoadingGate)
        .onChange(of: isLoading) { _, _ in syncLoadingGate() }
        .onDisappear { loadingGate.hideImmediately() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.micro) {
                Text("笔记内容")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text(selectionSummary)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)
            HStack(spacing: Spacing.cozy) {
                sortMenu
                actionControl
            }
        }
        .padding(.top, Spacing.half)
    }

    private var sortMenu: some View {
        Menu {
            Section("排序方式") {
                ForEach(BookContentSortRule.allowedRules(for: selectedSortType), id: \.self) { rule in
                    Button {
                        onChangeSort(selectedSortType, rule)
                    } label: {
                        Label(
                            rule.menuTitle,
                            systemImage: rule == selectedSortRule ? "checkmark" : rule.systemImage
                        )
                    }
                    .disabled(rule == selectedSortRule)
                }
            }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
                .font(AppTypography.subheadline)
        }
        .disabled(isWriting || isLoading || errorMessage != nil)
        .accessibilityLabel("排序")
        .accessibilityValue(selectedSortRule.menuTitle)
    }

    private var categoryPicker: some View {
        Picker("笔记内容类型", selection: $selection) {
            ForEach(BookContentWorkspaceTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("笔记内容类型")
    }

    @ViewBuilder
    private var actionControl: some View {
        switch selection {
        case .notes:
            NavigationLink(value: NoteRoute.create(seed: NoteEditorSeed(
                bookId: bookID,
                chapterId: nil,
                contentHTML: "",
                ideaHTML: ""
            ))) {
                Label("记书摘", systemImage: "plus")
            }
            .font(AppTypography.subheadline)
        case .reviews:
            NavigationLink(value: ContentRoute.reviewEditorCreate(bookId: bookID)) {
                Label("写书评", systemImage: "plus")
            }
            .font(AppTypography.subheadline)
        case .related:
            Menu {
                Button("新建相关内容", systemImage: "square.and.pencil", action: onCreateRelatedContent)
                if isRelatedBookCategoryVisible {
                    Button("添加相关书籍", systemImage: "books.vertical", action: onAddRelatedBook)
                }
                Divider()
                Button("管理分类", systemImage: "slider.horizontal.3", action: onManageCategories)
            } label: {
                Label("相关操作", systemImage: "plus")
                    .font(AppTypography.subheadline)
            }
            .disabled(isWriting)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .notes:
            notesContent
        case .reviews:
            observedWorkspaceContent(emptyMessage: "还没有书评", emptyIcon: "doc.text") {
                reviewContent
            }
        case .related:
            observedWorkspaceContent(emptyMessage: "还没有相关内容", emptyIcon: "link") {
                relatedContent
            }
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        NavigationLink(
            value: NoteRoute.noteExcerptList(
                context: NoteExcerptListContext(
                    scope: .book(id: bookID),
                    displayTitle: "本书书摘"
                )
            )
        ) {
            CardContainer(showsBorder: true, borderColor: Color.surfaceBorderSubtle) {
                HStack(spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: Spacing.micro) {
                        Text("管理本书书摘")
                            .font(AppTypography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Text("搜索、排序、选择与批量操作")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                }
                .padding(Spacing.contentEdge)
            }
        }
        .buttonStyle(.plain)

        if notes.isEmpty {
            EmptyStateView(icon: "text.quote", message: "暂无书摘")
                .frame(minHeight: BookContentWorkspaceLayout.emptyMinHeight)
        } else {
            ForEach(notes) { note in
                NavigationLink(
                    value: ContentRoute.contentViewer(
                        source: .bookNotes(bookId: bookID),
                        initialItemID: .note(note.id)
                    )
                ) {
                    noteCard(note)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func observedWorkspaceContent<Content: View>(
        emptyMessage: String,
        emptyIcon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let errorMessage {
            failureCard(message: errorMessage)
        } else if isLoading {
            if loadingGate.isVisible {
                LoadingStateView("正在加载笔记内容…", style: .card)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.base)
            } else {
                Color.clear.frame(minHeight: BookContentWorkspaceLayout.loadingPlaceholderHeight)
            }
        } else if isSelectedSectionEmpty {
            EmptyStateView(icon: emptyIcon, message: emptyMessage)
                .frame(minHeight: BookContentWorkspaceLayout.emptyMinHeight)
        } else {
            if isWriting {
                LoadingStateView("正在更新相关内容…", style: .card)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
            content()
        }
    }

    private var reviewContent: some View {
        ForEach(snapshot.reviews) { review in
            NavigationLink(
                value: ContentRoute.contentViewer(
                    source: .bookReviews(bookId: bookID),
                    initialItemID: .review(review.id)
                )
            ) {
                reviewCard(review)
            }
            .buttonStyle(.plain)
        }
    }

    private var relatedContent: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            ForEach(snapshot.relatedSections) { section in
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    HStack(spacing: Spacing.half) {
                        Text(section.title.isEmpty ? "未命名分类" : section.title)
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                        Text("\(section.items.count)")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.horizontal, Spacing.micro)

                    ForEach(section.items) { item in
                        relatedNavigationLink(item, categoryID: section.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relatedNavigationLink(_ item: BookContentRelatedItem, categoryID: Int64) -> some View {
        switch item.destination {
        case .content(let contentID):
            NavigationLink(
                value: ContentRoute.contentViewer(
                    source: .bookRelated(bookId: bookID, categoryId: categoryID),
                    initialItemID: .relevant(contentID)
                )
            ) {
                relatedContentCard(item)
            }
            .buttonStyle(.plain)
        case .book(let relatedBookID):
            if item.isPlaceholder {
                Button {
                    onOpenRelatedPlaceholder(item)
                } label: {
                    relatedBookCard(item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("编辑书籍资料", systemImage: "square.and.pencil") {
                        onEditRelatedBook(item)
                    }
                    Button("移除相关书籍", systemImage: "trash", role: .destructive) {
                        onRequestDeleteRelatedBook(item)
                    }
                }
            } else {
                NavigationLink(value: BookRoute.detail(bookId: relatedBookID)) {
                    relatedBookCard(item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("编辑书籍资料", systemImage: "square.and.pencil") {
                        onEditRelatedBook(item)
                    }
                    Button("移除相关书籍", systemImage: "trash", role: .destructive) {
                        onRequestDeleteRelatedBook(item)
                    }
                }
            }
        }
    }

    private func noteCard(_ note: NoteExcerpt) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.none) {
                if !note.contentPlainText.isEmpty {
                    Text(note.contentPlainText)
                        .font(NoteExcerptTypography.body)
                        .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                        .lineLimit(6)
                        .foregroundStyle(Color.textPrimary)
                }

                if !note.ideaPlainText.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.textHint.opacity(0.6))
                            .frame(width: BookContentWorkspaceLayout.ideaBarWidth)

                        Text(note.ideaPlainText)
                            .font(NoteExcerptTypography.idea)
                            .lineSpacing(NoteExcerptTypography.ideaLineSpacing)
                            .lineLimit(3)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.top, Spacing.base)
                }

                if !note.footerText.isEmpty {
                    Text(note.footerText)
                        .font(NoteExcerptTypography.footer)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.top, Spacing.base)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    private func reviewCard(_ review: BookContentReviewItem) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(review.title.isEmpty ? "未命名书评" : review.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                if !review.contentPlainText.isEmpty {
                    Text(review.contentPlainText)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .combine)
    }

    private func relatedContentCard(_ item: BookContentRelatedItem) -> some View {
        CardContainer {
            HStack(alignment: .top, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text(relatedContentTitle(item))
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    if !item.contentPlainText.isEmpty, item.title.isEmpty == false {
                        Text(item.contentPlainText)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(3)
                    }

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .combine)
    }

    private func relatedBookCard(_ item: BookContentRelatedItem) -> some View {
        CardContainer {
            HStack(spacing: Spacing.base) {
                XMBookCover.fixedWidth(
                    BookContentWorkspaceLayout.relatedBookCoverWidth,
                    urlString: item.coverURL,
                    cornerRadius: CornerRadius.inlayHairline,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text(item.title.isEmpty ? "未命名书籍" : item.title)
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .combine)
    }

    private func failureCard(message: String) -> some View {
        CardContainer(showsBorder: true, borderColor: Color.surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Label("暂时无法加载", systemImage: "exclamationmark.triangle")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(message)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                Button("重试", action: onRetry)
                    .font(AppTypography.subheadline)
                    .buttonStyle(.bordered)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var selectionSummary: String {
        switch selection {
        case .notes:
            "\(notes.count) 条书摘"
        case .reviews:
            "\(snapshot.reviews.count) 篇书评"
        case .related:
            "\(snapshot.relatedItemCount) 条相关"
        }
    }

    private var isSelectedSectionEmpty: Bool {
        switch selection {
        case .notes:
            notes.isEmpty
        case .reviews:
            snapshot.reviews.isEmpty
        case .related:
            snapshot.relatedItemCount == 0
        }
    }

    private var isRelatedBookCategoryVisible: Bool {
        snapshot.categories.contains { $0.isRelatedBook && !$0.isHidden }
    }

    private var selectedSortType: BookContentSortType {
        switch selection {
        case .notes: .notes
        case .reviews: .reviews
        case .related: .related
        }
    }

    private var selectedSortRule: BookContentSortRule {
        snapshot.sortPreferences.rule(for: selectedSortType)
    }

    private var displayedItemIDs: [Int64] {
        switch selection {
        case .notes:
            notes.map(\.id)
        case .reviews:
            snapshot.reviews.map(\.id)
        case .related:
            snapshot.relatedSections.flatMap { $0.items.map(\.id) }
        }
    }

    private func relatedContentTitle(_ item: BookContentRelatedItem) -> String {
        if !item.title.isEmpty { return item.title }
        if !item.contentPlainText.isEmpty { return item.contentPlainText }
        return "未命名内容"
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: isLoading ? .read : .none)
    }
}

private extension BookContentSortRule {
    var menuTitle: String {
        switch self {
        case .createdDateAscending: "时间 · 由旧到新"
        case .createdDateDescending: "时间 · 由新到旧"
        case .positionAscending: "位置 · 由前到后"
        case .positionDescending: "位置 · 由后到前"
        }
    }

    var systemImage: String {
        switch self {
        case .createdDateAscending, .positionAscending: "chevron.down"
        case .createdDateDescending, .positionDescending: "chevron.up"
        }
    }
}

/// 工作区的 iOS 分段浏览维度，保留 Android 业务类型但不复刻其 ViewPager 组织。
private enum BookContentWorkspaceTab: String, CaseIterable, Identifiable {
    case notes
    case reviews
    case related

    var id: Self { self }

    var title: String {
        switch self {
        case .notes: "书摘"
        case .reviews: "书评"
        case .related: "相关"
        }
    }
}

private enum BookContentWorkspaceLayout {
    static let emptyMinHeight: CGFloat = 180
    static let loadingPlaceholderHeight: CGFloat = 96
    static let ideaBarWidth: CGFloat = 3
    static let relatedBookCoverWidth: CGFloat = 44
}
