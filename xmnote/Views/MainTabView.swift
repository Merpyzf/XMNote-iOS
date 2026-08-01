//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

/**
 * [INPUT]: 依赖 Reading/Book/Note/Content/Personal/Search 各模块容器视图与对应路由枚举，依赖 ReadingTimerCoordinator、BookCollectionImportRouter、ReadingTimerDeepLinkRouter、XMToastCenter 与 DesktopWebSessionCoordinator 承接全局状态和外部动作
 * [OUTPUT]: 对外提供 MainTabView（五个主 Tab 的 NavigationStack、系统底部计时状态条、阅读计时 UIKit Zoom、书单分享导入、网页端入口、搜索来源详情覆盖与 DEBUG UI Test 路由）
 * [POS]: 应用根导航入口，统一协调阅读计时的 UIKit Zoom、关闭原因及关闭后路由，同时保留各 Tab 导航现场
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 应用主 Tab 枚举，统一根级导航页签身份。
enum AppTab: String, CaseIterable, Codable {
    case reading, books, notes, profile, search
}

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
    case searchResultCover(UUID)
}

/// 记录计时页打开时的导航来源，确保关闭后动作回到原宿主而非读取易变的当前 Tab。
enum ReadingTimerPresentationOrigin: Equatable {
    case tab(AppTab)
    case searchResultCover(UUID)
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

/// 应用主导航容器，组织五个主 Tab 及跨模块路由跳转。
struct MainTabView: View {
    @Environment(\.openURL) private var openURL
    @Environment(BookCollectionImportRouter.self) private var bookCollectionImportRouter
    @Environment(ReadingTimerDeepLinkRouter.self) private var readingTimerDeepLinkRouter
    @Environment(DesktopWebSessionCoordinator.self) private var desktopWebSessionCoordinator
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(ReadingTimerCoordinator.self) private var readingTimerCoordinator
    @Environment(ReadingTimerSettingsStore.self) private var readingTimerSettingsStore
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .reading
    @State private var readingPath = NavigationPath()
    @State private var booksPath = NavigationPath()
    @State private var notesPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchResultCoverPath = NavigationPath()
    @State private var searchResultCover: SearchResultCover?
    @State private var readingTimerPresentation: ReadingTimerPresentation?
    @State private var pendingReadingTimerDismissal: ReadingTimerPendingDismissal?
    @State private var retainedReadingTimerTransitionSource: ReadingTimerSession?
    @State private var readingTimerZoomOwner = ReadingTimerZoomPresentationOwner()
    @State private var pendingReadingTimerDeepLinkRequest: ReadingTimerPresentationRequest?
    @State private var isSearchResultCoverDismissing = false
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
                                origin: .tab(.reading)
                            )
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
                        .navigationDestination(for: ReadingRoute.self) { route in
                            readingDestination(for: route)
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
                        .navigationDestination(for: ReadingRoute.self) { route in
                            readingDestination(for: route)
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
                        .navigationDestination(for: ReadingRoute.self) { route in
                            readingDestination(for: route)
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
                        .navigationDestination(for: ReadingRoute.self) { route in
                            readingDestination(for: route)
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
        .tabViewBottomAccessory(isEnabled: shouldShowReadingTimerAccessory) {
            if let session = readingTimerAccessorySession {
                ReadingTimerAccessoryZoomSource(
                    owner: readingTimerZoomOwner,
                    session: session,
                    repositories: repositories,
                    timerSettings: readingTimerSettingsStore,
                    isWriting: readingTimerCoordinator.isWriting,
                    dismissalRequest: readingTimerZoomDismissalRequest,
                    preparePresentation: {
                        prepareReadingTimerAccessoryPresentation(session: session)
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
                    onTogglePlayback: toggleGlobalReadingTimer
                )
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
        .onChange(of: desktopWebSessionCoordinator.premiumUpgradeRequestID) { _, requestID in
            guard requestID != nil else { return }
            openPremiumUpgradeFromDesktopWeb()
        }
        .onChange(of: readingTimerDeepLinkRouter.pendingRoute) { _, route in
            guard let route else { return }
            openReadingTimerDeepLink(route)
        }
        .onChange(of: readingTimerCoordinator.backgroundCountdownCompletionEvent) { _, event in
            guard event != nil else { return }
            toastCenter.info("阅读倒计时已结束，记录正在等待保存。")
        }
        .onChange(of: readingTimerCoordinator.longDurationReminderEvent) { _, event in
            guard event != nil else { return }
            toastCenter.warning("本次阅读已计时超过 8 小时，请确认是否仍在阅读。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingTimerSessionDidChange)) { notification in
            let recordId = (notification.object as? NSNumber)?.int64Value
            Task {
                await readingTimerCoordinator.refresh(reason: .externalMutation(recordId: recordId))
            }
        }
        .fullScreenCover(
            item: searchResultCoverPresentationBinding,
            onDismiss: completeSearchResultCoverDismissal
        ) { cover in
            searchResultCoverContent(for: cover)
        }
        .overlay {
            readingTimerMainRootZoomSource
        }
        .task {
            if let pendingImport = bookCollectionImportRouter.pendingImport {
                prepareForBookCollectionImport(pendingImport)
            }
            if let pendingRoute = readingTimerDeepLinkRouter.pendingRoute {
                openReadingTimerDeepLink(pendingRoute)
            }
            #if DEBUG
            await applyUITestLaunchRouteIfNeeded()
            #endif
        }
    }

    private var isReadingTimerAccessoryInteractionSuppressed: Bool {
        readingTimerPresentation != nil || pendingReadingTimerDismissal != nil
    }

    /// 根 Tab 没有具体业务卡片来源时，使用当前可见根容器作为系统 Zoom 来源。
    private var readingTimerMainRootZoomSource: some View {
        ReadingTimerZoomPresenter(
            owner: readingTimerZoomOwner,
            sourceID: mainReadingTimerRootSourceID,
            dismissalRequest: readingTimerZoomDismissalRequest,
            isInteractiveDismissEnabled: !readingTimerCoordinator.isWriting,
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
                requestDismiss: requestDismiss
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 搜索结果覆盖层有独立 UIKit 宿主，历史路由也从该覆盖层根容器进入 Zoom。
    @ViewBuilder
    private func readingTimerSearchRootZoomSource(for cover: SearchResultCover) -> some View {
        ReadingTimerZoomPresenter(
            owner: readingTimerZoomOwner,
            sourceID: searchReadingTimerRootSourceID(for: cover.id),
            dismissalRequest: readingTimerZoomDismissalRequest,
            isInteractiveDismissEnabled: !readingTimerCoordinator.isWriting,
            shouldAutoPresent: shouldAutoPresentSearchRootZoom(for: cover.id),
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
                requestDismiss: requestDismiss
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var mainReadingTimerRootSourceID: AnyHashable {
        AnyHashable("reading-timer-root-main")
    }

    private func searchReadingTimerRootSourceID(for coverID: UUID) -> AnyHashable {
        AnyHashable("reading-timer-root-search-\(coverID.uuidString)")
    }

    private var shouldAutoPresentMainRootZoom: Bool {
        guard let presentation = readingTimerPresentation else { return false }
        return presentation.host == .mainTab && presentation.source == .rootFallback
    }

    private func shouldAutoPresentSearchRootZoom(for coverID: UUID) -> Bool {
        guard let presentation = readingTimerPresentation else { return false }
        return presentation.host == .searchResultCover(coverID) && presentation.source == .rootFallback
    }

    /// 普通页面来源与根容器共用同一 destination，确保计时页状态和环境注入只有一个实现。
    private func readingTimerZoomDestination(
        presentation: ReadingTimerPresentation,
        requestDismiss: @escaping (ReadingTimerDismissReason) -> Void
    ) -> some View {
        ReadingTimerFullScreenHost(
            presentation: presentation,
            onRequestDismiss: requestDismiss
        )
        .environment(readingTimerCoordinator)
        .environment(repositories)
        .environment(readingTimerSettingsStore)
    }

    /// 为页面卡片生成显式 Zoom 配置；业务票据在来源真正打开时才创建。
    private func makeReadingTimerZoomConfiguration(
        sourceID: AnyHashable,
        request: ReadingTimerPresentationRequest,
        host: ReadingTimerPresentationHost,
        origin: ReadingTimerPresentationOrigin
    ) -> ReadingTimerZoomSourceConfiguration {
        ReadingTimerZoomSourceConfiguration(
            owner: readingTimerZoomOwner,
            sourceID: sourceID,
            dismissalRequest: readingTimerZoomDismissalRequest,
            isInteractiveDismissEnabled: !readingTimerCoordinator.isWriting,
            preparePresentation: {
                presentReadingTimer(
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
        if let retainedSource = retainedReadingTimerTransitionSource,
           readingTimerPresentation != nil || pendingReadingTimerDismissal != nil {
            if let activeSession = readingTimerCoordinator.activeSession,
               activeSession.id == retainedSource.id {
                return activeSession
            }
            return retainedSource
        }
        guard let activeSession = readingTimerCoordinator.activeSession,
              activeSession.status.isUnfinished else {
            return nil
        }
        return activeSession
    }

    private var shouldShowReadingTimerAccessory: Bool {
        guard readingTimerAccessorySession != nil,
              searchResultCover == nil else {
            return false
        }
        switch selectedTab {
        case .reading:
            return readingPath.isEmpty
        case .books:
            return booksPath.isEmpty
        case .notes:
            return notesPath.isEmpty
        case .profile:
            return profilePath.isEmpty
        case .search:
            return searchPath.isEmpty
        }
    }

    /// 统一拦截搜索结果覆盖层的系统关闭写回，让后续深链可靠等待 fullScreenCover 完成退场。
    private var searchResultCoverPresentationBinding: Binding<SearchResultCover?> {
        Binding(
            get: { searchResultCover },
            set: { cover in
                if let cover {
                    searchResultCover = cover
                } else {
                    beginSearchResultCoverDismissal()
                }
            }
        )
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
        ZStack {
            NavigationStack(path: $searchResultCoverPath) {
                searchResultCoverDestination(for: cover.target)
                    .navigationDestination(for: BookRoute.self) { route in
                        searchResultBookDestination(for: route)
                            .toolbar(.hidden, for: .tabBar)
                    }
                    .navigationDestination(for: ReadingRoute.self) { route in
                        searchResultReadingDestination(for: route)
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

            readingTimerSearchRootZoomSource(for: cover)
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
                onStartReading: { bookId in
                    presentReadingTimerFromSearchResult(bookId: bookId)
                },
                onSupplementReading: { bookId in
                    searchResultCoverPath.append(ReadingRoute.readingSupplement(bookId: bookId))
                },
                readingTimerZoomConfiguration: searchResultReadingTimerZoomConfiguration(
                    bookId: bookId
                )
            )
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

    private func searchResultReadingTimerZoomConfiguration(
        bookId: Int64
    ) -> ReadingTimerZoomSourceConfiguration? {
        guard let coverID = searchResultCover?.id else { return nil }
        return makeReadingTimerZoomConfiguration(
            sourceID: AnyHashable("reading-timer-search-book-detail-\(coverID.uuidString)-\(bookId)"),
            request: .book(bookId),
            host: .searchResultCover(coverID),
            origin: .searchResultCover(coverID)
        )
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
        guard readingTimerPresentation == nil,
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

    /// 从当前可见的搜索结果覆盖层打开计时全屏页，关闭后仍回到同一个覆盖层导航栈。
    private func presentReadingTimerFromSearchResult(bookId: Int64) {
        guard let coverID = searchResultCover?.id else { return }
        presentReadingTimer(
            request: .book(bookId),
            host: .searchResultCover(coverID),
            origin: .searchResultCover(coverID),
            source: .rootFallback
        )
    }

    /// 在 UIKit 已确认来源可呈现后创建 Accessory 专属票据，防止无效点击留下全局状态。
    private func prepareReadingTimerAccessoryPresentation(
        session: ReadingTimerSession
    ) -> ReadingTimerPresentation? {
        guard let activeSession = readingTimerCoordinator.activeSession,
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
    private func toggleGlobalReadingTimer() {
        Task {
            if readingTimerCoordinator.canPause {
                await readingTimerCoordinator.pause()
            } else if readingTimerCoordinator.canResume {
                await readingTimerCoordinator.resume()
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
        if pendingReadingTimerDismissal == nil,
           let presentation = readingTimerPresentation {
            prepareReadingTimerDismissal(.minimize, for: presentation)
        }
        readingTimerPresentation = nil
        readingTimerCoordinator.isTimerInterfacePresented = false
        retainedReadingTimerTransitionSource = nil
        guard let dismissal = pendingReadingTimerDismissal else { return }
        pendingReadingTimerDismissal = nil

        let isSupersededByDeepLink = pendingReadingTimerDeepLinkRequest != nil
        if !isSupersededByDeepLink,
           dismissal.reason == .minimize,
           scenePhase == .active,
           readingTimerCoordinator.consumeGlobalContinuationTipIfNeeded() {
            toastCenter.info("阅读计时将在底部继续。")
        }
        if !isSupersededByDeepLink,
           let action = dismissal.postDismissAction {
            performReadingTimerPostDismissAction(action)
        }
        continuePendingReadingTimerDeepLinkIfPossible()
    }

    /// 在退场完成后把记书摘动作追加到进入计时页时捕获的准确宿主路径。
    private func performReadingTimerPostDismissAction(
        _ action: ReadingTimerPostDismissAction
    ) {
        switch action {
        case .openNote(let bookId, let origin):
            let route = NoteRoute.create(seed: NoteEditorSeed(
                bookId: bookId,
                chapterId: nil,
                contentHTML: "",
                ideaHTML: ""
            ))
            switch origin {
            case .tab(let tab):
                selectedTab = tab
                append(route, to: tab)
            case .searchResultCover(let coverID):
                guard searchResultCover?.id == coverID else { return }
                searchResultCoverPath.append(route)
            }
        }
    }

    /// 把历史 NavigationPath 中的计时 case 幂等转交给统一全屏呈现；MainActor 让出一帧等待旧页面出栈，呈现门闩防止竞态重复。
    private func relayReadingTimerRoute(
        request: ReadingTimerPresentationRequest,
        from tab: AppTab
    ) {
        popCurrentRoute(from: tab)
        Task { @MainActor in
            await Task.yield()
            presentReadingTimer(
                request: request,
                host: .mainTab,
                origin: .tab(tab),
                source: .rootFallback
            )
        }
    }

    /// 把搜索覆盖层历史路径中的计时 case 转交给当前可见覆盖层；MainActor 让出一帧后重新校验覆盖层身份。
    private func relaySearchResultReadingTimerRoute(
        request: ReadingTimerPresentationRequest
    ) {
        popCurrentSearchResultRoute()
        Task { @MainActor in
            await Task.yield()
            guard let coverID = searchResultCover?.id else { return }
            presentReadingTimer(
                request: request,
                host: .searchResultCover(coverID),
                origin: .searchResultCover(coverID),
                source: .rootFallback
            )
        }
    }

    @ViewBuilder
    private func readingDestination(for route: ReadingRoute) -> some View {
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
                    append(ReadingRoute.readingSupplement(bookId: bookId), to: selectedTab)
                },
                readingTimerZoomConfiguration: makeReadingTimerZoomConfiguration(
                    sourceID: AnyHashable("reading-timer-book-detail-\(selectedTab.rawValue)-\(bookId)"),
                    request: .book(bookId),
                    host: .mainTab,
                    origin: .tab(selectedTab)
                )
            )
        case .readingSession(let bookId):
            ReadingTimerLegacyRouteRelay {
                relayReadingTimerRoute(
                    request: .book(bookId),
                    from: selectedTab
                )
            }
        case .readingSessionRecord(let recordId, let bookId):
            ReadingTimerLegacyRouteRelay {
                relayReadingTimerRoute(
                    request: .record(recordId: recordId, bookId: bookId),
                    from: selectedTab
                )
            }
        case .readingSupplement(let bookId):
            ReadingTimerSupplementView(bookId: bookId)
        case .readCalendar(let date):
            ReadCalendarView(date: date)
        }
    }

    @ViewBuilder
    private func searchResultReadingDestination(for route: ReadingRoute) -> some View {
        switch route {
        case .bookDetail(let bookId):
            BookDetailView(
                bookId: bookId,
                onStartReading: { bookId in
                    presentReadingTimerFromSearchResult(bookId: bookId)
                },
                onSupplementReading: { bookId in
                    searchResultCoverPath.append(ReadingRoute.readingSupplement(bookId: bookId))
                },
                readingTimerZoomConfiguration: searchResultReadingTimerZoomConfiguration(
                    bookId: bookId
                )
            )
        case .readingSession(let bookId):
            ReadingTimerLegacyRouteRelay {
                relaySearchResultReadingTimerRoute(request: .book(bookId))
            }
        case .readingSessionRecord(let recordId, let bookId):
            ReadingTimerLegacyRouteRelay {
                relaySearchResultReadingTimerRoute(
                    request: .record(recordId: recordId, bookId: bookId)
                )
            }
        case .readingSupplement(let bookId):
            ReadingTimerSupplementView(bookId: bookId)
        case .readCalendar(let date):
            ReadCalendarView(date: date)
        }
    }

    // MARK: - Book Destinations

    @ViewBuilder
    private func bookDestination(for route: BookRoute) -> some View {
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
                    append(ReadingRoute.readingSupplement(bookId: bookId), to: selectedTab)
                },
                readingTimerZoomConfiguration: makeReadingTimerZoomConfiguration(
                    sourceID: AnyHashable("reading-timer-book-detail-\(selectedTab.rawValue)-\(bookId)"),
                    request: .book(bookId),
                    host: .mainTab,
                    origin: .tab(selectedTab)
                )
            )
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
            PersonalSettingsView()
        case .readingTimerSettings:
            ReadingTimerSettingsView()
        case .premium:
            Text("会员")
        case .readCalendar:
            ReadCalendarView(date: nil)
        case .readReminder:
            Text("阅读提醒")
        case .dataImport:
            DataImportView {
                append(.premium, to: .profile)
            }
        case .dataBackup:
            DataBackupView()
        case .webdavServers:
            WebDAVServerListView()
        case .batchExport:
            Text("批量导出")
        case .desktopWeb:
            DesktopWebView()
        case .apiIntegration:
            Text("API 集成")
        case .aiConfiguration:
            Text("AI 配置")
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

    private func append(_ route: ReadingRoute, to tab: AppTab) {
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

    private func replaceReadingPath(with route: ReadingRoute) {
        var path = NavigationPath()
        path.append(route)
        readingPath = path
    }

    /// 移除当前 Tab 顶部路由，供历史计时 route 中继先恢复真实来源页面。
    private func popCurrentRoute(from tab: AppTab) {
        switch tab {
        case .reading:
            guard !readingPath.isEmpty else { return }
            readingPath.removeLast()
        case .books:
            guard !booksPath.isEmpty else { return }
            booksPath.removeLast()
        case .notes:
            guard !notesPath.isEmpty else { return }
            notesPath.removeLast()
        case .profile:
            guard !profilePath.isEmpty else { return }
            profilePath.removeLast()
        case .search:
            guard !searchPath.isEmpty else { return }
            searchPath.removeLast()
        }
    }

    /// 移除搜索结果覆盖层顶部路由，供历史计时 route 中继恢复覆盖层内的真实来源页面。
    private func popCurrentSearchResultRoute() {
        guard !searchResultCoverPath.isEmpty else { return }
        searchResultCoverPath.removeLast()
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
            beginSearchResultCoverDismissal()
        } else {
            searchResultCoverPath.removeLast()
        }
    }

    /// 标记搜索结果覆盖层已进入系统退场，阻止动画完成前从被遮挡的根层呈现新全屏页。
    private func beginSearchResultCoverDismissal() {
        guard searchResultCover != nil else { return }
        isSearchResultCoverDismissing = true
        searchResultCover = nil
    }

    /// 完成系统覆盖层清理并按进入详情前的搜索呈现状态恢复搜索宿主。
    private func completeSearchResultCoverDismissal() {
        searchResultCoverPath = NavigationPath()
        searchResultCover = nil
        isSearchResultCoverDismissing = false
        let shouldOpenPendingReadingTimer = pendingReadingTimerDeepLinkRequest != nil
        if !shouldOpenPendingReadingTimer,
           shouldRestoreSearchPresentationAfterCover,
           selectedTab == .search,
           searchPath.isEmpty {
            setSearchPresented(true, disablesAnimations: true)
        }
        shouldRestoreSearchPresentationAfterCover = false
        continuePendingReadingTimerDeepLinkIfPossible()
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

    /// 消费 App 根层分发的计时深链，在当前 scene 内精确恢复目标记录并清空其他覆盖层。
    private func openReadingTimerDeepLink(_ route: ReadingRoute) {
        switch route {
        case .readingSession(let bookId):
            presentReadingTimerDeepLink(request: .book(bookId))
        case .readingSessionRecord(let recordId, let bookId):
            presentReadingTimerDeepLink(
                request: .record(recordId: recordId, bookId: bookId)
            )
        default:
            selectedTab = .reading
            searchResultCoverPath = NavigationPath()
            beginSearchResultCoverDismissal()
            replaceReadingPath(with: route)
        }
        readingTimerDeepLinkRouter.consume(route)
    }

    /// 深链始终采用无来源标准入场；若搜索结果覆盖层可见，则等待其 onDismiss 后再从根 Tab 呈现。
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

    /// 以 newest-wins 语义推进待处理深链，严格等待现有计时全屏页与搜索覆盖层各自完成 onDismiss。
    private func continuePendingReadingTimerDeepLinkIfPossible() {
        guard readingTimerPresentation == nil,
              pendingReadingTimerDismissal == nil,
              let request = pendingReadingTimerDeepLinkRequest else {
            return
        }
        if searchResultCover != nil || isSearchResultCoverDismissing {
            guard !isSearchResultCoverDismissing else { return }
            searchResultCoverPath = NavigationPath()
            beginSearchResultCoverDismissal()
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

    /// 消费网页端原生高级版动作，切换到“我的”并沿用该 Tab 的既有导航栈继续 push。
    private func openPremiumUpgradeFromDesktopWeb() {
        selectedTab = .profile
        profilePath.append(PersonalRoute.premium)
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

/// 兼容历史 Codable 路径的瞬时中继页，每个视图身份只把旧 route 转发一次。
private struct ReadingTimerLegacyRouteRelay: View {
    let onRelay: () -> Void

    @State private var didRelay = false

    var body: some View {
        Color.surfacePage
            .ignoresSafeArea()
            .task {
                guard !didRelay else { return }
                didRelay = true
                onRelay()
            }
    }
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
        .environment(ReadingTimerDeepLinkRouter())
        .environment(DesktopWebSessionCoordinator())
}
