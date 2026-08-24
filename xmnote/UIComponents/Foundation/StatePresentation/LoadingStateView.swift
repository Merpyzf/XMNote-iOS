/**
 * [INPUT]: 依赖 SwiftUI ProgressView、CardContainer 与 DesignTokens，接收可选加载说明和呈现样式
 * [OUTPUT]: 对外提供 LoadingStateView，统一读取主态与局部加载的视觉表达
 * [POS]: UIComponents/Foundation/StatePresentation 的加载视觉组件，与 LoadingGate、LoadPhaseHost 配套使用
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
