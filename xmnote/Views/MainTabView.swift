//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

enum AppTab: String, CaseIterable {
    case reading, books, notes, profile, search
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .reading
    @State private var readingPath = NavigationPath()
    @State private var booksPath = NavigationPath()
    @State private var notesPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var searchPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("在读", systemImage: "calendar", value: .reading) {
                NavigationStack(path: $readingPath) {
                    ReadingContainerView(
                        onAddBook: { append(BookRoute.add, to: .reading) },
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .reading) }
                    )
                        .toolbar(.hidden, for: .navigationBar)
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
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .books) }
                    )
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
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .notes) }
                    )
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
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .profile) }
                    )
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
                        onAddBook: { append(BookRoute.add, to: .search) },
                        onAddNote: { append(NoteRoute.create(bookId: nil), to: .search) }
                    )
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
    }

    // MARK: - Reading Destinations

    @ViewBuilder
    private func readingDestination(for route: ReadingRoute) -> some View {
        switch route {
        case .bookDetail:
            Text("书籍详情")
        case .readingSession:
            Text("阅读计时")
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
            Text("阅读日历")
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
}

private struct SearchView: View {
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    @State private var query = ""

    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {}
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            searchField

            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(query.isEmpty ? "搜索书籍与书摘" : "暂无匹配结果")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.half)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { Color.windowBackground.ignoresSafeArea() }
        .safeAreaInset(edge: .top, spacing: 0) {
            PrimaryTopBar {
                Text("搜索")
                    .font(.system(size: 17, weight: .semibold))
            } trailing: {
                AddMenuCircleButton(onAddBook: onAddBook, onAddNote: onAddNote)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索书籍或书摘", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        )
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
