//
//  NoteContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

// MARK: - Sub Tab

enum NoteSubTab: CaseIterable, Hashable {
    case notes, review

    var title: String {
        switch self {
        case .notes: "笔记"
        case .review: "回顾"
        }
    }
}

// MARK: - Container

struct NoteContainerView: View {
    @State private var selectedSubTab: NoteSubTab = .notes
    @State private var viewModel = NoteViewModel()

    var body: some View {
        VStack(spacing: 0) {
            segmentedContent
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            toolbarContent
        }
    }

    // MARK: - Segmented Content

    @ViewBuilder
    private var segmentedContent: some View {
        switch selectedSubTab {
        case .notes:
            ScrollView {
                NoteCollectionView(viewModel: viewModel)
            }
            .searchable(text: $viewModel.searchText, prompt: "搜索标签")
        case .review:
            NoteReviewPlaceholderView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // TODO: sort/settings action
            } label: {
                Image(systemName: selectedSubTab == .notes ? "arrow.up.arrow.down" : "gearshape")
            }
        }
    }
}

#Preview {
    NavigationStack {
        NoteContainerView()
    }
}
