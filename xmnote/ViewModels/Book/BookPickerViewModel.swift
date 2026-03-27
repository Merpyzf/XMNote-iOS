/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供本地书籍查询与结果解析，依赖 BookSearchRepositoryProtocol 提供在线搜索与种子补齐
 * [OUTPUT]: 对外提供 BookPickerViewModel、BookPickerVisibleScope 与 BookPickerStatus，驱动通用书籍选择流状态机
 * [POS]: ViewModels/Book 的书籍选择状态编排器，被 BookPickerView 与测试共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍选择流当前正在展示的结果范围。
enum BookPickerVisibleScope: Hashable {
    case local
    case online
}

/// 书籍选择流的结果区状态。
enum BookPickerStatus: Hashable {
    case localLoading
    case localResults
    case localEmptyLibrary
    case localNoResults
    case onlineIdle
    case onlineLoading
    case onlineResults
    case onlineFailure(String)
    case onlineNoResults
}

/// 书籍选择状态源，统一承接本地查询、在线搜索、多选与创建回填。
@MainActor
@Observable
final class BookPickerViewModel {
    var query: String
    var visibleScope: BookPickerVisibleScope
    var selectedOnlineSource: BookSearchSource
    var localBooks: [BookPickerBook]
    var remoteResults: [BookSearchResult]
    var selectedBooks: [BookPickerBook]
    var isLoadingLocal = false
    var isSearchingOnline = false
    var onlineErrorMessage: String?
    var hasSubmittedOnlineSearch = false

    let configuration: BookPickerConfiguration

    private let bookRepository: any BookRepositoryProtocol
    private let searchRepository: any BookSearchRepositoryProtocol
    private var hasLoaded = false
    private var localSearchTask: Task<Void, Never>?
    private var onlineSearchTask: Task<Void, Never>?
    private var localSearchSequence = 0
    private var onlineSearchSequence = 0

    init(
        configuration: BookPickerConfiguration,
        bookRepository: any BookRepositoryProtocol,
        searchRepository: any BookSearchRepositoryProtocol
    ) {
        self.configuration = configuration
        self.bookRepository = bookRepository
        self.searchRepository = searchRepository
        self.query = configuration.defaultQuery
        self.localBooks = []
        self.remoteResults = []
        self.selectedBooks = Self.deduplicatedBooks(configuration.preselectedBooks)
        self.visibleScope = configuration.scope == .online ? .online : .local
        if let preferred = configuration.preferredOnlineSource,
           configuration.onlineSources.contains(preferred) {
            self.selectedOnlineSource = preferred
        } else {
            self.selectedOnlineSource = configuration.onlineSources.first ?? .wenqu
        }
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isMultipleSelectionEnabled: Bool {
        configuration.selectionMode == .multiple
    }

    var supportsManualCreate: Bool {
        configuration.allowsManualCreate
    }

    var supportsOnline: Bool {
        configuration.scope != .local && !configuration.onlineSources.isEmpty
    }

    var supportsScopeSwitch: Bool {
        configuration.scope == .both && supportsOnline
    }

    var selectedCount: Int {
        selectedBooks.count
    }

    var status: BookPickerStatus {
        switch visibleScope {
        case .local:
            if isLoadingLocal { return .localLoading }
            if !localBooks.isEmpty { return .localResults }
            return trimmedQuery.isEmpty ? .localEmptyLibrary : .localNoResults
        case .online:
            if trimmedQuery.isEmpty { return .onlineIdle }
            if isSearchingOnline { return .onlineLoading }
            if let onlineErrorMessage { return .onlineFailure(onlineErrorMessage) }
            if !remoteResults.isEmpty { return .onlineResults }
            return hasSubmittedOnlineSearch ? .onlineNoResults : .onlineIdle
        }
    }

    /// 首次进入书籍选择流时加载默认范围的数据。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch visibleScope {
        case .local:
            await refreshLocalBooks()
        case .online:
            guard !trimmedQuery.isEmpty else { return }
            await submitOnlineSearch()
        }
    }

    /// 更新关键词并按当前可见范围触发对应刷新策略。
    func updateQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query

        switch visibleScope {
        case .local:
            localSearchTask?.cancel()
            localSearchTask = Task { [weak self] in
                await self?.refreshLocalBooks()
            }
        case .online:
            if trimmedQuery.isEmpty {
                remoteResults = []
                onlineErrorMessage = nil
                hasSubmittedOnlineSearch = false
            }
        }
    }

    /// 切换本地/在线结果范围，并保留当前关键词与已选上下文。
    func switchVisibleScope(_ scope: BookPickerVisibleScope) {
        guard visibleScope != scope else { return }
        visibleScope = scope
        switch scope {
        case .local:
            localSearchTask?.cancel()
            localSearchTask = Task { [weak self] in
                await self?.refreshLocalBooks()
            }
        case .online:
            guard !trimmedQuery.isEmpty else {
                remoteResults = []
                onlineErrorMessage = nil
                return
            }
            onlineSearchTask?.cancel()
            onlineSearchTask = Task { [weak self] in
                await self?.submitOnlineSearch()
            }
        }
    }

    /// 切换当前在线搜索源；若已有关键词，则自动重新发起在线搜索。
    func selectOnlineSource(_ source: BookSearchSource) {
        guard configuration.onlineSources.contains(source) else { return }
        guard selectedOnlineSource != source else { return }
        selectedOnlineSource = source
        onlineErrorMessage = nil
        remoteResults = []

        guard visibleScope == .online, !trimmedQuery.isEmpty else { return }
        onlineSearchTask?.cancel()
        onlineSearchTask = Task { [weak self] in
            await self?.submitOnlineSearch()
        }
    }

    /// 刷新本地书籍列表，供本地范围与实时搜索消费。
    func refreshLocalBooks() async {
        localSearchSequence += 1
        let requestID = localSearchSequence
        let keyword = trimmedQuery
        isLoadingLocal = true
        defer {
            if requestID == localSearchSequence {
                isLoadingLocal = false
            }
        }

        do {
            let books = try await bookRepository.fetchPickerBooks(matching: keyword)
            guard requestID == localSearchSequence else { return }
            localBooks = books
        } catch {
            guard requestID == localSearchSequence else { return }
            localBooks = []
        }
    }

    /// 发起当前关键词的在线搜索，并统一收口错误与结果态。
    func submitOnlineSearch() async {
        let keyword = trimmedQuery
        onlineSearchSequence += 1
        let requestID = onlineSearchSequence
        remoteResults = []
        onlineErrorMessage = nil

        guard !keyword.isEmpty else {
            if requestID == onlineSearchSequence {
                hasSubmittedOnlineSearch = false
            }
            return
        }

        hasSubmittedOnlineSearch = true
        isSearchingOnline = true
        defer {
            if requestID == onlineSearchSequence {
                isSearchingOnline = false
            }
        }

        do {
            let source = selectedOnlineSource
            let results = try await searchRepository.search(keyword: keyword, source: source)
            guard requestID == onlineSearchSequence else { return }
            remoteResults = results
        } catch {
            guard requestID == onlineSearchSequence else { return }
            onlineErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 单选模式直接完成；多选模式则切换本地书籍的选中状态。
    func handleLocalBookTap(_ book: BookPickerBook) -> BookPickerResult? {
        if isMultipleSelectionEnabled {
            toggleSelection(for: book)
            return nil
        }
        return .single(book)
    }

    /// 远端结果需要先补齐为录入种子，再进入创建链路。
    func prepareSeed(for result: BookSearchResult) async -> BookEditorSeed? {
        do {
            return try await searchRepository.prepareSeed(for: result)
        } catch {
            onlineErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// 手动创建成功后回填本地书；单选直接完成，多选加入已选集合。
    func handleCreatedBook(bookId: Int64) async -> BookPickerResult? {
        do {
            guard let book = try await bookRepository.fetchPickerBook(bookId: bookId) else {
                onlineErrorMessage = "新建书籍已保存，但未能回填到选择器"
                return nil
            }

            if isMultipleSelectionEnabled {
                addSelectedBookIfNeeded(book)
                return nil
            }
            return .single(book)
        } catch {
            return nil
        }
    }

    /// 多选模式确认当前已选集合。
    func confirmMultipleSelection() -> BookPickerResult? {
        guard isMultipleSelectionEnabled, !selectedBooks.isEmpty else { return nil }
        return .multiple(selectedBooks)
    }

    /// 本地无结果时允许直接切换到在线检索，减少任务中断。
    func switchToOnlineIfSupported() {
        guard supportsOnline else { return }
        switchVisibleScope(.online)
    }

    /// 为创建链路生成手动录入种子。
    func makeManualSeed() -> BookEditorSeed {
        .manual
    }

    func isBookSelected(_ book: BookPickerBook) -> Bool {
        selectedBooks.contains(where: { $0.id == book.id })
    }

    private func toggleSelection(for book: BookPickerBook) {
        if let index = selectedBooks.firstIndex(where: { $0.id == book.id }) {
            selectedBooks.remove(at: index)
        } else {
            selectedBooks.append(book)
        }
    }

    private func addSelectedBookIfNeeded(_ book: BookPickerBook) {
        guard !selectedBooks.contains(where: { $0.id == book.id }) else { return }
        selectedBooks.append(book)
    }

    private static func deduplicatedBooks(_ books: [BookPickerBook]) -> [BookPickerBook] {
        var seen = Set<Int64>()
        return books.filter { seen.insert($0.id).inserted }
    }
}
