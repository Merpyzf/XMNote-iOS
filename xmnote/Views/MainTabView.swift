//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

/**
 * [INPUT]: 依赖可选 AppRuntimeContext、已原子恢复的 AppSceneSnapshot、scene 级 AppNavigationCoordinator、阅读日历、外部导入/网页动作与各业务目的页
 * [OUTPUT]: 对外提供 MainTabView（五个类型安全浏览栈、首帧 Tab 稳定显现、回顾同构启动壳层、带根级退出控件的单一全屏任务栈、恢复表面门控、阅读计时 UIKit Zoom、底部计时条与退场后一次性回流）
 * [POS]: 应用根导航宿主，只消费协调器状态并使用系统 push/cover；恢复目的页提交前不暴露底层根页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 描述计时页需要加载的业务对象，避免呈现层改写计时会话身份。
enum ReadingTimerPresentationRequest: Equatable {
    case book(Int64)
    case record(recordId: Int64, bookId: Int64)

    var bookId: Int64 {
        switch self {
        case .book(let bookId):
            return bookId
        case .record(_, let bookId):
            return bookId
        }
    }

    var recordId: Int64? {
        switch self {
        case .book:
            return nil
        case .record(let recordId, _):
            return recordId
        }
    }
}

/// 标识实际承载计时全屏页的可见层级，搜索覆盖层与根 Tab 共用同一呈现状态。
enum ReadingTimerPresentationHost: Equatable {
    case mainTab
    case bottomAccessory
}

/// 记录计时页打开时的导航来源，确保关闭后动作回到原宿主而非读取易变的当前 Tab。
enum ReadingTimerPresentationOrigin: Equatable {
    case tab(AppTab)
}

/// 阅读计时全屏页的稳定呈现票据，统一携带请求、宿主、来源与转场身份。
enum ReadingTimerPresentationSource: Equatable {
    case registered(AnyHashable)
    case rootFallback
}

struct ReadingTimerPresentation: Identifiable, Equatable {
    let id = UUID()
    let request: ReadingTimerPresentationRequest
    let host: ReadingTimerPresentationHost
    let origin: ReadingTimerPresentationOrigin
    let source: ReadingTimerPresentationSource
}

/// 普通页面来源只携带呈现桥接所需的显式依赖，不把计时业务状态塞进子页面环境。
struct ReadingTimerZoomSourceConfiguration {
    let owner: ReadingTimerZoomPresentationOwner
    let sourceID: AnyHashable
    let dismissalRequest: ReadingTimerZoomDismissalRequest?
    let isInteractiveDismissEnabled: Bool
    let preparePresentation: () -> ReadingTimerPresentation?
    let onDismissalRequested: (ReadingTimerPresentation, ReadingTimerDismissReason) -> Void
    let onDismissalCompleted: (ReadingTimerPresentation, ReadingTimerDismissReason) -> Void
}

/// 由根容器预配置宿主与来源，供在读首页卡片创建稳定的 Zoom 来源票据。
typealias ReadingTimerZoomConfigurationFactory = (
    _ sourceID: AnyHashable,
    _ request: ReadingTimerPresentationRequest
) -> ReadingTimerZoomSourceConfiguration

/// 描述计时全屏页完成关闭后才可执行的导航动作，避免导航与系统退场竞争。
private enum ReadingTimerPostDismissAction: Equatable {
    case openNote(bookId: Int64, origin: ReadingTimerPresentationOrigin)
}

/// 冻结一次关闭请求的业务语义，交由系统呈现的 onDismiss 完成生命周期收口。
private struct ReadingTimerPendingDismissal: Equatable {
    let presentationID: UUID
    let reason: ReadingTimerDismissReason
    let postDismissAction: ReadingTimerPostDismissAction?
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

/// 标识业务路由当前属于根 Tab 浏览栈还是全屏任务栈，确保同一入口按宿主关系分流。
private enum AppRouteHost: Hashable {
    case tab(AppTab)
    case task
}

/// 标识冷启动恢复时必须先完成挂载的最终浏览表面，防止系统栈协调期间短暂暴露根页。
private struct RestoredNavigationSurface: Hashable {
    let tab: AppTab
    let route: AppRoute
}

/// 应用主导航容器，组织五个主 Tab 及跨模块路由跳转。
struct MainTabView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Environment(SceneStateStore.self) private var sceneStateStore
    @Environment(BookCollectionImportRouter.self) private var bookCollectionImportRouter
    @Environment(ReadingTimerDeepLinkRouter.self) private var readingTimerDeepLinkRouter
    @Environment(DesktopWebSessionCoordinator.self) private var desktopWebSessionCoordinator
    @Environment(ReadingTimerSettingsStore.self) private var readingTimerSettingsStore
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.scenePhase) private var scenePhase
    let runtime: AppRuntimeContext?
    let initialSceneSnapshot: AppSceneSnapshot
    @State private var navigationCoordinator: AppNavigationCoordinator
    @State private var pendingRestoredNavigationSurface: RestoredNavigationSurface?
    @State private var readingTimerPresentation: ReadingTimerPresentation?
    @State private var pendingReadingTimerDismissal: ReadingTimerPendingDismissal?
    @State private var retainedReadingTimerTransitionSource: ReadingTimerSession?
    @State private var readingTimerZoomOwner = ReadingTimerZoomPresentationOwner()
    @State private var pendingReadingTimerDeepLinkRequest: ReadingTimerPresentationRequest?
    @State private var searchQuery = ""
    @State private var searchSubmitRequest: GlobalSearchSubmitRequest?
    @State private var isSearchPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var pendingGlobalSearchSuggestion: PendingGlobalSearchSuggestion?
    @State private var pendingGlobalSearchSuggestionTask: Task<Void, Never>?
    @State private var pendingGlobalSearchSubmitTask: Task<Void, Never>?
    @State private var protectedGlobalSearchQuery: String?
    @State private var globalSearchCommitToken: UUID?
    @State private var isInitialTabPresentationCovered = true
    #if DEBUG
    @State private var didApplyUITestLaunchRoute = false
    #endif

    /// 以 SceneStorage 解码结果建立首帧 Tab 与路径初值；后续运行时发布不会重置这些本地导航状态。
    init(runtime: AppRuntimeContext?, initialSceneSnapshot: AppSceneSnapshot) {
        self.runtime = runtime
        self.initialSceneSnapshot = initialSceneSnapshot
        let restoredTab = initialSceneSnapshot.selectedTab
        let restoredSurface = initialSceneSnapshot.navigation
            .path(for: restoredTab)
            .last
            .map { RestoredNavigationSurface(tab: restoredTab, route: $0) }
        _navigationCoordinator = State(
            initialValue: AppNavigationCoordinator(snapshot: initialSceneSnapshot)
        )
        _pendingRestoredNavigationSurface = State(initialValue: restoredSurface)
        _searchQuery = State(initialValue: initialSceneSnapshot.searchQuery)
    }

    var body: some View {
        presentedTabContent
            .allowsHitTesting(
                pendingRestoredNavigationSurface == nil && !isInitialTabPresentationCovered
            )
            .accessibilityHidden(
                pendingRestoredNavigationSurface != nil || isInitialTabPresentationCovered
            )
            .overlay {
                if pendingRestoredNavigationSurface != nil {
                    RestoredNavigationSurfaceGate()
                }
            }
            .overlay {
                if isInitialTabPresentationCovered {
                    Color.surfacePage
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }
            }
    }

    /// 页面内部只通过协调器读写当前 Tab；保留短名称以减少计时与搜索业务中的噪声。
    private var selectedTab: AppTab {
        get { navigationCoordinator.selectedTab }
        nonmutating set { navigationCoordinator.selectedTab = newValue }
    }

    private var readingPath: [AppRoute] { navigationCoordinator.path(for: .reading) }
    private var booksPath: [AppRoute] { navigationCoordinator.path(for: .books) }
    private var notesPath: [AppRoute] { navigationCoordinator.path(for: .notes) }
    private var profilePath: [AppRoute] { navigationCoordinator.path(for: .profile) }
    private var searchPath: [AppRoute] { navigationCoordinator.path(for: .search) }

    /// 构建五个彼此独立的浏览栈；这里只描述页面树，不附加根级状态监听与呈现器。
    private var tabContent: some View {
        TabView(selection: $navigationCoordinator.selectedTab) {
            Tab("在读", systemImage: "calendar", value: .reading) {
                NavigationStack(path: navigationCoordinator.pathBinding(for: .reading)) {
                    Group {
                        if let runtime {
                            ReadingContainerView(
                                onAddBook: { navigationCoordinator.present(.addBook) },
                                onAddNote: {
                                    navigationCoordinator.present(.noteEditor(mode: .create, seed: .empty))
                                },
                                onOpenReadCalendar: { date in
                                    navigationCoordinator.present(
                                        .readCalendar(initialDate: date)
                                    )
                                },
                                onOpenBookDetail: { bookId in
                                    append(BookRoute.detail(bookId: bookId), to: .reading)
                                },
                                onStartReading: { bookId in
                                    presentReadingTimer(
                                        request: .book(bookId),
                                        host: .mainTab,
                                        origin: .tab(.reading),
                                        source: .rootFallback
                                    )
                                },
                                readingTimerZoomConfigurationFactory: { sourceID, request in
                                    makeReadingTimerZoomConfiguration(
                                        sourceID: sourceID,
                                        request: request,
                                        host: .mainTab,
                                        origin: .tab(.reading),
                                        runtime: runtime
                                    )
                                },
                                onOpenContentViewer: { source, initialItem in
                                    navigationCoordinator.present(
                                        .contentViewer(
                                            source: source,
                                            initialItemID: initialItem,
                                            keyword: ""
                                        )
                                    )
                                }
                            )
                            .environment(runtime.databaseManager)
                            .environment(runtime.repositories)
                            .environment(runtime.readingTimerCoordinator)
                            .transition(.opacity)
                        } else {
                            MainTabBootstrapPage(
                                tab: .reading,
                                snapshot: bootstrapSceneSnapshot,
                                hasRestoredNavigation: !readingPath.isEmpty
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(runtimeTransitionAnimation, value: isRuntimeReady)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: AppRoute.self) { route in
                        appDestination(for: route, hostTab: .reading)
                    }
                }
            }

            Tab("书籍", systemImage: "book", value: .books) {
                NavigationStack(path: navigationCoordinator.pathBinding(for: .books)) {
                    Group {
                        if let runtime {
                            BookContainerView(
                                onAddBook: { navigationCoordinator.present(.addBook) },
                                onAddNote: {
                                    navigationCoordinator.present(.noteEditor(mode: .create, seed: .empty))
                                },
                                onOpenBookRoute: { openBookRoute($0, from: .tab(.books)) },
                                onOpenNoteRoute: { openNoteRoute($0, from: .tab(.books)) },
                                onOpenTagManagement: { append(PersonalRoute.tagManagement, to: .books) },
                                onOpenSourceManagement: { append(PersonalRoute.bookSource, to: .books) },
                                onOpenAuthorManagement: { append(PersonalRoute.authorManagement, to: .books) },
                                onOpenPressManagement: { append(PersonalRoute.pressManagement, to: .books) },
                                onOpenGuide: openBookManagementGuide
                            )
                            .environment(runtime.databaseManager)
                            .environment(runtime.repositories)
                            .environment(runtime.readingTimerCoordinator)
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
                    .navigationDestination(for: AppRoute.self) { route in
                        appDestination(for: route, hostTab: .books)
                    }
                }
            }

            Tab("笔记", systemImage: "archivebox", value: .notes) {
                NavigationStack(path: navigationCoordinator.pathBinding(for: .notes)) {
                    Group {
                        if let runtime {
                            NoteContainerView(
                                onAddBook: { navigationCoordinator.present(.addBook) },
                                onAddNote: {
                                    navigationCoordinator.present(.noteEditor(mode: .create, seed: .empty))
                                },
                                onOpenNoteRoute: { openNoteRoute($0, from: .tab(.notes)) },
                                onOpenBookRoute: { openBookRoute($0, from: .tab(.notes)) },
                                onOpenContentRoute: { openContentRoute($0, from: .tab(.notes)) },
                                onOpenContentViewer: { source, itemID in
                                    navigationCoordinator.present(
                                        .contentViewer(
                                            source: source,
                                            initialItemID: itemID,
                                            keyword: ""
                                        )
                                    )
                                }
                            )
                            .environment(runtime.databaseManager)
                            .environment(runtime.repositories)
                            .environment(runtime.readingTimerCoordinator)
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
                    .animation(notesRuntimeTransitionAnimation, value: isRuntimeReady)
                    .navigationDestination(for: AppRoute.self) { route in
                        appDestination(for: route, hostTab: .notes)
                    }
                }
            }

            Tab("我的", systemImage: "person", value: .profile) {
                NavigationStack(path: navigationCoordinator.pathBinding(for: .profile)) {
                    Group {
                        if let runtime {
                            PersonalView(
                                onAddBook: { navigationCoordinator.present(.addBook) },
                                onAddNote: {
                                    navigationCoordinator.present(.noteEditor(mode: .create, seed: .empty))
                                },
                                onOpenReadCalendar: {
                                    navigationCoordinator.present(
                                        .readCalendar(initialDate: nil)
                                    )
                                }
                            )
                            .environment(runtime.databaseManager)
                            .environment(runtime.repositories)
                            .environment(runtime.readingTimerCoordinator)
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
                    .navigationDestination(for: AppRoute.self) { route in
                        appDestination(for: route, hostTab: .profile)
                    }
                }
            }

            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack(path: navigationCoordinator.pathBinding(for: .search)) {
                    Group {
                        if let runtime {
                            GlobalSearchView(
                                query: $searchQuery,
                                submitRequest: searchSubmitRequest,
                                onBeginSearchSuggestion: beginGlobalSearchSuggestion,
                                onCancelSearchSuggestion: cancelGlobalSearchSuggestion,
                                onCommitSearchSuggestion: commitGlobalSearchSuggestion,
                                onPrepareHistoryClearConfirmation: dismissGlobalSearchKeyboard,
                                onOpenResult: openGlobalSearchResult
                            )
                            .environment(runtime.databaseManager)
                            .environment(runtime.repositories)
                            .environment(runtime.readingTimerCoordinator)
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
                    .navigationDestination(for: AppRoute.self) { route in
                        appDestination(for: route, hostTab: .search)
                    }
                }
            }
        }
    }

    /// 为 Tab 树挂载底部计时条、系统搜索宿主与统一导航环境。
    private var configuredTabContent: some View {
        tabContent
        .transaction { transaction in
            guard isInitialTabPresentationCovered else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .toolbarVisibility(
            navigationCoordinator.isTabChromeSuppressed ? .hidden : .automatic,
            for: .tabBar
        )
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(
            isEnabled: isReadingTimerAccessoryEnabled && !navigationCoordinator.isTabChromeSuppressed
        ) {
            if let runtime, let session = readingTimerAccessorySession {
                ReadingTimerAccessoryZoomSource(
                    owner: readingTimerZoomOwner,
                    session: session,
                    repositories: runtime.repositories,
                    timerSettings: readingTimerSettingsStore,
                    isWriting: runtime.readingTimerCoordinator.isWriting,
                    dismissalRequest: readingTimerZoomDismissalRequest,
                    preparePresentation: {
                        prepareReadingTimerAccessoryPresentation(
                            session: session,
                            runtime: runtime
                        )
                    },
                    onDismissalRequested: { presentation, reason in
                        requestReadingTimerDismissal(reason, for: presentation)
                    },
                    onDismissalCompleted: { presentation, reason in
                        completeReadingTimerZoomDismissal(
                            reason,
                            for: presentation
                        )
                    },
                    onTogglePlayback: { toggleGlobalReadingTimer(runtime: runtime) }
                )
                .environment(runtime.readingTimerCoordinator)
                .environment(runtime.repositories)
                .environment(readingTimerSettingsStore)
                .allowsHitTesting(!isReadingTimerAccessoryInteractionSuppressed)
                .accessibilityHidden(isReadingTimerAccessoryInteractionSuppressed)
            }
        }
        .mainTabSearchHost(
            searchText: searchHostTextBinding,
            isPresented: $isSearchPresented,
            isFocused: $isSearchFieldFocused,
            onSubmit: submitGlobalSearchQuery
        )
        .tabViewSearchActivation(.searchTabSelection)
        .environment(navigationCoordinator)
    }

    /// 监听可恢复浏览状态与跨进程事件；每个监听只把事件转交给对应 owner。
    private var observedTabContent: some View {
        configuredTabContent
        .onChange(of: selectedTab) { _, newTab in
            syncSearchPresentationForCurrentState()
        }
        .onChange(of: navigationCoordinator.browseState) { _, state in
            sceneStateStore.updateNavigation(
                selectedTab: state.selectedTab,
                navigation: state.navigation
            )
        }
        .onChange(of: searchQuery) { _, newQuery in
            sceneStateStore.updateSearchQuery(newQuery)
        }
        .onChange(of: searchPath.count) { _, _ in
            syncSearchPresentationForCurrentState()
        }
        .onChange(of: bookCollectionImportRouter.pendingImport) { _, request in
            guard runtime != nil, let request else { return }
            prepareForBookCollectionImport(request)
        }
        .onChange(of: desktopWebSessionCoordinator.premiumUpgradeRequestID) { _, requestID in
            guard runtime != nil,
                  scenePhase == .active,
                  let requestID,
                  desktopWebSessionCoordinator.consumePremiumUpgradeRequest(requestID) else {
                return
            }
            openPremiumUpgradeFromDesktopWeb()
        }
        .onChange(of: readingTimerDeepLinkRouter.pendingRequest) { _, request in
            guard runtime != nil, let request else { return }
            openReadingTimerDeepLink(request)
        }
        .onChange(of: runtime?.readingTimerCoordinator.backgroundCountdownCompletionEvent) { _, event in
            guard event != nil else { return }
            toastCenter.info("阅读倒计时已结束，记录正在等待保存")
        }
        .onChange(of: runtime?.readingTimerCoordinator.longDurationReminderEvent) { _, event in
            guard event != nil else { return }
            toastCenter.warning("本次阅读已计时超过 8 小时，请确认是否仍在阅读")
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingTimerSessionDidChange)) { notification in
            guard let coordinator = runtime?.readingTimerCoordinator else { return }
            let recordId = (notification.object as? NSNumber)?.int64Value
            Task {
                await coordinator.refresh(reason: .externalMutation(recordId: recordId))
            }
        }
    }

    /// 根级呈现层只承载统一 cover、计时 Zoom 与 scene 恢复，并在全屏内容活跃时隔离底层可访问性。
    private var presentedTabContent: some View {
        observedTabContent
        .accessibilityHidden(navigationCoordinator.isTaskPresentationActiveOrDismissing)
        .fullScreenCover(
            item: navigationCoordinator.taskPresentationBinding,
            onDismiss: completeFullScreenTaskDismissal
        ) { presentation in
            if let runtime {
                fullScreenTaskContent(for: presentation, runtime: runtime)
                    .environment(runtime.databaseManager)
                    .environment(runtime.repositories)
                    .environment(runtime.readingTimerCoordinator)
            }
        }
        .overlay {
            readingTimerMainRootZoomSource
        }
        .task {
            await releaseInitialTabAnimationSuppressionIfNeeded()
            consumePendingRuntimeRequestsIfNeeded()
            #if DEBUG
            if runtime != nil {
                await applyUITestLaunchRouteIfNeeded()
            }
            #endif
        }
        .onChange(of: isRuntimeReady) { _, isReady in
            guard isReady else { return }
            consumePendingRuntimeRequestsIfNeeded()
            #if DEBUG
            Task { @MainActor in
                await applyUITestLaunchRouteIfNeeded()
            }
            #endif
        }
    }

    private var isRuntimeReady: Bool {
        runtime != nil
    }

    private var runtimeTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .smooth(duration: 0.16)
    }

    private var notesRuntimeTransitionAnimation: Animation? {
        isRestoringNoteReviewRoot ? nil : runtimeTransitionAnimation
    }

    private var isRestoringNoteReviewRoot: Bool {
        initialSceneSnapshot.selectedTab == .notes
            && initialSceneSnapshot.notes.selectedSubTab == .review
            && initialSceneSnapshot.navigation.path(for: .notes).isEmpty
    }

    /// 等待系统 TabView 完成首次内部选中态协调后无动画揭示页面；任务随页面生命周期取消，用户后续切换继续使用原生反馈。
    @MainActor
    private func releaseInitialTabAnimationSuppressionIfNeeded() async {
        guard isInitialTabPresentationCovered else { return }
        do {
            try await Task.sleep(
                for: reduceMotion ? .milliseconds(120) : .milliseconds(650)
            )
        } catch {
            return
        }
        guard isInitialTabPresentationCovered, !Task.isCancelled else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInitialTabPresentationCovered = false
        }
    }

    private var bootstrapSceneSnapshot: AppSceneSnapshot {
        initialSceneSnapshot
    }

    /// 为恢复路径中的目的页延迟注入运行时依赖；未就绪时保留静态表面和现有类型安全浏览路径。
    @ViewBuilder
    private func runtimeDestination<Destination: View>(
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        if let runtime {
            destination()
                .environment(runtime.databaseManager)
                .environment(runtime.repositories)
                .environment(runtime.readingTimerCoordinator)
        } else {
            Color.surfacePage
                .ignoresSafeArea()
                .toolbar(.hidden, for: .tabBar)
        }
    }

    private var isReadingTimerAccessoryInteractionSuppressed: Bool {
        readingTimerPresentation != nil || pendingReadingTimerDismissal != nil
    }

    /// 根 Tab 没有具体业务卡片来源时，使用当前可见根容器作为系统 Zoom 来源。
    @ViewBuilder
    private var readingTimerMainRootZoomSource: some View {
        if let runtime {
            ReadingTimerZoomPresenter(
                owner: readingTimerZoomOwner,
                sourceID: mainReadingTimerRootSourceID,
                dismissalRequest: readingTimerZoomDismissalRequest,
                isInteractiveDismissEnabled: !runtime.readingTimerCoordinator.isWriting,
                shouldAutoPresent: shouldAutoPresentMainRootZoom,
                preparePresentation: { readingTimerPresentation },
                onDismissalRequested: { presentation, reason in
                    requestReadingTimerDismissal(reason, for: presentation)
                },
                onDismissalCompleted: { presentation, reason in
                    completeReadingTimerZoomDismissal(reason, for: presentation)
                }
            ) { _ in
                Color.clear
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } destination: { presentation, requestDismiss in
                readingTimerZoomDestination(
                    presentation: presentation,
                    requestDismiss: requestDismiss,
                    runtime: runtime
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Color.clear
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var mainReadingTimerRootSourceID: AnyHashable {
        AnyHashable("reading-timer-root-main")
    }

    private var shouldAutoPresentMainRootZoom: Bool {
        guard let presentation = readingTimerPresentation else { return false }
        return presentation.host == .mainTab && presentation.source == .rootFallback
    }

    /// 普通页面来源与根容器共用同一 destination，确保计时页状态和环境注入只有一个实现。
    private func readingTimerZoomDestination(
        presentation: ReadingTimerPresentation,
        requestDismiss: @escaping (ReadingTimerDismissReason) -> Void,
        runtime: AppRuntimeContext
    ) -> some View {
        ReadingTimerFullScreenHost(
            presentation: presentation,
            onRequestDismiss: requestDismiss
        )
        .environment(runtime.readingTimerCoordinator)
        .environment(runtime.repositories)
        .environment(readingTimerSettingsStore)
    }

    /// 为页面卡片生成显式 Zoom 配置；业务票据在来源真正打开时才创建。
    private func makeReadingTimerZoomConfiguration(
        sourceID: AnyHashable,
        request: ReadingTimerPresentationRequest,
        host: ReadingTimerPresentationHost,
        origin: ReadingTimerPresentationOrigin,
        runtime explicitRuntime: AppRuntimeContext? = nil
    ) -> ReadingTimerZoomSourceConfiguration {
        let resolvedRuntime = explicitRuntime ?? runtime
        return ReadingTimerZoomSourceConfiguration(
            owner: readingTimerZoomOwner,
            sourceID: sourceID,
            dismissalRequest: readingTimerZoomDismissalRequest,
            isInteractiveDismissEnabled: !(resolvedRuntime?.readingTimerCoordinator.isWriting ?? true),
            preparePresentation: {
                guard resolvedRuntime != nil else { return nil }
                return presentReadingTimer(
                    request: request,
                    host: host,
                    origin: origin,
                    source: .registered(sourceID)
                )
            },
            onDismissalRequested: { presentation, reason in
                requestReadingTimerDismissal(reason, for: presentation)
            },
            onDismissalCompleted: { presentation, reason in
                completeReadingTimerZoomDismissal(reason, for: presentation)
            }
        )
    }

    /// 把当前计时票据的程序化关闭请求交给同一个 UIKit Zoom owner。
    private var readingTimerZoomDismissalRequest: ReadingTimerZoomDismissalRequest? {
        guard let presentation = readingTimerPresentation,
              let dismissal = pendingReadingTimerDismissal,
              dismissal.presentationID == presentation.id else {
            return nil
        }
        return ReadingTimerZoomDismissalRequest(
            presentationID: presentation.id,
            reason: dismissal.reason
        )
    }

    /// 优先投影当前有效会话；来源式全屏页退场期间保留同一记录快照，避免系统 Zoom 在源提前卸载时黑闪。
    private var readingTimerAccessorySession: ReadingTimerSession? {
        guard let coordinator = runtime?.readingTimerCoordinator else { return nil }
        if let retainedSource = retainedReadingTimerTransitionSource,
           readingTimerPresentation != nil || pendingReadingTimerDismissal != nil {
            if let activeSession = coordinator.activeSession,
               activeSession.id == retainedSource.id {
                return activeSession
            }
            return retainedSource
        }
        guard let activeSession = coordinator.activeSession,
              activeSession.status.isUnfinished else {
            return nil
        }
        return activeSession
    }

    // 未完成计时是应用级任务；普通 Tab 内导航不得改变底部计时控制的可达性。
    private var isReadingTimerAccessoryEnabled: Bool {
        readingTimerAccessorySession != nil
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

    /// 为根级全屏呈现建立独立导航栈，并将辅助技术焦点约束在当前模态内容内。
    @ViewBuilder
    private func fullScreenTaskContent(
        for presentation: AppFullScreenTaskPresentation,
        runtime: AppRuntimeContext
    ) -> some View {
        NavigationStack(path: $navigationCoordinator.taskPath) {
            fullScreenTaskDestination(
                presentation.destination,
                navigationContext: .modalRoot,
                runtime: runtime
            )
            .navigationDestination(for: AppTaskRoute.self) { route in
                appTaskDestination(for: route, runtime: runtime)
            }
        }
        .environment(navigationCoordinator)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func fullScreenTaskDestination(
        _ destination: AppFullScreenTaskDestination,
        navigationContext: AppTaskNavigationContext,
        runtime: AppRuntimeContext
    ) -> some View {
        switch destination {
        case .addBook:
            if navigationContext == .modalRoot {
                BookSearchView(
                    onDismissRequested: navigationCoordinator.dismissTask,
                    onCompletedBookSelection: navigationCoordinator.completeAddBook,
                    completionDismissBehavior: .handledByParent
                )
            } else {
                BookSearchView(
                    onCompletedBookSelection: navigationCoordinator.completeAddBook,
                    completionDismissBehavior: .handledByParent
                )
            }
        case .bookEditor(let mode):
            BookEditorView(
                mode: mode,
                onSavedBookID: navigationCoordinator.completeBookEditor,
                navigationContext: navigationContext
            )
        case .noteEditor(let mode, let seed):
            NoteEditorView(
                mode: mode,
                seed: seed,
                navigationContext: navigationContext
            )
        case .reviewEditor(let mode):
            ReviewEditorView(
                mode: mode,
                navigationContext: navigationContext
            )
        case .relevantEditor(let mode):
            RelevantEditorView(
                mode: mode,
                navigationContext: navigationContext
            )
        case .contentViewer(let source, let initialItemID, let keyword):
            ContentViewerView(
                source: source,
                initialItemID: initialItemID,
                keyword: keyword
            )
                .appTaskRootDismissControl(
                    isVisible: navigationContext == .modalRoot,
                    style: .collapse(accessibilityLabel: "关闭内容查看")
                )
        case .readCalendar(let initialDate):
            ReadCalendarView(
                date: initialDate,
                onOpenRoute: { route in
                    navigationCoordinator.taskPath.append(.readCalendar(route))
                },
                onOpenPremium: {
                    navigationCoordinator.exitTask(to: .personal(.premium))
                }
            )
                .appTaskRootDismissControl(
                    isVisible: navigationContext == .modalRoot,
                    style: .collapse(accessibilityLabel: "关闭阅读日历")
                )
        case .dataImport(let destination):
            dataImportTaskDestination(destination, repositories: runtime.repositories)
                .appTaskRootDismissControl(
                    isVisible: navigationContext == .modalRoot,
                    style: .text("取消")
                )
        }
    }

    /// 全屏任务内部只注册 AppTaskRoute，避免临时目的地被写入可持久化浏览路径。
    @ViewBuilder
    private func appTaskDestination(
        for route: AppTaskRoute,
        runtime: AppRuntimeContext
    ) -> some View {
        switch route {
        case .destination(let destination):
            fullScreenTaskDestination(
                destination,
                navigationContext: .taskChild,
                runtime: runtime
            )
        case .book(let route):
            bookDestination(for: route, host: .task)
        case .reading(let route):
            readingDestination(for: route, hostTab: selectedTab)
        case .note(let route):
            noteDestination(for: route, host: .task)
        case .content(let route):
            contentDestination(for: route, host: .task)
        case .readCalendar(let route):
            readCalendarTaskDestination(for: route)
        }
    }

    @ViewBuilder
    private func dataImportTaskDestination(
        _ destination: DataImportTaskDestination,
        repositories: RepositoryContainer
    ) -> some View {
        switch destination {
        case .desktopComputer:
            DesktopWebView(mode: .computerImport)
        case .lifeWeek:
            LifeWeekImportView(repository: repositories.noteImportRepository)
        case .wereadAuthorization:
            WereadImportAuthView(
                repository: repositories.wereadImportRepository,
                onOpenPremium: openPremiumFromFullScreenTask
            )
        case .kindle:
            KindleImportView(
                gateway: DefaultKindleImportGateway(
                    repository: repositories.noteImportRepository
                )
            )
        case .api:
            ApiNoteImportView(
                repository: repositories.noteImportRepository,
                isPremium: appState.isPremium,
                onOpenPremium: openPremiumFromFullScreenTask
            )
        case .hanwang:
            HanWangImportView(repository: repositories.noteImportRepository)
        case .file(let title, let parserID):
            NoteImportSourceScreen(title: title, input: .file(parserID: parserID))
        case .fileCandidates(let title, let parserIDs):
            NoteImportSourceScreen(title: title, input: .fileCandidates(parserIDs))
        case .clipboard(let title, let parserID):
            NoteImportSourceScreen(title: title, input: .clipboard(parserID: parserID))
        case .clipboardCandidates(let title, let parserIDs):
            NoteImportSourceScreen(title: title, input: .clipboardCandidates(parserIDs))
        }
    }

    // MARK: - Reading Destinations

    /// 创建唯一计时呈现票据；Accessory 来源会话保留到 UIKit 确认退场完成。
    @discardableResult
    private func presentReadingTimer(
        request: ReadingTimerPresentationRequest,
        host: ReadingTimerPresentationHost,
        origin: ReadingTimerPresentationOrigin,
        source: ReadingTimerPresentationSource = .rootFallback,
        transitionSourceSession: ReadingTimerSession? = nil
    ) -> ReadingTimerPresentation? {
        guard runtime != nil,
              readingTimerPresentation == nil,
              pendingReadingTimerDismissal == nil else {
            return nil
        }
        if let transitionSourceSession {
            retainedReadingTimerTransitionSource = transitionSourceSession
        } else {
            retainedReadingTimerTransitionSource = nil
        }
        let presentation = ReadingTimerPresentation(
            request: request,
            host: host,
            origin: origin,
            source: source
        )
        readingTimerPresentation = presentation
        return presentation
    }

    /// 在 UIKit 已确认来源可呈现后创建 Accessory 专属票据，防止无效点击留下全局状态。
    private func prepareReadingTimerAccessoryPresentation(
        session: ReadingTimerSession,
        runtime: AppRuntimeContext
    ) -> ReadingTimerPresentation? {
        guard let activeSession = runtime.readingTimerCoordinator.activeSession,
              activeSession.id == session.id,
              activeSession.status.isUnfinished else {
            return nil
        }
        return presentReadingTimer(
            request: .record(
                recordId: activeSession.id,
                bookId: activeSession.book.id
            ),
            host: .bottomAccessory,
            origin: .tab(selectedTab),
            source: .registered(session.id),
            transitionSourceSession: activeSession
        )
    }

    /// 处理迷你条唯一的高频可逆操作；Task 继承 MainActor，Coordinator 串行保护状态写入且无需跨页面取消。
    private func toggleGlobalReadingTimer(runtime: AppRuntimeContext) {
        Task {
            if runtime.readingTimerCoordinator.canPause {
                await runtime.readingTimerCoordinator.pause()
            } else if runtime.readingTimerCoordinator.canResume {
                await runtime.readingTimerCoordinator.resume()
            }
        }
    }

    /// 接收计时页的显式关闭原因；业务票据保持到 UIKit Zoom 确认退场完成。
    private func requestReadingTimerDismissal(
        _ reason: ReadingTimerDismissReason,
        for presentation: ReadingTimerPresentation
    ) {
        guard readingTimerPresentation?.id == presentation.id else { return }
        prepareReadingTimerDismissal(reason, for: presentation)
    }

    /// UIKit 确认 Zoom 已完成后再清空票据与来源；交互取消不会调用本方法。
    private func completeReadingTimerZoomDismissal(
        _ reason: ReadingTimerDismissReason,
        for presentation: ReadingTimerPresentation
    ) {
        guard readingTimerPresentation?.id == presentation.id else {
            return
        }
        prepareReadingTimerDismissal(reason, for: presentation)
        completeReadingTimerDismissal()
    }

    /// 冻结本次退场原因与后续动作，防止全屏页退场期间读取已变化的当前 Tab 或搜索覆盖层。
    private func prepareReadingTimerDismissal(
        _ reason: ReadingTimerDismissReason,
        for presentation: ReadingTimerPresentation
    ) {
        guard pendingReadingTimerDismissal?.presentationID != presentation.id else { return }
        let postDismissAction: ReadingTimerPostDismissAction?
        if case .openNote(let bookId) = reason {
            postDismissAction = .openNote(bookId: bookId, origin: presentation.origin)
        } else {
            postDismissAction = nil
        }
        pendingReadingTimerDismissal = ReadingTimerPendingDismissal(
            presentationID: presentation.id,
            reason: reason,
            postDismissAction: postDismissAction
        )
    }

    /// 在系统确认计时全屏页已完全关闭后收口全局生命周期、提示与延迟导航。
    private func completeReadingTimerDismissal() {
        guard let coordinator = runtime?.readingTimerCoordinator else {
            readingTimerPresentation = nil
            pendingReadingTimerDismissal = nil
            retainedReadingTimerTransitionSource = nil
            return
        }
        if pendingReadingTimerDismissal == nil,
           let presentation = readingTimerPresentation {
            prepareReadingTimerDismissal(.minimize, for: presentation)
        }
        readingTimerPresentation = nil
        coordinator.isTimerInterfacePresented = false
        retainedReadingTimerTransitionSource = nil
        guard let dismissal = pendingReadingTimerDismissal else { return }
        pendingReadingTimerDismissal = nil

        let isSupersededByDeepLink = pendingReadingTimerDeepLinkRequest != nil
        if !isSupersededByDeepLink,
           dismissal.reason == .minimize,
           scenePhase == .active,
           coordinator.consumeGlobalContinuationTipIfNeeded() {
            toastCenter.info("阅读计时将在底部继续")
        }
        if !isSupersededByDeepLink,
           let action = dismissal.postDismissAction {
            performReadingTimerPostDismissAction(action)
        }
        continuePendingReadingTimerDeepLinkIfPossible()
    }

    /// 在退场完成后把记书摘任务交给统一导航协调器，保持原 Tab 浏览现场不变。
    private func performReadingTimerPostDismissAction(
        _ action: ReadingTimerPostDismissAction
    ) {
        switch action {
        case .openNote(let bookId, let origin):
            let seed = NoteEditorSeed(
                bookId: bookId,
                chapterId: nil,
                contentHTML: "",
                ideaHTML: ""
            )
            switch origin {
            case .tab(let tab):
                selectedTab = tab
                navigationCoordinator.updateCurrentTab(tab)
                navigationCoordinator.present(.noteEditor(mode: .create, seed: seed))
            }
        }
    }

    /// 按当前宿主打开可恢复的书籍浏览路由。
    private func openBookRoute(_ route: BookRoute, from host: AppRouteHost) {
        append(route, to: host)
    }

    /// 按当前宿主打开可恢复的笔记浏览路由。
    private func openNoteRoute(_ route: NoteRoute, from host: AppRouteHost) {
        append(route, to: host)
    }

    /// 按当前宿主打开可恢复的内容详情路由。
    private func openContentRoute(_ route: ContentRoute, from host: AppRouteHost) {
        append(route, to: host)
    }

    /// 五个 Tab 只消费统一 AppRoute；业务枚举不再直接成为根栈的数据元素。
    @ViewBuilder
    private func appDestination(
        for route: AppRoute,
        hostTab: AppTab
    ) -> some View {
        runtimeDestination {
            switch route {
            case .book(let route):
                bookDestination(for: route, host: .tab(hostTab))
            case .reading(let route):
                if hostTab == .reading {
                    readingDestination(for: route, hostTab: hostTab)
                } else {
                    readingDestination(for: route, hostTab: hostTab)
                        .toolbar(.hidden, for: .tabBar)
                }
            case .note(let route):
                noteDestination(for: route, host: .tab(hostTab))
            case .content(let route):
                contentDestination(for: route, host: .tab(hostTab))
            case .personal(let route):
                personalDestination(for: route, hostTab: hostTab)
            case .export(let route):
                ExportView(route: route)
            case .debug(let route):
                debugDestination(for: route)
            }
        }
        .toolbarVisibility(
            navigationCoordinator.isTabChromeSuppressed ? .hidden : .automatic,
            for: .tabBar
        )
        .onAppear {
            completeRestoredNavigationSurfaceIfReady(route: route, hostTab: hostTab)
        }
        .onChange(of: isRuntimeReady, initial: true) { _, _ in
            completeRestoredNavigationSurfaceIfReady(route: route, hostTab: hostTab)
        }
    }

    /// 仅在恢复栈的最终目的页已经进入视图树且运行时可用后揭开页面，避免展示中间根页或半成品目的页。
    private func completeRestoredNavigationSurfaceIfReady(
        route: AppRoute,
        hostTab: AppTab
    ) {
        guard isRuntimeReady,
              pendingRestoredNavigationSurface == RestoredNavigationSurface(
                  tab: hostTab,
                  route: route
              ) else {
            return
        }
        pendingRestoredNavigationSurface = nil
    }

    @ViewBuilder
    private func readingDestination(
        for route: ReadingRoute,
        hostTab: AppTab
    ) -> some View {
        switch route {
        case .bookDetail(let bookId):
            BookDetailView(
                bookId: bookId,
                onStartReading: { bookId in
                    presentReadingTimer(
                        request: .book(bookId),
                        host: .mainTab,
                        origin: .tab(selectedTab),
                        source: .rootFallback
                    )
                },
                onSupplementReading: { bookId in
                    append(ReadingRoute.readingSupplement(bookId: bookId), to: hostTab)
                },
                onOpenReadingDetail: { bookId in
                    openBookRoute(.readingDetail(bookId: bookId), from: .tab(hostTab))
                },
                onOpenChapterNotes: { bookId, chapterId, title in
                    openBookRoute(
                        .chapterNotes(bookId: bookId, chapterId: chapterId, title: title),
                        from: .tab(hostTab)
                    )
                },
                onOpenBook: { bookId in
                    openBookRoute(.detail(bookId: bookId), from: .tab(hostTab))
                },
                readingTimerZoomConfiguration: makeReadingTimerZoomConfiguration(
                    sourceID: AnyHashable("reading-timer-book-detail-\(selectedTab.rawValue)-\(bookId)"),
                    request: .book(bookId),
                    host: .mainTab,
                    origin: .tab(selectedTab)
                )
            )
        case .readingSupplement(let bookId):
            ReadingTimerSupplementView(bookId: bookId)
        }
    }

    // MARK: - Book Destinations

    /// 在阅读日历的独立全屏任务栈内继续打开日期详情或分享页，并把后续业务路由留在同一现场。
    @ViewBuilder
    private func readCalendarTaskDestination(for route: ReadCalendarRoute) -> some View {
        switch route {
        case .daily(let date):
            DailyReadingView(
                date: date,
                onOpenBookRoute: { openBookRoute($0, from: .task) },
                onOpenNoteRoute: { openNoteRoute($0, from: .task) },
                onOpenContentRoute: { openContentRoute($0, from: .task) }
            )
        case .share(let monthStart, let initialType):
            ReadCalendarShareView(
                monthStart: monthStart,
                initialType: initialType,
                onOpenPremium: {
                    navigationCoordinator.exitTask(to: .personal(.premium))
                }
            )
        }
    }

    @ViewBuilder
    private func bookDestination(for route: BookRoute, host: AppRouteHost) -> some View {
        switch route {
        case .detail(let bookId):
            BookDetailView(
                bookId: bookId,
                onStartReading: { bookId in
                    presentReadingTimer(
                        request: .book(bookId),
                        host: .mainTab,
                        origin: .tab(selectedTab),
                        source: .rootFallback
                    )
                },
                onSupplementReading: { bookId in
                    append(ReadingRoute.readingSupplement(bookId: bookId), to: host)
                },
                onOpenReadingDetail: { bookId in
                    openBookRoute(.readingDetail(bookId: bookId), from: host)
                },
                onOpenChapterNotes: { bookId, chapterId, title in
                    openBookRoute(
                        BookRoute.chapterNotes(bookId: bookId, chapterId: chapterId, title: title),
                        from: host
                    )
                },
                onOpenBook: { bookId in
                    openBookRoute(.detail(bookId: bookId), from: host)
                },
                readingTimerZoomConfiguration: makeReadingTimerZoomConfiguration(
                    sourceID: AnyHashable("reading-timer-book-detail-\(selectedTab.rawValue)-\(bookId)"),
                    request: .book(bookId),
                    host: .mainTab,
                    origin: .tab(selectedTab)
                ),
                onOpenBookRoute: { route in
                    openBookRoute(route, from: host)
                }
            )
        case .chapterCatalog(let bookID, let chapterID):
            BookDetailView(
                bookId: bookID,
                launchConfiguration: BookDetailLaunchConfiguration(
                    bookID: bookID,
                    initialSection: .catalog,
                    targetChapterID: chapterID,
                    initiallyCollapsesHeader: true,
                    animatesInitialHeaderTransition: false,
                    showsOneShotCoverTip: false
                ),
                onOpenChapterNotes: { bookID, chapterID, title in
                    openBookRoute(
                        .chapterNotes(bookId: bookID, chapterId: chapterID, title: title),
                        from: host
                    )
                },
                onOpenBook: { nestedBookID in
                    openBookRoute(.detail(bookId: nestedBookID), from: host)
                },
                onOpenBookRoute: { nestedRoute in
                    openBookRoute(nestedRoute, from: host)
                }
            )
        case .readingDetail(let bookId):
            BookReadingDetailView(bookID: bookId)
        case .chapterManager(let bookID, let bookName, let doubanID, let focusChapterID):
            ChapterManagerView(
                bookID: bookID,
                bookName: bookName,
                doubanID: doubanID,
                focusChapterID: focusChapterID
            )
        case .chapterNotes(let bookId, let chapterId, let title):
            BookChapterNotesView(
                bookId: bookId,
                chapterId: chapterId,
                title: title
            )
        case .bookshelfList(let route):
            BookshelfBookListView(
                route: route,
                onOpenRoute: { route in
                    openBookRoute(route, from: host)
                },
                onOpenNoteRoute: { route in
                    openNoteRoute(route, from: host)
                }
            )
        case .collectionDetail(let collectionID):
            BookCollectionDetailView(
                collectionID: collectionID,
                onOpenRoute: { route in
                    openBookRoute(route, from: host)
                }
            )
        }
    }

    // MARK: - Note Destinations

    @ViewBuilder
    private func noteDestination(for route: NoteRoute, host: AppRouteHost) -> some View {
        switch route {
        case .detail(let noteId):
            NoteDetailView(noteId: noteId)
        case .noteExcerpts(let scope):
            noteExcerptListDestination(
                context: NoteExcerptListContext(scope: scope, displayTitle: "书摘"),
                host: host
            )
        case .noteExcerptList(let context):
            noteExcerptListDestination(context: context, host: host)
        case .chapterNotes(let bookID, let chapterID, let includeDescendants):
            chapterNotesDestination(
                context: ChapterNoteListContext(
                    bookID: bookID,
                    chapterID: chapterID,
                    includeDescendants: includeDescendants,
                    displayTitle: "章节书摘"
                ),
                host: host
            )
        case .chapterNoteList(let context):
            chapterNotesDestination(context: context, host: host)
        case .mergeNotes(let bookID, let noteIDs):
            NoteMergeView(bookID: bookID, noteIDs: noteIDs) { source, itemID in
                navigationCoordinator.present(
                    .contentViewer(source: source, initialItemID: itemID, keyword: "")
                )
            }
        case .relatedCategory(let scope):
            relatedCategoryDestination(scope: scope, host: host)
        case .tagManagement:
            TagManagementView()
        case .notesByTag(let tagId):
            noteExcerptListDestination(
                context: NoteExcerptListContext(
                    scope: NoteExcerptScope(legacyTagID: tagId),
                    displayTitle: "书摘"
                ),
                host: host
            )
        }
    }

    /// 构造统一书摘列表目的地，并把查看器及后续笔记路由留在当前 Tab。
    @ViewBuilder
    private func noteExcerptListDestination(
        context: NoteExcerptListContext,
        host: AppRouteHost
    ) -> some View {
        if let repositories = runtime?.repositories {
            NoteExcerptListView(
                context: context,
                repository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
                onOpenViewer: { source, itemID in
                    navigationCoordinator.present(
                        .contentViewer(source: source, initialItemID: itemID, keyword: "")
                    )
                },
                onOpenNoteRoute: { openNoteRoute($0, from: host) }
            )
        } else {
            Color.surfacePage.ignoresSafeArea()
        }
    }

    /// 构造章节书摘目的地，复用当前 Tab 的 Viewer 与笔记导航现场。
    private func chapterNotesDestination(
        context: ChapterNoteListContext,
        host: AppRouteHost
    ) -> some View {
        ChapterNotesView(
            context: context,
            onOpenViewer: { source, itemID in
                navigationCoordinator.present(
                    .contentViewer(source: source, initialItemID: itemID, keyword: "")
                )
            },
            onOpenNoteRoute: { openNoteRoute($0, from: host) }
        )
    }

    /// 构造相关分类列表，统一路由普通内容、书籍与通用查看器。
    private func relatedCategoryDestination(
        scope: RelatedCategoryScope,
        host: AppRouteHost
    ) -> some View {
        RelatedCategoryListView(
            scope: scope,
            onOpenViewer: { source, itemID in
                navigationCoordinator.present(
                    .contentViewer(source: source, initialItemID: itemID, keyword: "")
                )
            },
            onOpenContentRoute: { openContentRoute($0, from: host) },
            onOpenBookRoute: { openBookRoute($0, from: host) }
        )
    }

    // MARK: - Content Destinations

    @ViewBuilder
    private func contentDestination(for route: ContentRoute, host: AppRouteHost) -> some View {
        switch route {
        case .reviewDetail(let reviewId):
            ReviewDetailView(reviewId: reviewId)
        case .relevantDetail(let contentId):
            RelevantDetailView(contentId: contentId)
        }
    }

    // MARK: - Personal Destinations

    @ViewBuilder
    private func personalDestination(
        for route: PersonalRoute,
        hostTab: AppTab
    ) -> some View {
        switch route {
        case .settings:
            PersonalSettingsView()
        case .readingTimerSettings:
            ReadingTimerSettingsView()
        case .premium:
            Text("会员")
        case .readReminder:
            Text("阅读提醒")
        case .dataImport:
            DataImportView()
        case .dataBackup:
            DataBackupView()
        case .webdavServers:
            WebDAVServerListView()
        case .batchExport:
            ExportView(route: ExportRoute(scope: .allBooks))
        case .desktopWeb:
            DesktopWebView()
        case .apiIntegration:
            ApiIntegrationView()
        case .aiConfiguration:
            AIConfigurationView()
        case .tagManagement:
            TagManagementView()
        case .groupManagement:
            BookGroupManagementView(
                onOpenBookRoute: { openBookRoute($0, from: .tab(hostTab)) }
            )
        case .bookSource:
            SourceManagementView()
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
            if let runtime {
                DebugCenterView()
                    .environment(runtime.repositories)
                    .environment(runtime.databaseManager)
            }
            #else
            Text("测试入口仅在 Debug 构建可用")
            #endif
        }
    }

    private func append(_ route: BookRoute, to tab: AppTab) {
        navigationCoordinator.push(.book(route), in: tab)
    }

    /// 把书籍浏览路由写入当前宿主拥有的路径。
    private func append(_ route: BookRoute, to host: AppRouteHost) {
        switch host {
        case .tab(let tab):
            append(route, to: tab)
        case .task:
            navigationCoordinator.taskPath.append(.book(route))
        }
    }

    private func append(_ route: ReadingRoute, to tab: AppTab) {
        navigationCoordinator.push(.reading(route), in: tab)
    }

    /// 把阅读浏览路由写入当前宿主拥有的路径。
    private func append(_ route: ReadingRoute, to host: AppRouteHost) {
        switch host {
        case .tab(let tab):
            append(route, to: tab)
        case .task:
            navigationCoordinator.taskPath.append(.reading(route))
        }
    }

    private func append(_ route: NoteRoute, to tab: AppTab) {
        navigationCoordinator.push(.note(route), in: tab)
    }

    /// 把笔记浏览路由写入当前宿主拥有的路径。
    private func append(_ route: NoteRoute, to host: AppRouteHost) {
        switch host {
        case .tab(let tab):
            append(route, to: tab)
        case .task:
            navigationCoordinator.taskPath.append(.note(route))
        }
    }

    private func append(_ route: ContentRoute, to tab: AppTab) {
        navigationCoordinator.push(.content(route), in: tab)
    }

    /// 把普通内容详情路由写入当前宿主拥有的路径。
    private func append(_ route: ContentRoute, to host: AppRouteHost) {
        switch host {
        case .tab(let tab):
            append(route, to: tab)
        case .task:
            navigationCoordinator.taskPath.append(.content(route))
        }
    }

    private func append(_ route: PersonalRoute, to tab: AppTab) {
        navigationCoordinator.push(.personal(route), in: tab)
    }

    /// 将全屏任务的回流目标写入指定 Tab 的普通浏览栈。
    private func append(_ destination: AppBrowseDestination, to tab: AppTab) {
        navigationCoordinator.push(destination, in: tab)
    }

    /// 搜索结果按页面关系分流：普通详情进入 Search 栈，沉浸查看器进入根级全屏任务。
    private func openGlobalSearchResult(_ target: GlobalSearchNavigationTarget) {
        dismissGlobalSearchKeyboard()
        switch target {
        case .book(let route):
            openBookRoute(route, from: .tab(.search))
        case .content(let route):
            openContentRoute(route, from: .tab(.search))
        case .contentViewer(let source, let initialItemID, let keyword):
            navigationCoordinator.present(
                .contentViewer(
                    source: source,
                    initialItemID: initialItemID,
                    keyword: keyword
                )
            )
        }
    }

    /// 系统全屏任务完成退场后清理临时路径，并按需回流到普通浏览层级。
    private func completeFullScreenTaskDismissal() {
        if let pending = navigationCoordinator.completeTaskDismissal() {
            selectedTab = pending.tab
            append(pending.destination, to: pending.tab)
        }
        syncSearchPresentationForCurrentState()
        continuePendingReadingTimerDeepLinkIfPossible()
    }

    /// 导入任务中的会员升级先关闭任务，再在“我的”Tab 进入会员浏览页。
    private func openPremiumFromFullScreenTask() {
        navigationCoordinator.exitTask(
            to: .personal(.premium),
            targetTab: .profile
        )
    }

    /// 按当前 Tab 和搜索栈深度同步系统搜索宿主；只在 Tab/path 变化时恢复，避免覆盖用户在搜索根页主动关闭搜索框的选择。
    private func syncSearchPresentationForCurrentState() {
        if selectedTab == .search && searchPath.isEmpty {
            setSearchPresented(true, disablesAnimations: false)
        } else {
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

    /// 消费 App 根层分发的计时深链；普通路由交给浏览栈，计时路由等待当前全屏任务退场后呈现。
    private func openReadingTimerDeepLink(_ request: ReadingTimerDeepLinkRequest) {
        guard runtime != nil else { return }
        switch request {
        case .book(let bookId):
            presentReadingTimerDeepLink(request: .book(bookId))
        case .record(let recordId, let bookId):
            presentReadingTimerDeepLink(
                request: .record(recordId: recordId, bookId: bookId)
            )
        }
        readingTimerDeepLinkRouter.consume(request)
    }

    /// 深链始终采用无来源标准入场；已有计时或全屏任务时，先等待其系统退场完成。
    private func presentReadingTimerDeepLink(
        request: ReadingTimerPresentationRequest
    ) {
        if let currentPresentation = readingTimerPresentation,
           currentPresentation.request == request,
           pendingReadingTimerDismissal == nil {
            return
        }
        pendingReadingTimerDeepLinkRequest = request

        if let currentPresentation = readingTimerPresentation {
            guard pendingReadingTimerDismissal == nil else { return }
            requestReadingTimerDismissal(.conflict, for: currentPresentation)
            return
        }
        continuePendingReadingTimerDeepLinkIfPossible()
    }

    /// 以 newest-wins 语义推进待处理深链，严格等待现有计时页与统一全屏任务各自完成退场。
    private func continuePendingReadingTimerDeepLinkIfPossible() {
        guard runtime != nil,
              readingTimerPresentation == nil,
              pendingReadingTimerDismissal == nil,
              let request = pendingReadingTimerDeepLinkRequest else {
            return
        }
        if navigationCoordinator.isTaskPresentationActiveOrDismissing {
            if navigationCoordinator.activeTask != nil {
                navigationCoordinator.dismissTask()
            }
            return
        }

        pendingReadingTimerDeepLinkRequest = nil
        selectedTab = .reading
        presentReadingTimer(
            request: request,
            host: .mainTab,
            origin: .tab(.reading),
            source: .rootFallback
        )
    }

    /// 防御系统搜索框在焦点切换期间产生的瞬时文本回写，保留当前明确提交的关键词。
    private func shouldIgnoreSearchHostTextUpdate(_ newValue: String) -> Bool {
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

    /// 运行时原子发布后统一消费启动期间保留的外部请求，避免依赖未就绪时提前清空 Router。
    private func consumePendingRuntimeRequestsIfNeeded() {
        guard runtime != nil else { return }
        if let pendingImport = bookCollectionImportRouter.pendingImport {
            prepareForBookCollectionImport(pendingImport)
        }
        if scenePhase == .active,
           let requestID = desktopWebSessionCoordinator.premiumUpgradeRequestID,
           desktopWebSessionCoordinator.consumePremiumUpgradeRequest(requestID) {
            openPremiumUpgradeFromDesktopWeb()
        }
        if let pendingRequest = readingTimerDeepLinkRouter.pendingRequest {
            openReadingTimerDeepLink(pendingRequest)
        }
    }

    /// 消费网页端原生高级版动作，切换到“我的”并沿用该 Tab 的既有导航栈继续 push。
    private func openPremiumUpgradeFromDesktopWeb() {
        if navigationCoordinator.activeTask != nil {
            navigationCoordinator.exitTask(
                to: .personal(.premium),
                targetTab: .profile
            )
            return
        }
        selectedTab = .profile
        navigationCoordinator.push(.personal(.premium), in: .profile)
    }

    private func prepareForBookCollectionImport(_ request: BookCollectionImportRequest) {
        selectedTab = .books
        if request.source == .systemShare {
            navigationCoordinator.replacePath(for: .books, with: [])
        }
    }

    #if DEBUG
    /// UI Test 启动后在 MainActor 串行注入目标场景；等待全屏挂载期间响应取消，避免失效视图继续写路由。
    @MainActor
    private func applyUITestLaunchRouteIfNeeded() async {
        guard !didApplyUITestLaunchRoute else {
            return
        }
        if UITestLaunchConfiguration.shouldExerciseTimerDeepLinkConflict {
            didApplyUITestLaunchRoute = true
            selectedTab = .reading
            navigationCoordinator.present(.readCalendar(initialDate: nil))
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
            } catch {
                return
            }
            readingTimerDeepLinkRouter.pendingRequest = .book(bookId: 1_001)
            await Task.yield()
            readingTimerDeepLinkRouter.pendingRequest = .book(bookId: 1_002)
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

/// 运行时依赖未就绪时的根 Tab 内容；只保留真实页面结构，不暴露伪内容或可操作元素。
struct MainTabBootstrapPage: View {
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

/// 初始恢复目的页尚未提交时覆盖整个 Tab 树，阻断视觉泄漏和误触，不参与任何导航状态。
private struct RestoredNavigationSurfaceGate: View {
    var body: some View {
        Color.surfacePage
            .ignoresSafeArea()
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("app.navigation-restoration-gate")
    }
}

/// 启动壳层复用生产首页的背景、顶部渐变与切换器，保证系统启动页之后立即建立真实版式重心。
private struct MainTabBootstrapHome: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tab: AppTab
    let snapshot: AppSceneSnapshot

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            MainTabBootstrapContent(tab: tab, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, PrimaryTopBarLayout.minimumHeight(for: dynamicTypeSize))

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

    private enum Metrics {
        static let leadingIconSize: CGFloat = 14
        static let trailingIconSize: CGFloat = 15
        static let iconColor = Color.iconPrimary.opacity(0.88)
    }

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
                        systemName: "plus",
                        iconSize: Metrics.leadingIconSize,
                        foregroundColor: Metrics.iconColor,
                        hitShape: .rectangle
                    )
                } trailing: {
                    TopBarActionIcon(
                        systemName: snapshot.notes.selectedSubTab == .notes
                            ? "arrow.up.arrow.down"
                            : "ellipsis",
                        iconSize: Metrics.trailingIconSize,
                        foregroundColor: Metrics.iconColor,
                        hitShape: .rectangle
                    )
                }
            }
        case .profile:
            TopSwitcher(title: "我的") {
                TopBarActionPill {
                    TopBarActionIcon(
                        systemName: "plus",
                        iconSize: Metrics.leadingIconSize,
                        foregroundColor: Metrics.iconColor,
                        hitShape: .rectangle
                    )
                } trailing: {
                    TopBarActionIcon(
                        systemName: "ellipsis",
                        iconSize: Metrics.trailingIconSize,
                        foregroundColor: Metrics.iconColor,
                        hitShape: .rectangle
                    )
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
                .scrollBounceBehavior(.always)
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
        .scrollBounceBehavior(.always)
    }
}

/// 笔记页保留分组列表段落密度；回顾页直接复用真实卡组同构壳层。
private struct MainTabNotesBootstrapContent: View {
    let selectedSubTab: NoteSubTab

    @ViewBuilder
    var body: some View {
        switch selectedSubTab {
        case .notes:
            ScrollView {
                Group {
                    BootstrapGroupedListStructure(rowCount: 5)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.section)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
        case .review:
            NoteReviewLoadingShell()
        }
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
        .scrollBounceBehavior(.always)
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
                            .frame(width: StrokeWidth.hairline, height: 38)
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
                        .stroke(Color.surfaceBorderSubtle.opacity(0.32), lineWidth: StrokeWidth.hairline)
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
    private static let rowIconSize: CGFloat = 36
    private static let dividerLeadingInset = Spacing.contentEdge + rowIconSize + Spacing.base

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
                                .frame(width: Self.rowIconSize, height: Self.rowIconSize)
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
                                .frame(height: StrokeWidth.hairline)
                                .padding(.leading, Self.dividerLeadingInset)
                        }
                    }
                }
            }
        }
    }
}

/// 我的页设置面板按生产 44pt 行高组织，圆角与表面色均复用现有令牌。
private struct BootstrapSettingsPanel: View {
    private static let rowIconSize: CGFloat = 24
    private static let rowHeight: CGFloat = 44
    private static let dividerLeadingInset = Spacing.contentEdge + rowIconSize + Spacing.base

    let rowCount: Int

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(spacing: Spacing.none) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HStack(spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                            .fill(Color.controlFillSecondary.opacity(0.72))
                            .frame(width: Self.rowIconSize, height: Self.rowIconSize)
                        BootstrapLine(width: index.isMultiple(of: 2) ? 92 : 116, height: 9)
                        Spacer(minLength: 0)
                        BootstrapLine(width: 18, height: 7)
                    }
                    .frame(minHeight: Self.rowHeight)
                    .padding(.horizontal, Spacing.contentEdge)

                    if index < rowCount - 1 {
                        Rectangle()
                            .fill(Color.surfaceBorderSubtle.opacity(0.36))
                            .frame(height: StrokeWidth.hairline)
                            .padding(.leading, Self.dividerLeadingInset)
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

/// 以不透明根表面统一承载计时全屏页，不介入 Coordinator 的业务读写。
struct ReadingTimerFullScreenHost: View {
    let presentation: ReadingTimerPresentation
    let onRequestDismiss: (ReadingTimerDismissReason) -> Void

    @Environment(ReadingTimerCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            Color.surfacePage
                .ignoresSafeArea()

            NavigationStack {
                ReadingTimerView(
                    bookId: presentation.request.bookId,
                    recordId: presentation.request.recordId,
                    onRequestDismiss: onRequestDismiss
                )
            }
        }
        .presentationBackground(Color.surfacePage)
        .interactiveDismissDisabled(coordinator.isWriting)
        .onAppear {
            coordinator.isTimerInterfacePresented = true
        }
        .overlay(alignment: .topLeading) {
            TopBarDismissButton(
                action: { onRequestDismiss(.minimize) },
                isEnabled: !coordinator.isWriting
            )
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.leading, Spacing.base)
            .zIndex(1)
        }
    }
}

/// 在系统 Bottom Accessory 环境中解析形态，再把同一 SwiftUI 计时条交给稳定 UIKit 来源宿主。
private struct ReadingTimerAccessoryZoomSource: View {
    let owner: ReadingTimerZoomPresentationOwner
    let session: ReadingTimerSession
    let repositories: RepositoryContainer
    let timerSettings: ReadingTimerSettingsStore
    let isWriting: Bool
    let dismissalRequest: ReadingTimerZoomDismissalRequest?
    let preparePresentation: () -> ReadingTimerPresentation?
    let onDismissalRequested: (ReadingTimerPresentation, ReadingTimerDismissReason) -> Void
    let onDismissalCompleted: (ReadingTimerPresentation, ReadingTimerDismissReason) -> Void
    let onTogglePlayback: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(ReadingTimerCoordinator.self) private var coordinator

    var body: some View {
        ReadingTimerZoomPresenter(
            owner: owner,
            sourceID: session.id,
            dismissalRequest: dismissalRequest,
            isInteractiveDismissEnabled: !isWriting,
            preparePresentation: preparePresentation,
            onDismissalRequested: onDismissalRequested,
            onDismissalCompleted: onDismissalCompleted
        ) { open in
            ReadingTimerAccessoryView(
                session: session,
                isWriting: isWriting,
                onOpen: open,
                onTogglePlayback: onTogglePlayback,
                layoutMode: placement == .inline ? .inline : .expanded
            )
            .background(
                Color.surfaceCard,
                in: RoundedRectangle(
                    cornerRadius: CornerRadius.containerXL,
                    style: .continuous
                )
            )
            .compositingGroup()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CornerRadius.containerXL,
                    style: .continuous
                )
            )
        } destination: { presentation, requestDismiss in
            ReadingTimerFullScreenHost(
                presentation: presentation,
                onRequestDismiss: requestDismiss
            )
            .environment(coordinator)
            .environment(repositories)
            .environment(timerSettings)
        }
        .frame(maxWidth: placement == .inline ? nil : .infinity)
    }
}

/// 普通入口把真实业务卡片注册为 Zoom 来源，目标页仍复用同一计时全屏宿主。
struct ReadingTimerNormalZoomSource<Source: View>: View {
    let configuration: ReadingTimerZoomSourceConfiguration
    let sourceBuilder: (@escaping () -> Void) -> Source
    @State private var isPresentationRequested = false

    @Environment(ReadingTimerCoordinator.self) private var coordinator
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(ReadingTimerSettingsStore.self) private var timerSettings

    init(
        configuration: ReadingTimerZoomSourceConfiguration,
        @ViewBuilder source: @escaping (@escaping () -> Void) -> Source
    ) {
        self.configuration = configuration
        sourceBuilder = source
    }

    var body: some View {
        ReadingTimerZoomPresenter(
            owner: configuration.owner,
            sourceID: configuration.sourceID,
            dismissalRequest: configuration.dismissalRequest,
            isInteractiveDismissEnabled: configuration.isInteractiveDismissEnabled,
            shouldAutoPresent: isPresentationRequested,
            preparePresentation: {
                guard isPresentationRequested else { return nil }
                return configuration.preparePresentation()
            },
            onDismissalRequested: configuration.onDismissalRequested,
            onDismissalCompleted: { presentation, reason in
                isPresentationRequested = false
                configuration.onDismissalCompleted(presentation, reason)
            }
        ) { _ in
            sourceBuilder {
                isPresentationRequested = true
            }
        } destination: { presentation, requestDismiss in
            ReadingTimerFullScreenHost(
                presentation: presentation,
                onRequestDismiss: requestDismiss
            )
            .environment(coordinator)
            .environment(repositories)
            .environment(timerSettings)
        }
    }
}

/// 最近搜索词按下阶段的待消费意图，用独立 id 区分连续点击同一个关键词的不同交互。
private struct PendingGlobalSearchSuggestion: Identifiable, Equatable {
    let id = UUID()
    let keyword: String
}

/// 根级全屏页面的退出控件样式，区分文字取消操作与垂直收起语义。
private enum AppTaskRootDismissControlStyle {
    case text(LocalizedStringKey)
    case collapse(accessibilityLabel: LocalizedStringKey)
}

/// 为没有自带未保存拦截的任务根页提供系统取消/关闭入口。
private struct AppTaskRootDismissControlModifier: ViewModifier {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator

    let isVisible: Bool
    let style: AppTaskRootDismissControlStyle

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isVisible)
            .toolbar {
                if isVisible {
                    ToolbarItem(placement: .cancellationAction) {
                        switch style {
                        case .text(let title):
                            Button(title) {
                                navigationCoordinator.dismissTask()
                            }
                        case .collapse(let accessibilityLabel):
                            Button {
                                navigationCoordinator.dismissTask()
                            } label: {
                                Label(accessibilityLabel, systemImage: "chevron.down")
                            }
                            .labelStyle(.iconOnly)
                            .tint(.primary)
                        }
                    }
                }
            }
    }
}

private extension View {
    /// 在全屏任务根页显示取消/关闭，任务子步骤继续使用系统返回。
    func appTaskRootDismissControl(
        isVisible: Bool,
        style: AppTaskRootDismissControlStyle
    ) -> some View {
        modifier(
            AppTaskRootDismissControlModifier(
                isVisible: isVisible,
                style: style
            )
        )
    }
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
    MainTabView(
        runtime: nil,
        initialSceneSnapshot: .empty(dataEpoch: 0)
    )
        .environment(AppState())
        .environment(SceneStateStore())
        .environment(BookCollectionImportRouter())
        .environment(ReadingTimerDeepLinkRouter())
        .environment(DesktopWebSessionCoordinator())
        .environment(ReadingTimerSettingsStore())
        .environment(XMToastCenter())
}
