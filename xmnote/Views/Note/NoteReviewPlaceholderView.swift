//
//  NoteReviewPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 EmptyStateView 公共组件
 * [OUTPUT]: 对外提供 NoteReviewPlaceholderView，书评空态占位
 * [POS]: Note 模块回顾空态视图，被 NoteContainerView 在回顾 Tab 无数据时展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct NoteReviewPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "arrow.clockwise", message: "暂无回顾内容")
    }
}

#Preview {
    NoteReviewPlaceholderView()
}
