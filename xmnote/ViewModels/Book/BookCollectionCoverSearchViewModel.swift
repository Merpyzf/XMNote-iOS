/**
 * [INPUT]: 依赖 BookSearchRepositoryProtocol 的在线搜索能力与 BookSearchSource 生产来源配置，承接书单内书籍封面在线匹配请求
 * [OUTPUT]: 对外提供 BookCollectionCoverSearchViewModel 与 BookCollectionCoverSearchStatus，驱动封面搜索 Sheet 的查询、来源切换、加载与错误状态
 * [POS]: ViewModels/Book 的书单封面匹配状态编排器，被 BookCollectionCoverSearchSheet 消费，不直接写入数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书单内封面在线匹配的读取状态，供 Sheet 映射 LoadingGate 与结果区文案。
enum BookCollectionCoverSearchStatus: Hashable {
    case idle
    case loading
    case results
    case empty
    case failure(String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

/// 书单内封面在线匹配状态源；所有 UI 状态写回固定在 MainActor，旧搜索任务会被取消并通过序号丢弃过期结果。
@MainActor
@Observable
final class BookCollectionCoverSearchViewModel {
    var query: String
    var selectedSource: BookSearchSource
    var results: [BookSearchResult]
    var status: BookCollectionCoverSearchStatus

    private let repository: any BookSearchRepositoryProtocol
    private var searchTask: Task<Void, Never>?
    private var searchSequence = 0

    var availableSources: [BookSearchSource] {
        BookSearchSource.productionCases
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        initialTitle: String,
        repository: any BookSearchRepositoryProtocol
    ) {
        self.query = initialTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedSource = BookSearchSource.productionCases.first ?? .wenqu
        self.results = []
        self.status = .idle
        self.repository = repository
    }

    isolated deinit {
        searchTask?.cancel()
    }

    /// 更新搜索词；清空时取消当前读取任务并复位结果，避免旧结果覆盖新的空态。
    func updateQuery(_ value: String) {
        query = value
        guard trimmedQuery.isEmpty else { return }
        searchTask?.cancel()
        results = []
        status = .idle
    }

    /// 切换在线搜索来源；若当前已有搜索词，则立即重新搜索并取消上一轮请求。
    func updateSource(_ source: BookSearchSource) {
        guard source.isProductionVisible else { return }
        guard selectedSource != source else { return }
        selectedSource = source
        guard !trimmedQuery.isEmpty else { return }
        search()
    }

    /// 发起封面搜索读取任务；任务取消或过期时不回写 UI，成功后仅保留存在封面链接的结果。
    func search() {
        searchTask?.cancel()
        let keyword = trimmedQuery
        guard !keyword.isEmpty else {
            results = []
            status = .failure(BookSearchError.emptyKeyword.errorDescription ?? "请输入书名")
            return
        }

        let requestID = nextSearchSequence()
        let source = selectedSource
        results = []
        status = .loading
        searchTask = Task { [repository] in
            do {
                let items = try await repository.search(keyword: keyword, source: source)
                let coverItems = items.filter {
                    !$0.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !Task.isCancelled else { return }
                applySearchResults(coverItems, requestID: requestID)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                applySearchFailure(message, requestID: requestID)
            }
        }
    }

    private func nextSearchSequence() -> Int {
        searchSequence += 1
        return searchSequence
    }

    private func isCurrentSearch(_ requestID: Int) -> Bool {
        requestID == searchSequence
    }

    private func applySearchResults(_ items: [BookSearchResult], requestID: Int) {
        guard isCurrentSearch(requestID) else { return }
        results = items
        status = items.isEmpty ? .empty : .results
    }

    private func applySearchFailure(_ message: String, requestID: Int) {
        guard isCurrentSearch(requestID) else { return }
        results = []
        status = .failure(message)
    }
}
