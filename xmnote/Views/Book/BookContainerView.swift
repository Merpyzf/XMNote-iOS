//
//  BookContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

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
    @Environment(DatabaseManager.self) private var databaseManager
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
            viewModel = BookViewModel(database: databaseManager.database)
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
        VStack(spacing: 0) {
            segmentedContent
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            BookTopSwitcher(
                selection: $selectedSubTab,
                onAddBook: onAddBook,
                onAddNote: onAddNote
            )
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

private struct BookTopSwitcher: View {
    @Binding var selection: BookSubTab
    let onAddBook: () -> Void
    let onAddNote: () -> Void

    var body: some View {
        PrimaryTopBar {
            InlineTabBar(selection: $selection) { $0.title }
        } trailing: {
            AddMenuCircleButton(onAddBook: onAddBook, onAddNote: onAddNote)
        }
    }
}

#Preview {
    NavigationStack {
        BookContainerView()
    }
}
