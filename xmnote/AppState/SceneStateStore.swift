import Foundation
import OSLog
import SwiftUI

/**
 * [INPUT]: 依赖 SceneStorage 数据、AppRoute 类型安全路径与各模块可编码语义状态
 * [OUTPUT]: 对外提供 SceneStateStore、AppSceneSnapshot v3 迁移、原子导航更新与路径净化
 * [POS]: AppState 模块的 scene 独立恢复容器，在交互页面挂载前一次性产出完整状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// SceneStateStore 负责维护当前 scene 的轻量恢复状态，并同步为可持久化快照。
@MainActor
@Observable
final class SceneStateStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "XMNote",
        category: "SceneState"
    )

    private(set) var snapshot: AppSceneSnapshot
    private(set) var persistedData: Data?
    private(set) var isRestored = false
    private var persistenceSink: ((Data) -> Void)?

    init() {
        snapshot = AppSceneSnapshot.empty(dataEpoch: 0)
    }

    /// 连接当前 scene 的系统存储写入端；编码完成后同步提交，避免持久化依赖外层视图重算时机。
    func connectPersistenceSink(_ sink: @escaping (Data) -> Void) {
        persistenceSink = sink
        if let persistedData {
            sink(persistedData)
        }
    }

    /// 场景根视图离场时断开系统存储，防止失效的动态属性位置继续接收写入。
    func disconnectPersistenceSink() {
        persistenceSink = nil
    }

    /// 从 SceneStorage 原子恢复当前 scene；v2 只迁移语义状态并一次性清空不可检查的旧导航表示。
    func restore(from data: Data?, currentDataEpoch: Int) {
        guard let data else {
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            isRestored = true
            Self.logger.info("Created empty scene snapshot epoch=\(currentDataEpoch)")
            return
        }

        let restored: AppSceneSnapshot
        do {
            restored = try Self.decoder.decode(AppSceneSnapshot.self, from: data)
        } catch {
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            isRestored = true
            Self.logger.error("Scene snapshot decode failed; reset reason=\(error.localizedDescription, privacy: .public)")
            return
        }

        guard restored.dataEpoch == currentDataEpoch else {
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            isRestored = true
            Self.logger.notice(
                "Scene snapshot epoch mismatch stored=\(restored.dataEpoch) current=\(currentDataEpoch); reset"
            )
            return
        }

        switch restored.snapshotVersion {
        case AppSceneSnapshot.currentVersion:
            var sanitized = restored
            sanitized.navigation = restored.navigation.sanitized()
            let didSanitize = sanitized.navigation != restored.navigation
            replaceSnapshot(sanitized, persist: didSanitize)
            if didSanitize {
                Self.logger.warning("Sanitized restored v3 navigation paths")
            }
            if !didSanitize {
                publishPersistedData(data)
            }
            Self.logger.info(
                "Restored scene v3 depths reading=\(sanitized.navigation.reading.count) books=\(sanitized.navigation.books.count) notes=\(sanitized.navigation.notes.count) profile=\(sanitized.navigation.profile.count) search=\(sanitized.navigation.search.count)"
            )
        case 2:
            var migrated = restored
            migrated.snapshotVersion = AppSceneSnapshot.currentVersion
            migrated.navigation = NavigationSceneSnapshot()
            replaceSnapshot(migrated, persist: true)
            Self.logger.notice("Migrated scene snapshot v2 to v3; preserved semantic state and cleared opaque paths")
        default:
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            Self.logger.error("Unsupported scene snapshot version=\(restored.snapshotVersion); reset")
        }
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

    /// 一次提交当前 Tab 与五组浏览路径，避免恢复文件出现跨字段的中间状态。
    func updateNavigation(
        selectedTab: AppTab,
        navigation: NavigationSceneSnapshot
    ) {
        let sanitized = navigation.sanitized()
        mutate {
            $0.selectedTab = selectedTab
            $0.navigation = sanitized
        }
    }

    func updateSearchQuery(_ query: String) {
        mutate { $0.searchQuery = query }
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

    private func replaceSnapshot(_ newSnapshot: AppSceneSnapshot, persist: Bool) {
        snapshot = newSnapshot
        if persist {
            do {
                publishPersistedData(try Self.encoder.encode(newSnapshot))
            } catch {
                Self.logger.error(
                    "Scene snapshot encode failed reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func publishPersistedData(_ data: Data) {
        persistedData = data
        persistenceSink?(data)
    }
}

/// AppSceneSnapshot 是单个 scene 的轻量恢复快照，只保存高价值语义锚点。
struct AppSceneSnapshot: Codable, Equatable {
    static let currentVersion = 3

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

struct NavigationSceneSnapshot: Codable, Hashable {
    var reading: [AppRoute] = []
    var books: [AppRoute] = []
    var notes: [AppRoute] = []
    var profile: [AppRoute] = []
    var search: [AppRoute] = []

    /// 返回指定 Tab 的类型安全路径。
    func path(for tab: AppTab) -> [AppRoute] {
        switch tab {
        case .reading: reading
        case .books: books
        case .notes: notes
        case .profile: profile
        case .search: search
        }
    }

    /// 修改指定 Tab 路径；调用方负责先执行统一净化规则。
    mutating func setPath(_ path: [AppRoute], for tab: AppTab) {
        switch tab {
        case .reading: reading = path
        case .books: books = path
        case .notes: notes = path
        case .profile: profile = path
        case .search: search = path
        }
    }

    /// 对五个 Tab 应用相同的深度、去重、去环和非法路由截断规则。
    func sanitized() -> NavigationSceneSnapshot {
        NavigationSceneSnapshot(
            reading: AppRoute.sanitizedBrowsePath(reading),
            books: AppRoute.sanitizedBrowsePath(books),
            notes: AppRoute.sanitizedBrowsePath(notes),
            profile: AppRoute.sanitizedBrowsePath(profile),
            search: AppRoute.sanitizedBrowsePath(search)
        )
    }
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

    /// 导航快照按 Tab 独立逐节点容错；坏节点只截断当前 Tab 的后续历史，其他 Tab 与合法前缀不受影响。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reading = Self.decodePath(from: container, forKey: .reading)
        books = Self.decodePath(from: container, forKey: .books)
        notes = Self.decodePath(from: container, forKey: .notes)
        profile = Self.decodePath(from: container, forKey: .profile)
        search = Self.decodePath(from: container, forKey: .search)
    }

    /// 逐元素解码以保留坏节点之前的有效浏览链；旧版类型擦除对象不是数组时直接返回空路径。
    private static func decodePath(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [AppRoute] {
        guard var pathContainer = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }

        var routes: [AppRoute] = []
        while !pathContainer.isAtEnd {
            guard let route = try? pathContainer.decode(AppRoute.self) else {
                break
            }
            routes.append(route)
        }
        return routes
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
