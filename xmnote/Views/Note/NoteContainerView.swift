//
//  NoteContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 NoteViewModel 驱动状态
 * [OUTPUT]: 对外提供 NoteContainerView 与 NoteSubTab 枚举
 * [POS]: Note 模块容器壳层，承载笔记/回顾二级切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Sub Tab

/// 笔记页二级分栏：笔记列表与回顾入口。
enum NoteSubTab: String, CaseIterable, Hashable, Codable {
    case notes, review

    var title: String {
        switch self {
        case .notes: "笔记"
        case .review: "回顾"
        }
    }
}

// MARK: - Container

/// NoteContainerView 作为笔记模块入口容器，负责搭建二级 Tab 与顶栏操作，并托管 NoteViewModel 生命周期。
struct NoteContainerView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(SceneStateStore.self) private var sceneStateStore
    @State private var viewModel: NoteViewModel?
    @State private var selectedSubTab: NoteSubTab = .notes
    @State private var didBootstrapFromScene = false
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?

    /// 注入新增书籍/笔记回调，让顶部快捷入口把用户操作上抛到外层页面。
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
                NoteContentView(
                    viewModel: viewModel,
                    selectedSubTab: $selectedSubTab,
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter
                )
            } else {
                Color.clear
            }
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            selectedSubTab = sceneStateStore.snapshot.notes.selectedSubTab
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = NoteViewModel(repository: repositories.noteRepository)
        }
        .onChange(of: selectedSubTab) { _, newValue in
            sceneStateStore.updateNoteSelectedSubTab(newValue)
        }
    }
}

// MARK: - Content View

private struct NoteContentView: View {
    @Bindable var viewModel: NoteViewModel
    @Binding var selectedSubTab: NoteSubTab
    private let topBarHeight: CGFloat = 56
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?

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
                tabs: NoteSubTab.allCases,
                titleProvider: \.title
            ) {
                noteActionButton
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
            tabs: NoteSubTab.allCases
        ) { tab in
            segmentedPage(for: tab)
        }
    }

    @ViewBuilder
    private func segmentedPage(for tab: NoteSubTab) -> some View {
        switch tab {
        case .notes:
            VStack(spacing: Spacing.none) {
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
        HStack(spacing: Spacing.cozy) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索标签", text: $viewModel.searchText)
                .font(AppTypography.subheadline)
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
        .padding(.horizontal, Spacing.base)
        .frame(height: 36)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.half)
    }

    private var noteActionButton: some View {
        Button {
            // TODO: sort/settings action
        } label: {
            TopBarActionIcon(
                systemName: selectedSubTab == .notes ? "arrow.up.arrow.down" : "gearshape",
                containerSize: 36
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
