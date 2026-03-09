//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

/**
 * [INPUT]: 依赖 Reading/Book/Note/Personal 各模块容器视图与对应路由枚举，依赖 DebugRoute 提供调试页面跳转
 * [OUTPUT]: 对外提供 MainTabView（四大主 Tab 的 NavigationStack 组织与目的地分发）
 * [POS]: 应用根导航入口，负责跨模块路由承接（含在读页热力图点击进入阅读日历）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

enum AppTab: String, CaseIterable {
    case reading, books, notes, profile, search
}

/// 应用主导航容器，组织四个主 Tab 及跨模块路由跳转。
struct MainTabView: View {
    @State private var selectedTab: AppTab = .reading
    @State private var readingPath = NavigationPath()
    @State private var booksPath = NavigationPath()
    @State private var notesPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("在读", systemImage: "calendar", value: .reading) {
                NavigationStack(path: $readingPath) {
                    ReadingContainerView(
                        onAddBook: { append(BookRoute.add, to: .reading) },
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .reading) },
                        onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .reading) },
                        onOpenReadCalendar: { date in
                            readingPath.append(ReadingRoute.readCalendar(date: date))
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
                }
            }

            Tab("书籍", systemImage: "book", value: .books) {
                NavigationStack(path: $booksPath) {
                    BookContainerView(
                        onAddBook: { append(BookRoute.add, to: .books) },
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .books) },
                        onOpenDebugCenter: { append(DebugRoute.debugCenter, to: .books) }
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
                }
            }

            Tab("笔记", systemImage: "archivebox", value: .notes) {
                NavigationStack(path: $notesPath) {
                    NoteContainerView(
                        onAddBook: { append(BookRoute.add, to: .notes) },
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .notes) },
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
                }
            }

            Tab("我的", systemImage: "person", value: .profile) {
                NavigationStack(path: $profilePath) {
                    PersonalView(
                        onAddBook: { append(BookRoute.add, to: .profile) },
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .profile) },
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
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .search) },
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
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSearchActivation(.searchTabSelection)
        .searchable(text: $searchQuery, prompt: "搜索书籍或书摘")
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
        case .edit:
            Text("编辑书籍")
        case .add:
            Text("添加书籍")
        }
    }

    // MARK: - Note Destinations

    @ViewBuilder
    private func noteDestination(for route: NoteRoute) -> some View {
        switch route {
        case .detail(let noteId):
            NoteDetailView(noteId: noteId)
        case .edit(let noteId):
            NoteDetailView(noteId: noteId, startInEditing: true)
        case .create:
            Text("创建笔记")
        case .notesByTag:
            Text("标签笔记")
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
            Text("作者管理")
        case .pressManagement:
            Text("出版社管理")
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
            Color.windowBackground.ignoresSafeArea()

            VStack(spacing: Spacing.base) {
                VStack(spacing: Spacing.base) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? "输入关键词开始搜索" : "暂无匹配结果")
                        .font(.body)
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
