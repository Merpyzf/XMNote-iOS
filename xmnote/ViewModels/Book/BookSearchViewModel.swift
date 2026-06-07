/**
 * [INPUT]: 依赖 BookSearchRepositoryProtocol 提供远端搜索、详情补抓、最近搜索与搜索设置持久化
 * [OUTPUT]: 对外提供 BookSearchViewModel，驱动书籍搜索页的查询、状态、设置与结果交互
 * [POS]: ViewModels/Book 的书籍搜索状态编排器，被 BookSearchView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍搜索状态源，负责组织远端书源搜索、最近搜索和搜索结果选择流程。
@Observable
final class BookSearchViewModel {
    struct SearchFailure {
        let bookSearchError: BookSearchError?
        let message: String
    }

    /// 搜索请求完成后的页面处理语义，区分真实成功、业务失败与已过期回调。
    enum SearchOutcome {
        case success
        case failure(SearchFailure)
        case stale
    }

    var query: String = ""
    var selectedSource: BookSearchSource = .wenqu
    var searchSettings: BookSearchSettings = .default
    var recentQueries: [String] = []
    var results: [BookSearchResult] = []
    var errorMessage: String?
    var latestSearchError: BookSearchError?
    var isSearching = false
    var hasSearched = false

    private let repository: any BookSearchRepositoryProtocol
    private var searchRequestSequence = 0

    init(
        repository: any BookSearchRepositoryProtocol,
        initialQuery: String = "",
        initialSource: BookSearchSource? = nil
    ) {
        self.repository = repository
        let settings = repository.fetchSearchSettings().normalized()
        let seedSource = initialSource ?? settings.defaultSource
        self.query = initialQuery
        self.searchSettings = settings
        self.selectedSource = seedSource.isProductionVisible ? seedSource : BookSearchSettings.default.defaultSource
        self.recentQueries = repository.fetchRecentQueries()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var shouldShowRecentQueries: Bool {
        !recentQueries.isEmpty
    }

    var shouldShowEmptyState: Bool {
        hasSearched && !isSearching && results.isEmpty && errorMessage == nil
    }

    var availableSources: [BookSearchSource] {
        BookSearchSource.productionCases
    }

    /// 更新搜索输入；输入变化会令当前搜索请求过期，清空时同步复位结果与错误状态。
    func searchQueryDidChange(_ query: String) {
        self.query = query
        invalidateSearchRequests()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetSearchStateForEmptyQuery()
        }
    }

    /// 刷新最近搜索词，保证删除或新增后 UI 与本地存储一致。
    func reloadRecentQueries() {
        recentQueries = repository.fetchRecentQueries()
    }

    /// 执行当前来源搜索；状态回写固定在 MainActor，并用请求序号把已取消或过期的旧请求标记为 stale。
    @MainActor
    func search() async -> SearchOutcome {
        let requestID = nextSearchRequestID()
        let keyword = trimmedQuery
        hasSearched = true
        results = []
        errorMessage = nil
        latestSearchError = nil

        guard !keyword.isEmpty else {
            let failure = SearchFailure(
                bookSearchError: .emptyKeyword,
                message: BookSearchError.emptyKeyword.errorDescription ?? "请输入书名、作者或 ISBN"
            )
            errorMessage = failure.message
            latestSearchError = failure.bookSearchError
            return .failure(failure)
        }

        repository.saveRecentQuery(keyword)
        reloadRecentQueries()

        isSearching = true
        defer {
            if isCurrentSearchRequest(requestID) {
                isSearching = false
            }
        }

        do {
            let items = try await repository.search(keyword: keyword, source: selectedSource)
            guard !Task.isCancelled, isCurrentSearchRequest(requestID) else { return .stale }
            results = items
            return .success
        } catch {
            guard !Task.isCancelled, isCurrentSearchRequest(requestID) else { return .stale }
            let bookSearchError = error as? BookSearchError
            let failure = SearchFailure(
                bookSearchError: bookSearchError,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            errorMessage = failure.message
            latestSearchError = failure.bookSearchError
            return .failure(failure)
        }
    }

    /// 将最近搜索词回填到输入框并立即触发搜索。
    @MainActor
    func search(withRecentQuery query: String) async {
        searchQueryDidChange(query)
        _ = await search()
    }

    /// 删除一条最近搜索词。
    func removeRecentQuery(_ query: String) {
        repository.removeRecentQuery(query)
        reloadRecentQueries()
    }

    /// 选择当前搜索来源，并在设置中同步默认来源。
    func updateSelectedSource(_ source: BookSearchSource) {
        let effectiveSource = source.isProductionVisible ? source : BookSearchSettings.default.defaultSource
        if selectedSource != effectiveSource {
            invalidateSearchRequests()
        }
        selectedSource = effectiveSource
        updateDefaultSource(effectiveSource)
    }

    /// 更新默认搜索源并持久化，供下次进入搜索页直接沿用。
    func updateDefaultSource(_ source: BookSearchSource) {
        searchSettings.defaultSource = source.isProductionVisible ? source : BookSearchSettings.default.defaultSource
        searchSettings = searchSettings.normalized()
        repository.saveSearchSettings(searchSettings)
    }

    /// 更新来源搜索页数；只有服务层实际消费页数的来源会被持久化。
    func updateSearchPageCount(_ count: Int, for source: BookSearchSource) {
        guard source.supportsSearchPageCount else { return }
        searchSettings.pageCounts[source] = BookSearchSettings.clampedPageCount(count)
        searchSettings = searchSettings.normalized()
        repository.saveSearchSettings(searchSettings)
    }

    /// 读取来源当前页数，供设置页用原生 Stepper 展示。
    func searchPageCount(for source: BookSearchSource) -> Int? {
        searchSettings.pageCount(for: source)
    }

    /// 更新快速切换开关；关闭后 UI 隐藏来源横排入口但保留当前默认源。
    func updateQuickSourceSwitch(_ isEnabled: Bool) {
        searchSettings.isQuickSourceSwitchEnabled = isEnabled
        repository.saveSearchSettings(searchSettings)
    }

    /// 更新保存后返回书架偏好，对齐 Android 添加完成后的返回控制。
    func updateReturnToBookshelfAfterSave(_ isEnabled: Bool) {
        searchSettings.shouldReturnToBookshelfAfterSave = isEnabled
        repository.saveSearchSettings(searchSettings)
    }

    /// 将轻量结果补齐为录入页种子；豆瓣场景会在这里抓详情。
    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        try await repository.prepareSeed(for: result)
    }

    private func resetSearchStateForEmptyQuery() {
        results = []
        errorMessage = nil
        latestSearchError = nil
        isSearching = false
        hasSearched = false
    }

    private func nextSearchRequestID() -> Int {
        searchRequestSequence += 1
        return searchRequestSequence
    }

    private func invalidateSearchRequests() {
        searchRequestSequence += 1
        isSearching = false
    }

    private func isCurrentSearchRequest(_ requestID: Int) -> Bool {
        searchRequestSequence == requestID
    }
}
