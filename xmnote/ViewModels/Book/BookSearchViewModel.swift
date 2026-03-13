/**
 * [INPUT]: 依赖 BookSearchRepositoryProtocol 提供远端搜索、详情补抓和最近搜索持久化
 * [OUTPUT]: 对外提供 BookSearchViewModel，驱动书籍搜索页的查询、状态与结果交互
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
        initialSource: BookSearchSource = .wenqu
    ) {
        self.repository = repository
        self.query = initialQuery
        self.selectedSource = initialSource
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

    /// 将轻量结果补齐为录入页种子；豆瓣场景会在这里抓详情。
    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        try await repository.prepareSeed(for: result)
    }
}
