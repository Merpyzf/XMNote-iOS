/**
 * [INPUT]: 依赖 MainTabView 提供搜索 query、提交/历史词协调与结果导航回调，依赖 RepositoryContainer 和 GlobalSearchViewModel
 * [OUTPUT]: 对外提供 GlobalSearchView，渲染 iOS 原生搜索 Tab 下的固定范围栏、全局搜索结果、搜索历史、分类筛选、空态、加载态、错误态与搜索来源详情打开入口
 * [POS]: Search 模块根视图，被 Search Tab NavigationStack 消费；普通详情 push，沉浸查看目标交给根级全屏任务呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 搜索宿主捕获到的提交事件，使用唯一 id 保证相同关键词连续提交也能被搜索页感知。
struct GlobalSearchSubmitRequest: Equatable, Identifiable {
    let id = UUID()
    let query: String
}

/// 搜索结果导航意图，由 MainTabView 按浏览层级或沉浸任务分流。
enum GlobalSearchNavigationTarget: Hashable {
    case book(BookRoute)
    case content(ContentRoute)
    case contentViewer(
        source: ContentViewerSourceContext,
        initialItemID: ContentViewerItemID,
        keyword: String
    )
}

/// 全局搜索 Tab 根视图，承接系统搜索框 query 并在 iOS 原生搜索语境内展示四类本地结果。
struct GlobalSearchView: View {
    @Binding private var query: String
    private let submitRequest: GlobalSearchSubmitRequest?
    private let onBeginSearchSuggestion: (String) -> Void
    private let onCancelSearchSuggestion: (String) -> Void
    private let onCommitSearchSuggestion: (String) -> Void
    private let onPrepareHistoryClearConfirmation: () -> Void
    private let onOpenResult: (GlobalSearchNavigationTarget) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: GlobalSearchViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var clearHistoryConfirmationRequest: GlobalSearchHistoryClearConfirmationRequest?
    @State private var historyManagementResetID = UUID()

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
        onBeginSearchSuggestion: @escaping (String) -> Void,
        onCancelSearchSuggestion: @escaping (String) -> Void,
        onCommitSearchSuggestion: @escaping (String) -> Void,
        onPrepareHistoryClearConfirmation: @escaping () -> Void,
        onOpenResult: @escaping (GlobalSearchNavigationTarget) -> Void
    ) {
        self._query = query
        self.submitRequest = submitRequest
        self.onBeginSearchSuggestion = onBeginSearchSuggestion
        self.onCancelSearchSuggestion = onCancelSearchSuggestion
        self.onCommitSearchSuggestion = onCommitSearchSuggestion
        self.onPrepareHistoryClearConfirmation = onPrepareHistoryClearConfirmation
        self.onOpenResult = onOpenResult
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                GlobalSearchLoadedContent(
                    query: trimmedQuery,
                    viewModel: viewModel,
                    historyManagementResetID: historyManagementResetID,
                    onOpenResult: openResult,
                    onBeginSuggestion: beginSuggestion,
                    onCancelSuggestion: cancelSuggestion,
                    onSelectSuggestion: selectSuggestion,
                    onRequestHistoryClearConfirmation: requestHistoryClearConfirmation
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
            bootstrapLoadingGate.hideImmediately()
        }
    }

    private func openResult(_ result: GlobalSearchResult) {
        let keyword = trimmedQuery
        viewModel?.recordConfirmedQuery(keyword)
        guard let target = navigationTarget(for: result.target, keyword: keyword) else {
            return
        }
        onOpenResult(target)
    }

    private func navigationTarget(
        for target: GlobalSearchTarget,
        keyword: String
    ) -> GlobalSearchNavigationTarget? {
        switch target {
        case .bookDetail(let bookId):
            return .book(.detail(bookId: bookId))
        case .noteViewer(let noteId, let bookId):
            return .contentViewer(
                source: .bookNotes(bookId: bookId),
                initialItemID: .note(noteId),
                keyword: keyword
            )
        case .relevantDetail(let contentId):
            return .content(.relevantDetail(contentId: contentId))
        case .relevantBook(_, let bookId):
            return .book(.detail(bookId: bookId))
        case .reviewDetail(let reviewId):
            return .content(.reviewDetail(reviewId: reviewId))
        }
    }

    private func beginSuggestion(_ suggestion: String) {
        onBeginSearchSuggestion(suggestion)
    }

    private func cancelSuggestion(_ suggestion: String) {
        onCancelSearchSuggestion(suggestion)
    }

    private func selectSuggestion(_ suggestion: String) {
        onCommitSearchSuggestion(suggestion)
    }

    private func requestHistoryClearConfirmation() {
        onPrepareHistoryClearConfirmation()
        let request = GlobalSearchHistoryClearConfirmationRequest()
        clearHistoryConfirmationRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
            presentClearHistoryConfirmation(for: request)
        }
    }

    private func presentClearHistoryConfirmation(for request: GlobalSearchHistoryClearConfirmationRequest) {
        guard clearHistoryConfirmationRequest?.id == request.id else { return }
        guard let presenter = UIApplication.shared.xmActiveAlertPresenter else { return }
        XMSystemAlertController.present(
            on: presenter,
            descriptor: clearHistoryDescriptor(for: request)
        )
    }

    private func clearHistoryDescriptor(for request: GlobalSearchHistoryClearConfirmationRequest) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "清空搜索历史？",
            message: "这会移除全部最近搜索词，不影响你的本地内容。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) {
                    dismissHistoryClearConfirmation(request)
                },
                XMSystemAlertAction(title: "清空", role: .destructive) {
                    viewModel?.clearRecentQueries()
                    historyManagementResetID = UUID()
                    dismissHistoryClearConfirmation(request)
                }
            ]
        )
    }

    private func dismissHistoryClearConfirmation(_ request: GlobalSearchHistoryClearConfirmationRequest) {
        guard clearHistoryConfirmationRequest?.id == request.id else { return }
        clearHistoryConfirmationRequest = nil
    }
}

private struct GlobalSearchHistoryClearConfirmationRequest: Identifiable {
    let id = UUID()
}

private extension UIApplication {
    var xmActiveAlertPresenter: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .xmTopMostPresentedViewController
    }
}

private extension UIViewController {
    var xmTopMostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.xmTopMostPresentedViewController
        }
        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.xmTopMostPresentedViewController ?? navigationController
        }
        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.xmTopMostPresentedViewController ?? tabBarController
        }
        return self
    }
}

private struct GlobalSearchLoadedContent: View {
    let query: String
    @Bindable var viewModel: GlobalSearchViewModel
    let historyManagementResetID: UUID
    let onOpenResult: (GlobalSearchResult) -> Void
    let onBeginSuggestion: (String) -> Void
    let onCancelSuggestion: (String) -> Void
    let onSelectSuggestion: (String) -> Void
    let onRequestHistoryClearConfirmation: () -> Void

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
                    onBeginSuggestion: onBeginSuggestion,
                    onCancelSuggestion: onCancelSuggestion,
                    onSelectSuggestion: selectHistorySuggestion,
                    onRemoveSuggestion: viewModel.removeRecentQuery,
                    onClearAllHistory: onRequestHistoryClearConfirmation
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
        .onChange(of: viewModel.loadState) { _, newValue in
            syncLoadingGate()
            if !isIdle(newValue) {
                resetHistoryManagementState()
            }
        }
        .onChange(of: query) { _, _ in
            resetResultScrollState()
            resetHistoryManagementState()
        }
        .onChange(of: viewModel.resultRevision) { _, _ in
            resetResultScrollState()
        }
        .onChange(of: historyManagementResetID) { _, _ in
            resetHistoryManagementState()
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
        let showsFieldScopeFilter = viewModel.shouldShowFieldScopeFilter
        let visibleResults = viewModel.visibleResults

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                if showsFieldScopeFilter {
                    fieldScopeFilterSection
                }

                if visibleResults.isEmpty {
                    if showsFieldScopeFilter {
                        GlobalSearchInlineEmptyView(title: "没有找到内容", subtitle: "换个范围试试")
                    } else {
                        topAnchoredContent {
                            GlobalSearchInlineEmptyView(title: "没有找到内容", subtitle: "换个范围试试")
                        }
                    }
                } else {
                    resultRows(visibleResults: visibleResults, showsFieldScopeFilter: showsFieldScopeFilter)
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

    private func resultRows(
        visibleResults: [GlobalSearchResult],
        showsFieldScopeFilter: Bool
    ) -> some View {
        let firstResultID = visibleResults.first?.id
        return ForEach(visibleResults) { result in
            if result.id == firstResultID, !showsFieldScopeFilter {
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

    private func selectHistorySuggestion(_ suggestion: String) {
        resetHistoryManagementState()
        onSelectSuggestion(suggestion)
    }

    private func resetHistoryManagementState() {
        guard isHistoryExpanded || isHistoryEditing else { return }
        isHistoryExpanded = false
        isHistoryEditing = false
    }

    private func isIdle(_ loadState: GlobalSearchViewModel.LoadState) -> Bool {
        if case .idle = loadState {
            return true
        }
        return false
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
    let onBeginSuggestion: (String) -> Void
    let onCancelSuggestion: (String) -> Void
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
                onBeginSelect: onBeginSuggestion,
                onCancelBeginSelect: onCancelSuggestion,
                onSelect: onSelectSuggestion,
                onRemove: onRemoveSuggestion,
                onClearAll: onClearAllHistory
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.section)
            .padding(.bottom, Spacing.actionReserved * 3)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.never)
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
    private let items: [XMJXGalleryItem]
    private let columnCount: Int

    init(imageURLs: [String], idPrefix: String) {
        self.items = imageURLs.enumerated().map { index, url in
            XMJXGalleryItem(
                id: "\(idPrefix)-\(index)-\(url)",
                thumbnailURL: url,
                originalURL: url
            )
        }
        self.columnCount = imageURLs.count == 1 ? 1 : min(5, imageURLs.count)
    }

    var body: some View {
        if !items.isEmpty {
            XMJXImageWall(
                items: items,
                columnCount: columnCount,
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
