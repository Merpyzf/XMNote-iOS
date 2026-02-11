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
    @State private var selectedSubTab: BookSubTab = .books

    var body: some View {
        Group {
            switch selectedSubTab {
            case .books:
                BookPlaceholderView()
            case .collections:
                CollectionListPlaceholderView()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            toolbarContent
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            InlineTabBar(selection: $selectedSubTab) { $0.title }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // TODO: 添加书籍/书单
            } label: {
                Image(systemName: "plus")
            }
        }
    }
}

#Preview {
    NavigationStack {
        BookContainerView()
    }
}
