/**
 * [INPUT]: 依赖本地化说明文案、Reicon info-circle Outline 可见圆环比例与设计系统动态字身、间距、颜色
 * [OUTPUT]: 对外提供无背景、无交互的轻量常驻提示 XMInlineInfoView
 * [POS]: UIComponents/Feedback 的纯展示说明组件，业务流程与外边距由调用方持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 用轻量信息图标陪衬常驻说明，不承担错误反馈、状态横幅或帮助入口。
struct XMInlineInfoView: View {
    let message: LocalizedStringResource

    /// 本组件的光学校准：中文可见字身约为 0.95em，中心位于基线上方约 1/3em。
    private enum Metrics {
        static let visibleGlyphHeightToEm: CGFloat = 0.95
        static let glyphCenterAboveBaselineToEm: CGFloat = 1 / 3
        // 原始 SVG 圆环从 1.25 延伸至 22.75；只补偿画布留白，不修改矢量路径。
        static let visibleRingToCanvas: CGFloat = 21.5 / 24
    }

    @Environment(\.fontResolutionContext) private var fontContext

    /// 接收单段可本地化说明；组件统一视觉，不添加业务状态、动作或容器外边距。
    init(_ message: LocalizedStringResource) {
        self.message = message
    }

    var body: some View {
        let textEm = AppTypography.footnote.resolve(in: fontContext).pointSize
        let visibleRingHeight = textEm * Metrics.visibleGlyphHeightToEm
        let iconSize = visibleRingHeight / Metrics.visibleRingToCanvas
        let centerAboveBaseline = textEm * Metrics.glyphCenterAboveBaselineToEm
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Image(.reiconInfoCircleOutline)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + centerAboveBaseline
                }
                .foregroundStyle(Color.iconSecondary)
                .accessibilityHidden(true)

            Text(message)
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("常驻说明") {
    VStack(spacing: Spacing.section) {
        XMInlineInfoView("设置将自动保存。")
        XMInlineInfoView("点击开始导入后，将登录你的「三联中读」账户，获取笔记数据。")
    }
    .padding(Spacing.screenEdge)
    .background(Color.surfacePage)
}

#Preview("常驻说明：大字号深色") {
    XMInlineInfoView("点击开始导入后，将登录你的「三联中读」账户，获取笔记数据。")
        .padding(Spacing.screenEdge)
        .background(Color.surfacePage)
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}

#Preview("常驻说明：窄宽度") {
    VStack(spacing: Spacing.section) {
        XMInlineInfoView("设置将自动保存。")
        XMInlineInfoView("点击开始导入后，将登录你的「三联中读」账户，获取笔记数据。")
    }
    .padding(Spacing.screenEdge)
    .frame(width: 280)
    .background(Color.surfacePage)
}
