/**
 * [INPUT]: 依赖 MainTabView 提供搜索 query 绑定与导航回调，依赖 RepositoryContainer 注入全局搜索仓储，依赖 GlobalSearchViewModel 驱动本地搜索状态
 * [OUTPUT]: 对外提供 GlobalSearchView，渲染 iOS 原生搜索 Tab 下的固定范围栏、全局搜索结果、分类筛选、空态、加载态与错误态
 * [POS]: Search 模块根视图，被 MainTabView 的搜索 Tab NavigationStack 消费，并通过回调回传 BookRoute/ContentRoute
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 全局搜索 Tab 根视图，承接系统搜索框 query 并在 iOS 原生搜索语境内展示四类本地结果。
struct GlobalSearchView: View {
    @Binding private var query: String
    private let onOpenBookRoute: (BookRoute) -> Void
    private let onOpenContentRoute: (ContentRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: GlobalSearchViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var isSearchTextComposing = false
    @State private var queryDispatchTask: Task<Void, Never>?

    private var topBarHeight: CGFloat {
        dynamicTypeSize >= .accessibility1 ? 60 : 56
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入系统搜索框 query 与导航回调，保持搜索页不直接持有外层 NavigationPath。
    init(
        query: Binding<String>,
        onOpenBookRoute: @escaping (BookRoute) -> Void,
        onOpenContentRoute: @escaping (ContentRoute) -> Void
    ) {
        self._query = query
        self.onOpenBookRoute = onOpenBookRoute
        self.onOpenContentRoute = onOpenContentRoute
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                GlobalSearchLoadedContent(
                    query: trimmedQuery,
                    viewModel: viewModel,
                    onOpenResult: openResult,
                    onSelectSuggestion: selectSuggestion
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
            newViewModel.queryDidChange(query)
        }
        .onChange(of: query) { _, newValue in
            dispatchQueryChange(newValue)
        }
        .onChange(of: isSearchTextComposing) { oldValue, newValue in
            guard oldValue, !newValue else { return }
            dispatchQueryChange(query)
        }
        .onSubmit(of: .search) {
            viewModel?.submit(query: query)
        }
        .background {
            SearchTextCompositionProbe(isComposing: $isSearchTextComposing)
                .frame(width: 0, height: 0)
        }
        .onDisappear {
            queryDispatchTask?.cancel()
            queryDispatchTask = nil
            bootstrapLoadingGate.hideImmediately()
            viewModel?.cancelSearch()
        }
    }

    private func openResult(_ result: GlobalSearchResult) {
        switch result.target {
        case .bookDetail(let bookId):
            onOpenBookRoute(.detail(bookId: bookId))
        case .noteViewer(let noteId, let bookId):
            onOpenContentRoute(
                .contentViewer(
                    source: .bookNotes(bookId: bookId),
                    initialItemID: .note(noteId),
                    keyword: trimmedQuery
                )
            )
        case .relevantDetail(let contentId):
            onOpenContentRoute(.relevantDetail(contentId: contentId))
        case .relevantBook(_, let bookId):
            onOpenBookRoute(.detail(bookId: bookId))
        case .reviewDetail(let reviewId):
            onOpenContentRoute(.reviewDetail(reviewId: reviewId))
        }
    }

    /// 延后一轮主线程再读取输入组合态；这样拼音候选的 marked text 更新有机会先到达，避免临时拼音触发搜索任务。
    private func dispatchQueryChange(_ newValue: String) {
        queryDispatchTask?.cancel()
        queryDispatchTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard !isSearchTextComposing else { return }
            viewModel?.queryDidChange(newValue)
        }
    }

    private func selectSuggestion(_ suggestion: String) {
        query = suggestion
        viewModel?.submit(query: suggestion)
    }
}

private struct GlobalSearchLoadedContent: View {
    let query: String
    @Bindable var viewModel: GlobalSearchViewModel
    let onOpenResult: (GlobalSearchResult) -> Void
    let onSelectSuggestion: (String) -> Void

    @State private var loadingGate = LoadingGate()
    @State private var resultScrollTarget: GlobalSearchScrollTarget? = .top
    @State private var scopeScrollTargets: [GlobalSearchScope: GlobalSearchScrollTarget] = [:]

    var body: some View {
        ZStack {
            switch viewModel.loadState {
            case .idle:
                GlobalSearchRootView(
                    recentQueries: viewModel.recentQueries,
                    onSelectSuggestion: onSelectSuggestion
                )
            case .preparing:
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            CardContainer(cornerRadius: CornerRadius.blockMedium, showsBorder: true, borderColor: .surfaceBorderSubtle) {
                rowContent
                    .padding(Spacing.base)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch result.display {
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
    let onSelectSuggestion: (String) -> Void

    var body: some View {
        if recentQueries.isEmpty {
            GlobalSearchPlaceholderView(
                title: "输入关键词",
                subtitle: "查找你的本地内容"
            )
            .padding(.bottom, Spacing.actionReserved * 2)
        } else {
            ScrollView {
                suggestionSection
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.section)
                    .padding(.bottom, Spacing.actionReserved * 3)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("最近搜索")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)],
                alignment: .leading,
                spacing: Spacing.cozy
            ) {
                ForEach(recentQueries, id: \.self) { suggestion in
                    Button {
                        onSelectSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, Spacing.base)
                            .frame(minHeight: Spacing.actionReserved)
                    }
                    .buttonStyle(GlobalSearchChipButtonStyle())
                    .accessibilityLabel("搜索 \(suggestion)")
                }
            }
        }
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

private struct GlobalSearchChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.surfaceCard, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
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

/// 监听系统搜索框的多阶段输入状态；marked text 未确认时不触发搜索，避免中文拼音候选中途发起读取任务。
private struct SearchTextCompositionProbe: UIViewRepresentable {
    @Binding var isComposing: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        let binding = $isComposing
        view.onCompositionChange = { composing in
            if binding.wrappedValue != composing {
                binding.wrappedValue = composing
            }
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        let binding = $isComposing
        uiView.onCompositionChange = { composing in
            if binding.wrappedValue != composing {
                binding.wrappedValue = composing
            }
        }
        uiView.refreshSoon()
    }

    /// UIKit 通知回调始终在主线程处理；对象释放时移除观察，避免搜索页离场后继续回写 SwiftUI 状态。
    final class ProbeView: UIView {
        var onCompositionChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            isHidden = true
            isUserInteractionEnabled = false
            registerObservers()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refreshSoon()
        }

        func refreshSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publish(self.window?.activeTextField?.markedTextRange != nil)
            }
        }

        private func registerObservers() {
            let names: [Notification.Name] = [
                UITextField.textDidBeginEditingNotification,
                UITextField.textDidChangeNotification,
                UITextField.textDidEndEditingNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let self else { return }
                    guard let textField = notification.object as? UITextField else {
                        self.refreshSoon()
                        return
                    }
                    self.publish(textField.markedTextRange != nil)
                }
            }
        }

        private func publish(_ composing: Bool) {
            onCompositionChange?(composing)
        }
    }
}

private extension UIView {
    var activeTextField: UITextField? {
        if let textField = self as? UITextField, textField.isFirstResponder {
            return textField
        }

        for subview in subviews {
            if let match = subview.activeTextField {
                return match
            }
        }

        return nil
    }
}
