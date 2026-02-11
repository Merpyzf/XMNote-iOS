//
//  StatisticsPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

struct StatisticsPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "chart.bar", message: "暂无统计数据")
    }
}

#Preview {
    StatisticsPlaceholderView()
}
