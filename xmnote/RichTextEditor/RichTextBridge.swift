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
