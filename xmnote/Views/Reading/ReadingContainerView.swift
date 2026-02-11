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

    var body: some View {
        TabView(selection: $selectedSubTab) {
            ReadingListPlaceholderView()
                .tag(ReadingSubTab.reading)
            TimelinePlaceholderView()
                .tag(ReadingSubTab.timeline)
            StatisticsPlaceholderView()
                .tag(ReadingSubTab.statistics)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                InlineTabBar(selection: $selectedSubTab) { $0.title }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ReadingContainerView()
    }
}
