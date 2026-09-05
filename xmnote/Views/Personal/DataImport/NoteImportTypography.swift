/**
 * [INPUT]: 依赖 AppTypography 的受控语义字体构造
 * [OUTPUT]: 提供导入准备页的焦点标题排版，响应系统 Dynamic Type
 * [POS]: 文件/剪贴板输入页与 Kindle 输入页共用的功能私有 Typography owner
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 插画下的任务标题需要高于步骤 headline 的焦点层级，按 title2 曲线缩放。
enum NoteImportTypography {
    static let heroTitle = AppTypography.fixed(baseSize: 26, relativeTo: .title2, weight: .semibold)
}
