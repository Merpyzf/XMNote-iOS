//
//  CollectionListPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 EmptyStateView 公共组件
 * [OUTPUT]: 对外提供 CollectionListPlaceholderView，书单空态占位
 * [POS]: Book 模块书单空态视图，被 BookContainerView 在书单 Tab 无数据时展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct CollectionListPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "rectangle.stack", message: "暂无书单")
    }
}

#Preview {
    CollectionListPlaceholderView()
}
