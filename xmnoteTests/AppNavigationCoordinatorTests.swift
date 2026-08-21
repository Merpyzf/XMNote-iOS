import Foundation
import SwiftUI
import Testing
@testable import xmnote

@MainActor
struct AppNavigationCoordinatorTests {
    @Test
    func fiveTabBrowsePathsRemainIndependent() {
        let coordinator = AppNavigationCoordinator()

        coordinator.push(.book(.detail(bookId: 1)), in: .books)
        coordinator.push(.note(.detail(noteId: 2)), in: .notes)
        coordinator.push(.personal(.settings), in: .profile)

        #expect(coordinator.path(for: .reading).isEmpty)
        #expect(coordinator.path(for: .books) == [.book(.detail(bookId: 1))])
        #expect(coordinator.path(for: .notes) == [.note(.detail(noteId: 2))])
        #expect(coordinator.path(for: .profile) == [.personal(.settings)])
        #expect(coordinator.path(for: .search).isEmpty)
    }

    @Test
    func immersiveBookBranchKeepsRootTabChromeHiddenAcrossDescendants() {
        let coordinator = AppNavigationCoordinator()
        coordinator.selectedTab = .notes
        coordinator.push(
            .note(
                .noteExcerptList(
                    context: NoteExcerptListContext(
                        scope: .book(id: 1),
                        displayTitle: "书摘"
                    )
                )
            ),
            in: .notes
        )

        #expect(!coordinator.isTabChromeSuppressed)

        coordinator.push(.book(.detail(bookId: 1)), in: .notes)
        coordinator.push(.book(.readingDetail(bookId: 1)), in: .notes)

        #expect(coordinator.isTabChromeSuppressed)

        coordinator.pathBinding(for: .notes).wrappedValue = [
            .note(
                .noteExcerptList(
                    context: NoteExcerptListContext(
                        scope: .book(id: 1),
                        displayTitle: "书摘"
                    )
                )
            )
        ]

        #expect(!coordinator.isTabChromeSuppressed)
    }

    @Test
    func tabChromeSuppressionTicketCannotLeakIntoAnotherTab() {
        let coordinator = AppNavigationCoordinator()
        let token = UUID()
        coordinator.selectedTab = .books
        coordinator.suppressTabChrome(for: token)

        #expect(coordinator.isTabChromeSuppressed)

        coordinator.selectedTab = .notes

        #expect(!coordinator.isTabChromeSuppressed)

        coordinator.selectedTab = .books
        #expect(coordinator.isTabChromeSuppressed)
        coordinator.restoreTabChrome(for: token)
        #expect(!coordinator.isTabChromeSuppressed)
    }

    @Test
    func duplicateTopRouteDoesNotEnterStackTwice() {
        let coordinator = AppNavigationCoordinator()
        let route = AppRoute.book(.detail(bookId: 1))

        coordinator.push(route, in: .books)
        coordinator.push(route, in: .books)

        #expect(coordinator.path(for: .books) == [route])
    }

    @Test
    func existingRoutePopsToItsOriginalPosition() {
        let coordinator = AppNavigationCoordinator()
        let first = AppRoute.book(.detail(bookId: 1))
        let second = AppRoute.book(.readingDetail(bookId: 1))
        let third = AppRoute.book(.chapterManager(bookID: 1, focusChapterID: nil))

        coordinator.push(first, in: .books)
        coordinator.push(second, in: .books)
        coordinator.push(third, in: .books)
        coordinator.push(second, in: .books)

        #expect(coordinator.path(for: .books) == [first, second])
    }

    @Test
    func deepLinkReplacesTargetHistoryWithoutTouchingOtherTabs() {
        let coordinator = AppNavigationCoordinator()
        coordinator.push(.book(.detail(bookId: 1)), in: .books)
        coordinator.push(.note(.detail(noteId: 2)), in: .notes)

        coordinator.replacePath(
            for: .books,
            with: [.book(.detail(bookId: 9)), .book(.readingDetail(bookId: 9))]
        )

        #expect(coordinator.selectedTab == .books)
        #expect(
            coordinator.path(for: .books)
                == [.book(.detail(bookId: 9)), .book(.readingDetail(bookId: 9))]
        )
        #expect(coordinator.path(for: .notes) == [.note(.detail(noteId: 2))])
    }

    @Test
    func fullScreenTaskNeverEntersBrowseSnapshot() {
        let coordinator = AppNavigationCoordinator()
        coordinator.push(.book(.detail(bookId: 1)), in: .books)
        let before = coordinator.browseState

        coordinator.present(.readCalendar(initialDate: nil))
        coordinator.taskPath.append(.readCalendar(.daily(date: Date(timeIntervalSince1970: 0))))

        #expect(coordinator.browseState == before)
        #expect(coordinator.activeTask != nil)
        #expect(coordinator.taskPath.count == 1)
    }

    @Test
    func taskDismissalReturnsBrowseFlowExactlyOnce() {
        let coordinator = AppNavigationCoordinator()
        coordinator.selectedTab = .books
        coordinator.push(.book(.detail(bookId: 1)), in: .books)
        coordinator.present(.readCalendar(initialDate: nil))
        coordinator.exitTask(
            to: .book(.readingDetail(bookId: 1)),
            targetTab: .books
        )

        #expect(coordinator.path(for: .books) == [.book(.detail(bookId: 1))])
        #expect(coordinator.isTaskDismissalInFlight)
        let pending = coordinator.completeTaskDismissal()
        #expect(pending?.tab == .books)
        #expect(pending?.destination == .book(.readingDetail(bookId: 1)))
        #expect(coordinator.completeTaskDismissal() == nil)
        #expect(!coordinator.isTaskDismissalInFlight)
    }

    @Test
    func systemDismissBindingKeepsPresentationChannelOccupiedUntilOnDismiss() {
        let coordinator = AppNavigationCoordinator()
        coordinator.present(.readCalendar(initialDate: nil))

        coordinator.taskPresentationBinding.wrappedValue = nil

        #expect(coordinator.activeTask == nil)
        #expect(coordinator.isTaskPresentationActiveOrDismissing)
        _ = coordinator.completeTaskDismissal()
        #expect(!coordinator.isTaskPresentationActiveOrDismissing)
    }

    @Test
    func readingTimerDeepLinkRouterUsesNewestRequest() throws {
        let router = ReadingTimerDeepLinkRouter()
        let first = try #require(URL(string: "xmnote://reading-timer/1"))
        let newest = try #require(URL(string: "xmnote://reading-timer/2?recordId=7"))

        #expect(router.handle(first))
        #expect(router.handle(newest))
        #expect(router.pendingRequest == .record(recordId: 7, bookId: 2))
    }

    @Test
    func versionTwoMigrationPreservesSemanticStateAndClearsPaths() throws {
        var legacy = AppSceneSnapshot.empty(dataEpoch: 7)
        legacy.snapshotVersion = 2
        legacy.selectedTab = .notes
        legacy.searchQuery = "不会写入日志的查询"
        legacy.notes.selectedSubTab = .review
        legacy.navigation.books = [.book(.detail(bookId: 1))]
        let data = try JSONEncoder().encode(legacy)
        let store = SceneStateStore()

        store.restore(from: data, currentDataEpoch: 7)

        #expect(store.snapshot.snapshotVersion == 3)
        #expect(store.snapshot.selectedTab == .notes)
        #expect(store.snapshot.searchQuery == legacy.searchQuery)
        #expect(store.snapshot.notes.selectedSubTab == .review)
        #expect(store.snapshot.navigation == NavigationSceneSnapshot())
        #expect(store.persistedData != data)
    }

    @Test
    func versionThreeSanitizesCyclesAndExcessiveDepth() throws {
        var snapshot = AppSceneSnapshot.empty(dataEpoch: 8)
        let cyclic: [AppRoute] = [
            .book(.detail(bookId: 1)),
            .book(.detail(bookId: 2)),
            .book(.detail(bookId: 3)),
            .book(.detail(bookId: 2)),
            .book(.detail(bookId: 4))
        ]
        snapshot.navigation.books = cyclic
        snapshot.navigation.notes = (1...40).map {
            .note(.detail(noteId: Int64($0)))
        }
        let store = SceneStateStore()

        store.restore(
            from: try JSONEncoder().encode(snapshot),
            currentDataEpoch: 8
        )

        #expect(
            store.snapshot.navigation.books
                == [
                    .book(.detail(bookId: 1)),
                    .book(.detail(bookId: 2)),
                    .book(.detail(bookId: 4))
                ]
        )
        #expect(store.snapshot.navigation.notes.count == 32)
    }

    @Test
    func corruptedVersionThreePathIsolatedToItsTab() throws {
        var snapshot = AppSceneSnapshot.empty(dataEpoch: 9)
        snapshot.selectedTab = .profile
        snapshot.navigation.books = [
            .book(.detail(bookId: 1)),
            .book(.readingDetail(bookId: 1)),
            .book(.detail(bookId: 2))
        ]
        snapshot.navigation.profile = [.personal(.settings)]
        let encoded = try JSONEncoder().encode(snapshot)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var navigation = try #require(root["navigation"] as? [String: Any])
        var books = try #require(navigation["books"] as? [Any])
        books[1] = "corrupted-route"
        navigation["books"] = books
        root["navigation"] = navigation
        let corrupted = try JSONSerialization.data(withJSONObject: root)
        let store = SceneStateStore()

        store.restore(from: corrupted, currentDataEpoch: 9)

        #expect(store.snapshot.selectedTab == .profile)
        #expect(store.snapshot.navigation.books == [.book(.detail(bookId: 1))])
        #expect(store.snapshot.navigation.profile == [.personal(.settings)])
    }

    @Test
    func sceneStoresDoNotShareNavigationState() {
        let first = SceneStateStore()
        let second = SceneStateStore()
        first.restore(from: nil, currentDataEpoch: 10)
        second.restore(from: nil, currentDataEpoch: 10)

        var navigation = NavigationSceneSnapshot()
        navigation.books = [.book(.detail(bookId: 1))]
        first.updateNavigation(selectedTab: .books, navigation: navigation)

        #expect(first.snapshot.selectedTab == .books)
        #expect(first.snapshot.navigation.books.count == 1)
        #expect(second.snapshot.selectedTab == .reading)
        #expect(second.snapshot.navigation.books.isEmpty)
    }

    @Test
    func scenePersistenceSinkReceivesEveryEncodedNavigationSnapshot() throws {
        let store = SceneStateStore()
        var emissions: [Data] = []
        store.connectPersistenceSink { emissions.append($0) }
        store.restore(from: nil, currentDataEpoch: 11)

        var navigation = NavigationSceneSnapshot()
        navigation.books = [
            .book(.detail(bookId: 1)),
            .book(.readingDetail(bookId: 1))
        ]
        store.updateNavigation(selectedTab: .books, navigation: navigation)

        let persisted = try JSONDecoder().decode(
            AppSceneSnapshot.self,
            from: #require(emissions.last)
        )
        #expect(emissions.count == 2)
        #expect(persisted.selectedTab == .books)
        #expect(persisted.navigation.books == navigation.books)
    }

    @Test
    func durableSceneArchiveKeepsSnapshotsIsolatedBySessionIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "xmnote-scene-archive-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let archive = SceneSnapshotArchive(rootDirectory: root)
        let first = Data("first-scene".utf8)
        let second = Data("second-scene".utf8)

        try archive.save(first, for: "session/one")
        try archive.save(second, for: "session/two")

        #expect(try archive.load(for: "session/one") == first)
        #expect(try archive.load(for: "session/two") == second)
        #expect(try archive.load(for: "unknown-session") == nil)
    }
}
