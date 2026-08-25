/**
 * [INPUT]: 依赖 AppTypography、SemanticColors、Spacing 与 CornerRadius，接收纯展示标签内容
 * [OUTPUT]: 对外提供 XMTagLabel，统一领域标签的排版、内边距、背景与连续圆角
 * [POS]: UIComponents/Foundation 的紧凑语义标签组件，被书籍、内容、笔记、搜索与时间线页面复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 纯展示语义标签；固定几何与表层规则，调用方只提供文本内容。
struct XMTagLabel<Content: View>: View {
    @ViewBuilder let content: Content

    /// 注入标签文本；内容可保留关键字高亮等文本内属性，但不能改写容器几何。
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .font(AppTypography.caption2)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(
                Color.tagBackground,
                in: RoundedRectangle(
                    cornerRadius: CornerRadius.inlaySmall,
                    style: .continuous
                )
            )
    }
}

extension XMTagLabel where Content == Text {
    /// 使用运行时领域文本构建标准标签，不把用户数据解释为本地化键。
    init(_ title: String) {
        self.init {
            Text(verbatim: title)
        }
    }
}
