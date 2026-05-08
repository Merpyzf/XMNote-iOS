/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供二级书籍列表观察流，依赖 BookshelfBookListRoute 描述当前聚合上下文
 * [OUTPUT]: 对外提供 BookshelfBookListViewModel，驱动二级书籍列表加载、空态、搜索、编辑选择、分组移动、批量写入与实时刷新
 * [POS]: Book 模块二级书籍列表状态编排器，被 BookshelfBookListView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 二级书籍列表编辑动作，已核对动作走真实写入，未核对 destructive 动作继续保护提示。
enum BookshelfBookListEditAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pin
    case unpin
    case reorder
    case moveToStart
    case moveToEnd
    case moveToGroup
    case addToBookList
    case moveOut
    case setTag
    case setSource
    case setReadStatus
    case exportNote
    case exportBook
    case renameGroup
    case deleteGroup
    case renameTag
    case deleteTag
    case renameSource
    case deleteSource
    case deleteBooks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pin:
            return "置顶"
        case .unpin:
            return "取消置顶"
        case .reorder:
            return "排序"
        case .moveToStart:
            return "最前"
        case .moveToEnd:
            return "最后"
        case .moveToGroup:
            return "移组"
        case .addToBookList:
            return "书单"
        case .moveOut:
            return "移出"
        case .setTag:
            return "标签"
        case .setSource:
            return "来源"
        case .setReadStatus:
            return "状态"
        case .exportNote:
            return "导出笔记"
        case .exportBook:
            return "导出书籍"
        case .renameGroup, .renameTag, .renameSource:
            return "重命名"
        case .deleteGroup:
            return "删分组"
        case .deleteTag:
            return "删标签"
        case .deleteSource:
            return "删来源"
        case .deleteBooks:
            return "删除"
        }
    }

    var systemImage: String {
        switch self {
        case .pin:
            return "pin"
        case .unpin:
            return "pin.slash"
        case .reorder:
            return "arrow.up.arrow.down"
        case .moveToStart:
            return "arrow.up.to.line"
        case .moveToEnd:
            return "arrow.down.to.line"
        case .moveToGroup:
            return "folder"
        case .addToBookList:
            return "books.vertical"
        case .moveOut:
            return "folder.badge.minus"
        case .setTag:
            return "tag"
        case .setSource:
            return "tray"
        case .setReadStatus:
            return "checklist"
        case .exportNote:
            return "doc.text"
        case .exportBook:
            return "square.and.arrow.up"
        case .renameGroup, .renameTag, .renameSource:
            return "pencil"
        case .deleteGroup, .deleteTag, .deleteSource, .deleteBooks:
            return "trash"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteGroup, .deleteTag, .deleteSource, .deleteBooks:
            return true
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .renameGroup, .renameTag, .renameSource:
            return false
        }
    }

    var requiresSelection: Bool {
        switch self {
        case .pin, .unpin, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .deleteBooks:
            return true
        case .reorder, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource:
            return false
        }
    }
}

/// 二级书籍列表批量编辑 Sheet 类型，承载打开 Sheet 时刻的可选项快照。
enum BookshelfBatchEditSheet: Identifiable, Hashable, Sendable {
    case tags(options: [BookEditorNamedOption], initialSelectedIDs: [Int64], allowsEmptySelection: Bool)
    case source(options: [BookEditorNamedOption], initialSelectedID: Int64?)
    case readStatus(options: [BookEditorNamedOption], initialStatusID: Int64?, initialChangedAt: Date?, initialRatingScore: Int64?)
    case moveGroup(options: [BookEditorNamedOption])

    var id: String {
        switch self {
        case .tags:
            return "tags"
        case .source:
            return "source"
        case .readStatus:
            return "readStatus"
        case .moveGroup:
            return "moveGroup"
        }
    }
}

/// 默认分组移出确认状态，承载打开弹窗时的选择数量。
struct BookshelfMoveOutPlacementConfirmation: Identifiable, Hashable, Sendable {
    let selectedCount: Int

    var id: Int { selectedCount }
}

/// 二级列表删除确认状态，覆盖批量删书与上下文分组/标签/来源删除。
struct BookshelfBookListDeleteConfirmation: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case books(bookIDs: [Int64])
        case group(title: String)
        case tag(title: String)
        case source(title: String)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .books(let bookIDs):
            return "books-\(bookIDs.map(String.init).joined(separator: "-"))"
        case .group(let title):
            return "group-\(title)"
        case .tag(let title):
            return "tag-\(title)"
        case .source(let title):
            return "source-\(title)"
        }
    }
}

/// 二级列表重命名输入状态，承载当前上下文对象与初始名称。
struct BookshelfBookListNameEdit: Identifiable, Hashable, Sendable {
    let action: BookshelfBookListEditAction
    let currentName: String

    var id: String { "\(action.rawValue)-\(currentName)" }
}

/// 二级书籍列表状态编排器，让 pushed destination 通过 Repository 实时观察数据，而不是消费静态路由数组。
@Observable
final class BookshelfBookListViewModel {
    let route: BookshelfBookListRoute
    var snapshot: BookshelfBookListSnapshot = .empty
    var contentState: BookshelfContentState = .loading
    var searchKeyword: String = "" {
        didSet {
            guard normalizedSearchKeyword(oldValue) != normalizedSearchKeyword(searchKeyword) else { return }
            restartObservation()
        }
    }
    var displaySetting: BookshelfDisplaySetting
    var isEditing = false
    var selectedBookIDs: [Int64] = []
    var actionNotice: String?
    var activeWriteAction: BookshelfBookListEditAction?
    var writeError: String?
    var activeBatchSheet: BookshelfBatchEditSheet?
    var activeMoveOutConfirmation: BookshelfMoveOutPlacementConfirmation?
    var activeDeleteConfirmation: BookshelfBookListDeleteConfirmation?
    var activeNameEdit: BookshelfBookListNameEdit?
    var nameEditText = ""
    var isLoadingBatchOptions = false

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var batchOptionsTask: Task<Void, Never>?

    var navigationTitle: String {
        snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? route.title : snapshot.title
    }

    var subtitle: String {
        snapshot.subtitle.isEmpty ? route.subtitleHint : snapshot.subtitle
    }

    var selectedBookIDSet: Set<Int64> {
        Set(selectedBookIDs)
    }

    var selectedCount: Int {
        selectedBookIDs.count
    }

    var visibleBookIDs: [Int64] {
        snapshot.books.map(\.id)
    }

    var visibleOrderItems: [BookshelfBookListOrderItem] {
        snapshot.books.map { BookshelfBookListOrderItem(id: $0.id, isPinned: $0.pinned) }
    }

    var isAllVisibleSelected: Bool {
        let visibleIDs = Set(visibleBookIDs)
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedBookIDSet)
    }

    var canEnterEditing: Bool {
        contentState == .content && !visibleBookIDs.isEmpty && activeWriteAction == nil
    }

    var canReorderBooksInDefaultGroup: Bool {
        isEditing
            && activeWriteAction == nil
            && !hasSearchKeyword
            && contentState == .content
            && displaySetting.sortCriteria == .custom
            && defaultGroupID != nil
            && snapshot.sections.count == 1
    }

    var movableBookIDs: Set<Int64> {
        guard canReorderBooksInDefaultGroup else { return [] }
        return Set(snapshot.books.filter { !$0.pinned }.map(\.id))
    }

    var supportsContextPin: Bool {
        defaultGroupID != nil
    }

    var hasSearchKeyword: Bool {
        !normalizedSearchKeyword(searchKeyword).isEmpty
    }

    var editActions: [BookshelfBookListEditAction] {
        switch route.context {
        case .defaultGroup:
            return [.pin, .unpin, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .deleteBooks, .renameGroup, .deleteGroup]
        case .tag(let tagID):
            var actions: [BookshelfBookListEditAction] = [.moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus, .deleteBooks]
            if tagID != nil {
                actions.append(contentsOf: [.renameTag, .deleteTag])
            }
            return actions
        case .source(let sourceID):
            var actions: [BookshelfBookListEditAction] = [.moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus, .deleteBooks]
            if sourceID != nil {
                actions.append(contentsOf: [.renameSource, .deleteSource])
            }
            return actions
        case .readStatus, .rating, .author, .press:
            return [.moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus, .deleteBooks]
        }
    }

    private var defaultGroupID: Int64? {
        guard case .defaultGroup(let groupID) = route.context else { return nil }
        return groupID
    }

    /// 注入路由和仓储，并启动二级列表观察流。
    init(
        route: BookshelfBookListRoute,
        repository: any BookRepositoryProtocol
    ) {
        self.route = route
        self.repository = repository
        let settings = repository.fetchBookshelfDisplaySettings(scope: .bookList)
        self.displaySetting = settings[route.context.dimension] ?? .defaultBookListValue(for: route.context.dimension)
        startObservation()
    }

    /// 取消二级列表观察与写入任务，避免页面释放后继续回写 UI 状态。
    deinit {
        observationTask?.cancel()
        writeTask?.cancel()
        batchOptionsTask?.cancel()
    }

    /// 清空搜索关键词并恢复完整列表。
    func clearSearchKeyword() {
        searchKeyword = ""
    }

    /// 保存二级列表显示设置，并重启观察流让排序、分区和布局立即生效。
    func updateDisplaySetting(_ setting: BookshelfDisplaySetting) {
        let sanitized = sanitizedDisplaySetting(setting)
        guard sanitized != displaySetting else { return }
        displaySetting = sanitized
        repository.saveBookshelfDisplaySetting(sanitized, for: route.context.dimension, scope: .bookList)
        restartObservation()
    }

    /// 进入二级列表编辑态，只改变本地选择状态，不触发任何写入。
    func enterEditing() {
        guard canEnterEditing else { return }
        isEditing = true
        actionNotice = nil
        writeError = nil
        pruneSelectionToVisibleBooks()
    }

    /// 退出二级列表编辑态并清空本地选择。
    func exitEditing() {
        isEditing = false
        selectedBookIDs.removeAll()
        activeBatchSheet = nil
        activeMoveOutConfirmation = nil
        activeDeleteConfirmation = nil
        activeNameEdit = nil
        nameEditText = ""
        cancelBatchOptionsLoading()
        actionNotice = nil
        writeError = nil
    }

    /// 切换单本书籍的本地选中状态。
    func toggleSelection(_ bookID: Int64) {
        guard isEditing, visibleBookIDs.contains(bookID) else { return }
        cancelBatchOptionsLoading()
        if let index = selectedBookIDs.firstIndex(of: bookID) {
            selectedBookIDs.remove(at: index)
        } else {
            selectedBookIDs.append(bookID)
        }
        actionNotice = nil
        writeError = nil
    }

    /// 选择当前可见的全部书籍。
    func selectAllVisible() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        selectedBookIDs = visibleBookIDs
        actionNotice = nil
        writeError = nil
    }

    /// 反选当前可见书籍，保持选择顺序与列表展示顺序一致。
    func invertVisibleSelection() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        let selected = selectedBookIDSet
        selectedBookIDs = visibleBookIDs.filter { !selected.contains($0) }
        actionNotice = nil
        writeError = nil
    }

    /// 执行二级列表编辑动作；已核对的排序/置顶和第一批批量写入会走 Repository，未核对动作保留保护提示。
    func performEditAction(_ action: BookshelfBookListEditAction) {
        if action.requiresSelection, selectedBookIDs.isEmpty {
            actionNotice = "请先选择书籍"
            return
        }
        switch action {
        case .pin:
            pinSelectedBooks()
        case .unpin:
            unpinSelectedBooks()
        case .moveToStart:
            moveSelectedBooks(toStart: true)
        case .moveToEnd:
            moveSelectedBooks(toStart: false)
        case .moveToGroup:
            presentMoveGroupSheet()
        case .addToBookList, .exportNote, .exportBook:
            performPlaceholderAction(action)
        case .moveOut:
            presentMoveOutConfirmation()
        case .setTag, .setSource, .setReadStatus:
            presentBatchSheet(for: action)
        case .renameGroup, .renameTag, .renameSource:
            presentNameEdit(for: action)
        case .deleteBooks:
            activeDeleteConfirmation = .init(kind: .books(bookIDs: selectedBookIDs))
            actionNotice = nil
            writeError = nil
        case .deleteGroup, .deleteTag, .deleteSource:
            presentDeleteConfirmation(for: action)
        case .reorder:
            performPlaceholderAction(action)
        }
    }

    /// 提交批量标签写入；单本替换、多本追加的差异由 Repository 对齐 Android 语义。
    func submitBatchTags(tagIDs: [Int64]) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        runWriteAction(.setTag, successMessage: "标签已更新") {
            try await self.repository.batchSetBooksTags(bookIDs: bookIDs, tagIDs: tagIDs)
        }
    }

    /// 提交批量来源写入，成功后由观察流刷新来源维度与当前二级列表。
    func submitBatchSource(sourceID: Int64) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        runWriteAction(.setSource, successMessage: "来源已更新") {
            try await self.repository.batchSetBooksSource(bookIDs: bookIDs, sourceID: sourceID)
        }
    }

    /// 提交批量阅读状态写入；读完状态必须携带评分，时间统一转成毫秒时间戳。
    func submitBatchReadStatus(statusID: Int64, changedAt: Date, ratingScore: Int64?) {
        if statusID == BookEntryReadingStatus.finished.rawValue, (ratingScore ?? 0) <= 0 {
            actionNotice = "标记读完时需要选择评分"
            return
        }
        let bookIDs = selectedBookIDs
        let input = BookshelfBatchReadStatusInput(
            statusID: statusID,
            changedAt: Int64(changedAt.timeIntervalSince1970 * 1000),
            ratingScore: ratingScore
        )
        activeBatchSheet = nil
        runWriteAction(.setReadStatus, successMessage: "阅读状态已更新") {
            try await self.repository.batchSetBookReadStatus(bookIDs: bookIDs, input: input)
        }
    }

    /// 提交批量移入分组，成功后由观察流刷新当前列表与默认书架。
    func submitMoveToGroup(groupID: Int64) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        runWriteAction(.moveToGroup, successMessage: "已移入分组") {
            try await self.repository.moveBooks(bookIDs, toGroup: groupID)
        }
    }

    /// 提交从当前分组移出，placement 决定回到默认书架的头部或尾部。
    func submitMoveOut(placement: GroupBooksPlacement) {
        let bookIDs = selectedBookIDs
        activeMoveOutConfirmation = nil
        runWriteAction(.moveOut, successMessage: "已移出分组") {
            try await self.repository.moveBooksOutOfGroup(bookIDs: bookIDs, placement: placement)
        }
    }

    /// 提交二级列表批量删书，成功后清空选择并由观察流刷新当前列表。
    func submitDeleteBooks() {
        let bookIDs: [Int64]
        if case .books(let targetIDs) = activeDeleteConfirmation?.kind {
            bookIDs = targetIDs
        } else {
            bookIDs = selectedBookIDs
        }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteBooks, successMessage: "已删除 \(bookIDs.count) 本") {
            try await self.repository.deleteBooks(bookIDs)
        }
    }

    /// 单本置顶，供二级列表长按菜单使用；仅默认分组上下文开放。
    func pinBook(_ bookID: Int64) {
        guard let groupID = defaultGroupID else { return }
        guard snapshot.books.first(where: { $0.id == bookID })?.pinned == false else {
            actionNotice = "该书籍已置顶"
            return
        }
        runWriteAction(.pin, successMessage: "已置顶") {
            try await self.repository.pinBooksInGroup(groupID: groupID, bookIDs: [bookID])
        }
    }

    /// 单本取消置顶，供二级列表长按菜单使用；仅默认分组上下文开放。
    func unpinBook(_ bookID: Int64) {
        guard defaultGroupID != nil else { return }
        guard snapshot.books.first(where: { $0.id == bookID })?.pinned == true else {
            actionNotice = "该书籍未置顶"
            return
        }
        runWriteAction(.unpin, successMessage: "已取消置顶") {
            try await self.repository.unpinBooksInGroup(bookIDs: [bookID])
        }
    }

    /// 打开单本书删除确认，供二级列表长按菜单使用。
    func presentDeleteBookConfirmation(bookID: Int64) {
        activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .books(bookIDs: [bookID]))
        actionNotice = nil
        writeError = nil
    }

    /// 展示尚未迁移的跨模块能力占位提示。
    func presentContextPlaceholder(_ message: String) {
        writeError = nil
        actionNotice = message
    }

    /// 删除当前默认分组上下文，并按 placement 安置组内书籍。
    func submitDeleteGroup(placement: GroupBooksPlacement) {
        guard case .defaultGroup(let groupID) = route.context else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteGroup, successMessage: "分组已删除") {
            try await self.repository.deleteGroup(groupID: groupID, placement: placement)
        }
    }

    /// 删除当前标签上下文。
    func submitDeleteTag() {
        guard case .tag(let tagID) = route.context, let tagID else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteTag, successMessage: "标签已删除") {
            try await self.repository.deleteTag(tagID: tagID)
        }
    }

    /// 删除当前来源上下文。
    func submitDeleteSource() {
        guard case .source(let sourceID) = route.context, let sourceID else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteSource, successMessage: "来源已删除") {
            try await self.repository.deleteSource(sourceID: sourceID)
        }
    }

    /// 提交当前上下文重命名输入，Repository 负责重名校验与真实写入。
    func submitNameEdit() {
        guard let activeNameEdit else { return }
        let name = nameEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionNotice = "\(activeNameEdit.action.title)名称不能为空"
            return
        }
        self.activeNameEdit = nil
        switch activeNameEdit.action {
        case .renameGroup:
            guard case .defaultGroup(let groupID) = route.context else { return }
            runWriteAction(.renameGroup, successMessage: "分组已重命名") {
                try await self.repository.renameGroup(groupID: groupID, newName: name)
            }
        case .renameTag:
            guard case .tag(let tagID) = route.context, let tagID else { return }
            runWriteAction(.renameTag, successMessage: "标签已重命名") {
                try await self.repository.renameTag(tagID: tagID, newName: name)
            }
        case .renameSource:
            guard case .source(let sourceID) = route.context, let sourceID else { return }
            runWriteAction(.renameSource, successMessage: "来源已重命名") {
                try await self.repository.renameSource(sourceID: sourceID, newName: name)
            }
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .deleteGroup, .deleteTag, .deleteSource, .deleteBooks:
            return
        }
    }

    /// 按 UIKit 拖拽结束后的最终 ID 顺序提交默认分组内排序。
    func commitBooksInDefaultGroupOrder(_ orderedBookIDs: [Int64]) {
        guard let groupID = defaultGroupID,
              canReorderBooksInDefaultGroup,
              orderedBookIDs != visibleBookIDs else {
            return
        }
        runWriteAction(.reorder, successMessage: "排序已更新") {
            try await self.repository.updateBooksInGroupOrder(groupID: groupID, orderedBookIDs: orderedBookIDs)
        }
    }

    private func pinSelectedBooks() {
        guard let groupID = defaultGroupID else {
            performPlaceholderAction(.pin)
            return
        }
        let targetIDs = selectedBookIDs.filter { selectedID in
            snapshot.books.first(where: { $0.id == selectedID })?.pinned == false
        }
        guard !targetIDs.isEmpty else {
            actionNotice = "所选书籍已置顶"
            selectedBookIDs.removeAll()
            return
        }
        runWriteAction(.pin, successMessage: "已置顶 \(targetIDs.count) 本") {
            try await self.repository.pinBooksInGroup(groupID: groupID, bookIDs: targetIDs)
        }
    }

    private func unpinSelectedBooks() {
        guard defaultGroupID != nil else {
            performPlaceholderAction(.unpin)
            return
        }
        let targetIDs = selectedBookIDs.filter { selectedID in
            snapshot.books.first(where: { $0.id == selectedID })?.pinned == true
        }
        guard !targetIDs.isEmpty else {
            actionNotice = "所选书籍未置顶"
            selectedBookIDs.removeAll()
            return
        }
        runWriteAction(.unpin, successMessage: "已取消置顶 \(targetIDs.count) 本") {
            try await self.repository.unpinBooksInGroup(bookIDs: targetIDs)
        }
    }

    private func moveSelectedBooks(toStart: Bool) {
        guard let groupID = defaultGroupID else {
            performPlaceholderAction(toStart ? .moveToStart : .moveToEnd)
            return
        }
        guard !hasSearchKeyword else {
            actionNotice = "搜索结果不支持移动排序，清除搜索后可调整组内顺序"
            return
        }
        guard displaySetting.sortCriteria == .custom else {
            actionNotice = "仅手动排序下支持移动到最前或最后"
            return
        }
        let targetIDs = selectedBookIDs.filter { selectedID in
            snapshot.books.first(where: { $0.id == selectedID })?.pinned == false
        }
        guard !targetIDs.isEmpty else {
            actionNotice = "至少选择一本非置顶书籍后才能移动"
            selectedBookIDs.removeAll()
            return
        }
        let action: BookshelfBookListEditAction = toStart ? .moveToStart : .moveToEnd
        let currentItems = visibleOrderItems
        runWriteAction(action, successMessage: toStart ? "已移到最前" : "已移到最后") {
            if toStart {
                try await self.repository.moveBooksInGroupToStart(targetIDs, groupID: groupID, currentItems: currentItems)
            } else {
                try await self.repository.moveBooksInGroupToEnd(targetIDs, groupID: groupID, currentItems: currentItems)
            }
        }
    }

    /// 拉取批量编辑候选项并打开对应 Sheet；Task 可被页面释放或下一次打开请求取消。
    /// - Note: 只在主线程回写 Sheet 状态；Repository 仍是唯一数据入口，避免 ViewModel 直接访问数据库。
    private func presentBatchSheet(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil, !isLoadingBatchOptions, !selectedBookIDs.isEmpty else { return }
        isLoadingBatchOptions = true
        actionNotice = "正在加载\(action.title)选项..."
        writeError = nil
        let bookIDs = selectedBookIDs
        batchOptionsTask?.cancel()
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchBookshelfBatchEditOptions(bookIDs: bookIDs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        return
                    }
                    self.isLoadingBatchOptions = false
                    self.presentBatchSheet(action, options: options, bookIDs: bookIDs)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isLoadingBatchOptions = false
                    self.writeError = error.localizedDescription
                    self.actionNotice = error.localizedDescription
                }
            }
        }
    }

    /// 拉取目标分组选项并打开移组 Sheet，避免 ViewModel 直接查询数据库。
    private func presentMoveGroupSheet() {
        guard activeWriteAction == nil, !isLoadingBatchOptions, !selectedBookIDs.isEmpty else { return }
        isLoadingBatchOptions = true
        actionNotice = "正在加载分组选项..."
        writeError = nil
        let bookIDs = selectedBookIDs
        let excludingGroupID = defaultGroupID
        batchOptionsTask?.cancel()
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchBookshelfMoveTargetGroups(excludingGroupID: excludingGroupID)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        return
                    }
                    self.isLoadingBatchOptions = false
                    guard !options.isEmpty else {
                        self.actionNotice = "暂无可移入的分组"
                        return
                    }
                    self.activeBatchSheet = .moveGroup(options: options)
                    self.actionNotice = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isLoadingBatchOptions = false
                    self.writeError = error.localizedDescription
                    self.actionNotice = error.localizedDescription
                }
            }
        }
    }

    /// 打开默认分组移出确认，用户选择回到默认书架的头部或尾部。
    private func presentMoveOutConfirmation() {
        guard case .defaultGroup = route.context else {
            performPlaceholderAction(.moveOut)
            return
        }
        guard activeWriteAction == nil, !selectedBookIDs.isEmpty else { return }
        activeMoveOutConfirmation = BookshelfMoveOutPlacementConfirmation(selectedCount: selectedBookIDs.count)
        actionNotice = nil
        writeError = nil
    }

    /// 打开当前上下文对象的重命名输入弹窗。
    private func presentNameEdit(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil else { return }
        guard canManageCurrentContext(action) else {
            performPlaceholderAction(action)
            return
        }
        let currentName = route.title
        nameEditText = currentName
        activeNameEdit = BookshelfBookListNameEdit(action: action, currentName: currentName)
        actionNotice = nil
        writeError = nil
    }

    /// 打开当前上下文对象的删除确认弹窗。
    private func presentDeleteConfirmation(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil else { return }
        guard canManageCurrentContext(action) else {
            performPlaceholderAction(action)
            return
        }
        switch action {
        case .deleteGroup:
            activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .group(title: route.title))
        case .deleteTag:
            activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .tag(title: route.title))
        case .deleteSource:
            activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .source(title: route.title))
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .renameGroup, .renameTag, .renameSource, .deleteBooks:
            return
        }
        actionNotice = nil
        writeError = nil
    }

    /// 判断当前路由上下文是否具备对应管理对象。
    private func canManageCurrentContext(_ action: BookshelfBookListEditAction) -> Bool {
        switch (route.context, action) {
        case (.defaultGroup, .renameGroup), (.defaultGroup, .deleteGroup):
            return true
        case (.tag(let tagID), .renameTag), (.tag(let tagID), .deleteTag):
            return tagID != nil
        case (.source(let sourceID), .renameSource), (.source(let sourceID), .deleteSource):
            return sourceID != nil
        default:
            return false
        }
    }

    /// 取消正在加载的批量编辑候选项，避免选择集合变化后继续打开旧快照 Sheet。
    private func cancelBatchOptionsLoading() {
        batchOptionsTask?.cancel()
        batchOptionsTask = nil
        isLoadingBatchOptions = false
    }

    /// 根据候选项快照打开具体批量编辑 Sheet。
    private func presentBatchSheet(
        _ action: BookshelfBookListEditAction,
        options: BookshelfBatchEditOptions,
        bookIDs: [Int64]
    ) {
        switch action {
        case .setTag:
            activeBatchSheet = .tags(
                options: options.tags,
                initialSelectedIDs: bookIDs.count == 1 ? options.initialTagIDs : [],
                allowsEmptySelection: bookIDs.count == 1
            )
            actionNotice = nil
        case .setSource:
            guard !options.sources.isEmpty else {
                actionNotice = "暂无可用来源"
                return
            }
            activeBatchSheet = .source(
                options: options.sources,
                initialSelectedID: preferredSourceID(from: options)
            )
            actionNotice = nil
        case .setReadStatus:
            guard !options.readStatuses.isEmpty else {
                actionNotice = "暂无可用阅读状态"
                return
            }
            activeBatchSheet = .readStatus(
                options: options.readStatuses,
                initialStatusID: preferredReadStatusID(from: options),
                initialChangedAt: preferredReadStatusChangedAt(from: options),
                initialRatingScore: options.initialRatingScore
            )
            actionNotice = nil
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .exportNote, .exportBook, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource, .deleteBooks:
            return
        }
    }

    /// 为来源 Sheet 选择进入时的默认来源，优先保留单本书当前来源，其次沿用来源维度上下文。
    private func preferredSourceID(from options: BookshelfBatchEditOptions) -> Int64? {
        if let sourceID = options.initialSourceID {
            return sourceID
        }
        if case .source(let sourceID) = route.context, let sourceID {
            return sourceID
        }
        return options.sources.first?.id
    }

    /// 为阅读状态 Sheet 选择进入时的默认状态，优先保留单本书当前状态，其次沿用状态维度上下文。
    private func preferredReadStatusID(from options: BookshelfBatchEditOptions) -> Int64? {
        if let statusID = options.initialReadStatusID {
            return statusID
        }
        if case .readStatus(let statusID) = route.context, let statusID {
            return statusID
        }
        return options.readStatuses.first(where: { $0.id == BookEntryReadingStatus.reading.rawValue })?.id
            ?? options.readStatuses.first?.id
    }

    /// 将单本书当前阅读状态时间转换为 Sheet 可编辑的日期，缺失时交给 Sheet 使用当前时间。
    private func preferredReadStatusChangedAt(from options: BookshelfBatchEditOptions) -> Date? {
        guard let timestamp = options.initialReadStatusChangedAt, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }

    /// 启动写操作任务；状态只在主线程回写，失败后保留当前选择并通过观察流恢复列表。
    /// - Note: Task 可被页面释放时自然取消；Repository 写入完成后再回到 MainActor 更新 UI，避免竞态污染选择状态。
    private func runWriteAction(
        _ action: BookshelfBookListEditAction,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) {
        guard activeWriteAction == nil else { return }
        batchOptionsTask?.cancel()
        isLoadingBatchOptions = false
        activeWriteAction = action
        actionNotice = "\(action.title)处理中..."
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await operation()
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.selectedBookIDs.removeAll()
                    self.actionNotice = successMessage
                    self.restartObservation()
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                    self.actionNotice = error.localizedDescription
                    self.restartObservation()
                }
            }
        }
    }

    /// 展示未开放写入动作的保护提示，避免绕过 Android 数据语义核对。
    private func performPlaceholderAction(_ action: BookshelfBookListEditAction) {
        if action == .addToBookList {
            actionNotice = "书单添加将在书单模块开发时开放"
            return
        }
        if action == .exportNote || action == .exportBook {
            actionNotice = "\(action.title)将在导出模块迁移时开放"
            return
        }
        actionNotice = "\(action.title)需先完成 Android 数据语义核对后再开放"
    }

    private func startObservation() {
        contentState = .loading
        let context = route.context
        let currentSetting = displaySetting
        let currentKeyword = normalizedSearchKeyword(searchKeyword)
        observationTask = Task {
            do {
                for try await snapshot in repository.observeBookshelfBookList(
                    context: context,
                    setting: currentSetting,
                    searchKeyword: currentKeyword
                ) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = snapshot
                        self.contentState = snapshot.books.isEmpty ? .empty : .content
                        self.pruneSelectionToVisibleBooks()
                    }
                }
            } catch {
                await MainActor.run {
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func restartObservation() {
        observationTask?.cancel()
        startObservation()
    }

    private func normalizedSearchKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedDisplaySetting(_ setting: BookshelfDisplaySetting) -> BookshelfDisplaySetting {
        var sanitized = setting
        let availableCriteria = BookshelfSortCriteria.availableForBookList(for: route.context.dimension)
        if !availableCriteria.contains(sanitized.sortCriteria) {
            sanitized.sortCriteria = BookshelfDisplaySetting.defaultBookListValue(for: route.context.dimension).sortCriteria
        }
        if sanitized.sortCriteria == .custom {
            sanitized.sortOrder = .descending
            sanitized.isSectionEnabled = false
        } else if !sanitized.sortCriteria.supportsSection {
            sanitized.isSectionEnabled = false
        }
        sanitized.pinnedInAllSorts = true
        sanitized.columnCount = max(2, min(sanitized.columnCount, 6))
        return sanitized
    }

    private func pruneSelectionToVisibleBooks() {
        let visibleIDs = Set(visibleBookIDs)
        selectedBookIDs = selectedBookIDs.filter { visibleIDs.contains($0) }
        if visibleIDs.isEmpty {
            isEditing = false
            actionNotice = nil
        }
    }
}
