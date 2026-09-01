/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 与 AIPersonalErrorCopy，按全部书摘范围观察搜索与稳定分页结果
 * [OUTPUT]: 对外提供 AIPromptExcerptPickerViewModel，管理书摘选择 Sheet 的防抖搜索、分页、空态与保留内容失败
 * [POS]: ViewModels/Personal 的提示词试运行书摘选择状态源，被 AIPromptExcerptPickerSheet 创建并持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书摘选择状态源；每次搜索或扩页都会取消旧观察，并用 revision 阻止迟到快照覆盖当前查询。
@MainActor
@Observable
final class AIPromptExcerptPickerViewModel {
    private enum Constants {
        static let pageSize = 30
        static let searchDelay = Duration.milliseconds(250)
    }

    private(set) var query = ""
    private(set) var items: [NoteExcerptListItem] = []
    private(set) var totalCount = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var retainedErrorMessage: String?

    private let repository: any NoteRepositoryProtocol
    private var requestedLimit = Constants.pageSize
    private var observationRevision = 0
    private var hasStarted = false
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// 注入笔记仓储；初始化不读取数据库，等待 Sheet 出现后显式启动。
    init(repository: any NoteRepositoryProtocol) {
        self.repository = repository
    }

    isolated deinit {
        observationTask?.cancel()
        searchTask?.cancel()
    }

    var hasMore: Bool {
        items.count < totalCount
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 首次呈现时建立全量书摘观察；重复调用保持当前搜索与分页现场。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startObservation(clearsContent: true)
    }

    /// 搜索输入先本地回写，再以短防抖重启数据库观察，避免每个输入法组合字符都创建查询。
    func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        searchTask?.cancel()
        observationTask?.cancel()
        items = []
        totalCount = 0
        isLoading = true
        errorMessage = nil
        retainedErrorMessage = nil
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Constants.searchDelay)
                guard let self, !Task.isCancelled else { return }
                self.requestedLimit = Constants.pageSize
                self.startObservation(clearsContent: true)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// 最后一行出现时扩大首段窗口；Repository 继续以单一稳定请求观察当前全部已加载条目。
    func loadNextPageIfNeeded(currentItemID: Int64) {
        guard currentItemID == items.last?.id,
              hasMore,
              !isLoading else {
            return
        }
        requestedLimit += Constants.pageSize
        startObservation(clearsContent: false)
    }

    /// 失败后使用当前查询和分页窗口重试；有可信内容时继续保留列表。
    func retry() {
        startObservation(clearsContent: items.isEmpty)
    }

    /// Sheet 离场时释放搜索与数据库观察，防止隐藏页面继续回写。
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        observationTask?.cancel()
        observationTask = nil
        isLoading = false
    }

    /// 为当前查询建立唯一观察流；扩页失败保留旧内容，首次或新搜索失败进入完整失败态。
    private func startObservation(clearsContent: Bool) {
        observationTask?.cancel()
        observationRevision &+= 1
        let revision = observationRevision
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = requestedLimit

        if clearsContent {
            items = []
            totalCount = 0
        }
        isLoading = true
        errorMessage = nil
        retainedErrorMessage = nil

        let stream = repository.observeNoteExcerptList(
            request: NoteExcerptPageRequest(
                scope: .all,
                query: normalizedQuery,
                searchScope: .contentIdeaAndBookMetadata,
                sort: .createdDescending,
                offset: 0,
                limit: limit
            )
        )
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    guard let self, self.observationRevision == revision else { return }
                    self.items = snapshot.items
                    self.totalCount = snapshot.totalCount
                    self.isLoading = false
                    self.errorMessage = nil
                    self.retainedErrorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.observationRevision == revision else {
                    return
                }
                self.isLoading = false
                if self.items.isEmpty {
                    self.errorMessage = AIPersonalErrorCopy.message(
                        for: error,
                        context: .readExcerpts
                    )
                } else {
                    self.retainedErrorMessage = AIPersonalErrorCopy.message(
                        for: error,
                        context: .readExcerpts
                    )
                }
            }
        }
    }
}
