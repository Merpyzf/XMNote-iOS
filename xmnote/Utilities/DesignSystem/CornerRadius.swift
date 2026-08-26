/**
 * [INPUT]: 仅依赖 SwiftUI 的 CGFloat
 * [OUTPUT]: 对外提供按 inlay、block、container 角色组织的 CornerRadius
 * [POS]: Utilities/DesignSystem 的表面圆角层，统一可复用容器的轮廓曲率
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Corner Radius
//
// 选择指南（两步决策）：
//
// 第一步：判断元素角色
//   inlay     → 嵌在卡片/容器内的小型视觉零件（色块、封面、标签、徽章）
//   block     → 独立可识别的内容单元（事件条、列表项、标准卡片）
//   container → 承载内容块的外壳（面板、弹层、突出容器）
//
// 第二步：按视觉体量选尺寸
//   none(0) < hairline(2) < tiny(3) < small(4) < medium(6) < blockLarge(12)
//   < containerMedium(16) < containerLarge(18) < containerXL(22)
//
// 示例：
//   热力图方格 → 嵌在卡片里的小零件 → inlay → 最小的 → inlayTiny
//   书籍封面   → 嵌在网格里的小零件 → inlay → 稍大   → inlaySmall
//   事件条     → 独立内容单元       → block → 紧凑   → blockSmall
//   标准卡片   → 独立内容单元       → block → 标准   → blockLarge
//   日历面板   → 包裹内容的容器     → container → 标准 → containerMedium

/// 全局圆角设计令牌，按 inlay/block/container 三类角色复用。
enum CornerRadius {
    static let none: CGFloat = 0          // 关闭圆角（状态切换）

    // --- inlay: 嵌在卡片/容器内的小型视觉零件 ---
    static let inlayHairline: CGFloat = 2  // 装饰分隔条、极细引导条
    static let inlayTiny: CGFloat = 3      // 热力图方格、图例色块
    static let inlaySmall: CGFloat = 4     // 紧凑语义标签、书籍封面缩略图
    static let inlayMedium: CGFloat = 6    // 较大徽章、嵌入式控件

    // --- block: 独立可识别的内容单元 ---
    static let blockSmall: CGFloat = 8     // 事件条、紧凑卡片
    static let blockMedium: CGFloat = 10   // 列表项、输入框
    static let blockLarge: CGFloat = 12    // 标准卡片、内容区域

    // --- container: 承载内容块的外壳 ---
    static let containerMedium: CGFloat = 16  // 面板、弹层
    static let containerLarge: CGFloat = 18   // 突出容器（热力图 widget）
    static let containerXL: CGFloat = 22     // 闪屏图标容器、大型品牌展示
}
