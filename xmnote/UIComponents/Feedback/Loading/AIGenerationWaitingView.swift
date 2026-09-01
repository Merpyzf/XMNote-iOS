/**
 * [INPUT]: 依赖 DesignSystem 排版与语义色，接收可见等待文案和无障碍朗读文案
 * [OUTPUT]: 对外提供 AIGenerationWaitingView，以低干扰文字反馈 AI 首个可见结果前的短暂等待
 * [POS]: UIComponents/Feedback/Loading 的跨功能 AI 生成等待视觉，不持有业务阶段或 LoadingGate
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 首个可见生成结果返回前，以可降级的轻量文字呼吸表达短暂等待。
struct AIGenerationWaitingView: View {
    let text: String
    let accessibilityText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 注入用户可见文案与稳定朗读文案；请求阶段和显示门闩由业务页面持有。
    init(_ text: String, accessibilityLabel: String) {
        self.text = text
        self.accessibilityText = accessibilityLabel
    }

    var body: some View {
        if reduceMotion {
            waitingText
                .opacity(Metrics.restingOpacity)
        } else {
            PhaseAnimator(Metrics.animatedOpacities) { opacity in
                waitingText
                    .opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: Metrics.animationDuration)
            }
        }
    }

    private var waitingText: some View {
        Text(text)
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(accessibilityText)
    }
}

private extension AIGenerationWaitingView {
    enum Metrics {
        static let animatedOpacities: [Double] = [0.90, 0.55]
        static let restingOpacity = 0.82
        static let animationDuration = 0.70
    }
}

#Preview("AI 生成等待") {
    AIGenerationWaitingView(
        "正在生成…",
        accessibilityLabel: "正在生成 AI 释义"
    )
    .padding()
}
