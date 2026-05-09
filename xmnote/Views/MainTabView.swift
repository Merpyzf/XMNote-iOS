//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 Reading/Book/Note/Content/Personal 各模块容器视图与对应路由枚举，依赖 DebugRoute 提供调试页面跳转，依赖 openURL 打开外部帮助文档，依赖书籍页回调协调 TabBar snapshot 恢复交接层
 * [OUTPUT]: 对外提供 MainTabView（五个主 Tab 的 NavigationStack 组织、目的地分发与根级 TabBar snapshot 恢复交接层）
 * [POS]: 应用根导航入口，负责跨模块路由承接与系统 TabView 外层视觉交接（含书架聚合列表、书架管理入口、在读页热力图点击进入阅读日历、内容查看与内容编辑）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 应用主 Tab 枚举，统一根级导航页签身份。
enum AppTab: String, CaseIterable, Codable {
    case reading, books, notes, profile, search
}

/// 根级 TabBar 快照交接命令，使用递增 id 保证连续相同事件也能传递给 UIKit 宿主。
private struct TabBarSnapshotHandoffCommand: Equatable {
    let id: Int
    let event: BookshelfTabBarSnapshotHandoffEvent

    static let initial = TabBarSnapshotHandoffCommand(id: 0, event: .hideSnapshot)

    func next(_ event: BookshelfTabBarSnapshotHandoffEvent) -> TabBarSnapshotHandoffCommand {
        TabBarSnapshotHandoffCommand(id: id + 1, event: event)
    }
}

/// 应用主导航容器，组织四个主 Tab 及跨模块路由跳转。
struct MainTabView: View {
    @Environment(SceneStateStore.self) private var sceneStateStore
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: AppTab = .reading
    @State private var readingPath = NavigationPath()
    @State private var booksPath = NavigationPath()
    @State private var notesPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var didBootstrapFromScene = false
    @State private var tabBarSnapshotHandoffCommand = TabBarSnapshotHandoffCommand.initial

    var body: some View {
        ZStack(alignment: .bottom) {
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
                        onOpenGuide: openBookManagementGuide,
                        onTabBarSnapshotHandoff: sendTabBarSnapshotHandoff
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
                    SearchView(
                        query: $searchQuery,
                        onAddBook: { append(BookRoute.add, to: .search) },
                        onAddNote: { append(NoteRoute.create(seed: .empty), to: .search) },
                        onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .search) }
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
            .mainTabSearchHost(isEnabled: selectedTab == .search, searchQuery: $searchQuery)

            TabBarSnapshotHandoffHost(
                command: tabBarSnapshotHandoffCommand,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .zIndex(10)
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            restoreFromSceneSnapshot()
        }
        .onChange(of: selectedTab) { _, newValue in
            sendTabBarSnapshotHandoff(.hideSnapshot)
            sceneStateStore.updateSelectedTab(newValue)
        }
        .onChange(of: searchQuery) { _, newValue in
            sceneStateStore.updateSearchQuery(newValue)
        }
        .onChange(of: pathSignature(for: readingPath)) { _, _ in
            sceneStateStore.updatePath(readingPath, for: .reading)
        }
        .onChange(of: pathSignature(for: booksPath)) { _, _ in
            sceneStateStore.updatePath(booksPath, for: .books)
        }
        .onChange(of: pathSignature(for: notesPath)) { _, _ in
            sceneStateStore.updatePath(notesPath, for: .notes)
        }
        .onChange(of: pathSignature(for: profilePath)) { _, _ in
            sceneStateStore.updatePath(profilePath, for: .profile)
        }
        .onChange(of: pathSignature(for: searchPath)) { _, _ in
            sceneStateStore.updatePath(searchPath, for: .search)
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

    private func openBookManagementGuide() {
        guard let url = URL(string: "https://docs.xmnote.com/#/book/bookmanagement") else { return }
        openURL(url)
    }

    /// 向 UIKit 快照宿主发送交接事件，让系统 TabBar 的恢复动作在真实快照下完成后再露出。
    private func sendTabBarSnapshotHandoff(_ event: BookshelfTabBarSnapshotHandoffEvent) {
        tabBarSnapshotHandoffCommand = tabBarSnapshotHandoffCommand.next(event)
    }

    private func contentRoute(
        for source: ContentViewerSourceContext,
        initialItem: ContentViewerItemID
    ) -> ContentRoute {
        .contentViewer(source: source, initialItemID: initialItem, keyword: "")
    }

    private func restoreFromSceneSnapshot() {
        let snapshot = sceneStateStore.snapshot
        selectedTab = snapshot.selectedTab
        searchQuery = snapshot.searchQuery
        readingPath = restoredPath(for: .reading)
        booksPath = restoredPath(for: .books)
        notesPath = restoredPath(for: .notes)
        profilePath = restoredPath(for: .profile)
        searchPath = restoredPath(for: .search)
    }

    private func restoredPath(for tab: AppTab) -> NavigationPath {
        guard let representation = sceneStateStore.pathRepresentation(for: tab) else {
            return NavigationPath()
        }
        return NavigationPath(representation)
    }

    private func pathSignature(for path: NavigationPath) -> String {
        guard let representation = path.codable,
              let data = try? JSONEncoder().encode(representation) else {
            return "empty"
        }
        return data.base64EncodedString()
    }
}

/// 根级 TabBar 快照交接宿主，只在书架退出编辑态时短暂显示真实系统 TabBar 的快照。
private struct TabBarSnapshotHandoffHost: UIViewRepresentable {
    let command: TabBarSnapshotHandoffCommand
    let reduceMotion: Bool

    func makeUIView(context: Context) -> TabBarSnapshotHandoffView {
        let view = TabBarSnapshotHandoffView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TabBarSnapshotHandoffView, context: Context) {
        guard context.coordinator.lastCommandID != command.id else { return }
        context.coordinator.lastCommandID = command.id

        switch command.event {
        case .prepareSnapshot:
            uiView.prepareSnapshot()
        case .showSnapshot:
            uiView.showSnapshot(
                duration: BookshelfManagementMotion.tabBarSnapshotFadeInDuration(reduceMotion: reduceMotion)
            )
        case .hideSnapshot:
            uiView.hideSnapshot(
                duration: BookshelfManagementMotion.tabBarSnapshotFadeOutDuration(reduceMotion: reduceMotion)
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastCommandID: Int?
    }
}

/// UIKit 容器负责捕获和摆放真实 UITabBar 快照，避免 SwiftUI 手绘底栏与系统底栏叠加露馅。
private final class TabBarSnapshotHandoffView: UIView {
    private var preparedSnapshot: UIView?
    private var activeSnapshot: UIView?
    private var preparedFrame: CGRect = .zero

    /// 在系统 TabBar 仍可见时捕获快照；若当前找不到可见 TabBar，则清理旧快照并放弃本次交接。
    func prepareSnapshot() {
        clearSnapshot(animated: false, duration: 0)

        guard let tabBar = visibleTabBar(),
              let snapshot = tabBar.snapshotView(afterScreenUpdates: false) else {
            return
        }

        preparedFrame = tabBar.convert(tabBar.bounds, to: self)
        snapshot.frame = preparedFrame
        snapshot.isUserInteractionEnabled = false
        snapshot.alpha = 1
        preparedSnapshot = snapshot
    }

    /// 把已准备好的 TabBar 快照放到根层；快照不可用时直接跳过，避免出现假的替代视觉。
    func showSnapshot(duration: TimeInterval) {
        guard let snapshot = preparedSnapshot else { return }
        activeSnapshot?.removeFromSuperview()
        preparedSnapshot = nil
        snapshot.layer.removeAllAnimations()
        snapshot.frame = preparedFrame
        snapshot.alpha = duration > 0 ? 0 : 1
        addSubview(snapshot)
        activeSnapshot = snapshot

        guard duration > 0 else { return }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 1
        }
    }

    /// 淡出并移除快照；重复调用或没有快照时保持幂等。
    func hideSnapshot(duration: TimeInterval) {
        guard activeSnapshot != nil || preparedSnapshot != nil else { return }
        clearSnapshot(animated: true, duration: duration)
    }

    private func clearSnapshot(animated: Bool, duration: TimeInterval) {
        preparedSnapshot?.removeFromSuperview()
        preparedSnapshot = nil

        guard let snapshot = activeSnapshot else { return }
        activeSnapshot = nil
        snapshot.layer.removeAllAnimations()

        guard animated, duration > 0 else {
            snapshot.removeFromSuperview()
            return
        }

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    private func visibleTabBar() -> UITabBar? {
        guard let rootView = window ?? activeWindow() else { return nil }
        return firstVisibleTabBar(in: rootView)
    }

    private func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func firstVisibleTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar,
           !tabBar.isHidden,
           tabBar.alpha > 0.01,
           tabBar.bounds.width > 0,
           tabBar.bounds.height > 0 {
            return tabBar
        }

        for subview in view.subviews.reversed() {
            if let tabBar = firstVisibleTabBar(in: subview) {
                return tabBar
            }
        }

        return nil
    }
}

private extension View {
    /// 仅在搜索 Tab 激活时挂载根级搜索宿主，避免其他导航栈长期持有搜索控制器状态。
    func mainTabSearchHost(
        isEnabled: Bool,
        searchQuery: Binding<String>
    ) -> some View {
        modifier(
            MainTabSearchHostModifier(
                isEnabled: isEnabled,
                searchQuery: searchQuery
            )
        )
    }
}

/// MainTabSearchHostModifier 条件挂载搜索 tab 的根级 searchable 宿主，避免跨 tab 残留搜索控制器状态。
private struct MainTabSearchHostModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchQuery: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .tabViewSearchActivation(.searchTabSelection)
                .searchable(text: $searchQuery, prompt: "搜索书籍或书摘")
        } else {
            content
        }
    }
}

private struct SearchView: View {
    @Binding var query: String
    private let topBarHeight: CGFloat = 52
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?

    /// 注入搜索与新增回调，组装主 Tab 页面上下文。
    init(
        query: Binding<String>,
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenDebugCenter: (() -> Void)? = nil
    ) {
        self._query = query
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            VStack(spacing: Spacing.base) {
                VStack(spacing: Spacing.base) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? "输入关键词开始搜索" : "暂无匹配结果")
                        .font(AppTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, topBarHeight)

            HomeTopHeaderGradient()
                .allowsHitTesting(false)

            HStack {
                Spacer(minLength: 0)
                AddMenuCircleButton(
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .frame(height: topBarHeight)
            .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
