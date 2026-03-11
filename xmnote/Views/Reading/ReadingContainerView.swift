import SwiftUI

/**
 * [INPUT]: 依赖 TopSwitcher/AddMenuCircleButton 顶部交互组件，依赖 Reading 子页面与书籍/日历路由回调
 * [OUTPUT]: 对外提供 ReadingContainerView（在读 Tab 容器，管理子页切换与事件上抛）
 * [POS]: 在读模块根容器，负责“在读/时间线/统计”切换和首页事件上抛
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - Sub Tab
/// ReadingSubTab 定义在读根容器的三段切换项，统一顶部切换标题和页面选择语义。
enum ReadingSubTab: String, CaseIterable {
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
    @State private var selectedSubTab: ReadingSubTab = .reading
    private let topBarHeight: CGFloat = 52
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void

    /// 注入新增书籍回调，连接阅读页顶栏操作入口。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenDebugCenter: (() -> Void)? = nil,
        onOpenReadCalendar: @escaping (Date) -> Void = { _ in },
        onOpenBookDetail: @escaping (Int64) -> Void = { _ in }
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
        self.onOpenReadCalendar = onOpenReadCalendar
        self.onOpenBookDetail = onOpenBookDetail
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.windowBackground.ignoresSafeArea()

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
    private func segmentedPage(for tab: ReadingSubTab) -> some View {
        switch tab {
        case .reading:
            ReadingDashboardView(
                onAddBook: onAddBook,
                onOpenReadCalendar: onOpenReadCalendar,
                onOpenBookDetail: onOpenBookDetail
            )
        case .timeline:
            ReadingTimelineView()
        case .statistics:
            StatisticsPlaceholderView()
        }
    }
}

#Preview {
    NavigationStack {
        ReadingContainerView()
    }
}
