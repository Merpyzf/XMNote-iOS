//
//  BookContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 BookViewModel 驱动状态
 * [OUTPUT]: 对外提供 BookContainerView 与 BookSubTab 枚举
 * [POS]: Book 模块容器壳层，承载书籍/书单二级切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Sub Tab

/// 书籍页二级分栏：书籍列表与书单列表。
enum BookSubTab: CaseIterable, Hashable {
    case books, collections

    var title: String {
        switch self {
        case .books: "书籍"
        case .collections: "书单"
        }
    }
}

// MARK: - Container

/// 书籍模块入口容器，负责书籍/书单二级切换与顶部新增操作。
struct BookContainerView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookViewModel?
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?

    /// 注入新增书籍回调，连接书籍页与外层操作入口。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenDebugCenter: (() -> Void)? = nil
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
    }

    var body: some View {
        Group {
            if let viewModel {
                BookContentView(
                    viewModel: viewModel,
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter
                )
            } else {
                Color.clear
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = BookViewModel(repository: repositories.bookRepository)
        }
    }
}

// MARK: - Content View

private struct BookContentView: View {
    @Bindable var viewModel: BookViewModel
    private let topBarHeight: CGFloat = 52
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    @State private var selectedSubTab: BookSubTab = .books

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            segmentedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, topBarHeight)

            HomeTopHeaderGradient()
                .allowsHitTesting(false)

            TopSwitcher(
                selection: $selectedSubTab,
                tabs: BookSubTab.allCases,
                titleProvider: \.title
            ) {
                AddMenuCircleButton(
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter,
                    usesGlassStyle: true
                )
            }
            .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Segmented Content

    private var segmentedContent: some View {
        KeepAliveSwitcherHost(
            selection: selectedSubTab,
            tabs: BookSubTab.allCases
        ) { tab in
            segmentedPage(for: tab)
        }
    }

    @ViewBuilder
    private func segmentedPage(for tab: BookSubTab) -> some View {
        switch tab {
        case .books:
            BookGridView(viewModel: viewModel)
        case .collections:
            CollectionListPlaceholderView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        BookContainerView()
    }
    .environment(repositories)
}
