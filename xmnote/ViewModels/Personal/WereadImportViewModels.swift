/**
 * [INPUT]: 依赖 WereadImportRepositoryProtocol 与微信读书导入领域模型
 * [OUTPUT]: 对外提供授权、分批与预览页面的 @Observable ViewModel 和导航载荷
 * [POS]: ViewModels/Personal 的微信读书导入状态编排层，不直接访问网络、数据库或偏好存储
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

@MainActor
@Observable
final class WereadImportAuthViewModel {
    enum Destination: Identifiable, Hashable {
        case batches(WereadBatchRoute)
        case preview(WereadPreviewRoute)
        var id: UUID { switch self { case .batches(let value): value.id; case .preview(let value): value.id } }
    }

    enum WorkKind: Equatable {
        case candidateFetch
        case backfill
    }

    enum ErrorContext: Equatable {
        case authorization
        case candidateFetch
        case backfill
    }

    var phase: WereadQRCodePhase = .loading
    var preferences: WereadImportPreferences = .default
    var authorization: WereadAuthorization?
    var qrCodeData: Data?
    var progressText = ""
    var isWorking = false
    var workKind: WorkKind?
    var destination: Destination?
    var errorMessage: String?
    var errorContext: ErrorContext?
    var webReloadToken = UUID()
    var backfillPrompt: WereadBackfillPrompt?
    var backfillProgressText = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskGeneration = 0
    private let repository: any WereadImportRepositoryProtocol

    init(repository: any WereadImportRepositoryProtocol) { self.repository = repository }

    func load() async {
        preferences = repository.fetchPreferences()
        if let restored = await repository.restoreAuthorization() {
            authorization = restored; phase = .authorized
            backfillPrompt = try? await repository.fetchBackfillPrompt()
            if backfillPrompt?.pendingCount == 0 { backfillPrompt = nil }
        } else { phase = .loading }
    }

    func updatePreferences(_ update: (inout WereadImportPreferences) -> Void) {
        update(&preferences); repository.savePreferences(preferences)
    }

    func receiveQRCode(_ data: Data?) { qrCodeData = data; phase = data == nil ? .loading : .available }
    func markExpired() { phase = .expired; qrCodeData = nil }
    func markFailed(_ message: String) { phase = .failed(message: message); qrCodeData = nil }
    func beginRefresh() {
        task?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        task = Task {
            await repository.clearAuthorization()
            guard generation == taskGeneration, !Task.isCancelled else { return }
            authorization = nil
            phase = .loading
            qrCodeData = nil
            errorMessage = nil
            errorContext = nil
            workKind = nil
            webReloadToken = UUID()
        }
    }

    func receiveCookie(_ cookie: String) {
        guard authorization == nil, !isWorking else { return }
        task?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        task = Task {
            do {
                let value = try await repository.validateAuthorization(cookieHeader: cookie)
                guard generation == taskGeneration, !Task.isCancelled else { return }
                authorization = value; phase = .authorized
            } catch is CancellationError { }
            catch {
                guard generation == taskGeneration else { return }
                errorMessage = error.localizedDescription
                errorContext = .authorization
                if case WereadImportError.authorizationExpired = error { phase = .expired }
            }
        }
    }

    /// 获取候选书籍并生成后续路由；通过 generation 丢弃被刷新或取消后的过期回调。
    private func fetchCandidates(generation: Int) async {
        guard let authorization, !isWorking else { return }
        isWorking = true
        workKind = .candidateFetch
        errorMessage = nil
        errorContext = nil
        progressText = "正在获取候选书籍…"
        do {
            let ids = try await repository.fetchImportBookIDs(authorization: authorization, preferences: preferences)
            guard generation == taskGeneration, !Task.isCancelled else { return }
            if ids.count > 100 {
                destination = .batches(.init(authorization: authorization, bookIDs: ids, importsReadingTime: preferences.importsReadingTime, repository: repository))
            } else {
                var books = try await repository.fetchImportBooks(
                    authorization: authorization,
                    bookIDs: ids,
                    importsReadingTime: preferences.importsReadingTime,
                    progress: { [weak self] current, total in
                        guard let self, generation == self.taskGeneration else { return }
                        self.progressText = "正在获取候选书籍（\(current)/\(total)）"
                    },
                    warning: { [weak self] message in
                        guard let self, generation == self.taskGeneration else { return }
                        self.errorMessage = message
                        self.errorContext = .candidateFetch
                    }
                )
                books = try await repository.matchLocalBooks(books)
                guard generation == taskGeneration, !Task.isCancelled else { return }
                destination = .preview(.init(books: books, returnsToBatch: false, repository: repository))
            }
        } catch is CancellationError { }
        catch {
            guard generation == taskGeneration else { return }
            if case WereadImportError.authorizationExpired = error {
                await expireAuthorization()
                errorContext = .authorization
            } else {
                errorContext = .candidateFetch
            }
            errorMessage = error.localizedDescription
        }
        guard generation == taskGeneration else { return }
        isWorking = false
        workKind = nil
        progressText = ""
    }

    /// 启动用户明确确认后的候选获取任务；新的请求会取消旧任务并以 generation 防止竞态回写。
    func beginCandidateFetch() {
        task?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        task = Task { await fetchCandidates(generation: generation) }
    }

    /// 清除已展示的阶段错误，避免旧错误影响下一次授权或获取。
    func clearError() {
        errorMessage = nil
        errorContext = nil
    }

    func postponeBackfill() { backfillPrompt = nil }

    func beginBackfill() {
        guard let authorization else { return }
        backfillPrompt = nil
        isWorking = true
        workKind = .backfill
        errorMessage = nil
        errorContext = nil
        task?.cancel()
        task = Task {
            do {
                let result = try await repository.performBackfill(authorization: authorization) { [weak self] value in
                    self?.backfillProgressText = "正在关联历史数据（\(value.current)/\(value.total)）"
                    self?.progressText = self?.backfillProgressText ?? ""
                }
                backfillProgressText = ""; progressText = ""; isWorking = false; workKind = nil
                if result.partialFailureCount > 0 {
                    errorMessage = "部分历史数据关联失败，下次授权后可继续重试"
                    errorContext = .backfill
                }
            } catch is CancellationError {
                backfillProgressText = ""; progressText = ""; isWorking = false; workKind = nil
            } catch {
                backfillProgressText = ""; progressText = ""; isWorking = false; workKind = nil
                errorMessage = error.localizedDescription
                errorContext = .backfill
            }
        }
    }

    private func expireAuthorization() async {
        await repository.clearAuthorization()
        authorization = nil
        phase = .loading
        qrCodeData = nil
        webReloadToken = UUID()
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskGeneration += 1
        isWorking = false
        workKind = nil
        progressText = ""
        backfillProgressText = ""
    }
}

@MainActor
final class WereadBatchRoute: Identifiable, Hashable {
    let id = UUID(); let authorization: WereadAuthorization; let bookIDs: [String]; let importsReadingTime: Bool; let repository: any WereadImportRepositoryProtocol
    init(authorization: WereadAuthorization, bookIDs: [String], importsReadingTime: Bool, repository: any WereadImportRepositoryProtocol) { self.authorization = authorization; self.bookIDs = bookIDs; self.importsReadingTime = importsReadingTime; self.repository = repository }
    static func == (lhs: WereadBatchRoute, rhs: WereadBatchRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class WereadPreviewRoute: Identifiable, Hashable {
    let id = UUID(); let books: [WereadImportBook]; let returnsToBatch: Bool; let repository: any WereadImportRepositoryProtocol
    init(books: [WereadImportBook], returnsToBatch: Bool, repository: any WereadImportRepositoryProtocol) { self.books = books; self.returnsToBatch = returnsToBatch; self.repository = repository }
    static func == (lhs: WereadPreviewRoute, rhs: WereadPreviewRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
@Observable
final class WereadBatchViewModel {
    var batches: [WereadImportBatch]
    var preview: WereadPreviewRoute?
    var errorMessage: String?
    var isLoading: Bool { batches.contains { if case .loading = $0.status { true } else { false } } }
    var completedPercent: Int {
        let total = batches.reduce(0) { $0 + $1.bookIDs.count }
        let completed = batches.reduce(0) { value, batch in
            value + (batch.status == .success ? batch.bookIDs.count : 0)
        }
        return total == 0 ? 0 : completed * 100 / total
    }
    private let route: WereadBatchRoute
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskGeneration = 0

    init(route: WereadBatchRoute) {
        self.route = route
        batches = route.bookIDs.chunkedForWeread(size: 100).enumerated().map { index, ids in
            .init(number: index + 1, start: index * 100 + 1, end: index * 100 + ids.count, bookIDs: ids)
        }
    }

    private func open(_ id: UUID, generation: Int) async {
        guard !isLoading, let index = batches.firstIndex(where: { $0.id == id }) else { return }
        if !batches[index].books.isEmpty { preview = .init(books: batches[index].books, returnsToBatch: true, repository: route.repository); return }
        batches[index].status = .loading(percent: 0); errorMessage = nil
        do {
            var books = try await route.repository.fetchImportBooks(
                authorization: route.authorization, bookIDs: batches[index].bookIDs, importsReadingTime: route.importsReadingTime,
                progress: { [weak self] current, total in
                    guard let self, generation == self.taskGeneration else { return }
                    self.batches[index].status = .loading(percent: total == 0 ? 0 : current * 100 / total)
                }
            )
            books = try await route.repository.matchLocalBooks(books)
            guard generation == taskGeneration, !Task.isCancelled else { return }
            batches[index].books = books; batches[index].status = .success
            preview = .init(books: books, returnsToBatch: true, repository: route.repository)
        } catch is CancellationError {
            guard generation == taskGeneration else { return }
            batches[index].status = .notStarted
        } catch {
            guard generation == taskGeneration else { return }
            batches[index].status = .failed; errorMessage = error.localizedDescription
        }
    }

    func beginOpen(_ id: UUID) {
        // 一个批次加载期间忽略其他批次点击；失败/成功收口后才允许重试或打开下一批。
        guard task == nil else { return }
        taskGeneration += 1
        let generation = taskGeneration
        task = Task { [weak self] in
            guard let self else { return }
            await self.open(id, generation: generation)
            if generation == self.taskGeneration {
                self.task = nil
            }
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
        taskGeneration += 1
        for index in batches.indices {
            if case .loading = batches[index].status {
                batches[index].status = .notStarted
            }
        }
    }
}

@MainActor
@Observable
final class WereadPreviewViewModel {
    var books: [WereadImportBook]
    var query = ""
    var isCommitting = false
    var progressText = ""
    var errorMessage: String?
    var didCommit = false
    private let repository: any WereadImportRepositoryProtocol
    @ObservationIgnored private var task: Task<Void, Never>?

    init(route: WereadPreviewRoute) {
        repository = route.repository
        var initialBooks = route.books
        if initialBooks.count == 1 {
            initialBooks[0].isSelected = true
            for index in initialBooks[0].notes.indices { initialBooks[0].notes[index].isSelected = true }
        }
        books = initialBooks
    }

    var visibleBooks: [WereadImportBook] { query.isEmpty ? books : books.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) } }
    var selectedCount: Int { books.filter(\.isSelected).count }
    func index(for id: UUID) -> Int? { books.firstIndex { $0.id == id } }
    func toggleBook(_ id: UUID) { guard let i = index(for: id) else { return }; books[i].isSelected.toggle(); books[i].notes.indices.forEach { books[i].notes[$0].isSelected = books[i].isSelected } }
    func selectAll(_ selected: Bool) { for i in books.indices { books[i].isSelected = selected; books[i].notes.indices.forEach { books[i].notes[$0].isSelected = selected } } }
    func updateBook(_ book: WereadImportBook) { guard let i = index(for: book.id) else { return }; books[i] = book }
    func map(_ id: UUID, to book: BookPickerBook?) { guard let i = index(for: id) else { return }; books[i].targetBookID = book?.id; books[i].targetBookTitle = book?.title }

    func commit() async {
        guard selectedCount > 0 else { errorMessage = "请先选择书籍"; return }
        isCommitting = true; errorMessage = nil
        do {
            try await repository.commitImport(books: books) { [weak self] current, total in self?.progressText = "正在导入（\(current)/\(total)）" }
            didCommit = true
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
        isCommitting = false; progressText = ""
    }
    func beginCommit() { task?.cancel(); task = Task { await commit() } }
    func cancel() { task?.cancel(); task = nil }
}

private extension Array {
    func chunkedForWeread(size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}
