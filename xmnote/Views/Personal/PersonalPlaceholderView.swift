//
//  PersonalPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 EmptyStateView 公共组件
 * [OUTPUT]: 对外提供 PersonalPlaceholderView，个人页占位
 * [POS]: Personal 模块空态视图
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct PersonalPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "person", message: "我的")
    }
}

#Preview {
    PersonalPlaceholderView()
}
