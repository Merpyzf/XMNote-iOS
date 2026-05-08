/**
 * [INPUT]: 依赖 BookSearchRepositoryProtocol 提供远端搜索、详情补抓、最近搜索与搜索设置持久化
 * [OUTPUT]: 对外提供 BookSearchViewModel，驱动书籍搜索页的查询、状态、设置与结果交互
 * [POS]: ViewModels/Book 的书籍搜索状态编排器，被 BookSearchView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍搜索状态源，负责组织六书源搜索、最近搜索和搜索结果选择流程。
@Observable
final class BookSearchViewModel {
    struct SearchFailure {
        let bookSearchError: BookSearchError?
        let message: String
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

    init(
        repository: any BookSearchRepositoryProtocol,
        initialQuery: String = "",
        initialSource: BookSearchSource? = nil
    ) {
        self.repository = repository
        let settings = repository.fetchSearchSettings()
        self.query = initialQuery
        self.searchSettings = settings
        self.selectedSource = initialSource ?? settings.defaultSource
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

    /// 刷新最近搜索词，保证删除或新增后 UI 与本地存储一致。
    func reloadRecentQueries() {
        recentQueries = repository.fetchRecentQueries()
    }

    /// 执行当前来源搜索，并在发起有效搜索时立即刷新最近搜索列表。
    @MainActor
    func search() async -> SearchFailure? {
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
            return failure
        }

        repository.saveRecentQuery(keyword)
        reloadRecentQueries()

        isSearching = true
        defer { isSearching = false }

        do {
            let items = try await repository.search(keyword: keyword, source: selectedSource)
            results = items
            return nil
        } catch {
            let bookSearchError = error as? BookSearchError
            let failure = SearchFailure(
                bookSearchError: bookSearchError,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            errorMessage = failure.message
            latestSearchError = failure.bookSearchError
            return failure
        }
    }

    /// 将最近搜索词回填到输入框并立即触发搜索。
    @MainActor
    func search(withRecentQuery query: String) async {
        self.query = query
        _ = await search()
    }

    /// 删除一条最近搜索词。
    func removeRecentQuery(_ query: String) {
        repository.removeRecentQuery(query)
        reloadRecentQueries()
    }

    /// 选择当前搜索来源，并在设置中同步默认来源。
    func updateSelectedSource(_ source: BookSearchSource) {
        selectedSource = source
        updateDefaultSource(source)
    }

    /// 更新默认搜索源并持久化，供下次进入搜索页直接沿用。
    func updateDefaultSource(_ source: BookSearchSource) {
        searchSettings.defaultSource = source
        repository.saveSearchSettings(searchSettings)
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
}
