//
//  BookPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 EmptyStateView 公共组件
 * [OUTPUT]: 对外提供 BookPlaceholderView，书籍空态占位
 * [POS]: Book 模块空态视图，被 BookGridView 在无数据时展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct BookPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "book", message: "暂无书籍")
    }
}

#Preview {
    BookPlaceholderView()
}
