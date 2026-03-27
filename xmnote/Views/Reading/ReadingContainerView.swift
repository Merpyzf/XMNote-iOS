import SwiftUI

/**
 * [INPUT]: 依赖 TopSwitcher/AddMenuCircleButton 顶部交互组件，依赖 Reading 子页面与书籍/日历/内容查看路由回调
 * [OUTPUT]: 对外提供 ReadingContainerView（在读 Tab 容器，管理子页切换与事件上抛）
 * [POS]: 在读模块根容器，负责“在读/时间线/统计”切换和首页事件上抛
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - Sub Tab
/// ReadingSubTab 定义在读根容器的三段切换项，统一顶部切换标题和页面选择语义。
enum ReadingSubTab: String, CaseIterable, Codable {
    case reading, timeline, statistics

    var title: String {
        switch self {
        case .reading: "在读"
        case .timeline: "时间线"
        case .statistics: "统计"
        }
    }
}

// MARK: - Container

/// 在读 Tab 容器，负责子页切换并上抛新增、书籍详情与阅读日历跳转事件。
struct ReadingContainerView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(SceneStateStore.self) private var sceneStateStore
    @State private var selectedSubTab: ReadingSubTab = .reading
    @State private var timelineViewModel: TimelineViewModel?
    @State private var subtabBootstrapCoordinator = SubtabBootstrapCoordinator<ReadingSubTab>()
    @State private var didBootstrapFromScene = false
    private let topBarHeight: CGFloat = 56
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void

    /// 注入新增书籍回调，连接阅读页顶栏操作入口。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenDebugCenter: (() -> Void)? = nil,
        onOpenReadCalendar: @escaping (Date) -> Void = { _ in },
        onOpenBookDetail: @escaping (Int64) -> Void = { _ in },
        onOpenContentViewer: @escaping (ContentViewerSourceContext, ContentViewerItemID) -> Void = { _, _ in }
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
        self.onOpenReadCalendar = onOpenReadCalendar
        self.onOpenBookDetail = onOpenBookDetail
        self.onOpenContentViewer = onOpenContentViewer
    }

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
                tabs: ReadingSubTab.allCases,
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
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            selectedSubTab = sceneStateStore.snapshot.reading.selectedSubTab
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard timelineViewModel == nil else { return }
            let viewModel = TimelineViewModel(repository: repositories.timelineRepository)
            if let snapshot = sceneStateStore.snapshot.reading.timeline {
                viewModel.applySceneSnapshot(snapshot)
            }
            timelineViewModel = viewModel
            await Task.yield()
            warmTimelineIfNeeded(priority: .utility)
        }
        .onChange(of: selectedSubTab) { _, newSelection in
            sceneStateStore.updateReadingSelectedSubTab(newSelection)
            guard newSelection == .timeline else { return }
            warmTimelineIfNeeded(priority: .userInitiated)
        }
    }

    private var segmentedContent: some View {
        KeepAliveSwitcherHost(
            selection: selectedSubTab,
            tabs: ReadingSubTab.allCases
        ) { tab in
            segmentedPage(for: tab)
        }
    }

    @ViewBuilder
    /// 封装segmentedPage对应的业务步骤，确保调用方可以稳定复用该能力。
    private func segmentedPage(for tab: ReadingSubTab) -> some View {
        switch tab {
        case .reading:
            ReadingDashboardView(
                onAddBook: onAddBook,
                onOpenReadCalendar: onOpenReadCalendar,
                onOpenBookDetail: onOpenBookDetail
            )
        case .timeline:
            ReadingTimelineView(
                viewModel: timelineViewModel,
                onOpenContentViewer: onOpenContentViewer,
                onOpenBookDetail: onOpenBookDetail
            )
        case .statistics:
            StatisticsPlaceholderView()
        }
    }

    /// 封装warmTimelineIfNeeded对应的业务步骤，确保调用方可以稳定复用该能力。
    private func warmTimelineIfNeeded(priority: TaskPriority) {
        guard let timelineViewModel else { return }
        subtabBootstrapCoordinator.warm(.timeline, priority: priority) {
            await timelineViewModel.loadInitialData()
        }
    }
}

#Preview {
    NavigationStack {
        ReadingContainerView()
    }
}
