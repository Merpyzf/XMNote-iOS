/**
 * [INPUT]: 仅依赖 SwiftUI 的 CGFloat
 * [OUTPUT]: 对外提供触控安全与交互控件尺寸的 InteractionMetrics
 * [POS]: Utilities/DesignSystem 的交互尺寸层，与视觉间距 token 解耦
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 跨页面交互尺寸令牌，只收纳具有平台或产品交互语义的稳定尺寸。
enum InteractionMetrics {
    /// 可点击控件的最小触控目标边长。
    static let minimumTouchTarget: CGFloat = 44
}
