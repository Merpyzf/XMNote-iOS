/**
 * [INPUT]: 依赖 UIKit 系统动态颜色
 * [OUTPUT]: 对外提供 RichTextAppearance 富文本编辑与展示共享的引用块外观
 * [POS]: RichTextEditor 功能模块的视觉 owner，统一编辑器、只读正文和可展开正文的引用色条
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 富文本编辑与展示链路共享的外观入口。
enum RichTextAppearance {
    /// 引用块左侧色条沿用既有系统绿色，并自动适配当前系统外观。
    static let quoteAccent = UIColor.systemGreen
}
