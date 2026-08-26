/**
 * [INPUT]: 依赖 BookPickerRepositoryProtocol 提供本地书籍查询与结果解析，依赖 BookSearchRepositoryProtocol 提供在线搜索、远端结果补齐与创建回填
 * [OUTPUT]: 对外提供 BookPickerViewModel、稳定本地结果快照、BookPickerSelectedItem、BookPickerVisibleScope、BookPickerStatus 与 BookPickerRemoteTapOutcome，驱动通用书籍选择流状态机
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

/// 在线结果点击后的统一副作用，兼容“进入编辑页”与“直接完成选择”两种链路。
enum BookPickerRemoteTapOutcome: Hashable {
    case presentEditor(BookEditorSeed)
    case complete(BookPickerResult)
}

private enum BookPickerSelectionKey: Hashable {
    case local(Int64)
    case remote(String)
}

/// 多选草稿中的稳定展示项，保留本地/远端来源身份且不触发远端详情解析。
enum BookPickerSelectedItem: Identifiable, Hashable, Sendable {
    case local(BookPickerBook)
    case remote(BookSearchResult)

    var id: String {
        switch self {
        case .local(let book):
            return "local-\(book.id)"
        case .remote(let result):
            return "remote-\(result.id)"
        }
    }

    var title: String {
        switch self {
        case .local(let book):
            return book.title
        case .remote(let result):
            return result.title
        }
    }

    var author: String {
        switch self {
        case .local(let book):
            return book.author
        case .remote(let result):
            return result.author
        }
    }

    var detail: String {
        switch self {
        case .local(let book):
            return book.press
        case .remote(let result):
            return result.source.title
        }
    }

    var coverURL: String {
        switch self {
        case .local(let book):
            return book.coverURL
        case .remote(let result):
            return result.coverURL
        }
    }
}

/// 选书本地搜索输入防抖策略，用于平衡输入跟手感和本地数据库读取频率。
private enum BookPickerSearchDebouncePolicy {
    static let delayNanoseconds: UInt64 = 200_000_000
}

/// 书籍选择状态源，统一承接本地查询、在线搜索、多选与创建回填。
@MainActor
@Observable
final class BookPickerViewModel {
    var query: String
    var visibleScope: BookPickerVisibleScope
    var selectedOnlineSource: BookSearchSource
    var localBooks: [BookPickerBook]
    private(set) var localSnapshotQuery: String
    var remoteResults: [BookSearchResult]
    var selectedBooks: [BookPickerBook]
    var selectedRemoteResults: [BookSearchResult]
    var isLoadingLocal = false
    var isSearchingOnline = false
    var isResolvingRemoteSelections = false
    var onlineErrorMessage: String?
    var hasSubmittedOnlineSearch = false

    let configuration: BookPickerConfiguration

    private let bookRepository: any BookPickerRepositoryProtocol
    private let searchRepository: any BookSearchRepositoryProtocol
    private var hasLoaded = false
    private var hasCompletedLocalSnapshot = false
    private var localSearchTask: Task<Void, Never>?
    private var onlineSearchTask: Task<Void, Never>?
    private var localSearchSequence = 0
    private var onlineSearchSequence = 0
    private var selectionOrder: [BookPickerSelectionKey]
    private var resolvedRemoteSelections: [String: BookPickerRemoteSelection]

    init(
        configuration: BookPickerConfiguration,
        bookRepository: any BookPickerRepositoryProtocol,
        searchRepository: any BookSearchRepositoryProtocol
    ) {
        self.configuration = configuration
        self.bookRepository = bookRepository
        self.searchRepository = searchRepository
        self.query = configuration.defaultQuery
        self.localBooks = []
        self.localSnapshotQuery = ""
        self.remoteResults = []
        let deduplicatedBooks = Self.deduplicatedBooks(configuration.preselectedBooks)
            .filter { !configuration.unavailableLocalBookIDs.contains($0.id) }
        self.selectedBooks = deduplicatedBooks
        self.selectedRemoteResults = []
        self.selectionOrder = deduplicatedBooks.map { .local($0.id) }
        self.resolvedRemoteSelections = [:]
        self.visibleScope = configuration.scope == .online ? .online : .local
        if let preferred = configuration.preferredOnlineSource,
           configuration.onlineSources.contains(preferred) {
            self.selectedOnlineSource = preferred
        } else {
            self.selectedOnlineSource = configuration.onlineSources.first ?? .wenqu
        }
    }

    /// 取消仍在等待或执行中的搜索任务，避免选书流释放后继续回写 MainActor 状态。
    isolated deinit {
        localSearchTask?.cancel()
        onlineSearchTask?.cancel()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isMultipleSelectionEnabled: Bool {
        configuration.selectionMode == .multiple
    }

    var supportsCreationFlow: Bool {
        configuration.allowsCreationFlow
    }

    var supportsOnline: Bool {
        configuration.scope != .local && !configuration.onlineSources.isEmpty
    }

    var supportsScopeSwitch: Bool {
        configuration.scope == .both && supportsOnline
    }

    var supportsDirectRemoteSelection: Bool {
        configuration.onlineSelectionPolicy == .returnRemoteSelection
    }

    var allowsEmptyMultipleConfirmation: Bool {
        configuration.multipleConfirmationPolicy == .allowsEmptyResult
    }

    var selectedCount: Int {
        selectedBooks.count + selectedRemoteResults.count
    }

    /// 按用户选择顺序提供管理 Sheet 的只读草稿快照，不解析在线详情。
    var selectedItemsInSelectionOrder: [BookPickerSelectedItem] {
        let localBooksByID = Dictionary(uniqueKeysWithValues: selectedBooks.map { ($0.id, $0) })
        let remoteResultsByID = Dictionary(uniqueKeysWithValues: selectedRemoteResults.map { ($0.id, $0) })

        return selectionOrder.compactMap { key in
            switch key {
            case .local(let bookID):
                return localBooksByID[bookID].map(BookPickerSelectedItem.local)
            case .remote(let resultID):
                return remoteResultsByID[resultID].map(BookPickerSelectedItem.remote)
            }
        }
    }

    var status: BookPickerStatus {
        switch visibleScope {
        case .local:
            if !hasCompletedLocalSnapshot { return .localLoading }
            if !localBooks.isEmpty { return .localResults }
            return localSnapshotQuery.isEmpty ? .localEmptyLibrary : .localNoResults
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
            scheduleLocalBooksRefreshAfterInputSettles()
        case .online:
            invalidateLocalSearch()
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
            invalidateLocalSearch()
            guard !trimmedQuery.isEmpty else {
                remoteResults = []
                onlineErrorMessage = nil
                hasSubmittedOnlineSearch = false
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
        let requestID = advanceLocalSearchSequence()
        let keyword = trimmedQuery
        await performLocalBooksRefresh(keyword: keyword, requestID: requestID)
    }

    /// 执行已捕获关键词的本地查询；仅允许仍为最新序号的请求一次性替换可信快照。
    private func performLocalBooksRefresh(keyword: String, requestID: Int) async {
        guard requestID == localSearchSequence else { return }
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
            localSnapshotQuery = keyword
            hasCompletedLocalSnapshot = true
        } catch {
            guard requestID == localSearchSequence else { return }
            localBooks = []
            localSnapshotQuery = keyword
            hasCompletedLocalSnapshot = true
        }
    }

    /// 输入变化时立即失效旧请求，再延迟 200ms 查询捕获的关键词，避免旧结果越过防抖窗口回写。
    private func scheduleLocalBooksRefreshAfterInputSettles() {
        localSearchTask?.cancel()
        let requestID = advanceLocalSearchSequence()
        let keyword = trimmedQuery
        localSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: BookPickerSearchDebouncePolicy.delayNanoseconds)
                try Task.checkCancellation()
                await self?.performLocalBooksRefresh(keyword: keyword, requestID: requestID)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// 推进本地搜索序号，使此前等待中或执行中的请求失去状态回写资格。
    private func advanceLocalSearchSequence() -> Int {
        localSearchSequence += 1
        isLoadingLocal = false
        return localSearchSequence
    }

    /// 取消本地搜索任务并失效可能不响应取消信号的仓储读取，阻止其稍后回写。
    private func invalidateLocalSearch() {
        localSearchTask?.cancel()
        localSearchTask = nil
        _ = advanceLocalSearchSequence()
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
        guard !isResolvingRemoteSelections, !isBookUnavailable(book) else { return nil }
        if isMultipleSelectionEnabled {
            toggleLocalSelection(for: book)
            return nil
        }
        return .single(.local(book))
    }

    /// 在线结果点击后根据配置决定是进入创建链路，还是直接作为远端结果回流。
    func handleRemoteResultTap(_ result: BookSearchResult) async -> BookPickerRemoteTapOutcome? {
        guard !isResolvingRemoteSelections else { return nil }
        if supportsDirectRemoteSelection {
            if isMultipleSelectionEnabled {
                toggleRemoteSelection(for: result)
                return nil
            }

            guard let remoteSelection = await resolveRemoteSelection(for: result) else {
                return nil
            }
            return .complete(.single(.remote(remoteSelection)))
        }

        guard let seed = await prepareSeed(for: result) else {
            return nil
        }
        return .presentEditor(seed)
    }

    /// 将远端结果补齐为录入种子，供“先创建再回填”的链路复用。
    func prepareSeed(for result: BookSearchResult) async -> BookEditorSeed? {
        await resolveRemoteSelection(for: result)?.seed
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
            return .single(.local(book))
        } catch {
            return nil
        }
    }

    /// 多选模式确认当前已选集合。
    func confirmMultipleSelection() async -> BookPickerResult? {
        guard isMultipleSelectionEnabled else { return nil }
        guard selectedCount > 0 || allowsEmptyMultipleConfirmation else { return nil }
        guard let selections = await resolveSelectionsInOrder() else { return nil }
        return .multiple(selections)
    }

    /// 本地无结果时允许直接切换到在线检索，减少任务中断。
    func switchToOnlineIfSupported() {
        guard supportsOnline else { return }
        switchVisibleScope(.online)
    }

    func isBookSelected(_ book: BookPickerBook) -> Bool {
        selectedBooks.contains(where: { $0.id == book.id })
    }

    func isBookUnavailable(_ book: BookPickerBook) -> Bool {
        configuration.unavailableLocalBookIDs.contains(book.id)
    }

    var unavailableLocalBookMessage: String? {
        configuration.unavailableLocalBookMessage
    }

    func isRemoteResultSelected(_ result: BookSearchResult) -> Bool {
        selectedRemoteResults.contains(where: { $0.id == result.id })
    }

    /// 从共享多选草稿移除本地或远端项；远端项只删除身份引用，不执行详情补齐。
    func removeSelection(_ item: BookPickerSelectedItem) {
        guard !isResolvingRemoteSelections else { return }
        switch item {
        case .local(let book):
            selectedBooks.removeAll { $0.id == book.id }
            selectionOrder.removeAll { $0 == .local(book.id) }
        case .remote(let result):
            selectedRemoteResults.removeAll { $0.id == result.id }
            selectionOrder.removeAll { $0 == .remote(result.id) }
        }
    }

    private func toggleLocalSelection(for book: BookPickerBook) {
        if let index = selectedBooks.firstIndex(where: { $0.id == book.id }) {
            selectedBooks.remove(at: index)
            selectionOrder.removeAll { $0 == .local(book.id) }
        } else {
            selectedBooks.append(book)
            selectionOrder.append(.local(book.id))
        }
    }

    private func toggleRemoteSelection(for result: BookSearchResult) {
        if let index = selectedRemoteResults.firstIndex(where: { $0.id == result.id }) {
            selectedRemoteResults.remove(at: index)
            selectionOrder.removeAll { $0 == .remote(result.id) }
        } else {
            selectedRemoteResults.append(result)
            selectionOrder.append(.remote(result.id))
        }
    }

    private func addSelectedBookIfNeeded(_ book: BookPickerBook) {
        if let index = selectedBooks.firstIndex(where: { $0.id == book.id }) {
            selectedBooks[index] = book
            return
        }
        selectedBooks.append(book)
        selectionOrder.append(.local(book.id))
    }

    /// 按用户选择顺序输出本地/在线混合集合；若任一远端结果补齐失败，则整体确认失败以避免半成品回流。
    private func resolveSelectionsInOrder() async -> [BookPickerSelection]? {
        let localBooksByID = Dictionary(uniqueKeysWithValues: selectedBooks.map { ($0.id, $0) })
        let remoteResultsByID = Dictionary(uniqueKeysWithValues: selectedRemoteResults.map { ($0.id, $0) })
        let requiresRemoteResolution = !remoteResultsByID.isEmpty

        if requiresRemoteResolution {
            isResolvingRemoteSelections = true
        }
        defer {
            if requiresRemoteResolution {
                isResolvingRemoteSelections = false
            }
        }

        var resolvedSelections: [BookPickerSelection] = []
        for key in selectionOrder {
            switch key {
            case .local(let bookID):
                guard let book = localBooksByID[bookID] else { continue }
                resolvedSelections.append(.local(book))
            case .remote(let resultID):
                guard let result = remoteResultsByID[resultID] else { continue }
                guard let remoteSelection = await resolveRemoteSelection(for: result) else {
                    return nil
                }
                resolvedSelections.append(.remote(remoteSelection))
            }
        }

        return resolvedSelections
    }

    /// 将在线结果补齐为完整的远端选择载荷，并缓存成功结果避免重复抓取详情。
    private func resolveRemoteSelection(for result: BookSearchResult) async -> BookPickerRemoteSelection? {
        if let cached = resolvedRemoteSelections[result.id] {
            return cached
        }

        do {
            let seed = try await searchRepository.prepareSeed(for: result)
            let remoteSelection = BookPickerRemoteSelection(result: result, seed: seed)
            resolvedRemoteSelections[result.id] = remoteSelection
            return remoteSelection
        } catch {
            onlineErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private static func deduplicatedBooks(_ books: [BookPickerBook]) -> [BookPickerBook] {
        var seen = Set<Int64>()
        return books.filter { seen.insert($0.id).inserted }
    }
}
