/**
 * [INPUT]: 依赖 RichTextEditor/HTMLParser（HTML→NSAttributedString）与 RichTextLayoutManager（引用块/列表绘制）
 * [OUTPUT]: 对外提供 RichText（只读 HTML 富文本展示组件）
 * [POS]: UIComponents/Foundation 的跨模块复用展示组件，供时间线卡片与未来笔记预览等场景使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 只读 HTML 富文本视图，桥接 UITextView + RichTextLayoutManager 渲染引用块色条与列表圆点。
struct RichText: UIViewRepresentable {
    let html: String
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var lineSpacing: CGFloat = 4

    func makeUIView(context: Context) -> UITextView {
        let layoutManager = RichTextLayoutManager()
        layoutManager.bulletColor = UIColor.label
        layoutManager.quoteColor = UIColor.systemGreen

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = UITextView(frame: CGRect.zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets.zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = UIColor.clear
        textView.setContentCompressionResistancePriority(UILayoutPriority.required, for: NSLayoutConstraint.Axis.vertical)
        textView.setContentHuggingPriority(UILayoutPriority.required, for: NSLayoutConstraint.Axis.vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let cacheKey = "\(html)|\(baseFont.pointSize)|\(textColor.description)|\(lineSpacing)"
        guard context.coordinator.lastCacheKey != cacheKey else { return }
        context.coordinator.lastCacheKey = cacheKey

        let attributed = buildAttributedString()
        textView.textStorage.setAttributedString(attributed)
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        guard width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastCacheKey: String = ""
    }

    // MARK: - Attributed String

    private func buildAttributedString() -> NSAttributedString {
        let parsed = HTMLParser.parse(html, baseFont: baseFont)
        let mutable = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: mutable.length)

        // 应用文本颜色（不覆盖 link 颜色）
        mutable.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: textColor, range: range)
            }
        }

        // 应用行间距
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            if let existing = value as? NSParagraphStyle {
                let merged = existing.mutableCopy() as! NSMutableParagraphStyle
                merged.lineSpacing = lineSpacing
                mutable.addAttribute(.paragraphStyle, value: merged, range: range)
            } else {
                mutable.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }

        return mutable
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        RichText(html: "这是<b>加粗</b>和<i>斜体</i>与<mark style=\"background-color:-394337\">高亮</mark>文本")
        RichText(
            html: "引用块测试文本",
            baseFont: .preferredFont(forTextStyle: .callout),
            textColor: .secondaryLabel
        )
        RichText(html: "纯文本，没有任何 HTML 标签")
    }
    .padding()
}
