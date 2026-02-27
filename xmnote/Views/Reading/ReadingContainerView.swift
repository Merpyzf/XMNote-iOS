import SwiftUI

/**
 * [INPUT]: 依赖 TopSwitcher/AddMenuCircleButton 顶部交互组件，依赖 Reading 子页面与路由回调
 * [OUTPUT]: 对外提供 ReadingContainerView（在读 Tab 容器，管理子页切换与事件上抛）
 * [POS]: 在读模块根容器，负责“在读/时间线/统计”切换和热力图点击导航事件传递
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - Sub Tab

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

struct ReadingContainerView: View {
    @State private var selectedSubTab: ReadingSubTab = .reading
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenReadCalendar: (Date) -> Void

    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenReadCalendar: @escaping (Date) -> Void = { _ in }
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenReadCalendar = onOpenReadCalendar
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.windowBackground.ignoresSafeArea()

            TabView(selection: $selectedSubTab) {
                ReadingListPlaceholderView(onOpenReadCalendar: onOpenReadCalendar)
                    .tag(ReadingSubTab.reading)
                TimelinePlaceholderView()
                    .tag(ReadingSubTab.timeline)
                StatisticsPlaceholderView()
                    .tag(ReadingSubTab.statistics)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HomeTopHeaderGradient()
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TopSwitcher(
                selection: $selectedSubTab,
                tabs: ReadingSubTab.allCases,
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
}

#Preview {
    NavigationStack {
        ReadingContainerView()
    }
}
