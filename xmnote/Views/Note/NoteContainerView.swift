//
//  NoteContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入笔记、内容、书籍与外部应用仓储，依赖 SceneStateStore 恢复首页语义快照，依赖 NoteViewModel/NoteReviewViewModel 驱动状态
 * [OUTPUT]: 对外提供 NoteContainerView 与 NoteSubTab 枚举，并上抛携带真实章节标题的笔记路由、书籍/目录定位、内容编辑及统一内容查看路由，同时为首页单本评分提供仓储能力
 * [POS]: Note 模块容器壳层，承载笔记/回顾二级切换、四分类首页状态保持与下拉搜索入口
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
    @State private var reviewViewModel: NoteReviewViewModel?
    @State private var selectedSubTab: NoteSubTab = .notes
    @State private var didBootstrapFromScene = false
    @State private var canPersistSceneSnapshot = false
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    let onOpenContentRoute: (ContentRoute) -> Void
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenDebugCenter: (() -> Void)?

    /// 注入新增书籍/笔记回调，让顶部快捷入口把用户操作上抛到外层页面。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenNoteRoute: @escaping (NoteRoute) -> Void = { _ in },
        onOpenBookRoute: @escaping (BookRoute) -> Void = { _ in },
        onOpenContentRoute: @escaping (ContentRoute) -> Void = { _ in },
        onOpenContentViewer: @escaping (ContentViewerSourceContext, ContentViewerItemID) -> Void = { _, _ in },
        onOpenDebugCenter: (() -> Void)? = nil
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenNoteRoute = onOpenNoteRoute
        self.onOpenBookRoute = onOpenBookRoute
        self.onOpenContentRoute = onOpenContentRoute
        self.onOpenContentViewer = onOpenContentViewer
        self.onOpenDebugCenter = onOpenDebugCenter
    }

    var body: some View {
        Group {
            if let viewModel, let reviewViewModel {
                NoteContentView(
                    viewModel: viewModel,
                    reviewViewModel: reviewViewModel,
                    selectedSubTab: $selectedSubTab,
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenNoteRoute: onOpenNoteRoute,
                    onOpenBookRoute: onOpenBookRoute,
                    onOpenContentRoute: onOpenContentRoute,
                    onOpenContentViewer: onOpenContentViewer,
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
            canPersistSceneSnapshot = false

            let snapshot = sceneStateStore.snapshot.notes
            let noteViewModel = NoteViewModel(
                repository: repositories.noteRepository,
                contentRepository: repositories.contentRepository,
                bookRepository: repositories.bookRepository,
                startsObserving: false
            )
            noteViewModel.applySceneSnapshot(snapshot)
            selectedSubTab = snapshot.selectedSubTab
            noteViewModel.restartObservations()
            viewModel = noteViewModel

            if reviewViewModel == nil {
                reviewViewModel = NoteReviewViewModel(
                    repository: repositories.noteRepository,
                    externalAppIntegrationRepository: repositories.externalAppIntegrationRepository
                )
            }

            canPersistSceneSnapshot = true
            syncSceneSnapshot()
        }
        .onChange(of: currentSceneSnapshot) { _, _ in
            syncSceneSnapshot()
        }
    }

    private var currentSceneSnapshot: NotesSceneSnapshot? {
        viewModel?.sceneSnapshot(selectedSubTab: selectedSubTab)
    }

    /// 仅在恢复完成后写回首页语义状态；相同快照由 SceneStateStore 自动过滤。
    private func syncSceneSnapshot() {
        guard canPersistSceneSnapshot, let currentSceneSnapshot else { return }
        sceneStateStore.updateNotes(currentSceneSnapshot)
    }
}

// MARK: - Content View

private struct NoteContentView: View {
    @Bindable var viewModel: NoteViewModel
    @Bindable var reviewViewModel: NoteReviewViewModel
    @Binding var selectedSubTab: NoteSubTab
    @State private var isReviewSettingsPresented = false
    private let topBarHeight: CGFloat = 56
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    let onOpenContentRoute: (ContentRoute) -> Void
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
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
                TopBarActionPill {
                    noteActionControl(presentation: .pillSegment)
                } trailing: {
                    AddMenuCircleButton(
                        onAddBook: onAddBook,
                        onAddNote: onAddNote,
                        onOpenDebugCenter: onOpenDebugCenter,
                        usesGlassStyle: true,
                        presentation: .pillSegment,
                        iconSize: NoteTopBarMetrics.actionIconSize
                    )
                }
            }
            .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isReviewSettingsPresented) {
            NoteReviewSettingsSheet(viewModel: reviewViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Segmented Content

    private var segmentedContent: some View {
        KeepAliveSwitcherHost(
            selection: selectedSubTab,
            tabs: NoteSubTab.allCases,
            transitionPolicy: .contextual
        ) { tab in
            segmentedPage(for: tab)
        }
    }

    @ViewBuilder
    private func segmentedPage(for tab: NoteSubTab) -> some View {
        switch tab {
        case .notes:
            NoteCollectionView(
                viewModel: viewModel,
                onOpenExcerptScope: { context in
                    onOpenNoteRoute(.noteExcerptList(context: context))
                },
                onOpenStarredChapter: { chapter in
                    onOpenNoteRoute(
                        .chapterNoteList(
                            context: ChapterNoteListContext(
                                bookID: chapter.bookID,
                                chapterID: chapter.id,
                                includeDescendants: true,
                                displayTitle: chapter.title
                            )
                        )
                    )
                },
                onLocateStarredChapter: { chapter in
                    onOpenBookRoute(
                        .chapterManager(
                            bookID: chapter.bookID,
                            focusChapterID: chapter.id
                        )
                    )
                },
                onOpenRelatedCategory: { scope in
                    onOpenNoteRoute(.relatedCategory(scope: scope))
                },
                onOpenReview: { review in
                    onOpenContentViewer(
                        .allReviews(
                            query: viewModel.normalizedSearchText,
                            sort: viewModel.reviewSort
                        ),
                        .review(review.id)
                    )
                },
                onOpenBook: { onOpenBookRoute(.detail(bookId: $0)) },
                onOpenTagManagement: { onOpenNoteRoute(.tagManagement) },
                onEditReview: { onOpenContentRoute(.reviewEditor(reviewId: $0)) }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .review:
            NoteReviewView(
                viewModel: reviewViewModel,
                onOpenContentViewer: onOpenContentViewer,
                onOpenSettings: { isReviewSettingsPresented = true }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func noteActionControl(presentation: TopBarActionPresentation) -> some View {
        if selectedSubTab == .notes {
            Menu {
                noteSortMenu
            } label: {
                TopBarActionIcon(
                    systemName: "arrow.up.arrow.down",
                    iconSize: NoteTopBarMetrics.actionIconSize,
                    foregroundColor: Color.iconPrimary.opacity(0.88),
                    hitShape: presentation == .pillSegment ? .rectangle : .circle
                )
            }
            .topBarActionPresentationStyle(presentation)
            .accessibilityLabel("排序")
        } else {
            Button {
                isReviewSettingsPresented = true
            } label: {
                TopBarActionIcon(
                    systemName: "gearshape",
                    iconSize: NoteTopBarMetrics.actionIconSize,
                    foregroundColor: Color.iconPrimary.opacity(0.88),
                    hitShape: presentation == .pillSegment ? .rectangle : .circle
                )
            }
            .topBarActionPresentationStyle(presentation)
            .accessibilityLabel("回顾设置")
        }
    }

    @ViewBuilder
    private var noteSortMenu: some View {
        switch viewModel.selectedCategory {
        case .excerpts:
            ForEach(NoteExcerptGroupSort.allCases) { option in
                sortMenuButton(
                    title: option.title,
                    isSelected: viewModel.excerptSort == option
                ) {
                    viewModel.excerptSort = option
                }
            }
        case .starredChapters:
            ForEach(StarredChapterSort.allCases, id: \.self) { option in
                sortMenuButton(
                    title: option.noteMenuTitle,
                    isSelected: viewModel.starredSort == option
                ) {
                    viewModel.starredSort = option
                }
            }
        case .related:
            ForEach(RelatedCategorySort.allCases, id: \.self) { option in
                sortMenuButton(
                    title: option.noteMenuTitle,
                    isSelected: viewModel.relatedSort == option
                ) {
                    viewModel.relatedSort = option
                }
            }
        case .reviews:
            ForEach(BookReviewSortRule.allCases, id: \.self) { option in
                sortMenuButton(
                    title: option.noteMenuTitle,
                    isSelected: viewModel.reviewSort == option
                ) {
                    viewModel.reviewSort = option
                }
            }
        }
    }

    private func sortMenuButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

}

private extension StarredChapterSort {
    var noteMenuTitle: String {
        switch self {
        case .recentlyChanged: "最近变更"
        case .noteCountDescending: "笔记数量 • 由多到少"
        }
    }
}

private extension RelatedCategorySort {
    var noteMenuTitle: String {
        switch self {
        case .countAscending: "数量从少到多"
        case .countDescending: "数量从多到少"
        case .createdAscending: "最早创建"
        case .createdDescending: "最近创建"
        }
    }
}

private extension BookReviewSortRule {
    var noteMenuTitle: String {
        switch self {
        case .wordCountAscending: "字数从少到多"
        case .wordCountDescending: "字数从多到少"
        case .createdAscending: "最早创建"
        case .createdDescending: "最近创建"
        }
    }
}

private enum NoteTopBarMetrics {
    static let actionIconSize: CGFloat = 14
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        NoteContainerView()
    }
    .environment(repositories)
}
