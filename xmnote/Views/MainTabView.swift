//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

/**
 * [INPUT]: 依赖 Reading/Book/Note/Content/Personal/Search 各模块容器视图与对应路由枚举，依赖 BookCollectionImportRouter 承接外部书单导入，依赖 DebugRoute 提供调试页面跳转，依赖 openURL 打开外部帮助文档，依赖 SwiftUI search focus 状态协调全局搜索输入
 * [OUTPUT]: 对外提供 MainTabView（五个主 Tab 的 NavigationStack 组织、书单分享导入入口定位、普通目的地分发、搜索来源详情系统全屏覆盖与 DEBUG UI Test 书架首页/二级列表直达路由）
 * [POS]: 应用根导航入口，负责跨模块路由承接（含书架聚合列表、书架管理入口、在读页热力图点击进入阅读日历、内容查看与内容编辑、搜索来源详情根级 fullScreenCover）
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
    @Environment(BookCollectionImportRouter.self) private var bookCollectionImportRouter
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
    #if DEBUG
    @State private var didApplyUITestLaunchRoute = false
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("在读", systemImage: "calendar", value: .reading) {
                NavigationStack(path: $readingPath) {
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
                        .navigationDestination(for: DebugRoute.self) { route in
                            debugDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                        .navigationDestination(for: ReadingRoute.self) { route in
                            readingDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                        .navigationDestination(for: BookRoute.self) { route in
                            bookDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                        .navigationDestination(for: NoteRoute.self) { route in
                            noteDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                        .navigationDestination(for: ContentRoute.self) { route in
                            contentDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                }
            }

            Tab("书籍", systemImage: "book", value: .books) {
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
                            noteDestination(for: route)
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
                }
            }

            Tab("笔记", systemImage: "archivebox", value: .notes) {
                NavigationStack(path: $notesPath) {
                    NoteContainerView(
                        onAddBook: { append(BookRoute.add, to: .notes) },
                        onAddNote: { append(NoteRoute.create(seed: .empty), to: .notes) },
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
                            noteDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                        .navigationDestination(for: ContentRoute.self) { route in
                            contentDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                }
            }

            Tab("我的", systemImage: "person", value: .profile) {
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
                            noteDestination(for: route)
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
                }
            }

            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
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
                            noteDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                        }
                        .navigationDestination(for: ContentRoute.self) { route in
                            contentDestination(for: route)
                                .toolbar(.hidden, for: .tabBar)
                    }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .mainTabSearchHost(
            searchText: searchHostTextBinding,
            isPresented: $isSearchPresented,
            isFocused: $isSearchFieldFocused,
            onSubmit: submitGlobalSearchQuery
        )
        .tabViewSearchActivation(.searchTabSelection)
        .onChange(of: selectedTab) { _, _ in
            syncSearchPresentationForCurrentState()
        }
        .onChange(of: searchPath.count) { _, _ in
            syncSearchPresentationForCurrentState()
        }
        .onChange(of: bookCollectionImportRouter.pendingImport) { _, request in
            guard let request else { return }
            prepareForBookCollectionImport(request)
        }
        .fullScreenCover(
            item: $searchResultCover,
            onDismiss: completeSearchResultCoverDismissal
        ) { cover in
            searchResultCoverContent(for: cover)
        }
        .task {
            if let pendingImport = bookCollectionImportRouter.pendingImport {
                prepareForBookCollectionImport(pendingImport)
            }
            #if DEBUG
            await applyUITestLaunchRouteIfNeeded()
            #endif
        }
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
    private func searchResultCoverContent(for cover: SearchResultCover) -> some View {
        NavigationStack(path: $searchResultCoverPath) {
            searchResultCoverDestination(for: cover.target)
                .navigationDestination(for: BookRoute.self) { route in
                    searchResultBookDestination(for: route)
                        .toolbar(.hidden, for: .tabBar)
                }
                .navigationDestination(for: NoteRoute.self) { route in
                    noteDestination(for: route)
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
            BookDetailView(bookId: bookId)
        case .edit(let bookId):
            BookEditorView(mode: .edit(bookId: bookId))
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

    // MARK: - Reading Destinations

    @ViewBuilder
    private func readingDestination(for route: ReadingRoute) -> some View {
        switch route {
        case .bookDetail:
            Text("书籍详情")
        case .readingSession:
            Text("阅读计时")
        case .readCalendar(let date):
            ReadCalendarView(date: date)
        }
    }

    // MARK: - Book Destinations

    @ViewBuilder
    private func bookDestination(for route: BookRoute) -> some View {
        switch route {
        case .detail(let bookId):
            BookDetailView(bookId: bookId)
        case .edit(let bookId):
            BookEditorView(mode: .edit(bookId: bookId))
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
    private func noteDestination(for route: NoteRoute) -> some View {
        switch route {
        case .detail(let noteId):
            NoteDetailView(noteId: noteId)
        case .edit(let noteId):
            NoteEditorView(mode: .edit(noteId: noteId))
        case .create(let seed):
            NoteEditorView(mode: .create, seed: seed)
        case .notesByTag:
            Text("标签笔记")
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
        case .relevantEditor(let contentId):
            RelevantEditorView(contentId: contentId)
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
            ReadCalendarView(date: nil)
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
            Text("API 集成")
        case .aiConfiguration:
            Text("AI 配置")
        case .tagManagement:
            Text("标签管理")
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

private extension View {
    /// 稳定挂载搜索 Tab 的根级搜索宿主，让 TabView 统一管理 search tab activation 与系统输入框生命周期。
    func mainTabSearchHost(
        searchText: Binding<String>,
        isPresented: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void
    ) -> some View {
        modifier(
            MainTabSearchHostModifier(
                searchText: searchText,
                isPresented: isPresented,
                isFocused: isFocused,
                onSubmit: onSubmit
            )
        )
    }
}
/// MainTabSearchHostModifier 承载搜索 tab 的根级 searchable 宿主，保持 TabView 外层结构身份稳定。
private struct MainTabSearchHostModifier: ViewModifier {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        content
            .searchable(text: $searchText, isPresented: $isPresented, prompt: "搜索本地内容")
            .searchFocused(isFocused)
            .onSubmit(of: .search, onSubmit)
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
