/**
 * [INPUT]: 依赖 NoteViewModel 提供四分类聚合、书评增量分页与写入状态，依赖外部闭包承接书摘、章节、目录定位、书籍、标签管理与书评导航
 * [OUTPUT]: 对外提供 NoteCollectionView，使用 XMInlineTabBar 渲染四分类入口，并通过单滚动坐标系承载语义一致的分类搜索、viewport 居中空态、常驻滚动现场及各类内容操作
 * [POS]: Note 模块首页分类展示层，被 NoteContainerView 嵌入并保持分类现场
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 笔记首页“分类 rail + 内容区”容器；页面本身只上抛业务身份，不持有导航路径。
struct NoteCollectionView: View {
    @Bindable var viewModel: NoteViewModel
    let onOpenExcerptScope: (NoteExcerptListContext) -> Void
    let onOpenStarredChapter: (StarredChapterItem) -> Void
    let onLocateStarredChapter: (StarredChapterItem) -> Void
    let onOpenRelatedCategory: (RelatedCategoryScope) -> Void
    let onOpenReview: (BookReviewListItem) -> Void
    let onOpenBook: (Int64) -> Void
    let onOpenTagManagement: () -> Void
    let onEditReview: (Int64) -> Void

    @Environment(XMToastCenter.self) private var toastCenter
    @State private var pendingRelatedCategoryDelete: RelatedCategoryItem?
    @State private var pendingReviewDelete: BookReviewListItem?
    @State private var pendingBookRating: BookReviewListItem?

    /// 注入四类入口回调；默认空实现用于预览和仍未接线的旧调用点。
    init(
        viewModel: NoteViewModel,
        onOpenExcerptScope: @escaping (NoteExcerptListContext) -> Void = { _ in },
        onOpenStarredChapter: @escaping (StarredChapterItem) -> Void = { _ in },
        onLocateStarredChapter: @escaping (StarredChapterItem) -> Void = { _ in },
        onOpenRelatedCategory: @escaping (RelatedCategoryScope) -> Void = { _ in },
        onOpenReview: @escaping (BookReviewListItem) -> Void = { _ in },
        onOpenBook: @escaping (Int64) -> Void = { _ in },
        onOpenTagManagement: @escaping () -> Void = {},
        onEditReview: @escaping (Int64) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onOpenExcerptScope = onOpenExcerptScope
        self.onOpenStarredChapter = onOpenStarredChapter
        self.onLocateStarredChapter = onLocateStarredChapter
        self.onOpenRelatedCategory = onOpenRelatedCategory
        self.onOpenReview = onOpenReview
        self.onOpenBook = onOpenBook
        self.onOpenTagManagement = onOpenTagManagement
        self.onEditReview = onEditReview
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            categoryRail
            categoryPages
        }
        .xmSystemAlert(item: $pendingReviewDelete) { review in
            XMSystemAlertDescriptor(
                title: "删除这篇书评？",
                message: "书评和附图会从当前列表移除，并同步保留删除状态。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        deleteReview(review)
                    }
                ]
            )
        }
        .xmSystemAlert(item: $pendingRelatedCategoryDelete) { item in
            relatedCategoryDeleteDescriptor(item)
        }
        .sheet(item: $pendingBookRating) { review in
            XMBookRatingSheet(
                bookTitle: review.bookTitle,
                initialScore: review.bookScore
            ) { score in
                try await viewModel.updateBookRating(bookID: review.bookID, score: score)
            }
        }
    }

    private var categoryRail: some View {
        XMInlineTabBar(
            items: NoteCategory.allCases.map {
                XMInlineTabItem(id: $0, title: $0.title)
            },
            selection: $viewModel.selectedCategory,
            accessibilityLabel: "笔记分类"
        )
        .frame(height: NoteHomeLayout.categoryRailHeight)
    }

    private var categoryPages: some View {
        KeepAliveSwitcherHost(
            selection: viewModel.selectedCategory,
            tabs: NoteCategory.allCases,
            transitionPolicy: .hardSwitch
        ) { category in
            NoteCollapsibleSearchPage(
                searchText: searchTextBinding(for: category),
                placeholder: searchPlaceholder(for: category),
                isPageActive: category == viewModel.selectedCategory
            ) { metrics in
                categoryContent(for: category, emptyStateOffset: metrics.emptyStateOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 常驻分类页必须直接绑定自己的搜索词，避免隐藏页借用当前 selection 后错误重启其它查询。
    private func searchTextBinding(for category: NoteCategory) -> Binding<String> {
        Binding(
            get: { viewModel.searchText(for: category) },
            set: { viewModel.updateSearchText($0, for: category) }
        )
    }

    /// 返回指定分类的输入提示，保证每个常驻搜索头恢复时拥有稳定语义。
    private func searchPlaceholder(for category: NoteCategory) -> String {
        switch category {
        case .excerpts: "搜索书摘分组"
        case .starredChapters: "输入关键字搜索星标章节"
        case .related: "搜索相关分类"
        case .reviews: "搜索书评"
        }
    }

    /// 将分类独立查询状态注入对应内容页，并只对空态应用不参与布局的视觉居中补偿。
    @ViewBuilder
    private func categoryContent(for category: NoteCategory, emptyStateOffset: CGFloat) -> some View {
        let hasQuery = !viewModel.normalizedSearchText(for: category).isEmpty
        switch category {
        case .excerpts:
            NoteHomeStateHost(
                state: viewModel.excerptState,
                loadingMessage: "正在加载书摘分组…",
                emptyRole: hasQuery ? .noResults : .empty,
                emptyMessage: hasQuery ? "没有匹配的书摘分组" : "暂无书摘",
                emptyStateOffset: emptyStateOffset,
                onRetry: viewModel.retrySelectedCategory
            ) {
                NoteTagsView(
                    viewModel: viewModel,
                    onOpenScope: onOpenExcerptScope,
                    onManageTags: onOpenTagManagement
                )
            }
        case .starredChapters:
            NoteHomeStateHost(
                state: viewModel.starredState,
                loadingMessage: "正在加载星标章节…",
                emptyRole: hasQuery ? .noResults : .empty,
                emptyMessage: hasQuery ? "没有匹配的星标章节" : "暂无星标章节",
                emptyStateOffset: emptyStateOffset,
                onRetry: viewModel.retrySelectedCategory
            ) {
                NoteStarredChapterGroupsView(
                    groups: viewModel.starredGroups,
                    searchKeyword: viewModel.searchText(for: .starredChapters),
                    onOpenChapter: onOpenStarredChapter,
                    onOpenBook: onOpenBook,
                    onLocateChapter: onLocateStarredChapter,
                    onRemoveStar: removeChapterStar
                )
            }
        case .related:
            NoteHomeStateHost(
                state: viewModel.relatedState,
                loadingMessage: "正在加载相关分类…",
                emptyRole: hasQuery ? .noResults : .empty,
                emptyMessage: hasQuery ? "没有匹配的相关分类" : "暂无相关内容",
                emptyStateOffset: emptyStateOffset,
                onRetry: viewModel.retrySelectedCategory
            ) {
                NoteRelatedCategoriesView(
                    snapshot: viewModel.relatedSnapshot,
                    searchQuery: viewModel.normalizedSearchText(for: .related),
                    isWriting: viewModel.isWriting,
                    onOpenCategory: onOpenRelatedCategory,
                    onUnavailableCategory: showUnavailableRelatedCategory,
                    onRequestDelete: { pendingRelatedCategoryDelete = $0 }
                )
            }
        case .reviews:
            NoteHomeStateHost(
                state: viewModel.reviewState,
                loadingMessage: "正在加载书评…",
                emptyRole: hasQuery ? .noResults : .empty,
                emptyMessage: hasQuery ? "没有匹配的书评" : "暂无书评",
                emptyStateOffset: emptyStateOffset,
                onRetry: viewModel.retrySelectedCategory
            ) {
                NoteBookReviewsView(
                    snapshot: viewModel.reviewSnapshot,
                    isLoadingMore: viewModel.isReviewLoadingMore,
                    loadMoreErrorMessage: viewModel.reviewLoadMoreErrorMessage,
                    onOpenReview: onOpenReview,
                    onOpenBook: onOpenBook,
                    onEditReview: onEditReview,
                    onDeleteReview: { pendingReviewDelete = $0 },
                    onRateBook: { pendingBookRating = $0 },
                    onLoadMoreIfNeeded: viewModel.loadMoreReviewsIfNeeded,
                    onRetryLoadMore: viewModel.retryReviewLoadMore
                )
            }
        }
    }

    /// 取消星标即时显示写入反馈；成功由章节卡移除表达，失败保留原卡并解释。
    private func removeChapterStar(_ chapter: StarredChapterItem) {
        Task {
            toastCenter.processing("正在取消章节星标…")
            let toastID = toastCenter.current?.id
            do {
                try await viewModel.removeChapterStar(chapterID: chapter.id)
                toastCenter.dismiss(id: toastID)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    /// 默认分类确认清空内容，自定义分类确认跨书删除同名定义，避免聚合入口掩盖实际影响范围。
    private func relatedCategoryDeleteDescriptor(_ item: RelatedCategoryItem) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: item.isDefault ? "清空“\(item.title)”中的相关内容？" : "删除“\(item.title)”分类？",
            message: item.isDefault
                ? "系统分类会保留；该聚合范围内的相关内容、附图和书籍关联会被软删除。"
                : "所有书籍中同名分类及其相关内容、附图和书籍关联都会被软删除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: item.isDefault ? "清空" : "删除", role: .destructive) {
                    deleteRelatedCategory(item)
                }
            ]
        )
    }

    /// 空分类保持可感知点击反馈，但不进入没有内容的二级列表。
    private func showUnavailableRelatedCategory(_ item: RelatedCategoryItem) {
        guard item.contentCount == 0 else { return }
        toastCenter.warning("这个分类还没有相关内容")
    }

    /// 聚合删除即时进入处理中状态；成功由分类消失或默认分类计数归零表达，失败保留原卡并解释。
    private func deleteRelatedCategory(_ item: RelatedCategoryItem) {
        Task {
            toastCenter.processing(item.isDefault ? "正在清空相关内容…" : "正在删除相关分类…")
            let toastID = toastCenter.current?.id
            do {
                try await viewModel.deleteRelatedCategory(scope: item.scope)
                toastCenter.dismiss(id: toastID)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    /// 删除书评使用中心确认与即时处理中状态，成功不追加冗余 Toast。
    private func deleteReview(_ review: BookReviewListItem) {
        Task {
            toastCenter.processing("正在删除书评…")
            let toastID = toastCenter.current?.id
            do {
                try await viewModel.deleteReview(reviewID: review.id)
                toastCenter.dismiss(id: toastID)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }
}

/// 首页分类阶段宿主，把 LoadingGate 的延迟/最短驻留规则统一应用到四类只读内容。
private struct NoteHomeStateHost<Content: View>: View {
    let state: NoteHomeSectionState
    let loadingMessage: String
    let emptyRole: XMStateRole
    let emptyMessage: String
    let emptyStateOffset: CGFloat
    let onRetry: () -> Void
    @ViewBuilder let content: Content

    @State private var loadingGate = LoadingGate()

    var body: some View {
        Group {
            if loadingGate.isVisible {
                LoadingStateView(loadingMessage, style: .card)
                    .padding(.top, Spacing.double)
            } else {
                switch state {
                case .loading:
                    Color.clear
                case .content:
                    content
                case .empty:
                    XMContentStateView(
                        role: emptyRole,
                        title: emptyMessage
                    )
                        .offset(y: emptyStateOffset)
                case .error:
                    XMContentStateView(
                        role: .failure,
                        title: "暂时无法加载内容",
                        action: XMStateAction("重试", perform: onRetry)
                    )
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: NoteHomeLayout.stateMinHeight,
            maxHeight: .infinity,
            alignment: .top
        )
        .onAppear(perform: syncLoadingGate)
        .onChange(of: state) { _, _ in syncLoadingGate() }
        .onDisappear { loadingGate.hideImmediately() }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: state == .loading ? .read : .none)
    }
}

private enum NoteHomeLayout {
    static let categoryRailHeight: CGFloat = InteractionMetrics.minimumTouchTarget
    static let stateMinHeight: CGFloat = 320
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NoteCollectionView(viewModel: NoteViewModel(repository: repositories.noteRepository))
        .background(Color.surfacePage)
}
