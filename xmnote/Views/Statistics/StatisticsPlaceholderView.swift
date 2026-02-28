//
//  StatisticsPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 EmptyStateView 公共组件
 * [OUTPUT]: 对外提供 StatisticsPlaceholderView，统计空态占位
 * [POS]: Statistics 模块空态视图
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct StatisticsPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "chart.bar", message: "暂无统计数据")
    }
}

#Preview {
    StatisticsPlaceholderView()
}
