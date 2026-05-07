/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供二级书籍列表观察流，依赖 BookshelfBookListRoute 描述当前聚合上下文
 * [OUTPUT]: 对外提供 BookshelfBookListViewModel，驱动二级书籍列表加载、空态、搜索、编辑选择与实时刷新
 * [POS]: Book 模块二级书籍列表状态编排器，被 BookshelfBookListView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 二级书籍列表编辑动作，当前只作为 Android 对齐入口占位，真实写入需完成 DAO/SQL 核对后再开放。
enum BookshelfBookListEditAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case moveOut
    case setTag
    case setSource
    case setReadStatus
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
        case .moveOut:
            return "移出"
        case .setTag:
            return "标签"
        case .setSource:
            return "来源"
        case .setReadStatus:
            return "状态"
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
        case .moveOut:
            return "folder.badge.minus"
        case .setTag:
            return "tag"
        case .setSource:
            return "tray"
        case .setReadStatus:
            return "checklist"
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
        case .moveOut, .setTag, .setSource, .setReadStatus, .renameGroup, .renameTag, .renameSource:
            return false
        }
    }

    var requiresSelection: Bool {
        switch self {
        case .moveOut, .setTag, .setSource, .setReadStatus, .deleteBooks:
            return true
        case .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource:
            return false
        }
    }
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

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?

    var navigationTitle: String {
        route.title
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

    var isAllVisibleSelected: Bool {
        let visibleIDs = Set(visibleBookIDs)
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedBookIDSet)
    }

    var canEnterEditing: Bool {
        contentState == .content && !visibleBookIDs.isEmpty
    }

    var editActions: [BookshelfBookListEditAction] {
        switch route.context {
        case .defaultGroup:
            return [.moveOut, .setTag, .setSource, .setReadStatus, .deleteBooks, .renameGroup, .deleteGroup]
        case .tag:
            return [.setTag, .setSource, .setReadStatus, .deleteBooks, .renameTag, .deleteTag]
        case .source:
            return [.setTag, .setSource, .setReadStatus, .deleteBooks, .renameSource, .deleteSource]
        case .readStatus, .rating, .author, .press:
            return [.setTag, .setSource, .setReadStatus, .deleteBooks]
        }
    }

    /// 注入路由和仓储，并启动二级列表观察流。
    init(
        route: BookshelfBookListRoute,
        repository: any BookRepositoryProtocol
    ) {
        self.route = route
        self.repository = repository
        self.displaySetting = .defaultBookListValue(for: route.context.dimension)
        startObservation()
    }

    /// 取消二级列表观察任务。
    deinit {
        observationTask?.cancel()
    }

    /// 清空搜索关键词并恢复完整列表。
    func clearSearchKeyword() {
        searchKeyword = ""
    }

    /// 进入二级列表编辑态，只改变本地选择状态，不触发任何写入。
    func enterEditing() {
        guard canEnterEditing else { return }
        isEditing = true
        actionNotice = nil
        pruneSelectionToVisibleBooks()
    }

    /// 退出二级列表编辑态并清空本地选择。
    func exitEditing() {
        isEditing = false
        selectedBookIDs.removeAll()
        actionNotice = nil
    }

    /// 切换单本书籍的本地选中状态。
    func toggleSelection(_ bookID: Int64) {
        guard isEditing, visibleBookIDs.contains(bookID) else { return }
        if let index = selectedBookIDs.firstIndex(of: bookID) {
            selectedBookIDs.remove(at: index)
        } else {
            selectedBookIDs.append(bookID)
        }
    }

    /// 选择当前可见的全部书籍。
    func selectAllVisible() {
        guard isEditing else { return }
        selectedBookIDs = visibleBookIDs
    }

    /// 反选当前可见书籍，保持选择顺序与列表展示顺序一致。
    func invertVisibleSelection() {
        guard isEditing else { return }
        let selected = selectedBookIDSet
        selectedBookIDs = visibleBookIDs.filter { !selected.contains($0) }
    }

    /// 展示未开放写入动作的保护提示，避免绕过 Android 数据语义核对。
    func performPlaceholderAction(_ action: BookshelfBookListEditAction) {
        if action.requiresSelection, selectedBookIDs.isEmpty {
            actionNotice = "请先选择书籍"
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

    private func pruneSelectionToVisibleBooks() {
        let visibleIDs = Set(visibleBookIDs)
        selectedBookIDs = selectedBookIDs.filter { visibleIDs.contains($0) }
        if visibleIDs.isEmpty {
            isEditing = false
            actionNotice = nil
        }
    }
}
