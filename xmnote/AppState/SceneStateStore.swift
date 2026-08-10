import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 SwiftUI NavigationPath/SceneStorage 语义与各模块可编码路由/状态快照
 * [OUTPUT]: 对外提供 SceneStateStore 与 AppSceneSnapshot，承接 scene 级轻量恢复
 * [POS]: AppState 模块的 scene 状态容器，统一管理根导航、根容器与高价值页面的恢复锚点
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// SceneStateStore 负责维护当前 scene 的轻量恢复状态，并同步为可持久化快照。
@MainActor
@Observable
final class SceneStateStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private(set) var snapshot: AppSceneSnapshot
    private(set) var persistedData: Data?
    private(set) var isRestored = false

    init() {
        snapshot = AppSceneSnapshot.empty(dataEpoch: 0)
    }

    /// 以当前数据版本创建空白 scene 会话；用于冷启动固定回到默认根入口，不读取历史 UI 快照。
    func startFreshSession(dataEpoch: Int) {
        replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: dataEpoch), persist: false)
        persistedData = nil
        isRestored = true
    }

    /// 从 SceneStorage 恢复快照；当快照版本或数据 epoch 不匹配时安全回到对应数据世界的默认根入口。
    func restore(from data: Data?, currentDataEpoch: Int) {
        guard let data else {
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            isRestored = true
            return
        }

        guard let restored = try? Self.decoder.decode(AppSceneSnapshot.self, from: data),
              restored.snapshotVersion == AppSceneSnapshot.currentVersion,
              restored.dataEpoch == currentDataEpoch else {
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            isRestored = true
            return
        }

        replaceSnapshot(restored, persist: false)
        persistedData = data
        isRestored = true
    }

    /// 数据世界发生切换时重置 scene 恢复状态，避免旧导航映射到新数据集。
    func resetForDataEpoch(_ dataEpoch: Int) {
        replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: dataEpoch), persist: true)
        isRestored = true
    }

    func updateSelectedTab(_ tab: AppTab) {
        mutate { $0.selectedTab = tab }
    }

    func updateSearchQuery(_ query: String) {
        mutate { $0.searchQuery = query }
    }

    func updatePath(_ path: NavigationPath, for tab: AppTab) {
        if let representation = path.codable {
            updatePathRepresentation(representation, for: tab)
            return
        }

        if path.isEmpty {
            updatePathRepresentation(nil, for: tab)
            return
        }

#if DEBUG
        print("[SceneStateStore] skip persist non-codable path tab=\(tab.rawValue)")
#endif
    }

    func pathRepresentation(for tab: AppTab) -> NavigationPath.CodableRepresentation? {
        switch tab {
        case .reading:
            snapshot.navigation.reading
        case .books:
            snapshot.navigation.books
        case .notes:
            snapshot.navigation.notes
        case .profile:
            snapshot.navigation.profile
        case .search:
            snapshot.navigation.search
        }
    }

    func updateReadingSelectedSubTab(_ tab: ReadingSubTab) {
        mutate { $0.reading.selectedSubTab = tab }
    }

    func updateBookSelectedSubTab(_ tab: BookSubTab) {
        mutate { $0.books.selectedSubTab = tab }
    }

    func updateNoteSelectedSubTab(_ tab: NoteSubTab) {
        mutate { $0.notes.selectedSubTab = tab }
    }

    /// 更新笔记首页完整语义快照；与当前值一致时由 mutate 阻止重复编码和落盘。
    func updateNotes(_ notes: NotesSceneSnapshot) {
        mutate { $0.notes = notes }
    }

    func updateTimeline(_ timeline: TimelineSceneSnapshot?) {
        mutate { $0.reading.timeline = timeline }
    }

    func updateReadCalendar(_ readCalendar: ReadCalendarSceneSnapshot?) {
        mutate { $0.reading.readCalendar = readCalendar }
    }

    func updateBookSearch(_ bookSearch: BookSearchSceneSnapshot?) {
        mutate { $0.books.search = bookSearch }
    }

    /// 更新通用内容查看器的选中锚点，供退出重进后恢复到同一内容。
    func updateContentViewer(_ contentViewer: ContentViewerSceneSnapshot?) {
        mutate { $0.contentViewer = contentViewer }
    }

    private func mutate(_ mutate: (inout AppSceneSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        replaceSnapshot(next, persist: true)
    }

    private func updatePathRepresentation(_ representation: NavigationPath.CodableRepresentation?, for tab: AppTab) {
        mutate {
            switch tab {
            case .reading:
                $0.navigation.reading = representation
            case .books:
                $0.navigation.books = representation
            case .notes:
                $0.navigation.notes = representation
            case .profile:
                $0.navigation.profile = representation
            case .search:
                $0.navigation.search = representation
            }
        }
    }

    private func replaceSnapshot(_ newSnapshot: AppSceneSnapshot, persist: Bool) {
        snapshot = newSnapshot
        if persist {
            persistedData = try? Self.encoder.encode(newSnapshot)
        }
    }
}

/// AppSceneSnapshot 是单个 scene 的轻量恢复快照，只保存高价值语义锚点。
struct AppSceneSnapshot: Codable, Equatable {
    static let currentVersion = 2

    var snapshotVersion: Int
    var dataEpoch: Int
    var selectedTab: AppTab
    var searchQuery: String
    var navigation: NavigationSceneSnapshot
    var reading: ReadingSceneSnapshot
    var books: BooksSceneSnapshot
    var notes: NotesSceneSnapshot
    var contentViewer: ContentViewerSceneSnapshot?

    static func empty(dataEpoch: Int) -> AppSceneSnapshot {
        AppSceneSnapshot(
            snapshotVersion: currentVersion,
            dataEpoch: dataEpoch,
            selectedTab: .reading,
            searchQuery: "",
            navigation: NavigationSceneSnapshot(),
            reading: ReadingSceneSnapshot(),
            books: BooksSceneSnapshot(),
            notes: NotesSceneSnapshot(),
            contentViewer: nil
        )
    }
}

struct NavigationSceneSnapshot: Codable, Equatable {
    var reading: NavigationPath.CodableRepresentation?
    var books: NavigationPath.CodableRepresentation?
    var notes: NavigationPath.CodableRepresentation?
    var profile: NavigationPath.CodableRepresentation?
    var search: NavigationPath.CodableRepresentation?
}

struct ReadingSceneSnapshot: Codable, Equatable {
    var selectedSubTab: ReadingSubTab = .reading
    var timeline: TimelineSceneSnapshot?
    var readCalendar: ReadCalendarSceneSnapshot?
}

struct BooksSceneSnapshot: Codable, Equatable {
    var selectedSubTab: BookSubTab = .books
    var search: BookSearchSceneSnapshot?
}

/// 笔记首页 scene 快照，只保存分类、各分类搜索词与排序等高价值语义状态。
struct NotesSceneSnapshot: Codable, Equatable {
    var selectedSubTab: NoteSubTab
    var selectedCategory: NoteCategory
    var excerptSearchText: String
    var starredChapterSearchText: String
    var relatedSearchText: String
    var reviewSearchText: String
    var excerptSort: NoteExcerptGroupSort
    var starredSort: StarredChapterSort
    var relatedSort: RelatedCategorySort
    var reviewSort: BookReviewSortRule

    init(
        selectedSubTab: NoteSubTab = .notes,
        selectedCategory: NoteCategory = .excerpts,
        excerptSearchText: String = "",
        starredChapterSearchText: String = "",
        relatedSearchText: String = "",
        reviewSearchText: String = "",
        excerptSort: NoteExcerptGroupSort = .defaultOrder,
        starredSort: StarredChapterSort = .recentlyChanged,
        relatedSort: RelatedCategorySort = .countDescending,
        reviewSort: BookReviewSortRule = .createdDescending
    ) {
        self.selectedSubTab = selectedSubTab
        self.selectedCategory = selectedCategory
        self.excerptSearchText = excerptSearchText
        self.starredChapterSearchText = starredChapterSearchText
        self.relatedSearchText = relatedSearchText
        self.reviewSearchText = reviewSearchText
        self.excerptSort = excerptSort
        self.starredSort = starredSort
        self.relatedSort = relatedSort
        self.reviewSort = reviewSort
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSubTab
        case selectedCategory
        case excerptSearchText
        case starredChapterSearchText
        case relatedSearchText
        case reviewSearchText
        case excerptSort
        case starredSort
        case relatedSort
        case reviewSort
    }

    /// 旧快照只有 selectedSubTab；所有新增字段缺失或出现未知稳定码时回退到当前默认值。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSubTab = (try? container.decodeIfPresent(NoteSubTab.self, forKey: .selectedSubTab)) ?? .notes
        selectedCategory = (try? container.decodeIfPresent(NoteCategory.self, forKey: .selectedCategory)) ?? .excerpts
        excerptSearchText = (try? container.decodeIfPresent(String.self, forKey: .excerptSearchText)) ?? ""
        starredChapterSearchText = (try? container.decodeIfPresent(String.self, forKey: .starredChapterSearchText)) ?? ""
        relatedSearchText = (try? container.decodeIfPresent(String.self, forKey: .relatedSearchText)) ?? ""
        reviewSearchText = (try? container.decodeIfPresent(String.self, forKey: .reviewSearchText)) ?? ""
        excerptSort = (try? container.decodeIfPresent(NoteExcerptGroupSort.self, forKey: .excerptSort)) ?? .defaultOrder
        starredSort = (try? container.decodeIfPresent(StarredChapterSort.self, forKey: .starredSort)) ?? .recentlyChanged
        relatedSort = (try? container.decodeIfPresent(RelatedCategorySort.self, forKey: .relatedSort)) ?? .countDescending
        reviewSort = (try? container.decodeIfPresent(BookReviewSortRule.self, forKey: .reviewSort)) ?? .createdDescending
    }
}

struct TimelineSceneSnapshot: Codable, Equatable {
    var selectedDate: Date
    var displayedMonthStart: Date
    var selectedCategory: TimelineEventCategory
}

struct ReadCalendarSceneSnapshot: Codable, Equatable {
    var pagerSelection: Date
    var selectedDate: Date?
    var displayMode: ReadCalendarContentView.DisplayMode
    var selectedYear: Int
}

struct BookSearchSceneSnapshot: Codable, Equatable {
    var query: String
    var selectedSource: BookSearchSource
}
struct ContentViewerSceneSnapshot: Codable, Equatable {
    var source: ContentViewerSourceContext
    var selectedItemID: ContentViewerItemID
}

extension AppSceneSnapshot {
    private enum CodingKeys: String, CodingKey {
        case snapshotVersion
        case dataEpoch
        case selectedTab
        case searchQuery
        case navigation
        case reading
        case books
        case notes
        case contentViewer
    }

    /// 兼容早期缺少后续模块字段的 scene 快照；未知或损坏的单个可选锚点降级为当前默认值。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dataEpoch = (try? container.decodeIfPresent(Int.self, forKey: .dataEpoch)) ?? 0
        let defaults = Self.empty(dataEpoch: dataEpoch)
        snapshotVersion = (try? container.decodeIfPresent(Int.self, forKey: .snapshotVersion))
            ?? defaults.snapshotVersion
        self.dataEpoch = dataEpoch
        selectedTab = (try? container.decodeIfPresent(AppTab.self, forKey: .selectedTab))
            ?? defaults.selectedTab
        searchQuery = (try? container.decodeIfPresent(String.self, forKey: .searchQuery))
            ?? defaults.searchQuery
        navigation = (try? container.decodeIfPresent(NavigationSceneSnapshot.self, forKey: .navigation))
            ?? defaults.navigation
        reading = (try? container.decodeIfPresent(ReadingSceneSnapshot.self, forKey: .reading))
            ?? defaults.reading
        books = (try? container.decodeIfPresent(BooksSceneSnapshot.self, forKey: .books))
            ?? defaults.books
        notes = (try? container.decodeIfPresent(NotesSceneSnapshot.self, forKey: .notes))
            ?? defaults.notes
        contentViewer = try? container.decodeIfPresent(
            ContentViewerSceneSnapshot.self,
            forKey: .contentViewer
        )
    }
}

extension NavigationSceneSnapshot {
    private enum CodingKeys: String, CodingKey {
        case reading
        case books
        case notes
        case profile
        case search
    }

    /// 导航快照按 Tab 独立容错，旧版本缺少搜索路径时仍可恢复其余四个根栈。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reading = try? container.decodeIfPresent(
            NavigationPath.CodableRepresentation.self,
            forKey: .reading
        )
        books = try? container.decodeIfPresent(
            NavigationPath.CodableRepresentation.self,
            forKey: .books
        )
        notes = try? container.decodeIfPresent(
            NavigationPath.CodableRepresentation.self,
            forKey: .notes
        )
        profile = try? container.decodeIfPresent(
            NavigationPath.CodableRepresentation.self,
            forKey: .profile
        )
        search = try? container.decodeIfPresent(
            NavigationPath.CodableRepresentation.self,
            forKey: .search
        )
    }
}

extension ReadingSceneSnapshot {
    private enum CodingKeys: String, CodingKey {
        case selectedSubTab
        case timeline
        case readCalendar
    }

    /// 阅读模块早期快照缺少高价值页面锚点时保留其可解码的二级 Tab。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSubTab = (try? container.decodeIfPresent(ReadingSubTab.self, forKey: .selectedSubTab))
            ?? .reading
        timeline = try? container.decodeIfPresent(TimelineSceneSnapshot.self, forKey: .timeline)
        readCalendar = try? container.decodeIfPresent(
            ReadCalendarSceneSnapshot.self,
            forKey: .readCalendar
        )
    }
}

extension BooksSceneSnapshot {
    private enum CodingKeys: String, CodingKey {
        case selectedSubTab
        case search
    }

    /// 书籍模块旧快照没有搜索锚点时恢复到书籍根页，避免整份 scene 数据解码失败。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSubTab = (try? container.decodeIfPresent(BookSubTab.self, forKey: .selectedSubTab))
            ?? .books
        search = try? container.decodeIfPresent(BookSearchSceneSnapshot.self, forKey: .search)
    }
}
