//
//  ReadingContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

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

    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {}
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.windowBackground.ignoresSafeArea()

            TabView(selection: $selectedSubTab) {
                ReadingListPlaceholderView()
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
