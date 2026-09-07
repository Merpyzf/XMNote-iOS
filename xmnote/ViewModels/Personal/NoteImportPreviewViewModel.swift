/**
 * [INPUT]: 依赖导入 Repository、来源快照、时长评估与资料补丁
 * [OUTPUT]: 提供共享目标草稿、独立单本编辑、筛选与同目标原子提交状态
 * [POS]: ViewModels/Personal 的导入会话 owner；所有写入仅经最终提交
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Observation

/// 单书来源身份与来源时长固定，取消选择不会恢复已取消的内容。
struct NoteImportPreviewBook: Identifiable {
    let id = UUID()
    let source: NoteImportDraftBook
    let sourceSeconds: Int64?
    var newBookPatch: NoteImportMetadataPatch
    var targetID: Int64?
    var placement: NoteImportPlacement = .newBook
    var isSelected: Bool
    var selectedNotes: Set<Int>
    var selectedReviews: Set<Int>
    var includesReadingPosition = true
    var isCompleted = false
    var issue: String?
    /// 初始化来源摘要与默认内容选择，书籍勾选由入口数量决定。
    init(source: NoteImportDraftBook, isSelected: Bool) {
        self.source = source
        sourceSeconds = NoteImportDurationMerge.sourceSeconds([source])
        self.isSelected = isSelected
        selectedNotes = Set(source.notes.indices)
        selectedReviews = Set(source.reviews.indices)
        let metadata = NoteImportBookMetadata(source: source)
        newBookPatch = .init(original: metadata, edited: metadata, changedAt: 0)
    }
    var hasContent: Bool { !source.notes.isEmpty || !source.reviews.isEmpty || sourceSeconds != nil || source.hasPreviewReadingPosition }
    var hasSelectedContent: Bool { !selectedNotes.isEmpty || !selectedReviews.isEmpty || (includesReadingPosition && source.hasPreviewReadingPosition) }
    var hasSelectedAttachmentFailure: Bool { selectedNotes.contains { !source.notes[$0].failedAttachmentURLs.isEmpty } }
    var contentTitle: String {
        var parts: [String] = []
        if !source.notes.isEmpty { parts.append(selectedNotes.count == source.notes.count ? "\(source.notes.count) 条书摘" : "书摘 \(selectedNotes.count)/\(source.notes.count)") }
        if !source.reviews.isEmpty { parts.append(selectedReviews.count == source.reviews.count ? "\(source.reviews.count) 条书评" : "书评 \(selectedReviews.count)/\(source.reviews.count)") }
        if parts.isEmpty, source.hasPreviewReadingPosition { parts.append("阅读位置") }
        return parts.isEmpty ? (sourceSeconds == nil ? "仅书籍资料" : "阅读时长") : parts.joined(separator: "　")
    }
}

/// 绑定选中来源集合和完整本地快照，避免共享目标更换输入后沿用旧确认。
struct NoteImportDurationChoice {
    var sourceIDs: [UUID]
    var assessment: NoteImportDurationAssessment
    var policy: NoteImportDurationPolicy?
}

/// MainActor 编排会话；读取使用版本票据丢弃迟到结果，取消只停止尚未提交的目标。
@MainActor @Observable
final class NoteImportPreviewViewModel {
    typealias Commit = @MainActor (NoteImportCommitGroup) async throws -> NoteImportCommitGroupResult
    var books: [NoteImportPreviewBook]
    var query = ""
    var filter = NoteImportFilter()
    let capabilities: NoteImportCapabilities
    var editorOptions: BookEditorOptions?
    var isPreparing = true
    var isAssessing = false
    var isCommitting = false
    var busyBookID: UUID?
    var progressText = ""
    var errorMessage: String?
    var hasUnsavedChanges = false
    var showsResult = false
    var hasAttemptedCommit = false
    var results: [NoteImportCommitGroupResult] = []
    private var targetPatches: [Int64: NoteImportMetadataPatch] = [:]
    private var durationChoices: [String: NoteImportDurationChoice] = [:]
    private let preferenceKey: String?
    private let repository: any NoteImportRepositoryProtocol
    private let commitHandler: Commit
    private var prepared = false
    private var assessmentRevision = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var targetTickets: [UUID: UUID] = [:]

    /// 入口持有会话，微信读书仅替换网络补全后提交的边界。
    init(books: [NoteImportDraftBook], repository: any NoteImportRepositoryProtocol, preferenceKey: String? = nil, commit: Commit? = nil) {
        self.books = books.map { .init(source: $0, isSelected: books.count == 1) }
        capabilities = .init(books: books)
        self.repository = repository
        self.preferenceKey = preferenceKey
        commitHandler = commit ?? { group in
            var value = group
            value.books = await repository.enrichImportBookInfoIfNeeded(group.books)
            try Task.checkCancellation()
            return try await repository.commitImportGroup(value)
        }
    }
    var sourceKey: String { preferenceKey ?? Set(books.map { String($0.source.source) }).sorted().joined(separator: "-") }
    var hasDurations: Bool { books.contains { $0.sourceSeconds != nil } }
    var hasMissingDurations: Bool { books.contains { $0.sourceSeconds == nil } }
    var selectedBooks: [NoteImportPreviewBook] { books.filter { $0.isSelected && !$0.isCompleted } }
    var selectedCount: Int { selectedBooks.count }
    var completedCount: Int { results.count }
    var pendingResultBooks: [NoteImportPreviewBook] {
        var seen: Set<String> = []
        return books.filter { !$0.isCompleted && ($0.isSelected || $0.issue != nil) && seen.insert(key($0)).inserted }
    }
    var failedCount: Int { books.filter { !$0.isCompleted && $0.issue != nil }.count }
    var isLocked: Bool { isPreparing || isCommitting || busyBookID != nil }
    var pendingIssues: [NoteImportPreviewBook] { selectedBooks.filter { validationMessage(for: $0) != nil } }
    var allVisibleSelected: Bool {
        let available = visibleBooks.filter { !$0.isCompleted }
        return !available.isEmpty && available.allSatisfy(\.isSelected)
    }
    var visibleBooks: [NoteImportPreviewBook] {
        let values = scopedBooks.filter { filter.statuses.isEmpty || filter.statuses.contains($0.source.sourceReadingStatus ?? .unavailable) }
        switch filter.sort {
        case .title: return values.sorted { metadata(for: $0).title.localizedStandardCompare(metadata(for: $1).title) == .orderedAscending }
        case .contentCount: return values.sorted { contentCount($0) > contentCount($1) }
        default: return values
        }
    }
    private var scopedBooks: [NoteImportPreviewBook] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { book in
            let metadata = metadata(for: book)
            let original = book.targetID.flatMap { targetPatches[$0]?.original }
            let names = [book.source.name, book.source.rawName, book.source.author, metadata.title, metadata.author, original?.title ?? "", original?.author ?? ""]
            return (keyword.isEmpty || names.contains { $0.localizedCaseInsensitiveContains(keyword) })
                && (!filter.onlyWithNotes || contentCount(book) > 0)
                && (!hasDurations || filter.duration.matches(book.sourceSeconds))
        }
    }
    /// 状态计数仅受搜索和额外条件影响，分类之间不相互清零。
    func count(for status: NoteImportReadingStatus?) -> Int {
        scopedBooks.filter { status == nil || ($0.source.sourceReadingStatus ?? .unavailable) == status }.count
    }
    /// 数量排序只统计书摘和独立书评，不混入时长条数。
    private func contentCount(_ book: NoteImportPreviewBook) -> Int { book.source.notes.count + book.source.reviews.count }
    /// 同一已有目标显示同一份待提交资料。
    func metadata(for book: NoteImportPreviewBook) -> NoteImportBookMetadata {
        book.targetID.flatMap { targetPatches[$0]?.edited } ?? book.newBookPatch.edited
    }
    /// 首次只读匹配来源与目标；取消后允许重试准备。
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        filter = repository.fetchPreviewPreferences(sourceKey: sourceKey)
        filter.statuses = []
        if !hasDurations || (filter.duration == .missing && !hasMissingDurations) { filter.duration = .all }
        defer { isPreparing = false }
        do { editorOptions = try await repository.fetchPreviewEditorOptions() }
        catch { errorMessage = error.localizedDescription }
        for index in books.indices {
            if Task.isCancelled { prepared = false; return }
            if books[index].isCompleted { continue }
            do {
                switch try await repository.previewTargetMatch(for: books[index].source) {
                case .none: break
                case .candidate: books[index].placement = .unresolved
                case .automatic(let targetID):
                    let metadata = try await repository.fetchPreviewBookMetadata(id: targetID)
                    try Task.checkCancellation()
                    targetPatches[targetID] = targetPatches[targetID] ?? .init(original: metadata, edited: metadata, changedAt: 0)
                    books[index].targetID = targetID
                    books[index].placement = .existingBook
                }
            } catch is CancellationError { prepared = false; return }
            catch { books[index].placement = .unresolved; books[index].issue = error.localizedDescription }
        }
        await refreshDurations()
    }
    /// 应用成功才保存额外偏好，分类不进入持久化。
    func applyFilter(_ value: NoteImportFilter) {
        filter = value
        do { try repository.savePreviewPreferences(value, sourceKey: sourceKey) }
        catch { errorMessage = error.localizedDescription }
    }
    /// 勾选不恢复内容子集，空内容保持未选并指向可修复问题。
    func toggleBook(_ id: UUID) {
        guard !isLocked, let index = books.firstIndex(where: { $0.id == id }), !books[index].isCompleted else { return }
        if !books[index].isSelected, !canSelect(books[index]) {
            books[index].issue = "请先选择要导入的内容"
            return
        }
        books[index].isSelected.toggle()
        selectionChanged()
    }
    /// 只选当前结果，冻结身份避免中途筛选变化。
    func selectVisible(_ selected: Bool) {
        guard !isLocked else { return }
        let ids = Set(visibleBooks.map(\.id))
        for index in books.indices where ids.contains(books[index].id) && !books[index].isCompleted {
            books[index].isSelected = selected && canSelect(books[index])
        }
        selectionChanged()
    }
    /// 清空选择但保留目标、资料和各内容子集。
    func clearSelection() {
        guard !isLocked else { return }
        for index in books.indices where !books[index].isCompleted { books[index].isSelected = false }
        selectionChanged()
    }
    /// 内容存在但全部排除时不隐式创建空书。
    private func canSelect(_ book: NoteImportPreviewBook) -> Bool {
        !book.hasContent || book.hasSelectedContent || (book.sourceSeconds != nil && durationChoice(for: book)?.policy != .keep)
    }
    /// 来源集合变化立即失效旧决策；异步回填使用版本保护。
    private func selectionChanged() {
        hasUnsavedChanges = true
        invalidateChangedGroups()
        Task { await refreshDurations() }
    }
    /// 内容子页只改变局部会话，不自动勾选原先未选中的书籍。
    func updateContents(_ value: NoteImportPreviewBook) {
        guard !isLocked, let index = books.firstIndex(where: { $0.id == value.id }) else { return }
        books[index].selectedNotes = value.selectedNotes
        books[index].selectedReviews = value.selectedReviews
        books[index].includesReadingPosition = value.includesReadingPosition
        if !canSelect(books[index]) { books[index].isSelected = false }
        books[index].issue = nil
        hasUnsavedChanges = true
    }
    /// 恢复本来源新书草稿，旧目标异步回调不可覆盖。
    func chooseNewBook(_ id: UUID) {
        guard !isCommitting, let index = books.firstIndex(where: { $0.id == id }) else { return }
        targetTickets[id] = UUID()
        books[index].targetID = nil; books[index].placement = .newBook; books[index].issue = nil
        selectionChanged()
    }
    /// MainActor 读取目标资料；票据和取消保护避免快速切换时使用旧目标。
    func chooseExistingBook(_ id: UUID, targetID: Int64) async {
        let ticket = UUID(); targetTickets[id] = ticket; busyBookID = id
        defer { if targetTickets[id] == ticket { busyBookID = nil } }
        do {
            let metadata = try await repository.fetchPreviewBookMetadata(id: targetID)
            try Task.checkCancellation()
            guard targetTickets[id] == ticket, let index = books.firstIndex(where: { $0.id == id }) else { return }
            targetPatches[targetID] = targetPatches[targetID] ?? .init(original: metadata, edited: metadata, changedAt: 0)
            books[index].targetID = targetID; books[index].placement = .existingBook; books[index].issue = nil
            hasUnsavedChanges = true
            await refreshDurations()
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
    /// 显式编辑共享资料补丁，只有阅读状态实际变更才更新时间。
    func updateMetadata(_ value: NoteImportBookMetadata, bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var patch = books[index].targetID.flatMap { targetPatches[$0] } ?? books[index].newBookPatch
        if patch.edited.readingStatusID != value.readingStatusID { patch.changedAt = Int64(Date().timeIntervalSince1970 * 1000) }
        patch.edited = value
        if let targetID = books[index].targetID { targetPatches[targetID] = patch }
        else { books[index].newBookPatch = patch }
        books[index].issue = nil
        hasUnsavedChanges = true
    }
    /// 复制整个目标上下文，子页修改只存在于此局部会话。
    func editorSession() -> NoteImportPreviewViewModel {
        let value = NoteImportPreviewViewModel(books: [], repository: repository, preferenceKey: preferenceKey, commit: commitHandler)
        value.books = books; value.targetPatches = targetPatches; value.durationChoices = durationChoices
        value.editorOptions = editorOptions; value.prepared = true; value.isPreparing = false
        return value
    }
    /// 顶层确认一次合入单本内容与共享目标修改；取消则无需回滚。
    func applyEditorSession(_ value: NoteImportPreviewViewModel, bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }), let edited = value.books.first(where: { $0.id == bookID }) else { return }
        books[index] = edited
        targetPatches = value.targetPatches
        durationChoices = value.durationChoices
        for index in books.indices where books[index].isSelected && !canSelect(books[index]) { books[index].isSelected = false }
        selectionChanged()
    }
    /// 按目标身份共享时长决定，新书始终以来源身份隔离。
    private func key(_ book: NoteImportPreviewBook) -> String { book.targetID.map { "target:\($0)" } ?? "source:\(book.id)" }
    /// 每组优先使用实际已选来源，未选组仍允许提前编辑。
    private func durationGroups() -> [[NoteImportPreviewBook]] {
        var groups: [[NoteImportPreviewBook]] = []
        var indices: [String: Int] = [:]
        for book in books where !book.isCompleted {
            let identity = key(book)
            if let index = indices[identity] { groups[index].append(book) }
            else { indices[identity] = groups.count; groups.append([book]) }
        }
        return groups.map { group in
            let selected = group.filter(\.isSelected)
            return selected.isEmpty ? group : selected
        }
    }
    /// 同步清除已经失去来源集合依据的决策，避免异步读取前点击导入。
    private func invalidateChangedGroups() {
        for group in durationGroups() {
            guard let first = group.first, var choice = durationChoices[key(first)], choice.sourceIDs != group.map(\.id) else { continue }
            choice.policy = choice.assessment.needsDecision ? nil : .merge
            durationChoices[key(first)] = choice
        }
    }
    /// 只读评估每个目标；版本号阻止旧选择集合或取消后的结果覆盖当前草稿。
    func refreshDurations() async {
        assessmentRevision += 1
        let revision = assessmentRevision
        isAssessing = true
        defer { if revision == assessmentRevision { isAssessing = false } }
        for group in durationGroups() {
            guard let first = group.first, group.contains(where: { $0.sourceSeconds != nil }) else { continue }
            do {
                let assessment = try await repository.assessImportDuration(targetID: first.targetID, drafts: group.map(\.source))
                try Task.checkCancellation()
                guard revision == assessmentRevision else { return }
                let ids = group.map(\.id), old = durationChoices[key(first)]
                let unchanged = old?.sourceIDs == ids && old?.assessment.snapshot == assessment.snapshot
                let policy: NoteImportDurationPolicy? = unchanged ? old?.policy : (assessment.needsDecision ? nil : .merge)
                durationChoices[key(first)] = .init(sourceIDs: ids, assessment: assessment, policy: policy)
            } catch is CancellationError { return }
            catch {
                guard revision == assessmentRevision else { return }
                durationChoices[key(first)] = nil
                for index in books.indices where key(books[index]) == key(first) { books[index].issue = error.localizedDescription }
            }
        }
    }
    /// 列表与单本设置读取同一目标决策。
    func durationChoice(for book: NoteImportPreviewBook) -> NoteImportDurationChoice? { durationChoices[key(book)] }
    /// 明确选择才保存策略；批量应用仅作用于本次其余冲突，活动计时不会被替换。
    func chooseDuration(_ policy: NoteImportDurationPolicy, bookID: UUID, applyToOthers: Bool = false) {
        guard let book = books.first(where: { $0.id == bookID }), var choice = durationChoices[key(book)] else { return }
        guard policy != .replace || !choice.assessment.hasActiveTimer else { return }
        choice.policy = policy; durationChoices[key(book)] = choice
        if applyToOthers {
            let selectedTargets = Set(selectedBooks.map(key))
            for identity in Array(durationChoices.keys) where selectedTargets.contains(identity) {
                guard var other = durationChoices[identity], other.assessment.needsDecision, other.policy == nil,
                      policy != .replace || !other.assessment.hasActiveTimer else { continue }
                other.policy = policy; durationChoices[identity] = other
            }
        }
        for index in books.indices {
            if key(books[index]) == key(book) { books[index].issue = nil }
            if books[index].isSelected && !canSelect(books[index]) { books[index].isSelected = false }
        }
        hasUnsavedChanges = true
    }
    /// 决策缺失是可处理状态，不用禁用按钮隐藏原因。
    func validationMessage(for book: NoteImportPreviewBook) -> String? {
        if book.placement == .unresolved { return "请选择存入书籍" }
        if let message = metadata(for: book).validationMessage { return message }
        if book.hasSelectedAttachmentFailure { return "部分图片未获取，请查看内容" }
        if book.sourceSeconds != nil {
            guard let choice = durationChoice(for: book) else { return book.issue ?? "正在核对阅读时长" }
            if choice.policy == nil { return "时长待选择" }
            if choice.policy == .replace && choice.assessment.hasActiveTimer { return NoteImportDurationError.activeTimer.localizedDescription }
        }
        return nil
    }
    /// 冻结内容子集；时长数组保持完整，策略在目标事务中生效。
    private func payload(for book: NoteImportPreviewBook) -> NoteImportCommitBook {
        var draft = book.source
        draft.notes = draft.notes.enumerated().compactMap { book.selectedNotes.contains($0.offset) ? $0.element : nil }
        draft.reviews = draft.reviews.enumerated().compactMap { book.selectedReviews.contains($0.offset) ? $0.element : nil }
        if !book.includesReadingPosition, book.source.hasPreviewReadingPosition { draft.bookmarkModifiedTime = 0; draft.readPosition = 0 }
        var value = NoteImportCommitBook(draft: draft, targetBookID: book.targetID)
        value.metadataPatch = book.targetID.flatMap { targetPatches[$0] } ?? book.newBookPatch
        value.validatesPreviewTarget = true
        return value
    }
    private var commitGroups: [NoteImportCommitGroup] {
        durationGroups().compactMap { group in
            let selected = group.filter(\.isSelected)
            guard let first = selected.first else { return nil }
            let choice = durationChoice(for: first)
            return .init(sourceIDs: selected.map(\.id), books: selected.map(payload), policy: choice?.policy ?? .keep, assessment: choice?.assessment)
        }
    }
    var replacementMessage: String? {
        let replacements = commitGroups.filter { $0.policy == .replace }
        guard !replacements.isEmpty else { return nil }
        let count = replacements.reduce(0) { $0 + ($1.assessment?.localCount ?? 0) }
        let insights = replacements.reduce(0) { $0 + ($1.assessment?.insightCount ?? 0) }
        let positions = replacements.reduce(0) { $0 + ($1.assessment?.positionCount ?? 0) }
        return "将删除 \(replacements.count) 本书的 \(count) 条本地时长记录，再导入来源时长。记录附带的 \(insights) 条感想和 \(positions) 条进度也会删除。"
    }
    /// 导入按钮先重读本地快照，已变化的决定会回到待处理列表。
    func prepareCommit() async { await refreshDurations() }
    /// 逐目标事务提交；只有成功返回后才标记组内全部来源完成。
    func beginCommit() {
        guard !isLocked, !isAssessing, selectedCount > 0, pendingIssues.isEmpty else { return }
        let frozen = commitGroups
        isCommitting = true; hasAttemptedCommit = true; showsResult = false
        task = Task {
            defer { isCommitting = false; progressText = ""; showsResult = true; task = nil }
            for (offset, group) in frozen.enumerated() {
                if Task.isCancelled { break }
                progressText = "正在导入 \(offset + 1)/\(frozen.count)"
                do {
                    let result = try await commitHandler(group)
                    results.append(result)
                    for index in books.indices where group.sourceIDs.contains(books[index].id) {
                        books[index].isCompleted = true; books[index].isSelected = false; books[index].issue = nil
                    }
                } catch is CancellationError { break }
                catch {
                    for index in books.indices where group.sourceIDs.contains(books[index].id) {
                        books[index].issue = error.localizedDescription
                        if error is NoteImportDurationError { durationChoices[key(books[index])]?.policy = nil }
                        if let error = error as? BookEditorError, case .bookNotFound = error { books[index].placement = .unresolved }
                    }
                }
            }
            hasUnsavedChanges = books.contains { !$0.isCompleted && ($0.isSelected || $0.newBookPatch.hasChanges || $0.targetID != nil) }
        }
    }
    /// 丢弃未提交内容，保留已经提交目标的结果。
    func discardPendingChanges() {
        guard !isCommitting else { return }
        assessmentRevision += 1; targetTickets.removeAll(); durationChoices.removeAll()
        books = books.map { $0.isCompleted ? $0 : .init(source: $0.source, isSelected: books.count == 1) }
        query = ""; filter = .init(); errorMessage = nil; hasUnsavedChanges = false; prepared = false; isPreparing = true
    }
    /// 停止后续目标，不撤销已完成事务。
    func stopImport() { task?.cancel() }
}
