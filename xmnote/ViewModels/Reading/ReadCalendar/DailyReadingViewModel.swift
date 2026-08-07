/**
 * [INPUT]: 依赖 ReadCalendar/Content/Note/ExternalApp Repository 获取、筛选与管理指定自然日的完整阅读轨迹
 * [OUTPUT]: 对外提供 DailyReadingViewModel，以独立状态承接主读取阶段、自动刷新告警、筛选排序与记录写入
 * [POS]: Reading/ReadCalendar 当日阅读轨迹状态中枢，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import os

/// 当日阅读轨迹页的读取阶段。
enum DailyReadingLoadPhase: Hashable {
    case idle
    case loading
    case loaded
    case failed
}

/// 当日阅读轨迹状态中枢；所有筛选和写入均通过 Repository 重查，以数据库结果收敛界面状态。
@MainActor
@Observable
final class DailyReadingViewModel {
    let date: Date
    var selectedBookID: Int64?
    var filter: DailyReadingTimelineFilter = .all
    var sortOrder: DailyReadingSortOrder = .ascending
    private(set) var trajectory: DailyReadingTrajectory
    private(set) var loadPhase: DailyReadingLoadPhase = .idle
    private(set) var errorMessage: String?
    private(set) var observationErrorMessage: String?
    private(set) var isWriting = false
    private(set) var noteActionItems: [Int64: NoteReviewCardItem] = [:]
    private(set) var configuredExternalDestinations: Set<ExternalAppDestination> = []

    private var loadTask: Task<Void, Never>?
    private var requestToken: UInt64 = 0

    /// 以目标自然日初始化轨迹页，页面进入后再从 Repository 读取完整记录。
    init(date: Date) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        self.date = normalizedDate
        self.trajectory = .empty(for: normalizedDate)
    }

    var title: String {
        let isCurrentYear = Calendar.current.component(.year, from: date)
            == Calendar.current.component(.year, from: Date())
        return isCurrentYear
            ? Self.monthDayFormatter.string(from: date)
            : Self.fullDateFormatter.string(from: date)
    }

    var books: [DailyReadingBookSummary] {
        trajectory.books
    }

    var records: [DailyReadingRecord] {
        trajectory.records
    }

    var hasAnyData: Bool {
        !books.isEmpty || !records.isEmpty
    }

    var hasActiveFilter: Bool {
        selectedBookID != nil || filter != .all
    }

    var canCheckIn: Bool {
        date <= Calendar.current.startOfDay(for: Date())
    }

    var checkInActionTitle: String {
        "打卡"
    }

    var selectedBook: ReadCalendarDayBook? {
        guard let selectedBookID else { return nil }
        return books.first { $0.id == selectedBookID }?.book
    }

    var checkInInitialBook: ReadCalendarDayBook? {
        selectedBook ?? books.first?.book
    }

    var noteContextSignature: String {
        records.compactMap { record in
            if case .note(let note) = record.event.kind { return String(note.noteId) }
            return nil
        }
        .sorted()
        .joined(separator: ",")
    }

    /// 返回记录所属书籍的当日摘要，供编辑 Sheet 使用真实书籍信息。
    func bookSummary(for bookID: Int64) -> DailyReadingBookSummary? {
        books.first { $0.id == bookID }
    }

    /// 首次进入时读取全部书籍、全部类型、从早到晚的当日轨迹。
    func loadIfNeeded(using repository: any ReadCalendarRepositoryProtocol) async {
        guard loadPhase == .idle else { return }
        await reload(using: repository)
    }

    /// 按当前书籍、类型和排序读取轨迹；取消和 token 双重保护阻止旧请求覆盖新选择。
    func reload(using repository: any ReadCalendarRepositoryProtocol) async {
        loadTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        let requestedBookID = selectedBookID
        let requestedFilter = filter
        let requestedSort = sortOrder
        loadPhase = .loading
        errorMessage = nil

        let task = Task {
            do {
                var result = try await repository.fetchDailyTrajectory(
                    for: date,
                    selectedBookID: requestedBookID,
                    filter: requestedFilter,
                    sortOrder: requestedSort
                )
                guard !Task.isCancelled, token == requestToken else { return }

                if let requestedBookID,
                   !result.books.contains(where: { $0.id == requestedBookID }) {
                    selectedBookID = nil
                    result = try await repository.fetchDailyTrajectory(
                        for: date,
                        selectedBookID: nil,
                        filter: requestedFilter,
                        sortOrder: requestedSort
                    )
                }
                guard !Task.isCancelled, token == requestToken else { return }
                trajectory = result
                errorMessage = nil
                loadPhase = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, token == requestToken else { return }
                Self.logger.error("读取当日阅读轨迹失败：\(error.localizedDescription, privacy: .public)")
                errorMessage = "读取阅读轨迹失败，请重试"
                loadPhase = .failed
            }
        }
        loadTask = task
        await task.value
    }

    /// 页面存续期间监听内容、计时、打卡、状态、标签与书籍变化，并重新读取当前轨迹。
    func observeChanges(using repository: any ReadCalendarRepositoryProtocol) async {
        observationErrorMessage = nil
        do {
            for try await _ in repository.observeDailyReadingChanges() {
                guard !Task.isCancelled else { return }
                await reload(using: repository)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("监听当日阅读轨迹变化失败：\(error.localizedDescription, privacy: .public)")
            observationErrorMessage = "自动刷新暂时不可用"
        }
    }

    /// 清除监听告警，供页面仅重建变化监听而不清空已有轨迹。
    func prepareObservationRetry() {
        observationErrorMessage = nil
    }

    /// 切换书籍后保留类型与排序，并重新读取该书当天的记录。
    func selectBook(
        _ bookID: Int64?,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        guard selectedBookID != bookID else { return }
        selectedBookID = bookID
        await reload(using: repository)
    }

    /// 切换记录类型后保留书籍与排序，并重新读取轨迹。
    func selectFilter(
        _ newFilter: DailyReadingTimelineFilter,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        guard filter != newFilter else { return }
        filter = newFilter
        await reload(using: repository)
    }

    /// 切换排序后保留书籍与记录类型，并重新读取轨迹。
    func selectSort(
        _ newSortOrder: DailyReadingSortOrder,
        using repository: any ReadCalendarRepositoryProtocol
    ) async {
        guard sortOrder != newSortOrder else { return }
        sortOrder = newSortOrder
        await reload(using: repository)
    }

    /// 清除书籍和类型筛选，保留用户当前选择的排序方向。
    func clearFilters(using repository: any ReadCalendarRepositoryProtocol) async {
        guard hasActiveFilter else { return }
        selectedBookID = nil
        filter = .all
        await reload(using: repository)
    }

    /// 为当前可见书摘批量读取标签、微信读书与分享上下文，并同步外部应用可用目标。
    func reloadActionContexts(
        noteRepository: any NoteRepositoryProtocol,
        externalRepository: any ExternalAppIntegrationRepositoryProtocol
    ) async {
        configuredExternalDestinations = Set(externalRepository.configuredDestinations())
        let noteIDs = records.compactMap { record -> Int64? in
            if case .note(let note) = record.event.kind { return note.noteId }
            return nil
        }
        guard !noteIDs.isEmpty else {
            noteActionItems = [:]
            return
        }
        let items = (try? await noteRepository.fetchNoteReviewItems(noteIDs: noteIDs)) ?? []
        guard !Task.isCancelled else { return }
        noteActionItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    /// 新建书摘标签，校验和落库规则复用 NoteRepository。
    func createTag(
        named name: String,
        using repository: any NoteRepositoryProtocol
    ) async -> NoteEditorTagOption? {
        do {
            return try await repository.createNoteTag(named: name)
        } catch {
            errorMessage = "创建标签失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 替换单条书摘标签，并重新读取该书摘的操作上下文。
    func replaceTags(
        _ tags: [NoteEditorTagOption],
        for item: NoteReviewCardItem,
        using repository: any NoteRepositoryProtocol
    ) async -> Bool {
        do {
            _ = try await repository.replaceNoteReviewTags(noteID: item.id, tags: tags)
            noteActionItems[item.id] = try await repository.fetchNoteReviewItem(noteID: item.id)
            return true
        } catch {
            errorMessage = "保存标签失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 将书摘发送到已配置目标；写入状态阻止同一页面重复发送。
    func sendNote(
        _ item: NoteReviewCardItem,
        to destination: ExternalAppDestination,
        using repository: any ExternalAppIntegrationRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        _ = try await repository.send(noteID: item.id, to: destination)
    }

    /// 新增或更新当天打卡，成功后重新读取完整轨迹与书籍筛选项。
    func saveCheckIn(
        recordID: Int64?,
        bookID: Int64,
        amount: Int,
        using repository: any ReadCalendarRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await repository.saveCheckIn(
            ReadCalendarCheckInDraft(
                recordID: recordID,
                bookID: bookID,
                amount: amount,
                date: date
            )
        )
        await reload(using: repository)
    }

    /// 更新阅读计时，Repository 负责时间校验与可选读完事务，完成后重新读取轨迹。
    func updateTiming(
        _ draft: ReadCalendarTimingDraft,
        using repository: any ReadCalendarRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await repository.updateTiming(draft)
        await reload(using: repository)
    }

    /// 按事件真实类型执行物理删除；读完里程碑保持只读，不进入删除路径。
    func delete(
        _ record: DailyReadingRecord,
        readCalendarRepository: any ReadCalendarRepositoryProtocol,
        contentRepository: any ContentRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        guard let recordID = record.recordID else { return }
        isWriting = true
        defer { isWriting = false }

        switch record.event.kind {
        case .checkIn:
            try await readCalendarRepository.deleteCheckIn(recordID: recordID)
        case .readTiming:
            try await readCalendarRepository.deleteTiming(recordID: recordID)
        case .note(let note):
            try await contentRepository.delete(itemID: .note(note.noteId))
        case .review(let review):
            try await contentRepository.delete(itemID: .review(review.reviewId))
        case .relevant(let relevant):
            try await contentRepository.delete(itemID: .relevant(relevant.contentId))
        case .relevantBook:
            try await contentRepository.deleteRelatedRelation(relationID: recordID)
        case .readStatus:
            return
        }
        await reload(using: readCalendarRepository)
    }

    /// 页面离开时取消读取任务，防止旧日期或旧筛选结果回写。
    func cancel() {
        requestToken &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "DailyReading"
    )
}
