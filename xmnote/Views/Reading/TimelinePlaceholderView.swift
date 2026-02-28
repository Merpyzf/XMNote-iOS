//
//  TimelinePlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 EmptyStateView 公共组件
 * [OUTPUT]: 对外提供 TimelinePlaceholderView，时间线空态占位
 * [POS]: Reading 模块时间线空态视图
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct TimelinePlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "clock.arrow.circlepath", message: "暂无阅读记录")
    }
}

#Preview {
    TimelinePlaceholderView()
}
