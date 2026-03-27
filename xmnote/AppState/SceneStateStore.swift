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

    /// 从 SceneStorage 恢复快照；当数据 epoch 不匹配时丢弃旧快照。
    func restore(from data: Data?, currentDataEpoch: Int) {
        guard let data else {
            replaceSnapshot(AppSceneSnapshot.empty(dataEpoch: currentDataEpoch), persist: true)
            isRestored = true
            return
        }

        guard let restored = try? Self.decoder.decode(AppSceneSnapshot.self, from: data),
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

    func updateTimeline(_ timeline: TimelineSceneSnapshot?) {
        mutate { $0.reading.timeline = timeline }
    }

    func updateReadCalendar(_ readCalendar: ReadCalendarSceneSnapshot?) {
        mutate { $0.reading.readCalendar = readCalendar }
    }

    func updateBookSearch(_ bookSearch: BookSearchSceneSnapshot?) {
        mutate { $0.books.search = bookSearch }
    }

    func updateContentViewer(_ contentViewer: ContentViewerSceneSnapshot?) {
        mutate { $0.contentViewer = contentViewer }
    }

    /// 封装mutate对应的业务步骤，确保调用方可以稳定复用该能力。
    private func mutate(_ mutate: (inout AppSceneSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        replaceSnapshot(next, persist: true)
    }

    /// 处理updatePathRepresentation对应的状态流转，确保交互过程与数据状态保持一致。
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

    /// 封装replaceSnapshot对应的业务步骤，确保调用方可以稳定复用该能力。
    private func replaceSnapshot(_ newSnapshot: AppSceneSnapshot, persist: Bool) {
        snapshot = newSnapshot
        if persist {
            persistedData = try? Self.encoder.encode(newSnapshot)
        }
    }
}

/// AppSceneSnapshot 是单个 scene 的轻量恢复快照，只保存高价值语义锚点。
struct AppSceneSnapshot: Codable, Equatable {
    var snapshotVersion: Int
    var dataEpoch: Int
    var selectedTab: AppTab
    var searchQuery: String
    var navigation: NavigationSceneSnapshot
    var reading: ReadingSceneSnapshot
    var books: BooksSceneSnapshot
    var notes: NotesSceneSnapshot
    var contentViewer: ContentViewerSceneSnapshot?

    /// 组装empty对应的界面片段，保持页面层级与信息结构清晰。
    static func empty(dataEpoch: Int) -> AppSceneSnapshot {
        AppSceneSnapshot(
            snapshotVersion: 1,
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

/// NavigationSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct NavigationSceneSnapshot: Codable, Equatable {
    var reading: NavigationPath.CodableRepresentation?
    var books: NavigationPath.CodableRepresentation?
    var notes: NavigationPath.CodableRepresentation?
    var profile: NavigationPath.CodableRepresentation?
    var search: NavigationPath.CodableRepresentation?
}

/// ReadingSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct ReadingSceneSnapshot: Codable, Equatable {
    var selectedSubTab: ReadingSubTab = .reading
    var timeline: TimelineSceneSnapshot?
    var readCalendar: ReadCalendarSceneSnapshot?
}

/// BooksSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct BooksSceneSnapshot: Codable, Equatable {
    var selectedSubTab: BookSubTab = .books
    var search: BookSearchSceneSnapshot?
}

/// NotesSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct NotesSceneSnapshot: Codable, Equatable {
    var selectedSubTab: NoteSubTab = .notes
}

/// TimelineSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct TimelineSceneSnapshot: Codable, Equatable {
    var selectedDate: Date
    var displayedMonthStart: Date
    var selectedCategory: TimelineEventCategory
}

/// ReadCalendarSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct ReadCalendarSceneSnapshot: Codable, Equatable {
    var pagerSelection: Date
    var selectedDate: Date?
    var displayMode: ReadCalendarContentView.DisplayMode
    var selectedYear: Int
}

/// BookSearchSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct BookSearchSceneSnapshot: Codable, Equatable {
    var query: String
    var selectedSource: BookSearchSource
}

/// ContentViewerSceneSnapshot 负责当前场景的struct定义，明确职责边界并组织相关能力。
struct ContentViewerSceneSnapshot: Codable, Equatable {
    var source: ContentViewerSourceContext
    var selectedItemID: ContentViewerItemID
}
