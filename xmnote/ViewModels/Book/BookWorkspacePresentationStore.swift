/**
 * [INPUT]: 依赖 BookDetail 与单书四域内容模型，接收工作台搜索、加载门闩、筛选、排序和目录展开状态
 * [OUTPUT]: 对外提供可取消的 BookWorkspacePresentationStore、共享 Chrome 占位与稳定业务内容 collection 快照
 * [POS]: Book 模块单书工作台展示派生层，把分组排序移出 SwiftUI/UIKit 热渲染路径，并以 revision 保证最新输入优先
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation
#if DEBUG
import os
#endif

/// 目录域的可见范围筛选。
nonisolated enum CatalogFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case starred
    case withNotes

    var title: String {
        switch self {
        case .all: "全部目录"
        case .starred: "仅收藏"
        case .withNotes: "有书摘"
        }
    }
}

/// 书摘域的阅读顺序。
nonisolated enum NotesSort: String, CaseIterable, Hashable, Sendable {
    case chapter
    case newest

    var title: String {
        switch self {
        case .chapter: "按章节"
        case .newest: "最近记录"
        }
    }
}

/// 书评域的时间顺序。
nonisolated enum ReviewSort: String, CaseIterable, Hashable, Sendable {
    case newest
    case oldest

    var title: String {
        switch self {
        case .newest: "最新优先"
        case .oldest: "最早优先"
        }
    }
}

/// Collection section 的稳定业务身份。
nonisolated enum BookWorkspaceCollectionSectionID: Hashable, Sendable {
    case chrome
    case catalog
    case notesChapter(Int64)
    case relatedCategory(Int64)
    case reviews
    case empty(BookWorkspaceSection)
}

/// Collection item 的稳定业务身份；禁止使用数组下标参与身份。
nonisolated enum BookWorkspaceCollectionItemID: Hashable, Sendable {
    case chromeSpacer
    case catalog(Int64)
    case note(Int64)
    case related(Int64)
    case review(Int64)
    case empty(BookWorkspaceSection)
}

/// 页面四域使用的布局语义，UIKit layout 只消费语义而不理解业务模型。
nonisolated enum BookWorkspaceCollectionSectionStyle: Hashable, Sendable {
    case chrome
    case groupedRows
    case noteCards
    case empty
}

/// 分区标题展示模型，章节标题可选择原生粘性行为。
nonisolated struct BookWorkspaceCollectionHeader: Hashable, Sendable {
    let title: String
    let count: Int
    let isStarred: Bool
    let isPinned: Bool
}

/// 目录行展示模型，预先计算层级、子节点和拼接位置。
nonisolated struct BookWorkspaceCatalogRow: Hashable, Sendable {
    let chapter: BookDetailChapter
    let hasChildren: Bool
    let isExpanded: Bool
    let isFirst: Bool
    let isLast: Bool
}

/// 书摘行展示模型，元信息在快照阶段完成格式化。
nonisolated struct BookWorkspaceNoteRow: Hashable, Sendable {
    let note: NoteExcerpt
    let footerText: String
}

/// 相关内容行展示模型。
nonisolated struct BookWorkspaceRelatedRow: Hashable, Sendable {
    let item: BookRelatedExcerpt
    let dateText: String
    let isFirst: Bool
    let isLast: Bool
}

/// 书评行展示模型。
nonisolated struct BookWorkspaceReviewRow: Hashable, Sendable {
    let item: BookReviewExcerpt
    let dateText: String
    let isFirst: Bool
    let isLast: Bool
}

/// 空态展示模型。
nonisolated struct BookWorkspaceEmptyRow: Hashable, Sendable {
    let title: String
    let systemImage: String
    let description: String
}

/// 单条 Collection item 的不可变展示载荷。
nonisolated enum BookWorkspaceCollectionItem: Hashable, Sendable {
    case chromeSpacer
    case catalog(BookWorkspaceCatalogRow)
    case note(BookWorkspaceNoteRow)
    case related(BookWorkspaceRelatedRow)
    case review(BookWorkspaceReviewRow)
    case empty(BookWorkspaceEmptyRow)
}

/// 一个原生 Collection section 的完整展示描述。
nonisolated struct BookWorkspaceCollectionSectionModel: Hashable, Sendable {
    let id: BookWorkspaceCollectionSectionID
    let style: BookWorkspaceCollectionSectionStyle
    let header: BookWorkspaceCollectionHeader?
    let itemIDs: [BookWorkspaceCollectionItemID]
}

/// 单个内容域的不可变展示快照。
nonisolated struct BookWorkspacePresentationSnapshot: Sendable {
    let revision: Int
    let sections: [BookWorkspaceCollectionSectionModel]
    let itemsByID: [BookWorkspaceCollectionItemID: BookWorkspaceCollectionItem]

    static func initial(for section: BookWorkspaceSection) -> Self {
        if section == .notes {
            return placeholder(for: section)
        }
        return Self(
            revision: 0,
            sections: [chromeSection(),
                BookWorkspaceCollectionSectionModel(
                    id: .empty(section),
                    style: .empty,
                    header: nil,
                    itemIDs: [.empty(section)]
                )
            ],
            itemsByID: [
                .chromeSpacer: .chromeSpacer,
                .empty(section): .empty(
                    BookWorkspaceEmptyRow(
                        title: "正在整理内容",
                        systemImage: "ellipsis",
                        description: ""
                    )
                )
            ]
        )
    }

    /// 为尚未达到读取反馈阈值的内容域只保留共享 Chrome 占位，不提前显示伪 loading 文案。
    static func placeholder(for section: BookWorkspaceSection) -> Self {
        Self(
            revision: 0,
            sections: [chromeSection()],
            itemsByID: [.chromeSpacer: .chromeSpacer]
        )
    }

    /// 只为共享头部与 Tab 提供滚动空间；实际 Chrome 由 Pager 宿主唯一渲染。
    nonisolated static func chromeSection() -> BookWorkspaceCollectionSectionModel {
        BookWorkspaceCollectionSectionModel(
            id: .chrome,
            style: .chrome,
            header: nil,
            itemIDs: [.chromeSpacer]
        )
    }
}

/// 单条书摘独立的可观察展开状态，避免父页面 Set 变化使所有可见行重新计算。
@Observable
@MainActor
final class BookWorkspaceNoteRowState {
    var isContentExpanded = false {
        didSet {
            guard oldValue != isContentExpanded else { return }
            onExpansionChange?()
        }
    }
    var isIdeaExpanded = false {
        didSet {
            guard oldValue != isIdeaExpanded else { return }
            onExpansionChange?()
        }
    }
    @ObservationIgnored var onExpansionChange: (() -> Void)?
}

/// 页面全部展示输入；值语义让状态源能够只重建发生变化的内容域。
nonisolated struct BookWorkspacePresentationInput: Hashable, Sendable {
    let book: BookDetail
    let notes: [NoteExcerpt]
    let notesLoadState: BookNotesLoadState
    let isNotesLoadingFeedbackVisible: Bool
    let relatedCategories: [BookRelatedCategory]
    let related: [BookRelatedExcerpt]
    let reviews: [BookReviewExcerpt]
    let catalogQuery: String
    let notesQuery: String
    let relatedQuery: String
    let reviewsQuery: String
    let catalogFilter: CatalogFilter
    let notesSort: NotesSort
    let notesWithIdeasOnly: Bool
    let selectedRelatedCategoryID: Int64?
    let reviewSort: ReviewSort
    let expandedChapterIDs: Set<Int64>
}

/// 单书工作台的派生展示状态源；构建任务可取消，发布始终回到 MainActor。
@Observable
@MainActor
final class BookWorkspacePresentationStore {
#if DEBUG
    private static let notesLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "BookWorkspaceNotes"
    )
    private let debugIdentifier = UUID().uuidString
#endif

    private(set) var catalogSnapshot = BookWorkspacePresentationSnapshot.initial(for: .catalog)
    private(set) var notesSnapshot = BookWorkspacePresentationSnapshot.initial(for: .notes)
    private(set) var relatedSnapshot = BookWorkspacePresentationSnapshot.initial(for: .related)
    private(set) var reviewsSnapshot = BookWorkspacePresentationSnapshot.initial(for: .reviews)

    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var notesTask: Task<Void, Never>?
    @ObservationIgnored private var relatedTask: Task<Void, Never>?
    @ObservationIgnored private var reviewsTask: Task<Void, Never>?
    @ObservationIgnored private var catalogRevision = 0
    @ObservationIgnored private var notesRevision = 0
    @ObservationIgnored private var relatedRevision = 0
    @ObservationIgnored private var reviewsRevision = 0
    @ObservationIgnored private var previousInput: BookWorkspacePresentationInput?
    @ObservationIgnored private var noteRowStates: [Int64: BookWorkspaceNoteRowState] = [:]
    @ObservationIgnored private var nextRevision = 1
    @ObservationIgnored private var currentBookID: Int64?

    /// 返回指定内容域最新已发布快照。
    func snapshot(for section: BookWorkspaceSection) -> BookWorkspacePresentationSnapshot {
        switch section {
        case .catalog: catalogSnapshot
        case .notes: notesSnapshot
        case .related: relatedSnapshot
        case .reviews: reviewsSnapshot
        }
    }

    /// 返回 Note ID 唯一的行状态 owner，Cell 回收和排序后仍复用同一引用。
    func rowState(for noteID: Int64) -> BookWorkspaceNoteRowState {
        if let state = noteRowStates[noteID] {
            return state
        }
        let state = BookWorkspaceNoteRowState()
        noteRowStates[noteID] = state
        return state
    }

    /// 比较四域输入并只调度真实变化的派生任务；搜索变化使用 150ms 去抖。
    func update(with input: BookWorkspacePresentationInput) {
        let previous = previousInput
        previousInput = input
        currentBookID = input.book.id
        pruneRowStates(validIDs: Set(input.notes.map(\.id)))

        let catalogChanged = previous.map {
            $0.book.chapters != input.book.chapters
                || $0.catalogQuery != input.catalogQuery
                || $0.catalogFilter != input.catalogFilter
                || $0.expandedChapterIDs != input.expandedChapterIDs
        } ?? true
        if catalogChanged {
            catalogRevision &+= 1
            scheduleCatalog(
                input,
                debouncesSearch: previous.map { $0.catalogQuery != input.catalogQuery } ?? false,
                revision: catalogRevision
            )
        }

        let notesChanged = previous.map {
            $0.notes != input.notes
                || $0.notesLoadState != input.notesLoadState
                || $0.isNotesLoadingFeedbackVisible != input.isNotesLoadingFeedbackVisible
                || $0.book.chapters != input.book.chapters
                || $0.notesQuery != input.notesQuery
                || $0.notesSort != input.notesSort
                || $0.notesWithIdeasOnly != input.notesWithIdeasOnly
        } ?? true
        if notesChanged {
            notesRevision &+= 1
#if DEBUG
            Self.notesLogger.debug(
                "[book.workspace.notes.store.received] host=\(self.debugIdentifier, privacy: .public) bookID=\(input.book.id) state=\(input.notesLoadState.rawValue, privacy: .public) count=\(input.notes.count) loadingVisible=\(input.isNotesLoadingFeedbackVisible) revision=\(self.notesRevision)"
            )
#endif
            scheduleNotes(
                input,
                debouncesSearch: previous.map { $0.notesQuery != input.notesQuery } ?? false,
                revision: notesRevision
            )
        }

        let relatedChanged = previous.map {
            $0.related != input.related
                || $0.relatedCategories != input.relatedCategories
                || $0.relatedQuery != input.relatedQuery
                || $0.selectedRelatedCategoryID != input.selectedRelatedCategoryID
        } ?? true
        if relatedChanged {
            relatedRevision &+= 1
            scheduleRelated(
                input,
                debouncesSearch: previous.map { $0.relatedQuery != input.relatedQuery } ?? false,
                revision: relatedRevision
            )
        }

        let reviewsChanged = previous.map {
            $0.reviews != input.reviews
                || $0.reviewsQuery != input.reviewsQuery
                || $0.reviewSort != input.reviewSort
        } ?? true
        if reviewsChanged {
            reviewsRevision &+= 1
            scheduleReviews(
                input,
                debouncesSearch: previous.map { $0.reviewsQuery != input.reviewsQuery } ?? false,
                revision: reviewsRevision
            )
        }
    }

    /// 取消全部派生任务并清空输入基线；重新出现后同一输入也会重新建立最新快照。
    func stop() {
        catalogTask?.cancel()
        notesTask?.cancel()
        relatedTask?.cancel()
        reviewsTask?.cancel()
        catalogTask = nil
        notesTask = nil
        relatedTask = nil
        reviewsTask = nil
        catalogRevision &+= 1
        notesRevision &+= 1
        relatedRevision &+= 1
        reviewsRevision &+= 1
        previousInput = nil
#if DEBUG
        Self.notesLogger.debug(
            "[book.workspace.notes.store.stopped] host=\(self.debugIdentifier, privacy: .public) bookID=\(self.currentBookID ?? 0) revision=\(self.notesRevision)"
        )
#endif
    }

    private func scheduleCatalog(
        _ input: BookWorkspacePresentationInput,
        debouncesSearch: Bool,
        revision: Int
    ) {
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            if debouncesSearch {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.makeCatalogSnapshot(input)
            }.value
            guard !Task.isCancelled, let self, self.catalogRevision == revision else { return }
            self.catalogSnapshot = self.publishing(snapshot)
        }
    }

    private func scheduleNotes(
        _ input: BookWorkspacePresentationInput,
        debouncesSearch: Bool,
        revision: Int
    ) {
#if DEBUG
        let cancelsPreviousTask = notesTask != nil
#endif
        notesTask?.cancel()
#if DEBUG
        if cancelsPreviousTask {
            Self.notesLogger.debug(
                "[book.workspace.notes.snapshot.cancel.requested] host=\(self.debugIdentifier, privacy: .public) bookID=\(input.book.id) state=\(input.notesLoadState.rawValue, privacy: .public) count=\(input.notes.count) revision=\(revision)"
            )
        }
        Self.notesLogger.debug(
            "[book.workspace.notes.snapshot.scheduled] host=\(self.debugIdentifier, privacy: .public) bookID=\(input.book.id) state=\(input.notesLoadState.rawValue, privacy: .public) count=\(input.notes.count) debounce=\(debouncesSearch) revision=\(revision)"
        )
#endif
        notesTask = Task { [weak self] in
            if debouncesSearch {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.makeNotesSnapshot(input)
            }.value
            guard !Task.isCancelled, let self, self.notesRevision == revision else {
#if DEBUG
                if let self {
                    Self.notesLogger.debug(
                        "[book.workspace.notes.snapshot.discarded] host=\(self.debugIdentifier, privacy: .public) bookID=\(input.book.id) state=\(input.notesLoadState.rawValue, privacy: .public) count=\(input.notes.count) revision=\(revision) current=\(self.notesRevision) cancelled=\(Task.isCancelled)"
                    )
                }
#endif
                return
            }
            let publishedSnapshot = self.publishing(snapshot)
            self.notesSnapshot = publishedSnapshot
            self.notesTask = nil
#if DEBUG
            let noteItemCount = publishedSnapshot.itemsByID.keys.reduce(into: 0) { count, itemID in
                if case .note = itemID {
                    count += 1
                }
            }
            Self.notesLogger.debug(
                "[book.workspace.notes.snapshot.published] host=\(self.debugIdentifier, privacy: .public) bookID=\(input.book.id) state=\(input.notesLoadState.rawValue, privacy: .public) source=\(input.notes.count) items=\(noteItemCount) revision=\(revision)"
            )
#endif
        }
    }

    private func scheduleRelated(
        _ input: BookWorkspacePresentationInput,
        debouncesSearch: Bool,
        revision: Int
    ) {
        relatedTask?.cancel()
        relatedTask = Task { [weak self] in
            if debouncesSearch {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.makeRelatedSnapshot(input)
            }.value
            guard !Task.isCancelled, let self, self.relatedRevision == revision else { return }
            self.relatedSnapshot = self.publishing(snapshot)
        }
    }

    private func scheduleReviews(
        _ input: BookWorkspacePresentationInput,
        debouncesSearch: Bool,
        revision: Int
    ) {
        reviewsTask?.cancel()
        reviewsTask = Task { [weak self] in
            if debouncesSearch {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.makeReviewsSnapshot(input)
            }.value
            guard !Task.isCancelled, let self, self.reviewsRevision == revision else { return }
            self.reviewsSnapshot = self.publishing(snapshot)
        }
    }

    private func publishing(_ snapshot: BookWorkspacePresentationSnapshot) -> BookWorkspacePresentationSnapshot {
        defer { nextRevision += 1 }
        return BookWorkspacePresentationSnapshot(
            revision: nextRevision,
            sections: snapshot.sections,
            itemsByID: snapshot.itemsByID
        )
    }

    private func pruneRowStates(validIDs: Set<Int64>) {
        noteRowStates = noteRowStates.filter { validIDs.contains($0.key) }
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func makeCatalogSnapshot(
        _ input: BookWorkspacePresentationInput
    ) -> BookWorkspacePresentationSnapshot {
        let keyword = normalized(input.catalogQuery)
        let allChapters = input.book.chapters
        let filtered = allChapters.filter { chapter in
            let matchesKeyword = keyword.isEmpty || chapter.title.localizedCaseInsensitiveContains(keyword)
            let matchesFilter: Bool
            switch input.catalogFilter {
            case .all: matchesFilter = true
            case .starred: matchesFilter = chapter.isStarred
            case .withNotes: matchesFilter = chapter.noteCount > 0
            }
            return matchesKeyword && matchesFilter
        }
        let visible = visibleChapters(filtered, expandedIDs: input.expandedChapterIDs)
        var items: [BookWorkspaceCollectionItemID: BookWorkspaceCollectionItem] = [
            .chromeSpacer: .chromeSpacer
        ]
        let contentIDs: [BookWorkspaceCollectionItemID]
        let contentSection: BookWorkspaceCollectionSectionModel

        if visible.isEmpty {
            let empty = BookWorkspaceEmptyRow(
                title: keyword.isEmpty ? "暂无目录" : "没有匹配的目录",
                systemImage: "list.bullet.indent",
                description: "目录同步或创建后会显示在这里。"
            )
            items[.empty(.catalog)] = .empty(empty)
            contentIDs = [.empty(.catalog)]
            contentSection = BookWorkspaceCollectionSectionModel(
                id: .empty(.catalog), style: .empty, header: nil, itemIDs: contentIDs
            )
        } else {
            let childParentIDs = Set(allChapters.filter { $0.parentID != 0 }.map(\.parentID))
            contentIDs = visible.map { .catalog($0.id) }
            for (index, chapter) in visible.enumerated() {
                items[.catalog(chapter.id)] = .catalog(
                    BookWorkspaceCatalogRow(
                        chapter: chapter,
                        hasChildren: childParentIDs.contains(chapter.id),
                        isExpanded: input.expandedChapterIDs.contains(chapter.id),
                        isFirst: index == visible.startIndex,
                        isLast: index == visible.index(before: visible.endIndex)
                    )
                )
            }
            contentSection = BookWorkspaceCollectionSectionModel(
                id: .catalog, style: .groupedRows, header: nil, itemIDs: contentIDs
            )
        }
        return BookWorkspacePresentationSnapshot(
            revision: 0,
            sections: [BookWorkspacePresentationSnapshot.chromeSection(), contentSection],
            itemsByID: items
        )
    }

    nonisolated private static func makeNotesSnapshot(
        _ input: BookWorkspacePresentationInput
    ) -> BookWorkspacePresentationSnapshot {
        switch input.notesLoadState {
        case .loading:
            guard input.isNotesLoadingFeedbackVisible else {
                return BookWorkspacePresentationSnapshot.placeholder(for: .notes)
            }
            return makeEmptySnapshot(
                for: .notes,
                title: "正在整理内容",
                systemImage: "ellipsis",
                description: ""
            )
        case .failed:
            return makeEmptySnapshot(
                for: .notes,
                title: "书摘加载失败",
                systemImage: "exclamationmark.triangle",
                description: "暂时无法读取书摘，请稍后再试。"
            )
        case .loaded:
            if input.isNotesLoadingFeedbackVisible {
                return makeEmptySnapshot(
                    for: .notes,
                    title: "正在整理内容",
                    systemImage: "ellipsis",
                    description: ""
                )
            }
        }

        let keyword = normalized(input.notesQuery)
        var notes = input.notes.filter { note in
            let matchesKeyword = keyword.isEmpty
                || note.searchableContentText.localizedCaseInsensitiveContains(keyword)
                || note.searchableIdeaText.localizedCaseInsensitiveContains(keyword)
                || note.chapterTitle.localizedCaseInsensitiveContains(keyword)
                || note.tagNames.contains { $0.localizedCaseInsensitiveContains(keyword) }
            return matchesKeyword && (!input.notesWithIdeasOnly || note.hasSourceIdea)
        }

        var items: [BookWorkspaceCollectionItemID: BookWorkspaceCollectionItem] = [
            .chromeSpacer: .chromeSpacer
        ]
        guard !notes.isEmpty else {
            return makeEmptySnapshot(
                for: .notes,
                title: keyword.isEmpty ? "还没有书摘" : "没有匹配的书摘",
                systemImage: "text.quote",
                description: "记录一句触动你的内容，稍后会按章节整理在这里。"
            )
        }

        let formatter = makeDateFormatter(pattern: "yyyy/MM/dd")
        if input.notesSort == .newest {
            notes.sort(by: noteComesBefore)
            let ids = notes.map { note -> BookWorkspaceCollectionItemID in
                let id = BookWorkspaceCollectionItemID.note(note.id)
                items[id] = .note(BookWorkspaceNoteRow(note: note, footerText: noteFooter(note, formatter: formatter)))
                return id
            }
            return BookWorkspacePresentationSnapshot(
                revision: 0,
                sections: [BookWorkspacePresentationSnapshot.chromeSection(),
                    BookWorkspaceCollectionSectionModel(
                        id: .notesChapter(-1),
                        style: .noteCards,
                        header: BookWorkspaceCollectionHeader(
                            title: "最近记录", count: notes.count, isStarred: false, isPinned: false
                        ),
                        itemIDs: ids
                    )
                ],
                itemsByID: items
            )
        }

        let chapterByID = Dictionary(uniqueKeysWithValues: input.book.chapters.map { ($0.id, $0) })
        let validChapterIDs = Set(chapterByID.keys)
        let order = chapterReadingOrder(input.book.chapters)
        let grouped = Dictionary(grouping: notes) { note in
            validChapterIDs.contains(note.chapterID) ? note.chapterID : 0
        }
        let orderedGroups = grouped.map { chapterID, children in
            (chapterID, chapterByID[chapterID], children.sorted(by: noteComesBefore))
        }.sorted { lhs, rhs in
            if lhs.0 == 0 { return false }
            if rhs.0 == 0 { return true }
            let left = order[lhs.0] ?? Int.max
            let right = order[rhs.0] ?? Int.max
            return left == right ? lhs.0 < rhs.0 : left < right
        }
        let sections = orderedGroups.map { chapterID, chapter, children in
            let ids = children.map { note -> BookWorkspaceCollectionItemID in
                let id = BookWorkspaceCollectionItemID.note(note.id)
                items[id] = .note(BookWorkspaceNoteRow(note: note, footerText: noteFooter(note, formatter: formatter)))
                return id
            }
            return BookWorkspaceCollectionSectionModel(
                id: .notesChapter(chapterID),
                style: .noteCards,
                header: BookWorkspaceCollectionHeader(
                    title: chapter?.title ?? "未指定章节",
                    count: children.count,
                    isStarred: chapter?.isStarred ?? false,
                    isPinned: true
                ),
                itemIDs: ids
            )
        }
        return BookWorkspacePresentationSnapshot(
            revision: 0,
            sections: [BookWorkspacePresentationSnapshot.chromeSection()] + sections,
            itemsByID: items
        )
    }

    nonisolated private static func makeEmptySnapshot(
        for section: BookWorkspaceSection,
        title: String,
        systemImage: String,
        description: String
    ) -> BookWorkspacePresentationSnapshot {
        var items: [BookWorkspaceCollectionItemID: BookWorkspaceCollectionItem] = [
            .chromeSpacer: .chromeSpacer
        ]
        items[.empty(section)] = .empty(
            BookWorkspaceEmptyRow(
                title: title,
                systemImage: systemImage,
                description: description
            )
        )
        return BookWorkspacePresentationSnapshot(
            revision: 0,
            sections: [BookWorkspacePresentationSnapshot.chromeSection(),
                BookWorkspaceCollectionSectionModel(
                    id: .empty(section), style: .empty, header: nil, itemIDs: [.empty(section)]
                )
            ],
            itemsByID: items
        )
    }

    nonisolated private static func makeRelatedSnapshot(
        _ input: BookWorkspacePresentationInput
    ) -> BookWorkspacePresentationSnapshot {
        let keyword = normalized(input.relatedQuery)
        let filtered = input.related.filter { item in
            let matchesCategory = input.selectedRelatedCategoryID == nil
                || item.categoryID == input.selectedRelatedCategoryID
            let matchesKeyword = keyword.isEmpty
                || item.title.localizedCaseInsensitiveContains(keyword)
                || item.contentPlainText.localizedCaseInsensitiveContains(keyword)
                || item.linkedBookTitle.localizedCaseInsensitiveContains(keyword)
                || item.linkedBookAuthor.localizedCaseInsensitiveContains(keyword)
            return matchesCategory && matchesKeyword
        }
        var items: [BookWorkspaceCollectionItemID: BookWorkspaceCollectionItem] = [
            .chromeSpacer: .chromeSpacer
        ]
        guard !filtered.isEmpty else {
            items[.empty(.related)] = .empty(
                BookWorkspaceEmptyRow(
                    title: keyword.isEmpty ? "还没有相关内容" : "没有匹配的相关内容",
                    systemImage: "link",
                    description: "把文章、观点或关联书籍整理到当前书中。"
                )
            )
            return BookWorkspacePresentationSnapshot(
                revision: 0,
                sections: [BookWorkspacePresentationSnapshot.chromeSection(),
                    BookWorkspaceCollectionSectionModel(
                        id: .empty(.related), style: .empty, header: nil, itemIDs: [.empty(.related)]
                    )
                ],
                itemsByID: items
            )
        }

        let orderByID = Dictionary(uniqueKeysWithValues: input.relatedCategories.map { ($0.id, $0.order) })
        let groups = Dictionary(grouping: filtered, by: \.categoryID).map { categoryID, children in
            (categoryID, children)
        }.sorted { lhs, rhs in
            let left = orderByID[lhs.0] ?? Int64.max
            let right = orderByID[rhs.0] ?? Int64.max
            return left == right ? lhs.0 < rhs.0 : left < right
        }
        let formatter = makeDateFormatter(pattern: "yyyy-MM-dd")
        let sections = groups.map { categoryID, children in
            let ids = children.enumerated().map { index, item -> BookWorkspaceCollectionItemID in
                let id = BookWorkspaceCollectionItemID.related(item.id)
                items[id] = .related(
                    BookWorkspaceRelatedRow(
                        item: item,
                        dateText: formattedDate(item.createdDate, formatter: formatter),
                        isFirst: index == children.startIndex,
                        isLast: index == children.index(before: children.endIndex)
                    )
                )
                return id
            }
            let title = children.first?.categoryTitle.isEmpty == false
                ? (children.first?.categoryTitle ?? "")
                : "未分类"
            return BookWorkspaceCollectionSectionModel(
                id: .relatedCategory(categoryID),
                style: .groupedRows,
                header: BookWorkspaceCollectionHeader(
                    title: title, count: children.count, isStarred: false, isPinned: false
                ),
                itemIDs: ids
            )
        }
        return BookWorkspacePresentationSnapshot(
            revision: 0,
            sections: [BookWorkspacePresentationSnapshot.chromeSection()] + sections,
            itemsByID: items
        )
    }

    nonisolated private static func makeReviewsSnapshot(
        _ input: BookWorkspacePresentationInput
    ) -> BookWorkspacePresentationSnapshot {
        let keyword = normalized(input.reviewsQuery)
        let filtered = input.reviews.filter { item in
            keyword.isEmpty
                || item.title.localizedCaseInsensitiveContains(keyword)
                || item.contentPlainText.localizedCaseInsensitiveContains(keyword)
        }.sorted { lhs, rhs in
            if input.reviewSort == .newest {
                return lhs.createdDate == rhs.createdDate ? lhs.id > rhs.id : lhs.createdDate > rhs.createdDate
            }
            return lhs.createdDate == rhs.createdDate ? lhs.id < rhs.id : lhs.createdDate < rhs.createdDate
        }
        var items: [BookWorkspaceCollectionItemID: BookWorkspaceCollectionItem] = [
            .chromeSpacer: .chromeSpacer
        ]
        guard !filtered.isEmpty else {
            items[.empty(.reviews)] = .empty(
                BookWorkspaceEmptyRow(
                    title: keyword.isEmpty ? "还没有书评" : "没有匹配的书评",
                    systemImage: "text.bubble",
                    description: "写下对整本书的判断、收获与推荐理由。"
                )
            )
            return BookWorkspacePresentationSnapshot(
                revision: 0,
                sections: [BookWorkspacePresentationSnapshot.chromeSection(),
                    BookWorkspaceCollectionSectionModel(
                        id: .empty(.reviews), style: .empty, header: nil, itemIDs: [.empty(.reviews)]
                    )
                ],
                itemsByID: items
            )
        }

        let formatter = makeDateFormatter(pattern: "yyyy-MM-dd")
        let ids = filtered.enumerated().map { index, item -> BookWorkspaceCollectionItemID in
            let id = BookWorkspaceCollectionItemID.review(item.id)
            items[id] = .review(
                BookWorkspaceReviewRow(
                    item: item,
                    dateText: formattedDate(item.createdDate, formatter: formatter),
                    isFirst: index == filtered.startIndex,
                    isLast: index == filtered.index(before: filtered.endIndex)
                )
            )
            return id
        }
        return BookWorkspacePresentationSnapshot(
            revision: 0,
            sections: [BookWorkspacePresentationSnapshot.chromeSection(),
                BookWorkspaceCollectionSectionModel(
                    id: .reviews, style: .groupedRows, header: nil, itemIDs: ids
                )
            ],
            itemsByID: items
        )
    }

    nonisolated private static func visibleChapters(
        _ chapters: [BookDetailChapter],
        expandedIDs: Set<Int64>
    ) -> [BookDetailChapter] {
        let ids = Set(chapters.map(\.id))
        let children = Dictionary(grouping: chapters, by: \.parentID)
        let roots = chapters.filter { $0.parentID == 0 || !ids.contains($0.parentID) }
        var result: [BookDetailChapter] = []
        var visited: Set<Int64> = []

        func append(_ chapter: BookDetailChapter) {
            guard visited.insert(chapter.id).inserted else { return }
            result.append(chapter)
            guard expandedIDs.contains(chapter.id) else { return }
            children[chapter.id, default: []].sorted(by: chapterComesBefore).forEach(append)
        }

        roots.sorted(by: chapterComesBefore).forEach(append)
        chapters.sorted(by: chapterComesBefore).forEach { chapter in
            if !visited.contains(chapter.id), chapter.parentID == 0 || !ids.contains(chapter.parentID) {
                append(chapter)
            }
        }
        return result
    }

    nonisolated private static func chapterReadingOrder(
        _ chapters: [BookDetailChapter]
    ) -> [Int64: Int] {
        let ids = Set(chapters.map(\.id))
        let children = Dictionary(grouping: chapters, by: \.parentID)
        let roots = chapters.filter { $0.parentID == 0 || !ids.contains($0.parentID) }
        var result: [Int64: Int] = [:]

        func append(_ chapter: BookDetailChapter) {
            guard result[chapter.id] == nil else { return }
            result[chapter.id] = result.count
            children[chapter.id, default: []].sorted(by: chapterComesBefore).forEach(append)
        }

        roots.sorted(by: chapterComesBefore).forEach(append)
        chapters.sorted(by: chapterComesBefore).forEach(append)
        return result
    }

    nonisolated private static func chapterComesBefore(
        _ lhs: BookDetailChapter,
        _ rhs: BookDetailChapter
    ) -> Bool {
        lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
    }

    nonisolated private static func noteComesBefore(_ lhs: NoteExcerpt, _ rhs: NoteExcerpt) -> Bool {
        lhs.createdDate == rhs.createdDate ? lhs.id > rhs.id : lhs.createdDate > rhs.createdDate
    }

    nonisolated private static func makeDateFormatter(pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        return formatter
    }

    nonisolated private static func formattedDate(
        _ timestamp: Int64,
        formatter: DateFormatter
    ) -> String {
        guard timestamp > 0 else { return "" }
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000))
    }

    nonisolated private static func noteFooter(
        _ note: NoteExcerpt,
        formatter: DateFormatter
    ) -> String {
        var parts: [String] = []
        if let position = NotePositionUnitFormatter.footerText(
            position: note.position,
            unit: note.positionUnit
        ) {
            parts.append(position)
        }
        if note.includeTime {
            let date = formattedDate(note.createdDate, formatter: formatter)
            if !date.isEmpty {
                parts.append(date)
            }
        }
        return parts.joined(separator: " | ")
    }

    isolated deinit {
        catalogTask?.cancel()
        notesTask?.cancel()
        relatedTask?.cancel()
        reviewsTask?.cancel()
    }
}
