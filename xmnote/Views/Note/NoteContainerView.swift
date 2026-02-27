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
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: NoteViewModel?
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
                NoteContentView(
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
            viewModel = NoteViewModel(repository: repositories.noteRepository)
        }
    }
}

// MARK: - Content View

private struct NoteContentView: View {
    @Bindable var viewModel: NoteViewModel
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    @State private var selectedSubTab: NoteSubTab = .notes

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
                tabs: NoteSubTab.allCases,
                titleProvider: \.title
            ) {
                noteActionButton
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
        case .notes:
            VStack(spacing: 0) {
                noteSearchBar
                ScrollView {
                    NoteCollectionView(viewModel: viewModel)
                }
            }
        case .review:
            NoteReviewPlaceholderView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private var noteSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索标签", text: $viewModel.searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
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
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.half)
    }

    private var noteActionButton: some View {
        Button {
            // TODO: sort/settings action
        } label: {
            TopBarActionIcon(
                systemName: selectedSubTab == .notes ? "arrow.up.arrow.down" : "gearshape"
            )
        }
        .topBarGlassButtonStyle(true)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        NoteContainerView()
    }
    .environment(repositories)
}
