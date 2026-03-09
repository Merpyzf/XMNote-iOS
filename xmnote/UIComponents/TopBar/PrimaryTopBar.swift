/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的间距设计令牌
 * [OUTPUT]: 对外提供 PrimaryTopBar 顶部容器组件
 * [POS]: UIComponents/TopBar 的结构容器组件，承载顶部左侧内容与右侧操作区布局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 主 Tab 顶部容器：左侧内容 + 右侧操作区，统一高度与边距。
struct PrimaryTopBar<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    /// 注入左右操作区内容，组装统一顶部栏布局。
    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Spacing.none) {
            leading
            Spacer(minLength: 0)
            HStack(spacing: Spacing.cozy) {
                trailing
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(height: 52)
        .background(Color.clear)
    }
}
