/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignSystem/Spacing.swift 的间距设计令牌
 * [OUTPUT]: 对外提供 PrimaryTopBar 顶部容器组件与 PrimaryTopBarLayout 动态高度合同
 * [POS]: UIComponents/Navigation/TopBar 的结构容器组件，承载顶部左侧内容与右侧操作区布局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 主 Tab 顶部栏的共享布局合同，供顶部组件与其下方内容避让使用同一高度。
enum PrimaryTopBarLayout {
    private static let regularMinimumHeight: CGFloat = 56
    private static let accessibilityMinimumHeight: CGFloat = 60

    /// 根据 Dynamic Type 返回顶部栏最小高度；辅助功能字号保留额外纵向空间。
    static func minimumHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? accessibilityMinimumHeight : regularMinimumHeight
    }
}

/// 主 Tab 顶部容器：左侧内容 + 右侧操作区，统一高度与边距。
struct PrimaryTopBar<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .frame(minHeight: PrimaryTopBarLayout.minimumHeight(for: dynamicTypeSize))
        .background(Color.clear)
    }
}
