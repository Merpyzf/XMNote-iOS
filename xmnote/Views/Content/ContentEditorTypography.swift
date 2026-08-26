/**
 * [INPUT]: 依赖 UIKit 与 AppTypography 的系统语义排版构造能力
 * [OUTPUT]: 对 Content 模块书评与相关内容编辑器提供共享正文 UIFont
 * [POS]: Views/Content 的 feature 排版 owner，被 ReviewEditorView 与 RelevantEditorView 共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 内容编辑器共享的正文排版，保留 body 默认字号与 Dynamic Type 缩放曲线。
enum ContentEditorTypography {
    static var richTextBodyUIFont: UIFont {
        AppTypography.uiSemantic(.body)
    }
}
