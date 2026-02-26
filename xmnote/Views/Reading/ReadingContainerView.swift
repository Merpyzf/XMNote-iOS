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
            ReadingHeaderGradient()

            TabView(selection: $selectedSubTab) {
                ReadingListPlaceholderView()
                    .tag(ReadingSubTab.reading)
                TimelinePlaceholderView()
                    .tag(ReadingSubTab.timeline)
                StatisticsPlaceholderView()
                    .tag(ReadingSubTab.statistics)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ReadingTopSwitcher(
                selection: $selectedSubTab,
                onAddBook: onAddBook,
                onAddNote: onAddNote
            )
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ReadingHeaderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(light: Color(hex: 0x2ECF77).opacity(0.2), dark: Color(hex: 0x1E2A25)),
                Color.windowBackground.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .ignoresSafeArea(edges: .top)
    }
}

private struct ReadingTopSwitcher: View {
    @Binding var selection: ReadingSubTab
    let onAddBook: () -> Void
    let onAddNote: () -> Void

    var body: some View {
        PrimaryTopBar {
            QuoteInlineTabBar(selection: $selection) { $0.title }
        } trailing: {
            AddMenuCircleButton(onAddBook: onAddBook, onAddNote: onAddNote)
        }
    }
}

#Preview {
    NavigationStack {
        ReadingContainerView()
    }
}
