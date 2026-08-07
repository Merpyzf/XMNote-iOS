//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

/**
 * [INPUT]: 依赖可选 AppRuntimeContext、五个业务根容器与含稳定页面标题上下文的路由枚举，依赖 SceneStateStore、BookCollectionImportRouter、openURL 与 SwiftUI search focus
 * [OUTPUT]: 对外提供 MainTabView，常驻五 Tab 导航骨架，在运行时依赖未就绪时展示静态结构壳层，就绪后原位接入生产页面并在栈内稳定注册 scene/深链/搜索路由及章节真实标题
 * [POS]: 应用根导航入口，负责启动期壳层与生产内容切换、跨模块路由、五栈恢复写回和搜索结果独立导航现场
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 应用主 Tab 枚举，统一根级导航页签身份。
enum AppTab: String, CaseIterable, Codable {
    case reading, books, notes, profile, search
}

/// 全局搜索提交节流策略，用于错开系统搜索输入层动画与结果页刷新。
private enum GlobalSearchCommitPolicy {
    static let keyboardSubmitDelayNanoseconds: UInt64 = 180_000_000
    static let suggestionFocusSettleDelayNanoseconds: UInt64 = 260_000_000
    static let suggestionTextSettleDelayNanoseconds: UInt64 = 60_000_000
    static let suggestionFallbackSubmitDelayNanoseconds: UInt64 = 320_000_000
    static let queryClearProtectionGraceNanoseconds: UInt64 = 120_000_000
}

/// 全局搜索提交来源，区分键盘提交和历史词直达，便于保持统一协调入口。
private enum GlobalSearchCommitSource: Sendable {
    case keyboard
    case suggestion

    var focusSettleDelayNanoseconds: UInt64 {
        switch self {
        case .keyboard:
            return 0
        case .suggestion:
            return GlobalSearchCommitPolicy.suggestionFocusSettleDelayNanoseconds
        }
    }

    var submitDelayNanoseconds: UInt64 {
        switch self {
        case .keyboard:
            return GlobalSearchCommitPolicy.keyboardSubmitDelayNanoseconds
        case .suggestion:
            return GlobalSearchCommitPolicy.suggestionTextSettleDelayNanoseconds
        }
    }

    var defersQueryWriteUntilFocusSettles: Bool {
        self == .suggestion
    }
}

/// 应用主导航容器，组织五个主 Tab 及跨模块路由跳转。
struct MainTabView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(BookCollectionImportRouter.self) private var bookCollectionImportRouter
    @Environment(SceneStateStore.self) private var sceneStateStore
    let runtime: AppRuntimeContext?
    let initialSceneSnapshot: AppSceneSnapshot
    @State private var selectedTab: AppTab = .reading
    @State private var readingPath = NavigationPath()
    @State private var booksPath = NavigationPath()
    @State private var notesPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchResultCoverPath = NavigationPath()
    @State private var searchResultCover: SearchResultCover?
    @State private var shouldRestoreSearchPresentationAfterCover = false
    @State private var searchQuery = ""
    @State private var searchSubmitRequest: GlobalSearchSubmitRequest?
    @State private var isSearchPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var pendingGlobalSearchSuggestion: PendingGlobalSearchSuggestion?
    @State private var pendingGlobalSearchSuggestionTask: Task<Void, Never>?
    @State private var pendingGlobalSearchSubmitTask: Task<Void, Never>?
    @State private var protectedGlobalSearchQuery: String?
    @State private var globalSearchCommitToken: UUID?
    @State private var didBootstrapFromScene = false
    @State private var canPersistSceneSnapshot = false
    #if DEBUG
    @State private var didApplyUITestLaunchRoute = false
    #endif

    /// 以 SceneStorage 解码结果建立首帧 Tab 与路径初值；后续 runtime 更新不会重置这些本地导航状态。
    init(runtime: AppRuntimeContext?, initialSceneSnapshot: AppSceneSnapshot) {
        self.runtime = runtime
        self.initialSceneSnapshot = initialSceneSnapshot
        _selectedTab = State(initialValue: initialSceneSnapshot.selectedTab)
        _readingPath = State(initialValue: Self.navigationPath(from: initialSceneSnapshot.navigation.reading))
        _booksPath = State(initialValue: Self.navigationPath(from: initialSceneSnapshot.navigation.books))
        _notesPath = State(initialValue: Self.navigationPath(from: initialSceneSnapshot.navigation.notes))
        _profilePath = State(initialValue: Self.navigationPath(from: initialSceneSnapshot.navigation.profile))
        _searchPath = State(initialValue: Self.navigationPath(from: initialSceneSnapshot.navigation.search))
        _searchQuery = State(initialValue: initialSceneSnapshot.searchQuery)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("在读", systemImage: "calendar", value: .reading) {
                NavigationStack(path: $readingPath) {
                    Group {
                        if let runtime {
                            ReadingContainerView(
                                onAddBook: { append(BookRoute.add, to: .reading) },
                                onAddNote: { append(NoteRoute.create(seed: .empty), to: .reading) },
                                onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .reading) },
                                onOpenReadCalendar: { date in
                                    readingPath.append(ReadingRoute.readCalendar(date: date))
                                },
                                onOpenBookDetail: { bookId in
                                    append(BookRoute.detail(bookId: bookId), to: .reading)
                                },
                                onOpenContentViewer: { source, initialItem in
                                    append(contentRoute(for: source, initialItem: initialItem), to: .reading)
                                }
                            )
                            .toolbar(.hidden, for: .navigationBar)
                            .environment(runtime.databaseManager)
                            .environment(runtime.repositories)
                        } else {
                            MainTabBootstrapPage(
                                tab: .reading,
                                snapshot: bootstrapSceneSnapshot,
                                hasRestoredNavigation: !readingPath.isEmpty
                            )
                            .toolbar(.hidden, for: .navigationBar)
                        }
                    }
                    .navigationDestination(for: DebugRoute.self) { route in
                        readingRuntimeDestination { _ in
                            debugDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .navigationDestination(for: ReadingRoute.self) { route in
                        readingRuntimeDestination { _ in
                            readingDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .navigationDestination(for: ReadCalendarRoute.self) { route in
                        readingRuntimeDestination { _ in
                            readCalendarDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .navigationDestination(for: BookRoute.self) { route in
                        readingRuntimeDestination { _ in
                            bookDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .navigationDestination(for: NoteRoute.self) { route in
                        readingRuntimeDestination { runtime in
                            noteDestination(for: route, repositories: runtime.repositories)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .navigationDestination(for: ContentRoute.self) { route in
                        readingRuntimeDestination { _ in
                            contentDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .navigationDestination(for: PersonalRoute.self) { route in
                        readingRuntimeDestination { _ in
                            personalDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                }
            }

            Tab("书籍", systemImage: "book", value: .books) {
                Group {
                    if let runtime {
                        NavigationStack(path: $booksPath) {
                            BookContainerView(
                                onAddBook: { append(BookRoute.add, to: .books) },
                                onAddNote: { append(NoteRoute.create(seed: .empty), to: .books) },
                                onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .books) },
                                onOpenBookRoute: { append($0, to: .books) },
                                onOpenNoteRoute: { append($0, to: .books) },
                                onOpenTagManagement: { append(PersonalRoute.tagManagement, to: .books) },
                                onOpenSourceManagement: { append(PersonalRoute.bookSource, to: .books) },
                                onOpenAuthorManagement: { append(PersonalRoute.authorManagement, to: .books) },
                                onOpenPressManagement: { append(PersonalRoute.pressManagement, to: .books) },
                                onOpenGuide: openBookManagementGuide
                            )
                            .navigationDestination(for: DebugRoute.self) { route in
                                debugDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: BookRoute.self) { route in
                                bookDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: NoteRoute.self) { route in
                                noteDestination(for: route, repositories: runtime.repositories)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: ContentRoute.self) { route in
                                contentDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: PersonalRoute.self) { route in
                                personalDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: ReadCalendarRoute.self) { route in
                                readCalendarDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                        }
                        .environment(runtime.databaseManager)
                        .environment(runtime.repositories)
                        .transition(.opacity)
                    } else {
                        MainTabBootstrapPage(
                            tab: .books,
                            snapshot: bootstrapSceneSnapshot,
                            hasRestoredNavigation: !booksPath.isEmpty
                        )
                        .transition(.opacity)
                    }
                }
                .animation(runtimeTransitionAnimation, value: isRuntimeReady)
            }

            Tab("笔记", systemImage: "archivebox", value: .notes) {
                Group {
                    if let runtime {
                        NavigationStack(path: $notesPath) {
                            NoteContainerView(
                                onAddBook: { append(BookRoute.add, to: .notes) },
                                onAddNote: { append(NoteRoute.create(seed: .empty), to: .notes) },
                                onOpenNoteRoute: { append($0, to: .notes) },
                                onOpenBookRoute: { append($0, to: selectedTab) },
                                onOpenContentRoute: { append($0, to: selectedTab) },
                                onOpenContentViewer: { source, initialItem in
                                    append(contentRoute(for: source, initialItem: initialItem), to: .notes)
                                },
                                onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .notes) }
                            )
                            .navigationDestination(for: DebugRoute.self) { route in
                                debugDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: BookRoute.self) { route in
                                bookDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: NoteRoute.self) { route in
                                noteDestination(for: route, repositories: runtime.repositories)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: ContentRoute.self) { route in
                                contentDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                        }
                        .environment(runtime.databaseManager)
                        .environment(runtime.repositories)
                        .transition(.opacity)
                    } else {
                        MainTabBootstrapPage(
                            tab: .notes,
                            snapshot: bootstrapSceneSnapshot,
                            hasRestoredNavigation: !notesPath.isEmpty
                        )
                        .transition(.opacity)
                    }
                }
                .animation(runtimeTransitionAnimation, value: isRuntimeReady)
            }

            Tab("我的", systemImage: "person", value: .profile) {
                Group {
                    if let runtime {
                        NavigationStack(path: $profilePath) {
                            PersonalView(
                                onAddBook: { append(BookRoute.add, to: .profile) },
                                onAddNote: { append(NoteRoute.create(seed: .empty), to: .profile) },
                                onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .profile) }
                            )
                            .navigationDestination(for: DebugRoute.self) { route in
                                debugDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: BookRoute.self) { route in
                                bookDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: NoteRoute.self) { route in
                                noteDestination(for: route, repositories: runtime.repositories)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: ContentRoute.self) { route in
                                contentDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: PersonalRoute.self) { route in
                                personalDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: ReadCalendarRoute.self) { route in
                                readCalendarDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                        }
                        .environment(runtime.databaseManager)
                        .environment(runtime.repositories)
                        .transition(.opacity)
                    } else {
                        MainTabBootstrapPage(
                            tab: .profile,
                            snapshot: bootstrapSceneSnapshot,
                            hasRestoredNavigation: !profilePath.isEmpty
                        )
                        .transition(.opacity)
                    }
                }
                .animation(runtimeTransitionAnimation, value: isRuntimeReady)
            }

            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                Group {
                    if let runtime {
                        NavigationStack(path: $searchPath) {
                            GlobalSearchView(
                                query: $searchQuery,
                                submitRequest: searchSubmitRequest,
                                isSearchResultCoverPresented: searchResultCover != nil,
                                onBeginSearchSuggestion: beginGlobalSearchSuggestion,
                                onCancelSearchSuggestion: cancelGlobalSearchSuggestion,
                                onCommitSearchSuggestion: commitGlobalSearchSuggestion,
                                onPrepareHistoryClearConfirmation: dismissGlobalSearchKeyboard,
                                onOpenSearchResultCover: openSearchResultCover
                            )
                            .navigationDestination(for: DebugRoute.self) { route in
                                debugDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: BookRoute.self) { route in
                                bookDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: NoteRoute.self) { route in
                                noteDestination(for: route, repositories: runtime.repositories)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                            .navigationDestination(for: ContentRoute.self) { route in
                                contentDestination(for: route)
                                    .toolbar(.hidden, for: .tabBar)
                            }
                        }
                        .environment(runtime.databaseManager)
                        .environment(runtime.repositories)
                        .transition(.opacity)
                    } else {
                        MainTabBootstrapPage(
                            tab: .search,
                            snapshot: bootstrapSceneSnapshot,
                            hasRestoredNavigation: !searchPath.isEmpty
                        )
                        .transition(.opacity)
                    }
                }
                .animation(runtimeTransitionAnimation, value: isRuntimeReady)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .mainTabSearchHost(
            isEnabled: selectedTab == .search,
            searchText: searchHostTextBinding,
            isPresented: $isSearchPresented,
            isFocused: $isSearchFieldFocused,
            onSubmit: submitGlobalSearchQuery
        )
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored, !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            canPersistSceneSnapshot = false
            restoreFromSceneSnapshot()
            canPersistSceneSnapshot = true
            persistCurrentSceneSnapshot()

            if let pendingImport = bookCollectionImportRouter.pendingImport {
                prepareForBookCollectionImport(pendingImport)
            }
            #if DEBUG
            await applyUITestLaunchRouteIfNeeded()
            #endif
        }
        .onChange(of: selectedTab) { _, newValue in
            syncSearchPresentationForCurrentState()
            guard canPersistSceneSnapshot else { return }
            sceneStateStore.updateSelectedTab(newValue)
        }
        .onChange(of: searchQuery) { _, newValue in
            guard canPersistSceneSnapshot else { return }
            sceneStateStore.updateSearchQuery(newValue)
        }
        .onChange(of: searchPath.count) { _, _ in
            syncSearchPresentationForCurrentState()
        }
        .onChange(of: pathPersistenceSignature(for: readingPath)) { _, _ in
            persistPath(readingPath, for: .reading)
        }
        .onChange(of: pathPersistenceSignature(for: booksPath)) { _, _ in
            persistPath(booksPath, for: .books)
        }
        .onChange(of: pathPersistenceSignature(for: notesPath)) { _, _ in
            persistPath(notesPath, for: .notes)
        }
        .onChange(of: pathPersistenceSignature(for: profilePath)) { _, _ in
            persistPath(profilePath, for: .profile)
        }
        .onChange(of: pathPersistenceSignature(for: searchPath)) { _, _ in
            persistPath(searchPath, for: .search)
        }
        .onChange(of: bookCollectionImportRouter.pendingImport) { _, request in
            guard let request else { return }
            prepareForBookCollectionImport(request)
        }
        .fullScreenCover(
            item: $searchResultCover,
            onDismiss: completeSearchResultCoverDismissal
        ) { cover in
            if let runtime {
                searchResultCoverContent(for: cover, repositories: runtime.repositories)
                    .environment(runtime.databaseManager)
                    .environment(runtime.repositories)
            }
        }
    }

    private var isRuntimeReady: Bool {
        runtime != nil
    }

    private var runtimeTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .smooth(duration: 0.16)
    }

    private var bootstrapSceneSnapshot: AppSceneSnapshot {
        sceneStateStore.isRestored ? sceneStateStore.snapshot : initialSceneSnapshot
    }

    /// 为阅读栈目的页延迟注入运行时依赖；依赖未就绪时保持恢复路径的静态背景，不重建 NavigationStack。
    @ViewBuilder
    private func readingRuntimeDestination<Destination: View>(
        @ViewBuilder destination: (AppRuntimeContext) -> Destination
    ) -> some View {
        if let runtime {
            destination(runtime)
                .environment(runtime.databaseManager)
                .environment(runtime.repositories)
        } else {
            Color.surfacePage
                .ignoresSafeArea()
                .toolbar(.hidden, for: .tabBar)
        }
    }

    /// 将 SceneStorage 中的可编码表示转换为首帧 NavigationPath；缺失表示时保持根页面。
    private static func navigationPath(
        from representation: NavigationPath.CodableRepresentation?
    ) -> NavigationPath {
        guard let representation else { return NavigationPath() }
        return NavigationPath(representation)
    }

    private var searchHostTextBinding: Binding<String> {
        Binding(
            get: {
                searchQuery
            },
            set: { newValue in
                guard !shouldIgnoreSearchHostTextUpdate(newValue) else { return }
                if let protectedGlobalSearchQuery,
                   newValue != protectedGlobalSearchQuery {
                    cancelPendingGlobalSearchCommit()
                }
                searchQuery = newValue
            }
        )
    }

    @ViewBuilder
    private func searchResultCoverContent(
        for cover: SearchResultCover,
        repositories: RepositoryContainer
    ) -> some View {
        NavigationStack(path: $searchResultCoverPath) {
            searchResultCoverDestination(for: cover.target)
                .navigationDestination(for: BookRoute.self) { route in
                    searchResultBookDestination(for: route)
                        .toolbar(.hidden, for: .tabBar)
                }
                .navigationDestination(for: NoteRoute.self) { route in
                    searchResultNoteDestination(for: route, repositories: repositories)
                        .toolbar(.hidden, for: .tabBar)
                }
                .navigationDestination(for: ContentRoute.self) { route in
                    contentDestination(for: route)
                        .toolbar(.hidden, for: .tabBar)
                }
        }
    }

    @ViewBuilder
    private func searchResultCoverDestination(for target: SearchResultViewerTarget) -> some View {
        searchResultCoverRoot(for: target)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfacePage.ignoresSafeArea())
            .navigationBarBackButtonHidden(true)
            .toolbar(.visible, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarBackButton(
                        action: dismissSearchResultCover,
                        foregroundColor: Color.textPrimary
                    )
                    .accessibilityLabel("返回搜索结果")
                }
            }
    }

    @ViewBuilder
    private func searchResultCoverRoot(for target: SearchResultViewerTarget) -> some View {
        switch target {
        case .book(let route):
            searchResultBookDestination(for: route)
        case .content(let route):
            contentDestination(for: route)
        }
    }

    @ViewBuilder
    private func searchResultBookDestination(for route: BookRoute) -> some View {
        switch route {
        case .detail(let bookId):
            BookDetailView(
                bookId: bookId,
                onOpenContentRoute: { route in
                    searchResultCoverPath.append(route)
                },
                onOpenBookRoute: { route in
                    searchResultCoverPath.append(route)
                }
            )
        case .chapterManager(let bookID, let focusChapterID):
            ChapterManagerView(bookID: bookID, focusChapterID: focusChapterID)
        case .edit(let bookId):
            BookEditorView(mode: .edit(bookId: bookId))
        case .editRelatedPlaceholder(let bookId, let sourceBookId):
            BookEditorView(mode: .editRelatedPlaceholder(
                bookId: bookId,
                sourceBookId: sourceBookId
            ))
        case .add:
            BookSearchView()
        case .create(let seed):
            BookEditorView(seed: seed)
        case .bookshelfList(let route):
            BookshelfBookListView(
                route: route,
                onOpenRoute: { route in
                    searchResultCoverPath.append(route)
                },
                onOpenNoteRoute: { route in
                    searchResultCoverPath.append(route)
                }
            )
        case .collectionDetail(let collectionID):
            BookCollectionDetailView(
                collectionID: collectionID,
                onOpenRoute: { route in
                    searchResultCoverPath.append(route)
                }
            )
        }
    }

    /// 搜索结果覆盖层内的笔记目的地只写入 cover path，避免下一级内容被追加到底层搜索 Tab 而不可见。
    @ViewBuilder
    private func searchResultNoteDestination(
        for route: NoteRoute,
        repositories: RepositoryContainer
    ) -> some View {
        switch route {
        case .detail(let noteId):
            NoteDetailView(noteId: noteId)
        case .edit(let noteId):
            NoteEditorView(mode: .edit(noteId: noteId))
        case .create(let seed):
            NoteEditorView(mode: .create, seed: seed)
        case .noteExcerpts(let scope):
            NoteExcerptListView(
                context: NoteExcerptListContext(scope: scope, displayTitle: "书摘"),
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenNoteRoute: { searchResultCoverPath.append($0) }
            )
        case .noteExcerptList(let context):
            NoteExcerptListView(
                context: context,
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenNoteRoute: { searchResultCoverPath.append($0) }
            )
        case .chapterNotes(let bookID, let chapterID, let includeDescendants):
            ChapterNotesView(
                context: ChapterNoteListContext(
                    bookID: bookID,
                    chapterID: chapterID,
                    includeDescendants: includeDescendants,
                    displayTitle: "章节书摘"
                ),
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenNoteRoute: { searchResultCoverPath.append($0) }
            )
        case .chapterNoteList(let context):
            ChapterNotesView(
                context: context,
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenNoteRoute: { searchResultCoverPath.append($0) }
            )
        case .mergeNotes(let bookID, let noteIDs):
            NoteMergeView(bookID: bookID, noteIDs: noteIDs) { source, itemID in
                replaceSearchCoverTopWithMergedViewer(source: source, itemID: itemID)
            }
        case .relatedCategory(let scope):
            RelatedCategoryListView(
                scope: scope,
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenContentRoute: { searchResultCoverPath.append($0) },
                onOpenBookRoute: { searchResultCoverPath.append($0) }
            )
        case .relatedCategoryManagement:
            RelatedCategoryListView(
                scope: .all,
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenContentRoute: { searchResultCoverPath.append($0) },
                onOpenBookRoute: { searchResultCoverPath.append($0) }
            )
        case .tagManagement:
            TagManagementView()
        case .notesByTag(let tagId):
            NoteExcerptListView(
                context: NoteExcerptListContext(
                    scope: NoteExcerptScope(legacyTagID: tagId),
                    displayTitle: "书摘"
                ),
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    searchResultCoverPath.append(contentRoute(for: source, initialItem: itemID))
                },
                onOpenNoteRoute: { searchResultCoverPath.append($0) }
            )
        }
    }

    // MARK: - Reading Destinations

    @ViewBuilder
    private func readingDestination(for route: ReadingRoute) -> some View {
        switch route {
        case .bookDetail:
            Text("书籍详情")
        case .readingSession:
            Text("阅读计时")
        case .readCalendar(let date):
            ReadCalendarView(
                date: date,
                onOpenRoute: { append($0, to: selectedTab) },
                onOpenPremium: { append(PersonalRoute.premium, to: selectedTab) }
            )
        }
    }

    // MARK: - Read Calendar Destinations

    @ViewBuilder
    private func readCalendarDestination(for route: ReadCalendarRoute) -> some View {
        switch route {
        case .daily(let date):
            DailyReadingView(
                date: date,
                onOpenRoute: { append($0, to: selectedTab) },
                onOpenBookRoute: { append($0, to: selectedTab) }
            )
        case .dailyBook(let date, let summary):
            DailyReadingBookView(
                date: date,
                summary: summary,
                onOpenBookRoute: { append($0, to: selectedTab) },
                onOpenNoteRoute: { append($0, to: selectedTab) },
                onOpenContentRoute: { append($0, to: selectedTab) }
            )
        case .share(let monthStart, let initialType):
            ReadCalendarShareView(
                monthStart: monthStart,
                initialType: initialType,
                onOpenPremium: { append(PersonalRoute.premium, to: selectedTab) }
            )
        }
    }

    // MARK: - Book Destinations

    @ViewBuilder
    private func bookDestination(for route: BookRoute) -> some View {
        switch route {
        case .detail(let bookId):
            BookDetailView(
                bookId: bookId,
                onOpenContentRoute: { route in
                    append(route, to: selectedTab)
                },
                onOpenBookRoute: { route in
                    append(route, to: selectedTab)
                }
            )
        case .chapterManager(let bookID, let focusChapterID):
            ChapterManagerView(bookID: bookID, focusChapterID: focusChapterID)
        case .edit(let bookId):
            BookEditorView(mode: .edit(bookId: bookId))
        case .editRelatedPlaceholder(let bookId, let sourceBookId):
            BookEditorView(mode: .editRelatedPlaceholder(
                bookId: bookId,
                sourceBookId: sourceBookId
            ))
        case .add:
            BookSearchView()
        case .create(let seed):
            BookEditorView(seed: seed)
        case .bookshelfList(let route):
            BookshelfBookListView(
                route: route,
                onOpenRoute: { route in
                    append(route, to: selectedTab)
                },
                onOpenNoteRoute: { route in
                    append(route, to: selectedTab)
                }
            )
        case .collectionDetail(let collectionID):
            BookCollectionDetailView(
                collectionID: collectionID,
                onOpenRoute: { route in
                    append(route, to: selectedTab)
                }
            )
        }
    }

    // MARK: - Note Destinations

    @ViewBuilder
    private func noteDestination(
        for route: NoteRoute,
        repositories: RepositoryContainer
    ) -> some View {
        switch route {
        case .detail(let noteId):
            NoteDetailView(noteId: noteId)
        case .edit(let noteId):
            NoteEditorView(mode: .edit(noteId: noteId))
        case .create(let seed):
            NoteEditorView(mode: .create, seed: seed)
        case .noteExcerpts(let scope):
            NoteExcerptListView(
                context: NoteExcerptListContext(scope: scope, displayTitle: "书摘"),
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenNoteRoute: { append($0, to: selectedTab) }
            )
        case .noteExcerptList(let context):
            NoteExcerptListView(
                context: context,
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenNoteRoute: { append($0, to: selectedTab) }
            )
        case .chapterNotes(let bookID, let chapterID, let includeDescendants):
            ChapterNotesView(
                context: ChapterNoteListContext(
                    bookID: bookID,
                    chapterID: chapterID,
                    includeDescendants: includeDescendants,
                    displayTitle: "章节书摘"
                ),
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenNoteRoute: { append($0, to: selectedTab) }
            )
        case .chapterNoteList(let context):
            ChapterNotesView(
                context: context,
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenNoteRoute: { append($0, to: selectedTab) }
            )
        case .mergeNotes(let bookID, let noteIDs):
            NoteMergeView(bookID: bookID, noteIDs: noteIDs) { source, itemID in
                replaceCurrentTopWithMergedViewer(
                    source: source,
                    itemID: itemID,
                    in: selectedTab
                )
            }
        case .relatedCategory(let scope):
            RelatedCategoryListView(
                scope: scope,
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenContentRoute: { append($0, to: selectedTab) },
                onOpenBookRoute: { append($0, to: selectedTab) }
            )
        case .relatedCategoryManagement:
            RelatedCategoryListView(
                scope: .all,
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenContentRoute: { append($0, to: selectedTab) },
                onOpenBookRoute: { append($0, to: selectedTab) }
            )
        case .tagManagement:
            TagManagementView()
        case .notesByTag(let tagId):
            NoteExcerptListView(
                context: NoteExcerptListContext(
                    scope: NoteExcerptScope(legacyTagID: tagId),
                    displayTitle: "书摘"
                ),
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    append(contentRoute(for: source, initialItem: itemID), to: selectedTab)
                },
                onOpenNoteRoute: { append($0, to: selectedTab) }
            )
        }
    }

    // MARK: - Content Destinations

    @ViewBuilder
    private func contentDestination(for route: ContentRoute) -> some View {
        switch route {
        case .contentViewer(let source, let initialItemID, let keyword):
            ContentViewerView(source: source, initialItemID: initialItemID, keyword: keyword)
        case .reviewDetail(let reviewId):
            ReviewDetailView(reviewId: reviewId)
        case .relevantDetail(let contentId):
            RelevantDetailView(contentId: contentId)
        case .reviewEditor(let reviewId):
            ReviewEditorView(reviewId: reviewId)
        case .reviewEditorCreate(let bookId):
            ReviewEditorView(bookId: bookId)
        case .relevantEditor(let contentId):
            RelevantEditorView(contentId: contentId)
        case .relevantEditorCreate(let bookId, let categoryId):
            RelevantEditorView(bookId: bookId, categoryId: categoryId)
        }
    }

    // MARK: - Personal Destinations

    @ViewBuilder
    private func personalDestination(for route: PersonalRoute) -> some View {
        switch route {
        case .settings:
            Text("设置")
        case .premium:
            Text("会员")
        case .readCalendar:
            ReadCalendarView(
                date: nil,
                onOpenRoute: { append($0, to: selectedTab) },
                onOpenPremium: { append(PersonalRoute.premium, to: selectedTab) }
            )
        case .readReminder:
            Text("阅读提醒")
        case .dataImport:
            Text("数据导入")
        case .dataBackup:
            DataBackupView()
        case .webdavServers:
            WebDAVServerListView()
        case .batchExport:
            Text("批量导出")
        case .apiIntegration:
            ApiIntegrationView()
        case .aiConfiguration:
            AIConfigurationView()
        case .tagManagement:
            TagManagementView()
        case .groupManagement:
            Text("书籍分组")
        case .bookSource:
            Text("书籍来源")
        case .authorManagement:
            BookContributorManagementView(kind: .author)
        case .pressManagement:
            BookContributorManagementView(kind: .press)
        case .about:
            Text("关于应用")
        }
    }

    // MARK: - Debug Destinations

    @ViewBuilder
    private func debugDestination(for route: DebugRoute) -> some View {
        switch route {
        case .debugCenter:
            #if DEBUG
            DebugCenterView()
            #else
            Text("测试入口仅在 Debug 构建可用")
            #endif
        }
    }

    private func append(_ route: BookRoute, to tab: AppTab) {
        switch tab {
        case .reading:
            readingPath.append(route)
        case .books:
            booksPath.append(route)
        case .notes:
            notesPath.append(route)
        case .profile:
            profilePath.append(route)
        case .search:
            searchPath.append(route)
        }
    }

    private func append(_ route: NoteRoute, to tab: AppTab) {
        switch tab {
        case .reading:
            readingPath.append(route)
        case .books:
            booksPath.append(route)
        case .notes:
            notesPath.append(route)
        case .profile:
            profilePath.append(route)
        case .search:
            searchPath.append(route)
        }
    }

    private func append(_ route: DebugRoute, to tab: AppTab) {
        switch tab {
        case .reading:
            readingPath.append(route)
        case .books:
            booksPath.append(route)
        case .notes:
            notesPath.append(route)
        case .profile:
            profilePath.append(route)
        case .search:
            searchPath.append(route)
        }
    }

    private func append(_ route: ContentRoute, to tab: AppTab) {
        switch tab {
        case .reading:
            readingPath.append(route)
        case .books:
            booksPath.append(route)
        case .notes:
            notesPath.append(route)
        case .profile:
            profilePath.append(route)
        case .search:
            searchPath.append(route)
        }
    }

    /// 将阅读日历内部路由追加到当前业务栈，保证在读/我的两个入口都保留各自现场。
    private func append(_ route: ReadCalendarRoute, to tab: AppTab) {
        switch tab {
        case .reading:
            readingPath.append(route)
        case .books:
            booksPath.append(route)
        case .notes:
            notesPath.append(route)
        case .profile:
            profilePath.append(route)
        case .search:
            searchPath.append(route)
        }
    }

    private func append(_ route: PersonalRoute, to tab: AppTab) {
        switch tab {
        case .reading:
            readingPath.append(route)
        case .books:
            booksPath.append(route)
        case .notes:
            notesPath.append(route)
        case .profile:
            profilePath.append(route)
        case .search:
            searchPath.append(route)
        }
    }

    /// 合并事务完成后原位替换当前合并 route，返回时直接回到来源列表而不会重建已失效页面。
    private func replaceCurrentTopWithMergedViewer(
        source: ContentViewerSourceContext,
        itemID: ContentViewerItemID,
        in tab: AppTab
    ) {
        let route = contentRoute(for: source, initialItem: itemID)
        withAnimation(reduceMotion ? nil : .snappy) {
            switch tab {
            case .reading:
                replaceTop(of: &readingPath, with: route)
            case .books:
                replaceTop(of: &booksPath, with: route)
            case .notes:
                replaceTop(of: &notesPath, with: route)
            case .profile:
                replaceTop(of: &profilePath, with: route)
            case .search:
                replaceTop(of: &searchPath, with: route)
            }
        }
    }

    /// 搜索结果覆盖层拥有独立栈；合并成功时只替换 cover 顶层，不触碰底层搜索 Tab 的现场。
    private func replaceSearchCoverTopWithMergedViewer(
        source: ContentViewerSourceContext,
        itemID: ContentViewerItemID
    ) {
        let route = contentRoute(for: source, initialItem: itemID)
        withAnimation(reduceMotion ? nil : .snappy) {
            replaceTop(of: &searchResultCoverPath, with: route)
        }
    }

    private func replaceTop(of path: inout NavigationPath, with route: ContentRoute) {
        if !path.isEmpty {
            path.removeLast()
        }
        path.append(route)
    }

    /// 搜索结果详情以系统全屏覆盖打开，底层 TabView 与搜索页保持原有身份和状态。
    private func openSearchResultCover(_ target: SearchResultViewerTarget) {
        guard searchResultCover == nil else { return }
        searchResultCoverPath = NavigationPath()
        shouldRestoreSearchPresentationAfterCover = selectedTab == .search && searchPath.isEmpty
        searchResultCover = SearchResultCover(target: target)
    }

    /// 关闭搜索结果全屏覆盖；覆盖层内仍有导航路径时先触发一次系统 pop，根详情再交给系统 dismiss。
    private func dismissSearchResultCover() {
        guard searchResultCover != nil else { return }
        if searchResultCoverPath.isEmpty {
            searchResultCover = nil
        } else {
            searchResultCoverPath.removeLast()
        }
    }

    /// 完成系统覆盖层清理并按进入详情前的搜索呈现状态恢复搜索宿主。
    private func completeSearchResultCoverDismissal() {
        searchResultCoverPath = NavigationPath()
        searchResultCover = nil
        if shouldRestoreSearchPresentationAfterCover,
           selectedTab == .search,
           searchPath.isEmpty {
            setSearchPresented(true, disablesAnimations: true)
        }
        shouldRestoreSearchPresentationAfterCover = false
    }

    /// 按当前 Tab 和搜索栈深度同步系统搜索宿主；只在 Tab/path 变化时恢复，避免覆盖用户在搜索根页主动关闭搜索框的选择。
    private func syncSearchPresentationForCurrentState() {
        if selectedTab == .search && searchPath.isEmpty {
            setSearchPresented(true, disablesAnimations: false)
        } else if selectedTab != .search {
            setSearchPresented(false, disablesAnimations: true)
        }
    }

    private func setSearchPresented(_ isPresented: Bool, disablesAnimations: Bool) {
        guard self.isSearchPresented != isPresented || (!isPresented && isSearchFieldFocused) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = disablesAnimations
        withTransaction(transaction) {
            if !isPresented {
                isSearchFieldFocused = false
            }
            self.isSearchPresented = isPresented
        }
    }

    /// 防御系统搜索框在覆盖层或焦点切换期间产生的瞬时文本回写，保留当前明确提交的关键词。
    private func shouldIgnoreSearchHostTextUpdate(_ newValue: String) -> Bool {
        if newValue.isEmpty, !searchQuery.isEmpty, shouldRestoreSearchPresentationAfterCover {
            return true
        }
        if let protectedGlobalSearchQuery,
           newValue != protectedGlobalSearchQuery,
           !isSearchFieldFocused {
            return true
        }
        return false
    }

    /// 系统搜索框提交由搜索宿主捕获，并交给统一协调器错开键盘动画与结果刷新。
    private func submitGlobalSearchQuery() {
        commitGlobalSearch(searchQuery, source: .keyboard)
    }

    /// 记录最近搜索词按下意图；任务固定在 MainActor，fallback 会在 Button release 被系统失焦吞掉时消费同一 token。
    private func beginGlobalSearchSuggestion(_ rawSuggestion: String) {
        let keyword = rawSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        pendingGlobalSearchSuggestionTask?.cancel()

        let pending = PendingGlobalSearchSuggestion(keyword: keyword)
        pendingGlobalSearchSuggestion = pending
        protectedGlobalSearchQuery = keyword
        if selectedTab == .search, searchPath.isEmpty {
            setSearchPresented(true, disablesAnimations: true)
        }
        dismissGlobalSearchKeyboard()

        pendingGlobalSearchSuggestionTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: GlobalSearchCommitPolicy.suggestionFallbackSubmitDelayNanoseconds)
                try Task.checkCancellation()
                consumePendingGlobalSearchSuggestion(pending)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// 历史词按下后若被识别为滚动或拖离，取消同一关键词的 fallback 提交，避免非点击手势触发搜索。
    private func cancelGlobalSearchSuggestion(_ rawSuggestion: String) {
        let keyword = rawSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              pendingGlobalSearchSuggestion?.keyword == keyword else { return }
        clearPendingGlobalSearchSuggestion()
        if protectedGlobalSearchQuery == keyword {
            protectedGlobalSearchQuery = nil
        }
    }

    /// 最近搜索词点击代表直接提交搜索；若按下阶段已有 pending token，则消费同一次交互避免双提交。
    private func commitGlobalSearchSuggestion(_ suggestion: String) {
        let keyword = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        if let pendingGlobalSearchSuggestion,
           pendingGlobalSearchSuggestion.keyword == keyword {
            consumePendingGlobalSearchSuggestion(pendingGlobalSearchSuggestion)
        } else {
            clearPendingGlobalSearchSuggestion()
            commitGlobalSearch(keyword, source: .suggestion)
        }
    }

    /// 消费一次历史词按下意图；按 token 校验防止 fallback 与 Button action 竞态重复下发搜索。
    private func consumePendingGlobalSearchSuggestion(_ pending: PendingGlobalSearchSuggestion) {
        guard pendingGlobalSearchSuggestion?.id == pending.id else { return }
        clearPendingGlobalSearchSuggestion()
        commitGlobalSearch(pending.keyword, source: .suggestion)
    }

    /// 统一编排全局搜索提交：用 SwiftUI 焦点状态释放键盘，并把历史词写入错开系统 search field 的布局切换窗口。
    /// - Note: 任务固定在 MainActor 写入 SwiftUI 状态；等待期间若用户重新聚焦并修改输入，会取消待提交关键词，避免过期搜索回写。
    private func commitGlobalSearch(_ rawKeyword: String, source: GlobalSearchCommitSource) {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        clearPendingGlobalSearchSuggestion()
        pendingGlobalSearchSubmitTask?.cancel()

        let token = UUID()
        globalSearchCommitToken = token
        protectedGlobalSearchQuery = keyword
        if !source.defersQueryWriteUntilFocusSettles, searchQuery != keyword {
            searchQuery = keyword
        }
        if selectedTab == .search, searchPath.isEmpty {
            setSearchPresented(true, disablesAnimations: true)
        }
        dismissGlobalSearchKeyboard()

        pendingGlobalSearchSubmitTask = Task { @MainActor in
            do {
                try await sleepIfNeeded(nanoseconds: source.focusSettleDelayNanoseconds)
                try Task.checkCancellation()
                guard globalSearchCommitToken == token else { return }
                if source.defersQueryWriteUntilFocusSettles, searchQuery != keyword {
                    searchQuery = keyword
                }

                try await sleepIfNeeded(nanoseconds: source.submitDelayNanoseconds)
                try Task.checkCancellation()
                guard globalSearchCommitToken == token else { return }
                searchSubmitRequest = GlobalSearchSubmitRequest(query: keyword)

                try await Task.sleep(nanoseconds: GlobalSearchCommitPolicy.queryClearProtectionGraceNanoseconds)
                try Task.checkCancellation()
                guard globalSearchCommitToken == token else { return }
                protectedGlobalSearchQuery = nil
                globalSearchCommitToken = nil
                pendingGlobalSearchSubmitTask = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// 只在确有延迟需要时挂起当前提交任务，避免 0ns sleep 额外切出当前 MainActor 片段。
    private func sleepIfNeeded(nanoseconds: UInt64) async throws {
        guard nanoseconds > 0 else { return }
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    /// 取消仍在等待的全局搜索提交，并解除对系统搜索框空文本回写的保护。
    private func cancelPendingGlobalSearchCommit() {
        clearPendingGlobalSearchSuggestion()
        pendingGlobalSearchSubmitTask?.cancel()
        pendingGlobalSearchSubmitTask = nil
        protectedGlobalSearchQuery = nil
        globalSearchCommitToken = nil
    }

    /// 清理历史词按下阶段的 fallback 任务；用户主动改写输入或提交落地时用于收口竞态窗口。
    private func clearPendingGlobalSearchSuggestion() {
        pendingGlobalSearchSuggestionTask?.cancel()
        pendingGlobalSearchSuggestionTask = nil
        pendingGlobalSearchSuggestion = nil
    }

    /// 最近搜索词注入后主动释放系统搜索框焦点，避免软键盘遮挡用户刚触发的结果列表。
    private func dismissGlobalSearchKeyboard() {
        isSearchFieldFocused = false
    }

    private func openBookManagementGuide() {
        guard let url = URL(string: "https://docs.xmnote.com/#/book/bookmanagement") else { return }
        openURL(url)
    }

    private func prepareForBookCollectionImport(_ request: BookCollectionImportRequest) {
        selectedTab = .books
        if request.source == .systemShare {
            booksPath = NavigationPath()
        }
    }

    private func contentRoute(
        for source: ContentViewerSourceContext,
        initialItem: ContentViewerItemID
    ) -> ContentRoute {
        .contentViewer(source: source, initialItemID: initialItem, keyword: "")
    }

    /// SceneStateStore 完成解码后一次性恢复根选择与五个系统 NavigationPath，随后才开放写回门闩。
    private func restoreFromSceneSnapshot() {
        let snapshot = sceneStateStore.snapshot
        selectedTab = snapshot.selectedTab
        searchQuery = snapshot.searchQuery
        readingPath = restoredPath(for: .reading)
        booksPath = restoredPath(for: .books)
        notesPath = restoredPath(for: .notes)
        profilePath = restoredPath(for: .profile)
        searchPath = restoredPath(for: .search)
        syncSearchPresentationForCurrentState()
    }

    /// SceneStateStore 已完成 CodableRepresentation 解码；这里直接交还系统重建路径，避免依赖其不透明编码格式。
    private func restoredPath(for tab: AppTab) -> NavigationPath {
        guard let representation = sceneStateStore.pathRepresentation(for: tab) else {
            return NavigationPath()
        }
        return NavigationPath(representation)
    }

    private func persistCurrentSceneSnapshot() {
        guard canPersistSceneSnapshot else { return }
        sceneStateStore.updateSelectedTab(selectedTab)
        sceneStateStore.updateSearchQuery(searchQuery)
        sceneStateStore.updatePath(readingPath, for: .reading)
        sceneStateStore.updatePath(booksPath, for: .books)
        sceneStateStore.updatePath(notesPath, for: .notes)
        sceneStateStore.updatePath(profilePath, for: .profile)
        sceneStateStore.updatePath(searchPath, for: .search)
    }

    private func persistPath(_ path: NavigationPath, for tab: AppTab) {
        guard canPersistSceneSnapshot else { return }
        sceneStateStore.updatePath(path, for: tab)
    }

    private func pathPersistenceSignature(for path: NavigationPath) -> String {
        guard let representation = path.codable,
              let data = try? JSONEncoder().encode(representation) else {
            return path.isEmpty ? "empty" : "non-codable-\(path.count)"
        }
        return data.base64EncodedString()
    }

    #if DEBUG
    /// UI Test 启动后直达书籍首页或目标二级列表，减少测试对真实恢复状态与首页聚合入口布局的依赖。
    @MainActor
    private func applyUITestLaunchRouteIfNeeded() async {
        guard !didApplyUITestLaunchRoute else {
            return
        }
        let requestedRoute = UITestLaunchConfiguration.requestedBookRoute
        guard UITestLaunchConfiguration.shouldOpenDefaultBookshelf || requestedRoute != nil else { return }
        didApplyUITestLaunchRoute = true
        selectedTab = .books
        await Task.yield()
        if let requestedRoute {
            append(requestedRoute, to: .books)
        }
    }
    #endif
}

/// 搜索结果系统全屏覆盖的根级呈现项，保持底层 TabView 与搜索状态不参与导航栈变化。
private struct SearchResultCover: Identifiable {
    let id = UUID()
    let target: SearchResultViewerTarget
}

/// 最近搜索词按下阶段的待消费意图，用独立 id 区分连续点击同一个关键词的不同交互。
private struct PendingGlobalSearchSuggestion: Identifiable, Equatable {
    let id = UUID()
    let keyword: String
}

/// 运行时依赖未就绪时的根 Tab 内容；只保留真实页面结构，不暴露伪内容或可操作元素。
private struct MainTabBootstrapPage: View {
    let tab: AppTab
    let snapshot: AppSceneSnapshot
    let hasRestoredNavigation: Bool

    var body: some View {
        Group {
            if hasRestoredNavigation {
                Color.surfacePage
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .tabBar)
            } else {
                MainTabBootstrapHome(tab: tab, snapshot: snapshot)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 启动壳层复用生产首页的背景、顶部渐变与切换器，保证系统启动页之后立即建立真实版式重心。
private struct MainTabBootstrapHome: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tab: AppTab
    let snapshot: AppSceneSnapshot

    private var topBarHeight: CGFloat {
        dynamicTypeSize >= .accessibility1 ? 60 : 56
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            MainTabBootstrapContent(tab: tab, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, topBarHeight)

            HomeTopHeaderGradient()
                .allowsHitTesting(false)

            MainTabBootstrapTopBar(tab: tab, snapshot: snapshot)
                .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 启动壳层顶部栏使用恢复后的真实栏目名称，右侧操作仅绘制生产组件外观且不响应交互。
private struct MainTabBootstrapTopBar: View {
    let tab: AppTab
    let snapshot: AppSceneSnapshot

    @ViewBuilder
    var body: some View {
        switch tab {
        case .reading:
            TopSwitcher(
                selection: .constant(snapshot.reading.selectedSubTab),
                tabs: ReadingSubTab.allCases,
                titleProvider: \.title
            ) {
                staticAddMenu
            }
        case .books:
            TopSwitcher(
                selection: .constant(snapshot.books.selectedSubTab),
                tabs: BookSubTab.allCases,
                titleProvider: \.title
            ) {
                staticAddMenu
            }
        case .notes:
            TopSwitcher(
                selection: .constant(snapshot.notes.selectedSubTab),
                tabs: NoteSubTab.allCases,
                titleProvider: \.title
            ) {
                TopBarActionPill {
                    TopBarActionIcon(
                        systemName: "arrow.up.arrow.down",
                        hitShape: .rectangle
                    )
                } trailing: {
                    TopBarActionIcon(systemName: "plus", hitShape: .rectangle)
                }
            }
        case .profile:
            TopSwitcher(title: "我的") {
                TopBarActionPill {
                    TopBarActionIcon(systemName: "gearshape", hitShape: .rectangle)
                } trailing: {
                    TopBarActionIcon(systemName: "plus", hitShape: .rectangle)
                }
            }
        case .search:
            TopSwitcher(title: "搜索", quote: "") {
                EmptyView()
            }
        }
    }

    private var staticAddMenu: some View {
        AddMenuCircleButton(
            onAddBook: {},
            onAddNote: {},
            usesGlassStyle: true
        )
    }
}

/// 五个根页的低对比静态结构，沿用生产页面的容器节奏但不承载数据或加载文案。
private struct MainTabBootstrapContent: View {
    let tab: AppTab
    let snapshot: AppSceneSnapshot

    @ViewBuilder
    var body: some View {
        switch tab {
        case .reading:
            MainTabReadingBootstrapContent(selectedSubTab: snapshot.reading.selectedSubTab)
        case .books:
            MainTabBooksBootstrapContent(selectedSubTab: snapshot.books.selectedSubTab)
        case .notes:
            MainTabNotesBootstrapContent(selectedSubTab: snapshot.notes.selectedSubTab)
        case .profile:
            MainTabProfileBootstrapContent()
        case .search:
            Color.clear
        }
    }
}

/// 在读页按恢复的二级栏目保留热力图卡、指标卡、双卡或列表的真实空间节奏。
private struct MainTabReadingBootstrapContent: View {
    let selectedSubTab: ReadingSubTab

    var body: some View {
        Group {
            if selectedSubTab == .reading {
                ReadingDashboardLoadingShell()
            } else {
                ScrollView {
                    Group {
                        switch selectedSubTab {
                        case .reading:
                            Color.clear
                        case .timeline:
                            BootstrapGroupedListStructure(rowCount: 5)
                        case .statistics:
                            statisticsStructure
                        }
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.half)
                    .padding(.bottom, Spacing.section)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var statisticsStructure: some View {
        VStack(spacing: Spacing.base) {
            BootstrapMetricsCard()
            BootstrapWidePanel(height: 176)
            HStack(spacing: Spacing.base) {
                BootstrapFeatureCard()
                BootstrapFeatureCard()
            }
        }
    }
}

/// 书籍页使用封面网格或书单面板骨架，宽度随容器变化但不制造具体书目。
private struct MainTabBooksBootstrapContent: View {
    let selectedSubTab: BookSubTab

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Spacing.base),
        count: 3
    )

    var body: some View {
        ScrollView {
            Group {
                switch selectedSubTab {
                case .books:
                    LazyVGrid(columns: columns, spacing: Spacing.section) {
                        ForEach(0..<6, id: \.self) { _ in
                            BootstrapBookGridItem()
                        }
                    }
                case .collections:
                    VStack(spacing: Spacing.base) {
                        ForEach(0..<4, id: \.self) { _ in
                            BootstrapCollectionPanel()
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.section)
        }
        .scrollIndicators(.hidden)
    }
}

/// 笔记页保留分组列表的段落密度；回顾页使用更疏朗的摘要卡节奏。
private struct MainTabNotesBootstrapContent: View {
    let selectedSubTab: NoteSubTab

    var body: some View {
        ScrollView {
            Group {
                switch selectedSubTab {
                case .notes:
                    BootstrapGroupedListStructure(rowCount: 5)
                case .review:
                    VStack(spacing: Spacing.base) {
                        BootstrapWidePanel(height: 132)
                        BootstrapGroupedListStructure(rowCount: 3)
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.section)
        }
        .scrollIndicators(.hidden)
    }
}

/// 我的页复刻生产设置分组的面板尺度与行高，不显示会员状态或具体设置内容。
private struct MainTabProfileBootstrapContent: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.comfortable) {
                BootstrapSettingsPanel(rowCount: 2)
                BootstrapSettingsPanel(rowCount: 4)
                BootstrapSettingsPanel(rowCount: 3)
                BootstrapSettingsPanel(rowCount: 2)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .scrollIndicators(.hidden)
    }
}

/// 指标卡以等分栏保留生产趋势区的基线关系，所有块均为同一中性色阶。
private struct BootstrapMetricsCard: View {
    var body: some View {
        CardContainer {
            HStack(spacing: Spacing.none) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        BootstrapLine(width: 42, height: 7)
                        BootstrapLine(width: 68, height: 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.base)

                    if index < 2 {
                        Rectangle()
                            .fill(Color.surfaceBorderSubtle.opacity(0.42))
                            .frame(width: CardStyle.borderWidth, height: 38)
                    }
                }
            }
            .padding(.vertical, Spacing.contentEdge)
        }
        .frame(height: 84)
    }
}

/// 双卡区域按生产卡片比例保留视觉重心，不放置图标、插画或大色块。
private struct BootstrapFeatureCard: View {
    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                BootstrapLine(width: 64)
                BootstrapLine(width: 94, height: 14)
                Spacer(minLength: Spacing.base)
                HStack(alignment: .bottom, spacing: Spacing.compact) {
                    ForEach([24.0, 42.0, 32.0, 54.0, 38.0], id: \.self) { height in
                        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                            .fill(Color.controlFillSecondary.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
        .aspectRatio(0.88, contentMode: .fit)
    }
}

/// 书架网格占位沿用封面纵横比和两级文本基线，确保切换到真实封面时列宽不变化。
private struct BootstrapBookGridItem: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle.opacity(0.32), lineWidth: CardStyle.borderWidth)
                }
                .aspectRatio(0.68, contentMode: .fit)
            BootstrapLine(height: 8)
            BootstrapLine(width: 58, height: 7)
        }
    }
}

/// 书单面板以重叠封面轮廓和两条信息基线表达生产结构，不注入任何具体内容。
private struct BootstrapCollectionPanel: View {
    var body: some View {
        CardContainer {
            HStack(spacing: Spacing.contentEdge) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(Color.controlFillSecondary.opacity(0.58))
                        .frame(width: 54, height: 76)
                        .offset(x: 8)
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(Color.controlFillSecondary)
                        .frame(width: 54, height: 76)
                        .offset(x: -8)
                }
                .frame(width: 76)

                VStack(alignment: .leading, spacing: Spacing.base) {
                    BootstrapLine(width: 112, height: 10)
                    BootstrapLine(width: 76)
                }
            }
            .padding(Spacing.contentEdge)
        }
        .frame(height: 112)
    }
}

/// 分组列表保留卡片边界、行距和分隔线，适配时间线与笔记首页的共同版式节奏。
private struct BootstrapGroupedListStructure: View {
    let rowCount: Int

    var body: some View {
        VStack(spacing: Spacing.base) {
            BootstrapWidePanel(height: 82)
            CardContainer {
                VStack(spacing: Spacing.none) {
                    ForEach(0..<rowCount, id: \.self) { index in
                        HStack(spacing: Spacing.base) {
                            RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                                .fill(Color.controlFillSecondary.opacity(0.72))
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: Spacing.cozy) {
                                BootstrapLine(width: index.isMultiple(of: 2) ? 124 : 96, height: 9)
                                BootstrapLine(width: index.isMultiple(of: 2) ? 184 : 148)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 64)
                        .padding(.horizontal, Spacing.contentEdge)

                        if index < rowCount - 1 {
                            Rectangle()
                                .fill(Color.surfaceBorderSubtle.opacity(0.36))
                                .frame(height: CardStyle.borderWidth)
                                .padding(.leading, 66)
                        }
                    }
                }
            }
        }
    }
}

/// 我的页设置面板按生产 44pt 行高组织，圆角与表面色均复用现有令牌。
private struct BootstrapSettingsPanel: View {
    let rowCount: Int

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(spacing: Spacing.none) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HStack(spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                            .fill(Color.controlFillSecondary.opacity(0.72))
                            .frame(width: 24, height: 24)
                        BootstrapLine(width: index.isMultiple(of: 2) ? 92 : 116, height: 9)
                        Spacer(minLength: 0)
                        BootstrapLine(width: 18, height: 7)
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, Spacing.contentEdge)

                    if index < rowCount - 1 {
                        Rectangle()
                            .fill(Color.surfaceBorderSubtle.opacity(0.36))
                            .frame(height: CardStyle.borderWidth)
                            .padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, Spacing.half)
        }
    }
}

/// 宽面板是启动壳层内的纯结构容器，提供疏密有别的短基线而不展示假数据。
private struct BootstrapWidePanel: View {
    let height: CGFloat

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                BootstrapLine(width: 82, height: 9)
                BootstrapLine(width: 156)
                BootstrapLine(width: 112)
                Spacer(minLength: 0)
            }
            .padding(Spacing.contentEdge)
        }
        .frame(height: height)
    }
}

/// 中性短基线只用于表达排版层级，不使用文字或品牌色制造伪内容。
private struct BootstrapLine: View {
    var width: CGFloat?
    var height: CGFloat

    init(width: CGFloat? = nil, height: CGFloat = 6) {
        self.width = width
        self.height = height
    }

    var body: some View {
        Capsule()
            .fill(Color.controlFillSecondary.opacity(0.72))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
    }
}

private extension View {
    /// 仅在搜索 Tab 激活时挂载根级搜索宿主，避免其他导航栈长期持有系统搜索与滚动宿主状态。
    func mainTabSearchHost(
        isEnabled: Bool,
        searchText: Binding<String>,
        isPresented: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void
    ) -> some View {
        modifier(
            MainTabSearchHostModifier(
                isEnabled: isEnabled,
                searchText: searchText,
                isPresented: isPresented,
                isFocused: isFocused,
                onSubmit: onSubmit
            )
        )
    }
}

/// MainTabSearchHostModifier 条件挂载搜索 Tab 的系统宿主，隔离非搜索 Tab 的导航与滚动状态。
private struct MainTabSearchHostModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String
    @Binding var isPresented: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .tabViewSearchActivation(.searchTabSelection)
                .searchable(text: $searchText, isPresented: $isPresented, prompt: "搜索本地内容")
                .searchFocused(isFocused)
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

#Preview {
    MainTabView(
        runtime: nil,
        initialSceneSnapshot: AppSceneSnapshot.empty(dataEpoch: 0)
    )
        .environment(AppState())
        .environment(SceneStateStore())
        .environment(BookCollectionImportRouter())
}
