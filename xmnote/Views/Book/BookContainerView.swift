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

struct BookContainerView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookViewModel?
    let onAddBook: () -> Void
    let onAddNote: () -> Void

    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {}
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
    }

    var body: some View {
        Group {
            if let viewModel {
                BookContentView(
                    viewModel: viewModel,
                    onAddBook: onAddBook,
                    onAddNote: onAddNote
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
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    @State private var selectedSubTab: BookSubTab = .books

    var body: some View {
        ZStack(alignment: .top) {
            Color.windowBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                segmentedContent
            }

            HomeTopHeaderGradient()
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TopSwitcher(
                selection: $selectedSubTab,
                tabs: BookSubTab.allCases,
                titleProvider: \.title
            ) {
                AddMenuCircleButton(
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    usesGlassStyle: true
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Segmented Content

    @ViewBuilder
    private var segmentedContent: some View {
        switch selectedSubTab {
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
