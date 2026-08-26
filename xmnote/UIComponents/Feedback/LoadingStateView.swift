/**
 * [INPUT]: 依赖 SwiftUI、AppTypography 与表层令牌，接收可选加载文案和展示样式
 * [OUTPUT]: 对外提供 LoadingStateView 的 inline 与 card 两种加载反馈
 * [POS]: UIComponents/Feedback 的加载反馈视觉组件，由 LoadingGate 或 LoadPhaseHost 等状态 owner 组合
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用加载视图支持轻量 inline 与卡片两种表达，加载时序由外部 LoadingGate 管理。
struct LoadingStateView: View {
    enum Style {
        case inline
        case card
    }

    let message: String?
    let style: Style

    /// 创建加载视觉；读取主态必须由 LoadingGate 或 LoadPhaseHost 控制显隐时序。
    init(_ message: String? = nil, style: Style = .inline) {
        self.message = message
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .inline:
                progressContent
            case .card:
                progressContent
                    .padding(Spacing.contentEdge)
                    .background(
                        Color.surfaceCard,
                        in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    )
            }
        }
    }

    @ViewBuilder
    private var progressContent: some View {
        if let message, !message.isEmpty {
            ProgressView(message)
                .font(AppTypography.body)
        } else {
            ProgressView()
        }
    }
}

#Preview("加载状态") {
    VStack(spacing: Spacing.section) {
        LoadingStateView("正在加载…")
        LoadingStateView("正在加载…", style: .card)
    }
    .padding()
    .background(Color.surfacePage)
}
