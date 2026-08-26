/**
 * [INPUT]: 仅依赖 SwiftUI 的 CGFloat
 * [OUTPUT]: 对外提供表达亲密性、容器与页面留白的 Spacing
 * [POS]: Utilities/DesignSystem 的布局间距层，不承担控件尺寸语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Spacing
//
// 选择指南（四步决策）：
//
// 第一步：先判断是不是“留白”问题
//   只有在表达元素之间的距离、容器与内容的边距、或视觉呼吸空间时，才使用 spacing token。
//   命中线宽、点击热区、组件尺寸约束时，不要把 spacing 当作通用尺寸常量。
//
// 第二步：判断层级
//   Inline    → 行内或紧密配对关系（图标与文字、主值与副标题、标签内边距）
//   Block     → 同级内容块之间的常规留白（按钮组、图表标题到图表、段落间距）
//   Container → 卡片或模块内部边距（内容到卡片边缘、局部分区）
//   Page      → 页面级边距与大分区留白
//
// 第三步：优先选择默认档
//   Inline    → half(6) / cozy(8)
//   Block     → cozy(8) / base(12)
//   Container → screenEdge(16) / contentEdge(18) / section(20)
//   Page      → screenEdge(16) / section(20) / double(24)
//
// 第四步：默认档不成立时，才使用补位档
//   微调档     → hairline(1) / tiny(2) / micro(3)，只用于视觉补偿、描边避让、极小留白
//   紧密补位档 → compact(4)，用于比 half 更紧的成组关系
//   中间补位档 → tight(10) / comfortable(14)，用于默认档之间的过渡密度
//
// 默认选择示例：
//   图标与短文本间距        → compact
//   主值与副标题            → half
//   图表标题到图表          → cozy
//   常规内容块间距          → base
//   页面横向安全边距        → screenEdge
//   普通卡片内容边距        → contentEdge
//   模块级强调分组          → section
//   大段留白/强分区         → double
//
// 反例：
//   不要用 spacing token 表达点击热区、组件尺寸或操作预留。
//   不要用 hairline / tiny / micro 充当卡片主边距。
//   不要默认从 tight / comfortable 开始试值，它们是补位档，不是首选档。

/// 全局间距设计令牌，统一页面留白层级、容器边距与紧密关系间距。
enum Spacing {
    static let none: CGFloat = 0
    static let hairline: CGFloat = 1
    static let tiny: CGFloat = 2
    static let micro: CGFloat = 3
    static let compact: CGFloat = 4
    static let half: CGFloat = 6
    static let cozy: CGFloat = 8
    static let tight: CGFloat = 10
    static let base: CGFloat = 12
    static let comfortable: CGFloat = 14
    static let section: CGFloat = 20
    static let double: CGFloat = 24
    static let screenEdge: CGFloat = 16
    static let contentEdge: CGFloat = 18
}
