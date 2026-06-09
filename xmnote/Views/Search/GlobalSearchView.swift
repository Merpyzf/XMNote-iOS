/**
 * [INPUT]: 依赖 MainTabView 提供搜索 query 绑定、搜索提交事件、软键盘收起动作、详情全屏覆盖打开回调与覆盖呈现状态，依赖 RepositoryContainer 注入全局搜索仓储，依赖 GlobalSearchViewModel 驱动本地搜索状态
 * [OUTPUT]: 对外提供 GlobalSearchView，渲染 iOS 原生搜索 Tab 下的固定范围栏、全局搜索结果、搜索历史、分类筛选、空态、加载态、错误态与搜索来源详情打开入口
 * [POS]: Search 模块根视图，被 MainTabView 的搜索 Tab NavigationStack 消费；搜索结果通过 route-only target 交给根级 fullScreenCover 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 搜索宿主捕获到的提交事件，使用唯一 id 保证相同关键词连续提交也能被搜索页感知。
struct GlobalSearchSubmitRequest: Equatable, Identifiable {
    let id = UUID()
    let query: String
}

/// 搜索来源详情覆盖层可承载的导航目标，避免搜索页直接写入外层 NavigationPath 或动画状态。
enum SearchResultViewerTarget: Hashable {
    case book(BookRoute)
    case content(ContentRoute)
}

/// 全局搜索 Tab 根视图，承接系统搜索框 query 并在 iOS 原生搜索语境内展示四类本地结果。
struct GlobalSearchView: View {
    @Binding private var query: String
    private let submitRequest: GlobalSearchSubmitRequest?
    private let isSearchResultCoverPresented: Bool
    private let onClearHistoryRequested: (@escaping () -> Void) -> Void
    private let onDismissSearchKeyboard: () -> Void
    private let onOpenSearchResultCover: (SearchResultViewerTarget) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: GlobalSearchViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    private var topBarHeight: CGFloat {
        dynamicTypeSize >= .accessibility1 ? 60 : 56
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入系统搜索框 query 与导航回调，保持搜索页不直接持有外层 NavigationPath。
    init(
        query: Binding<String>,
        submitRequest: GlobalSearchSubmitRequest?,
        isSearchResultCoverPresented: Bool,
        onClearHistoryRequested: @escaping (@escaping () -> Void) -> Void,
        onDismissSearchKeyboard: @escaping () -> Void,
        onOpenSearchResultCover: @escaping (SearchResultViewerTarget) -> Void
    ) {
        self._query = query
        self.submitRequest = submitRequest
        self.isSearchResultCoverPresented = isSearchResultCoverPresented
        self.onClearHistoryRequested = onClearHistoryRequested
        self.onDismissSearchKeyboard = onDismissSearchKeyboard
        self.onOpenSearchResultCover = onOpenSearchResultCover
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                GlobalSearchLoadedContent(
                    query: trimmedQuery,
                    viewModel: viewModel,
                    isSearchResultCoverPresented: isSearchResultCoverPresented,
                    onOpenResult: openResult,
                    onSelectSuggestion: selectSuggestion,
                    onClearHistoryRequested: onClearHistoryRequested
                )
                .padding(.top, topBarHeight)
            } else if bootstrapLoadingGate.isVisible {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, topBarHeight)
            }

            HomeTopHeaderGradient()
                .allowsHitTesting(false)

            TopSwitcher(title: "搜索", quote: "") {
                EmptyView()
            }
            .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = GlobalSearchViewModel(repository: repositories.globalSearchRepository)
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            newViewModel.draftDidChange(query)
            if let submitRequest {
                newViewModel.submit(query: submitRequest.query)
            }
        }
        .onChange(of: query) { _, newValue in
            viewModel?.draftDidChange(newValue)
        }
        .onChange(of: submitRequest?.id) { _, _ in
            guard let submitRequest else { return }
            viewModel?.submit(query: submitRequest.query)
        }
        .onDisappear {
            guard !isSearchResultCoverPresented else { return }
            bootstrapLoadingGate.hideImmediately()
            viewModel?.cancelSearch()
        }
    }

    private func openResult(_ result: GlobalSearchResult) {
        let keyword = trimmedQuery
        viewModel?.recordConfirmedQuery(keyword)
        guard let target = searchResultCoverTarget(for: result.target, keyword: keyword) else {
            return
        }
        onOpenSearchResultCover(target)
    }

    private func searchResultCoverTarget(
        for target: GlobalSearchTarget,
        keyword: String
    ) -> SearchResultViewerTarget? {
        switch target {
        case .bookDetail(let bookId):
            return .book(.detail(bookId: bookId))
        case .noteViewer(let noteId, let bookId):
            return .content(
                .contentViewer(
                    source: .bookNotes(bookId: bookId),
                    initialItemID: .note(noteId),
                    keyword: keyword
                )
            )
        case .relevantDetail(let contentId):
            return .content(.relevantDetail(contentId: contentId))
        case .relevantBook(_, let bookId):
            return .book(.detail(bookId: bookId))
        case .reviewDetail(let reviewId):
            return .content(.reviewDetail(reviewId: reviewId))
        }
    }

    private func selectSuggestion(_ suggestion: String) {
        query = suggestion
        viewModel?.submit(query: suggestion)
        onDismissSearchKeyboard()
    }
}

private struct GlobalSearchLoadedContent: View {
    let query: String
    @Bindable var viewModel: GlobalSearchViewModel
    let isSearchResultCoverPresented: Bool
    let onOpenResult: (GlobalSearchResult) -> Void
    let onSelectSuggestion: (String) -> Void
    let onClearHistoryRequested: (@escaping () -> Void) -> Void

    @State private var loadingGate = LoadingGate()
    @State private var resultScrollTarget: GlobalSearchScrollTarget? = .top
    @State private var scopeScrollTargets: [GlobalSearchScope: GlobalSearchScrollTarget] = [:]
    @State private var isHistoryExpanded = false
    @State private var isHistoryEditing = false

    var body: some View {
        ZStack {
            switch viewModel.loadState {
            case .idle:
                GlobalSearchRootView(
                    recentQueries: viewModel.recentQueries,
                    isHistoryExpanded: $isHistoryExpanded,
                    isHistoryEditing: $isHistoryEditing,
                    onSelectSuggestion: onSelectSuggestion,
                    onRemoveSuggestion: viewModel.removeRecentQuery,
                    onClearAllHistory: {
                        onClearHistoryRequested {
                            viewModel.clearRecentQueries()
                        }
                    }
                )
            case .loading:
                if loadingGate.isVisible {
                    LoadingStateView("正在搜索…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .loaded:
                if viewModel.snapshot.isEmpty {
                    GlobalSearchPlaceholderView(
                        title: "没有找到内容",
                        subtitle: "换个关键词再试"
                    )
                } else {
                    resultsContent
                }
            case .failed(_, let message):
                GlobalSearchErrorView(message: message) {
                    viewModel.retry(query: query)
                }
            }
        }
        .onAppear(perform: syncLoadingGate)
        .onChange(of: viewModel.loadState) { _, _ in
            syncLoadingGate()
        }
        .onChange(of: query) { _, _ in
            resetResultScrollState()
        }
        .onChange(of: viewModel.resultRevision) { _, _ in
            resetResultScrollState()
        }
        .onChange(of: viewModel.selectedScope) { oldValue, newValue in
            handleScopeChange(from: oldValue, to: newValue)
        }
        .onDisappear {
            guard !isSearchResultCoverPresented else { return }
            loadingGate.hideImmediately()
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.shouldShowScopeFilter {
            XMScrollEdgeChrome(
                presentation: .contained,
                contentSpacing: Spacing.none,
                topBar: {
                    scopeSelectorHeader
                }
            ) {
                resultsScrollContent(topPadding: Spacing.none)
            }
        } else {
            resultsScrollContent(topPadding: Spacing.base)
        }
    }

    private var scopeSelectorHeader: some View {
        XMScopeSelector(
            items: scopeSelectorItems,
            selection: scopeSelection,
            style: .content,
            countFormat: .plain,
            accessibilityLabel: String(localized: "搜索范围")
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.cozy)
    }

    private func resultsScrollContent(topPadding: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                if viewModel.shouldShowFieldScopeFilter {
                    fieldScopeFilterSection
                }

                if viewModel.visibleResults.isEmpty {
                    if viewModel.shouldShowFieldScopeFilter {
                        GlobalSearchInlineEmptyView(title: "没有找到内容", subtitle: "换个范围试试")
                    } else {
                        topAnchoredContent {
                            GlobalSearchInlineEmptyView(title: "没有找到内容", subtitle: "换个范围试试")
                        }
                    }
                } else {
                    resultRows
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, topPadding)
            .padding(.bottom, Spacing.actionReserved * 3)
        }
        .scrollPosition(id: $resultScrollTarget, anchor: .top)
        .scrollIndicators(.hidden)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var fieldScopeFilterSection: some View {
        topAnchoredContent {
            GlobalSearchFieldScopeFilterBar(
                scopes: viewModel.availableFieldScopes,
                selectedScope: viewModel.currentFieldScope,
                countProvider: { viewModel.fieldScopeCount($0) },
                onSelect: viewModel.selectFieldScope
            )
        }
    }

    private var resultRows: some View {
        let firstResultID = viewModel.visibleResults.first?.id
        return ForEach(viewModel.visibleResults) { result in
            if result.id == firstResultID, !viewModel.shouldShowFieldScopeFilter {
                topAnchoredContent {
                    resultRow(result)
                }
            } else {
                resultRow(result)
            }
        }
    }

    private func resultRow(_ result: GlobalSearchResult) -> some View {
        GlobalSearchResultRow(
            result: result,
            keyword: query,
            onOpen: {
                onOpenResult(result)
            }
        )
        .id(GlobalSearchScrollTarget.result(result.id))
    }

    private func topAnchoredContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            Color.clear
                .frame(height: Spacing.hairline)
                .id(GlobalSearchScrollTarget.top)
                .accessibilityHidden(true)

            content()
        }
    }

    private var scopeSelectorItems: [XMScopeSelectorItem<GlobalSearchScope>] {
        viewModel.availableScopes.map { scope in
            XMScopeSelectorItem(
                id: scope,
                title: scope.title,
                count: viewModel.scopeCount(for: scope)
            )
        }
    }

    private var scopeSelection: Binding<GlobalSearchScope> {
        Binding(
            get: { viewModel.selectedScope },
            set: { selectScope($0) }
        )
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.loadState.isLoading ? .read : .none)
    }

    private func selectScope(_ scope: GlobalSearchScope) {
        guard viewModel.selectedScope != scope else { return }
        scopeScrollTargets[viewModel.selectedScope] = resultScrollTarget ?? .top
        viewModel.selectScope(scope)
    }

    private func handleScopeChange(from oldScope: GlobalSearchScope, to newScope: GlobalSearchScope) {
        guard oldScope != newScope else { return }
        if scopeScrollTargets[oldScope] == nil {
            scopeScrollTargets[oldScope] = resultScrollTarget ?? .top
        }
        setResultScrollTarget(normalizedScrollTarget(for: scopeScrollTargets[newScope] ?? .top))
    }

    private func resetResultScrollState() {
        scopeScrollTargets.removeAll()
        setResultScrollTarget(.top)
    }

    private func setResultScrollTarget(_ target: GlobalSearchScrollTarget) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            resultScrollTarget = target
        }
    }

    private func normalizedScrollTarget(for target: GlobalSearchScrollTarget) -> GlobalSearchScrollTarget {
        switch target {
        case .top:
            return .top
        case .result(let id):
            return viewModel.visibleResults.contains { $0.id == id } ? target : .top
        }
    }
}

/// 搜索结果滚动锚点，区分列表顶部与结果 ID，避免普通字符串和顶部哨兵值冲突。
private enum GlobalSearchScrollTarget: Hashable {
    case top
    case result(String)
}

private struct GlobalSearchFieldScopeFilterBar: View {
    let scopes: [GlobalSearchFieldScope]
    let selectedScope: GlobalSearchFieldScope?
    let countProvider: (GlobalSearchFieldScope) -> Int
    let onSelect: (GlobalSearchFieldScope?) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.tight) {
                ForEach(scopes) { scope in
                    let isSelected = selectedScope == scope
                    Button {
                        onSelect(isSelected ? nil : scope)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.tiny) {
                            Text(scope.title)
                                .font(AppTypography.caption)
                                .foregroundStyle(isSelected ? Color.brandDeep : Color.textSecondary)
                                .lineLimit(1)

                            let count = countProvider(scope)
                            if count > 0 {
                                Text("\(count)")
                                    .font(AppTypography.caption2)
                                    .foregroundStyle(isSelected ? Color.brandDeep.opacity(0.68) : Color.textHint)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, Spacing.cozy)
                        .frame(minHeight: Spacing.actionReserved - Spacing.tight)
                        .background(
                            isSelected ? Color.brand.opacity(0.11) : Color.controlFillSecondary.opacity(0.52),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    isSelected ? Color.brand.opacity(0.32) : Color.surfaceBorderSubtle,
                                    lineWidth: CardStyle.borderWidth
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scope.title)
                }
            }
            .padding(.vertical, Spacing.hairline)
        }
        .scrollIndicators(.hidden)
    }
}

private struct GlobalSearchResultRow: View {
    let result: GlobalSearchResult
    let keyword: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            rowLabel
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开\(result.title)")
    }

    private var rowLabel: some View {
        GlobalSearchResultSourcePreview(display: result.display, keyword: keyword)
    }
}

/// 搜索结果卡片的语义预览面，供列表 row 与覆盖详情入口共用。
struct GlobalSearchResultSourcePreview: View {
    let display: GlobalSearchResultDisplay
    let keyword: String

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.blockMedium, showsBorder: true, borderColor: .surfaceBorderSubtle) {
            rowContent
                .padding(Spacing.base)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch display {
        case .book(let book):
            GlobalSearchBookRow(book: book, keyword: keyword)
        case .note(let note):
            GlobalSearchNoteRow(note: note, keyword: keyword)
        case .relevantContent(let relevant):
            GlobalSearchRelevantContentRow(relevant: relevant, keyword: keyword)
        case .relevantBook(let relevantBook):
            GlobalSearchRelevantBookRow(relevantBook: relevantBook, keyword: keyword)
        case .review(let review):
            GlobalSearchReviewRow(review: review, keyword: keyword)
        }
    }
}

private struct GlobalSearchInlineEmptyView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section * 2)
    }
}

private struct GlobalSearchPlaceholderView: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textHint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
    }
}

private struct GlobalSearchRootView: View {
    let recentQueries: [String]
    @Binding var isHistoryExpanded: Bool
    @Binding var isHistoryEditing: Bool
    let onSelectSuggestion: (String) -> Void
    let onRemoveSuggestion: (String) -> Void
    let onClearAllHistory: () -> Void

    var body: some View {
        ScrollView {
            XMSearchHistorySection(
                queries: recentQueries,
                isExpanded: $isHistoryExpanded,
                isEditing: $isHistoryEditing,
                title: "最近搜索",
                emptyPresentation: .hidden,
                onSelect: onSelectSuggestion,
                onRemove: onRemoveSuggestion,
                onClearAll: onClearAllHistory
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.section)
            .padding(.bottom, Spacing.actionReserved * 3)
        }
        .scrollIndicators(.hidden)
    }
}

private struct GlobalSearchBookRow: View {
    let book: GlobalSearchBookDisplay
    let keyword: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                58,
                urlString: book.coverURL ?? "",
                cornerRadius: CornerRadius.inlaySmall,
                placeholderIconSize: .small,
                priority: .low,
                surfaceStyle: .spine
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.tight) {
                XMKeywordHighlighting.text(
                    book.title,
                    keyword: keyword,
                    baseFont: AppTypography.bodyMedium,
                    highlightFont: AppTypography.semantic(.body, weight: .semibold),
                    baseColor: Color.textPrimary
                )
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

                GlobalSearchBookMetadataLines(book: book, keyword: keyword)

                GlobalSearchInfoChipStrip(items: book.contextChips, keyword: keyword)

                GlobalSearchTagStrip(tags: book.tagNames, keyword: keyword)

                if !book.dateText.isEmpty {
                    Text(book.dateText)
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textHint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

private struct GlobalSearchRelevantBookRow: View {
    let relevantBook: GlobalSearchRelevantBookDisplay
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            GlobalSearchBookRow(book: relevantBook.book, keyword: keyword)

            GlobalSearchFooter(
                leading: formattedBookTitle(relevantBook.sourceBookTitle),
                trailing: relevantBook.book.dateText
            )
        }
    }
}

private struct GlobalSearchNoteRow: View {
    let note: GlobalSearchNoteDisplay
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if !note.content.isEmpty {
                XMKeywordHighlighting.text(
                    note.content,
                    keyword: keyword,
                    baseFont: NoteExcerptTypography.body,
                    highlightFont: NoteExcerptTypography.body,
                    baseColor: Color.textPrimary
                )
                .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !note.idea.isEmpty {
                GlobalSearchIdeaBlock(text: note.idea, keyword: keyword)
            }

            GlobalSearchImageWall(imageURLs: note.imageURLs, idPrefix: "note")

            GlobalSearchTagStrip(tags: note.tagNames, keyword: keyword)

            GlobalSearchFooter(
                leading: formattedBookTitle(note.bookTitle),
                trailing: note.dateText
            )
        }
    }
}

private struct GlobalSearchRelevantContentRow: View {
    let relevant: GlobalSearchRelevantContentDisplay
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if !relevant.title.isEmpty {
                XMKeywordHighlighting.text(
                    relevant.title,
                    keyword: keyword,
                    baseFont: AppTypography.subheadlineSemibold,
                    highlightFont: AppTypography.subheadlineSemibold,
                    baseColor: Color.textPrimary
                )
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !relevant.content.isEmpty {
                XMKeywordHighlighting.text(
                    relevant.content,
                    keyword: keyword,
                    baseFont: NoteExcerptTypography.body,
                    highlightFont: NoteExcerptTypography.body,
                    baseColor: Color.textPrimary
                )
                .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GlobalSearchImageWall(imageURLs: relevant.imageURLs, idPrefix: "relevant")

            GlobalSearchTagStrip(tags: relevant.categoryTitle.isEmpty ? [] : [relevant.categoryTitle], keyword: keyword)

            GlobalSearchFooter(
                leading: formattedBookTitle(relevant.bookTitle),
                trailing: relevant.dateText
            )
        }
    }
}

private struct GlobalSearchReviewRow: View {
    let review: GlobalSearchReviewDisplay
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if !review.title.isEmpty {
                XMKeywordHighlighting.text(
                    review.title,
                    keyword: keyword,
                    baseFont: AppTypography.subheadlineSemibold,
                    highlightFont: AppTypography.subheadlineSemibold,
                    baseColor: Color.textPrimary
                )
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !review.content.isEmpty {
                XMKeywordHighlighting.text(
                    review.content,
                    keyword: keyword,
                    baseFont: NoteExcerptTypography.body,
                    highlightFont: NoteExcerptTypography.body,
                    baseColor: Color.textPrimary
                )
                .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GlobalSearchImageWall(imageURLs: review.imageURLs, idPrefix: "review")

            GlobalSearchFooter(
                leading: formattedBookTitle(review.bookTitle),
                trailing: review.dateText
            )
        }
    }
}

private struct GlobalSearchBookMetadataLines: View {
    let book: GlobalSearchBookDisplay
    let keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            metadataLine(label: "作者：", value: book.author)
            metadataLine(label: "译者：", value: book.translator)
            metadataLine(label: "出版社：", value: book.press)
            metadataLine(label: "ISBN：", value: book.isbn)
        }
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            XMKeywordHighlighting.text(
                label + value,
                keyword: keyword,
                baseFont: AppTypography.caption,
                highlightFont: AppTypography.captionSemibold,
                baseColor: Color.textSecondary
            )
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GlobalSearchIdeaBlock: View {
    let text: String
    let keyword: String

    var body: some View {
        XMKeywordHighlighting.text(
            text,
            keyword: keyword,
            baseFont: NoteExcerptTypography.idea,
            highlightFont: NoteExcerptTypography.idea,
            baseColor: Color.textSecondary
        )
        .lineSpacing(NoteExcerptTypography.ideaLineSpacing)
        .lineLimit(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.cozy)
        .background(
            Color.controlFillSecondary.opacity(0.46),
            in: RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
        )
    }
}

private struct GlobalSearchImageWall: View {
    let imageURLs: [String]
    let idPrefix: String

    var body: some View {
        if !imageURLs.isEmpty {
            XMJXImageWall(
                items: imageURLs.enumerated().map { index, url in
                    XMJXGalleryItem(
                        id: "\(idPrefix)-\(index)-\(url)",
                        thumbnailURL: url,
                        originalURL: url
                    )
                },
                columnCount: imageURLs.count == 1 ? 1 : min(5, imageURLs.count),
                spacing: Spacing.half
            )
        }
    }
}

private struct GlobalSearchInfoChipStrip: View {
    let items: [String]
    let keyword: String

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.tight) {
                    ForEach(items, id: \.self) { item in
                        XMKeywordHighlighting.text(
                            item,
                            keyword: keyword,
                            baseFont: AppTypography.caption2Medium,
                            highlightFont: AppTypography.caption2Medium,
                            baseColor: Color.textSecondary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(
                            Color.controlFillSecondary.opacity(0.54),
                            in: Capsule()
                        )
                    }
                }
            }
        }
    }
}

private struct GlobalSearchTagStrip: View {
    let tags: [String]
    var keyword: String = ""

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.tight) {
                    ForEach(tags, id: \.self) { tag in
                        XMKeywordHighlighting.text(
                            "#\(tag)",
                            keyword: keyword,
                            baseFont: AppTypography.caption2Medium,
                            highlightFont: AppTypography.caption2Medium,
                            baseColor: Color.textSecondary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(Color.tagBackground, in: Capsule())
                    }
                }
            }
        }
    }
}

private struct GlobalSearchFooter: View {
    let leading: String
    let trailing: String

    var body: some View {
        if !leading.isEmpty || !trailing.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                if !leading.isEmpty {
                    Text(leading)
                        .font(NoteExcerptTypography.footer)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.cozy)

                if !trailing.isEmpty {
                    Text(trailing)
                        .font(NoteExcerptTypography.footer)
                        .foregroundStyle(Color.textHint)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct GlobalSearchErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "exclamationmark.circle")
                .font(AppTypography.title2)
                .foregroundStyle(Color.feedbackWarning)
                .accessibilityHidden(true)

            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: onRetry) {
                Label("重新搜索", systemImage: "arrow.clockwise")
                    .font(AppTypography.subheadlineSemibold)
                    .padding(.horizontal, Spacing.base)
                    .frame(minHeight: Spacing.actionReserved)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
    }
}

private func formattedBookTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "" : "《\(trimmed)》"
}

private extension GlobalSearchBookDisplay {
    var contextChips: [String] {
        [readStatusName, sourceName, progressText.isEmpty ? "" : "进度 \(progressText)", recentReadText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
