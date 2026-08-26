/**
 * [INPUT]: 仅依赖 SwiftUI 的 CGFloat
 * [OUTPUT]: 对外提供跨组件稳定复用的 StrokeWidth 描边语义
 * [POS]: Utilities/DesignSystem 的边界度量层，不承担间距、圆角或组件尺寸语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 跨组件描边宽度令牌，只收纳已在多个独立生产场景证明稳定的边界语义。
enum StrokeWidth {
    /// 轻量分隔与卡片轮廓使用的半点描边。
    static let hairline: CGFloat = 0.5
}
