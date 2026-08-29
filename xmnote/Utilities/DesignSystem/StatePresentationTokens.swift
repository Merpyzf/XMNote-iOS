/**
 * [INPUT]: 依赖 SwiftUI 与 AppTypography，集中声明通用状态展示的尺寸、切换节奏和排版语义
 * [OUTPUT]: 对外提供 StatePresentationMetrics 与 StatePresentationTypography
 * [POS]: Utilities/DesignSystem 的状态反馈令牌，被 Feedback/StatePresentation 与加载阶段宿主复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用状态呈现的尺寸与切换节奏，供完整状态、紧凑状态和局部提示条共同复用。
enum StatePresentationMetrics {
    static let centeredIconSize: CGFloat = 32
    static let cardIconSize: CGFloat = 18
    static let bannerIconSize: CGFloat = 16
    static let phaseTransitionDuration: TimeInterval = 0.16
}

/// 通用状态呈现的文字层级，避免状态组件之间重复组合字体语义。
enum StatePresentationTypography {
    static let title = AppTypography.body
    static let compactMessage = AppTypography.subheadline
    static let action = AppTypography.subheadline
    static let bannerMessage = AppTypography.footnote
    static let bannerAction = AppTypography.footnote
}
