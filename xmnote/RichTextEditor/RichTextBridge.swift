/**
 * [INPUT]: 依赖 RichTextEditor 模块格式定义与 UIKit/TextKit 能力，承接富文本解析/渲染/编辑链路
 * [OUTPUT]: 对外提供 RichTextBridge 能力，用于富文本编辑器的序列化、交互或样式支持
 * [POS]: RichTextEditor 功能模块内部构件，服务 Note 编辑场景的 Android 业务意图对齐
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 业务层富文本桥接：统一 HTML ↔ NSAttributedString 转换入口。
enum RichTextBridge {

    static func htmlToAttributed(
        _ html: String,
        baseFont: UIFont = .systemFont(ofSize: 16),
        traitCollection: UITraitCollection = .current
    ) -> NSAttributedString {
        HTMLParser.parse(
            html,
            baseFont: baseFont,
            traitCollection: traitCollection
        )
    }

    static func attributedToHtml(_ attributedText: NSAttributedString) -> String {
        HTMLSerializer.serialize(attributedText)
    }
}
