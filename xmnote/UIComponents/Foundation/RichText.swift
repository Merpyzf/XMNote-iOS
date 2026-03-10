/**
 * [INPUT]: 依赖 RichTextEditor/HTMLParser（HTML→NSAttributedString）与 RichTextLayoutManager（引用块/列表绘制）
 * [OUTPUT]: 对外提供 RichText（只读 HTML 富文本展示组件，支持 maxLines 截断与截断状态回调）
 * [POS]: UIComponents/Foundation 的跨模块复用展示组件，供时间线卡片与未来笔记预览等场景使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 只读 HTML 富文本视图，桥接 UITextView + RichTextLayoutManager 渲染引用块色条与列表圆点。
/// `maxLines > 0` 时通过 `textContainer.maximumNumberOfLines` 截断，零额外 HTML 解析成本。
struct RichText: UIViewRepresentable {
    let html: String
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var lineSpacing: CGFloat = 4
    /// 最大显示行数，0 = 无限制（默认），正数启用原生省略号截断
    var maxLines: Int = 0
    /// 截断状态变更回调，仅在 maxLines > 0 时有意义
    var onTruncationChanged: ((Bool) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let layoutManager = RichTextLayoutManager()
        layoutManager.bulletColor = UIColor.label
        layoutManager.quoteColor = UIColor.systemGreen

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = true
        textContainer.maximumNumberOfLines = maxLines
        textContainer.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
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
        let cacheKey = "\(html)|\(baseFont.pointSize)|\(textColor.description)|\(lineSpacing)|\(maxLines)"
        let needsContentUpdate = context.coordinator.lastCacheKey != cacheKey

        if needsContentUpdate {
            context.coordinator.lastCacheKey = cacheKey
            context.coordinator.lastTruncationKey = ""
            context.coordinator.lastSizeKey = ""
            let attributed = buildAttributedString()
            textView.textStorage.setAttributedString(attributed)
        }

        textView.textContainer.maximumNumberOfLines = maxLines
        textView.textContainer.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping

        if needsContentUpdate {
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let screenWidth = uiView.window?.screen.bounds.width ?? 390
        let width = proposal.width ?? screenWidth
        guard width > 0, width.isFinite else { return nil }

        // SwiftUI 单次 pass 可能多次调用 sizeThatFits，缓存避免重复测量
        let sizeKey = "\(context.coordinator.lastCacheKey)|\(Int(width))"
        if context.coordinator.lastSizeKey == sizeKey {
            if let callback = onTruncationChanged, maxLines > 0 {
                detectTruncation(uiView, context: context, callback: callback)
            }
            return context.coordinator.lastSize
        }

        // 手动同步 container width：sizeThatFits 持有确切 proposed width，
        // 但 textContainer.widthTracksTextView 依赖 frame 赋值（此时仍为 zero），
        // 必须显式注入，否则 detectTruncation 因零宽守卫永远跳过
        uiView.textContainer.size.width = width

        uiView.textContainer.maximumNumberOfLines = maxLines
        uiView.textContainer.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))

        // 宽度变化时失效截断缓存，确保新宽度下重新检测
        if context.coordinator.lastLayoutWidth != width {
            context.coordinator.lastLayoutWidth = width
            context.coordinator.lastTruncationKey = ""
        }

        // sizeThatFits 内部因 widthTracksTextView 会将 container width 重置为
        // textView.frame.width（此时仍为 zero），必须在截断检测前重新注入
        uiView.textContainer.size.width = width

        if let callback = onTruncationChanged, maxLines > 0 {
            detectTruncation(uiView, context: context, callback: callback)
        }

        let result = CGSize(width: width, height: size.height)
        context.coordinator.lastSizeKey = sizeKey
        context.coordinator.lastSize = result
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastCacheKey: String = ""
        /// 缓存截断检测结果 (htmlKey → isTruncated)，避免视图复用时重复检测
        var lastTruncationKey: String = ""
        var lastTruncationResult: Bool = false
        /// 上次布局宽度，宽度变化时失效截断缓存
        var lastLayoutWidth: CGFloat = 0
        /// sizeThatFits 结果缓存，SwiftUI 单次 pass 可能多次调用，避免重复测量
        var lastSizeKey: String = ""
        var lastSize: CGSize = .zero
    }

    // MARK: - Truncation Detection

    /// 无限布局下枚举行片段计数实际行数，与 maxLines 直接比较判定截断。
    /// `glyphRange(for:)` 按几何尺寸而非行数截断，短文本在无限高度下返回全量 glyph，
    /// 导致截断检测失败——故改用 `enumerateLineFragments` 语义直接、零耦合。
    private func detectTruncation(
        _ textView: UITextView,
        context: Context,
        callback: @escaping (Bool) -> Void
    ) {
        guard maxLines > 0, let layoutManager = textView.layoutManager as? RichTextLayoutManager else {
            let truncationKey = "\(html)|\(maxLines)|0"
            context.coordinator.lastTruncationKey = truncationKey
            context.coordinator.lastTruncationResult = false
            DispatchQueue.main.async { callback(false) }
            return
        }

        let containerWidth = textView.textContainer.size.width
        guard containerWidth > 0, containerWidth.isFinite else { return }

        // textStorage 为空时直接返回且不缓存，防止缓存中毒：
        // sizeThatFits 可能先于 updateUIView 执行，此时 textStorage 空，
        // 截断检测必然 false；若缓存此结果，内容填充后命中旧缓存将永久丢失展开按钮
        guard textView.textStorage.length > 0 else { return }

        let truncationKey = "\(html)|\(maxLines)|\(Int(containerWidth))"
        if context.coordinator.lastTruncationKey == truncationKey {
            DispatchQueue.main.async {
                callback(context.coordinator.lastTruncationResult)
            }
            return
        }

        let container = textView.textContainer
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)

        // 无限行 + 无限高度 → 枚举行片段计数实际行数
        container.maximumNumberOfLines = 0
        container.size.height = .greatestFiniteMagnitude
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)

        var lineCount = 0
        let glyphRange = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineCount += 1
        }
        let isTruncated = lineCount > maxLines

        // 恢复受限行数，确保后续渲染省略号正常
        container.maximumNumberOfLines = maxLines

        context.coordinator.lastTruncationKey = truncationKey
        context.coordinator.lastTruncationResult = isTruncated

        // callback 异步分发：layout pass 内不可直接修改 @State
        DispatchQueue.main.async { callback(isTruncated) }
    }

    // MARK: - Attributed String

    private func buildAttributedString() -> NSAttributedString {
        let mutable = HTMLParser.parse(html, baseFont: baseFont)
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
