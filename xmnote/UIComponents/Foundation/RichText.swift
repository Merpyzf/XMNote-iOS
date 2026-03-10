/**
 * [INPUT]: 依赖 RichTextEditor/HTMLParser（HTML→NSAttributedString）与 RichTextLayoutManager（引用块/列表绘制）
 * [OUTPUT]: 对外提供 RichText（只读 HTML 富文本展示组件，支持 maxLines 截断与截断状态回调）
 * [POS]: UIComponents/Foundation 的跨模块复用展示组件，供时间线卡片与未来笔记预览等场景使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

struct RichTextLayoutSnapshot: Equatable {
    let size: CGSize
    let isTruncated: Bool
}

private final class RichTextLayoutSnapshotBox: NSObject {
    let snapshot: RichTextLayoutSnapshot

    init(snapshot: RichTextLayoutSnapshot) {
        self.snapshot = snapshot
    }
}

final class RichTextRenderCache {
    static let shared = RichTextRenderCache()

    private let attributedCache = NSCache<NSString, NSAttributedString>()
    private let layoutCache = NSCache<NSString, RichTextLayoutSnapshotBox>()

    private init() {
        attributedCache.countLimit = 256
        layoutCache.countLimit = 1024
    }

    func resolveAttributedString(
        for key: String,
        builder: () -> NSAttributedString
    ) -> NSAttributedString {
        let nsKey = key as NSString
        if let cached = attributedCache.object(forKey: nsKey) {
            return cached
        }

        let attributed = builder()
        let cachedValue = attributed.copy() as? NSAttributedString ?? attributed
        attributedCache.setObject(cachedValue, forKey: nsKey)
        return cachedValue
    }

    func cachedLayoutSnapshot(for key: String) -> RichTextLayoutSnapshot? {
        layoutCache.object(forKey: key as NSString)?.snapshot
    }

    func storeLayoutSnapshot(_ snapshot: RichTextLayoutSnapshot, for key: String) {
        layoutCache.setObject(RichTextLayoutSnapshotBox(snapshot: snapshot), forKey: key as NSString)
    }

    func removeAll() {
        attributedCache.removeAllObjects()
        layoutCache.removeAllObjects()
    }
}

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
        let traitCollection = textView.traitCollection
        let contentKey = Self.contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let needsContentUpdate = context.coordinator.lastContentKey != contentKey

        if needsContentUpdate {
            context.coordinator.lastContentKey = contentKey
            context.coordinator.lastLayoutKey = ""
            context.coordinator.lastLayoutSnapshot = nil
            context.coordinator.lastReportedTruncation = nil

            let attributed = Self.resolvedAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                traitCollection: traitCollection
            )
            textView.textStorage.setAttributedString(attributed)
            textView.invalidateIntrinsicContentSize()
        }

        textView.textContainer.maximumNumberOfLines = maxLines
        textView.textContainer.lineBreakMode = lineBreakMode
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let screenWidth = uiView.window?.screen.bounds.width ?? 390
        let width = proposal.width ?? screenWidth
        guard width > 0, width.isFinite else { return nil }

        let traitCollection = uiView.traitCollection
        let contentKey = Self.contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let scale = uiView.window?.screen.scale ?? max(uiView.traitCollection.displayScale, 1)
        let layoutKey = Self.layoutCacheKey(
            contentKey: contentKey,
            maxLines: maxLines,
            width: width,
            screenScale: scale
        )

        if context.coordinator.lastLayoutKey == layoutKey,
           let snapshot = context.coordinator.lastLayoutSnapshot {
            if let callback = onTruncationChanged, maxLines > 0 {
                notifyTruncationIfNeeded(
                    isTruncated: snapshot.isTruncated,
                    context: context,
                    callback: callback
                )
            }
            return snapshot.size
        }

        if let snapshot = Self.cachedLayoutSnapshot(for: layoutKey) {
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastLayoutSnapshot = snapshot
            if let callback = onTruncationChanged, maxLines > 0 {
                notifyTruncationIfNeeded(
                    isTruncated: snapshot.isTruncated,
                    context: context,
                    callback: callback
                )
            }
            return snapshot.size
        }

        uiView.textContainer.size.width = width
        let snapshot = measureLayoutSnapshot(for: uiView, width: width)
        Self.storeLayoutSnapshot(snapshot, for: layoutKey)
        context.coordinator.lastLayoutKey = layoutKey
        context.coordinator.lastLayoutSnapshot = snapshot

        if let callback = onTruncationChanged, maxLines > 0 {
            notifyTruncationIfNeeded(
                isTruncated: snapshot.isTruncated,
                context: context,
                callback: callback
            )
        }

        return snapshot.size
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastContentKey: String = ""
        var lastLayoutKey: String = ""
        var lastLayoutSnapshot: RichTextLayoutSnapshot?
        var lastReportedTruncation: Bool?
    }

    private var lineBreakMode: NSLineBreakMode {
        maxLines > 0 ? .byTruncatingTail : .byWordWrapping
    }

    private func measureLayoutSnapshot(
        for textView: UITextView,
        width: CGFloat
    ) -> RichTextLayoutSnapshot {
        let isTruncated = maxLines > 0 ? detectTruncation(for: textView, width: width) : false

        textView.textContainer.maximumNumberOfLines = maxLines
        textView.textContainer.lineBreakMode = lineBreakMode
        textView.textContainer.size.width = width
        let size = textView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )

        return RichTextLayoutSnapshot(
            size: CGSize(width: width, height: size.height),
            isTruncated: isTruncated
        )
    }

    /// 无限布局下枚举行片段计数实际行数，与 maxLines 直接比较判定截断。
    /// 这里先做一次无限行布局，再回到受限行布局做最终测量，避免展开/收起阶段重复解析 HTML。
    private func detectTruncation(for textView: UITextView, width: CGFloat) -> Bool {
        guard maxLines > 0 else { return false }
        guard width > 0, width.isFinite else { return false }
        guard textView.textStorage.length > 0 else { return false }

        let container = textView.textContainer
        let layoutManager = textView.layoutManager

        container.size.width = width
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        container.size.height = .greatestFiniteMagnitude

        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)

        var lineCount = 0
        let glyphRange = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, stop in
            lineCount += 1
            if lineCount > maxLines {
                stop.pointee = true
            }
        }
        return lineCount > maxLines
    }

    private func notifyTruncationIfNeeded(
        isTruncated: Bool,
        context: Context,
        callback: @escaping (Bool) -> Void
    ) {
        guard context.coordinator.lastReportedTruncation != isTruncated else {
            return
        }
        context.coordinator.lastReportedTruncation = isTruncated
        DispatchQueue.main.async { callback(isTruncated) }
    }

    static func resolvedAttributedString(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        let contentKey = contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        return resolveAttributedString(contentKey: contentKey) {
            buildAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                traitCollection: traitCollection
            )
        }
    }

    static func resolvedPreviewAttributedString(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        let previewKey = previewContentKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        return resolveAttributedString(contentKey: previewKey) {
            let baseAttributed = resolvedAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                traitCollection: traitCollection
            )
            let previewAttributed = NSMutableAttributedString(attributedString: baseAttributed)
            sanitizePreviewAttributedString(previewAttributed, lineSpacing: lineSpacing)
            return previewAttributed
        }
    }

    private static func buildAttributedString(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        let mutable = HTMLParser.parse(html, baseFont: baseFont, traitCollection: traitCollection)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: textColor, range: range)
            }
        }

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

    private static func sanitizePreviewAttributedString(
        _ attributed: NSMutableAttributedString,
        lineSpacing: CGFloat
    ) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }

        attributed.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }
            attributed.addAttribute(.foregroundColor, value: UIColor.link, range: range)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            attributed.removeAttribute(.link, range: range)
        }

        attributed.removeAttribute(.bulletList, range: fullRange)
        attributed.removeAttribute(.blockquote, range: fullRange)

        attributed.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.headIndent = 0
            style.firstLineHeadIndent = 0
            style.lineSpacing = lineSpacing
            style.lineBreakMode = .byTruncatingTail
            attributed.addAttribute(.paragraphStyle, value: style, range: range)
        }

        trimTrailingWhitespaceAndNewlines(in: attributed)
    }

    private static func trimTrailingWhitespaceAndNewlines(in attributed: NSMutableAttributedString) {
        while attributed.length > 0 {
            let lastIndex = attributed.length - 1
            let lastCharacter = attributed.attributedSubstring(
                from: NSRange(location: lastIndex, length: 1)
            ).string
            guard lastCharacter.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
                return
            }
            attributed.deleteCharacters(in: NSRange(location: lastIndex, length: 1))
        }
    }

    static func cachedLayoutSnapshot(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        maxLines: Int,
        width: CGFloat,
        traitCollection: UITraitCollection = .current,
        screenScale: CGFloat? = nil
    ) -> RichTextLayoutSnapshot? {
        let contentKey = contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let layoutKey = layoutCacheKey(
            contentKey: contentKey,
            maxLines: maxLines,
            width: width,
            screenScale: screenScale ?? max(traitCollection.displayScale, 1)
        )
        return cachedLayoutSnapshot(for: layoutKey)
    }

    @MainActor
    static func prewarmPreviewLayoutSnapshot(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        maxLines: Int,
        width: CGFloat,
        traitCollection: UITraitCollection,
        screenScale: CGFloat
    ) {
        guard width > 0, width.isFinite else { return }

        let contentKey = previewContentKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let layoutKey = layoutCacheKey(
            contentKey: contentKey,
            maxLines: maxLines,
            width: width,
            screenScale: screenScale
        )
        guard cachedLayoutSnapshot(for: layoutKey) == nil else { return }

        let attributed = resolvedPreviewAttributedString(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let measurementView = CollapsedRichTextPreviewView()
        let snapshot = measurementView.measureLayoutSnapshot(
            attributedText: attributed,
            width: width,
            maxLines: maxLines
        )
        storeLayoutSnapshot(snapshot, for: layoutKey)
    }

    static func previewContentKey(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> String {
        let baseKey = contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        return "preview|\(baseKey)"
    }

    static func resolveAttributedString(
        contentKey: String,
        builder: () -> NSAttributedString
    ) -> NSAttributedString {
        RichTextRenderCache.shared.resolveAttributedString(for: contentKey, builder: builder)
    }

    static func cachedLayoutSnapshot(for layoutKey: String) -> RichTextLayoutSnapshot? {
        RichTextRenderCache.shared.cachedLayoutSnapshot(for: layoutKey)
    }

    static func storeLayoutSnapshot(
        _ snapshot: RichTextLayoutSnapshot,
        for layoutKey: String
    ) {
        RichTextRenderCache.shared.storeLayoutSnapshot(snapshot, for: layoutKey)
    }

    static func contentCacheKey(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> String {
        [
            html,
            baseFont.fontName,
            Self.roundedToken(baseFont.pointSize),
            Self.colorToken(textColor, traitCollection: traitCollection),
            Self.roundedToken(lineSpacing),
            String(traitCollection.userInterfaceStyle.rawValue),
            traitCollection.preferredContentSizeCategory.rawValue,
        ].joined(separator: "|")
    }

    static func layoutCacheKey(
        contentKey: String,
        maxLines: Int,
        width: CGFloat,
        screenScale: CGFloat
    ) -> String {
        let bucket = Int((width * max(screenScale, 1)).rounded())
        return "\(contentKey)|lines:\(maxLines)|width:\(bucket)"
    }

    private static func roundedToken(_ value: CGFloat) -> String {
        String(Int((value * 1000).rounded()))
    }

    private static func colorToken(
        _ color: UIColor,
        traitCollection: UITraitCollection
    ) -> String {
        let resolved = color.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return resolved.description
        }
        return [
            String(Int((red * 255).rounded())),
            String(Int((green * 255).rounded())),
            String(Int((blue * 255).rounded())),
            String(Int((alpha * 255).rounded())),
        ].joined(separator: ",")
    }
}

#if DEBUG
extension RichText {
    static func testingResetCaches() {
        RichTextRenderCache.shared.removeAll()
    }

    static func testingResolveAttributedString(
        contentKey: String,
        builder: () -> NSAttributedString
    ) -> NSAttributedString {
        resolveAttributedString(contentKey: contentKey, builder: builder)
    }

    static func testingResolvePreviewAttributedString(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        resolvedPreviewAttributedString(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
    }

    static func testingCachedLayoutSnapshot(for layoutKey: String) -> RichTextLayoutSnapshot? {
        cachedLayoutSnapshot(for: layoutKey)
    }

    static func testingStoreLayoutSnapshot(
        _ snapshot: RichTextLayoutSnapshot,
        for layoutKey: String
    ) {
        storeLayoutSnapshot(snapshot, for: layoutKey)
    }

    static func testingContentCacheKey(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        traitCollection: UITraitCollection
    ) -> String {
        contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
    }

    static func testingLayoutCacheKey(
        contentKey: String,
        maxLines: Int,
        width: CGFloat,
        screenScale: CGFloat
    ) -> String {
        layoutCacheKey(
            contentKey: contentKey,
            maxLines: maxLines,
            width: width,
            screenScale: screenScale
        )
    }
}
#endif

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
