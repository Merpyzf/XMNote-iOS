import UIKit

/// UITextView 子类，对标 KnifeText.java
/// 实现 8 种格式的 apply/remove/contains 三件套
final class RichTextEditorView: UITextView {

    // MARK: - 段落级格式参数（对标 KnifeBulletSpan / KnifeQuoteSpan）

    /// Bullet 圆点半径（pt），对标 DEFAULT_RADIUS = 3
    static let defaultBulletRadius: CGFloat = 3
    /// Bullet 圆点与文字间距（pt），对标 DEFAULT_GAP_WIDTH = 2
    static let defaultBulletGapWidth: CGFloat = 2
    /// 段落缩进额外留白（pt）
    static let defaultIndentPadding: CGFloat = 8

    /// 默认段落缩进值（圆点直径 + 间距 + 额外留白），供 HTMLParser 等外部引用
    static let defaultParagraphIndent: CGFloat = (defaultBulletRadius * 2) + defaultBulletGapWidth + defaultIndentPadding

    var bulletRadius: CGFloat = defaultBulletRadius
    var bulletGapWidth: CGFloat = defaultBulletGapWidth
    /// Bullet 圆点颜色
    var bulletColor: UIColor = .label

    /// Quote 色条宽度（pt），对标 DEFAULT_STRIPE_WIDTH = 2
    var quoteStripeWidth: CGFloat = 2
    /// Quote 色条与文字间距（pt），对标 DEFAULT_GAP_WIDTH = 2
    var quoteGapWidth: CGFloat = 2
    /// Quote 色条颜色
    var quoteColor: UIColor = .systemGreen

    /// 链接文本颜色（nil 表示使用系统默认）
    var linkColor: UIColor? {
        didSet { refreshLinkTextAttributes() }
    }

    /// 链接是否显示下划线
    var isLinkUnderline: Bool = true {
        didSet { refreshLinkTextAttributes() }
    }

    // MARK: - 初始化

    init() {
        let textStorage = NSTextStorage()
        let richLayoutManager = RichTextLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        richLayoutManager.addTextContainer(container)
        textStorage.addLayoutManager(richLayoutManager)

        super.init(frame: .zero, textContainer: container)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init() instead")
    }

    private func commonInit() {
        font = .systemFont(ofSize: 16)
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        contentInsetAdjustmentBehavior = .never
        refreshLinkTextAttributes()
    }

    private func refreshLinkTextAttributes() {
        var attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: isLinkUnderline ? NSUnderlineStyle.single.rawValue : 0,
        ]
        if let linkColor {
            attrs[.foregroundColor] = linkColor
        }
        linkTextAttributes = attrs
    }

    /// 12 度倾斜矩阵，模拟 CJK 字体的斜体效果
    private static let obliqueTransform = CGAffineTransform(
        a: 1, b: 0,
        c: CGFloat(tanf(Float.pi / 180 * 12)),
        d: 1, tx: 0, ty: 0
    )

    /// 统一包裹 textStorage 修改，确保 beginEditing/endEditing 配对
    func mutateTextStorage(_ body: () -> Void) {
        textStorage.beginEditing()
        body()
        textStorage.endEditing()
    }

    // MARK: - 统一格式操作入口

    /// 切换格式（toggle）：已有则移除，没有则应用
    func toggleFormat(_ format: RichTextFormat, highlightARGB: UInt32 = HighlightColors.defaultHighlightColor) {
        let range = selectedRange
        if containsFormat(format, in: range) {
            removeFormat(format, in: range, highlightARGB: highlightARGB)
        } else {
            applyFormat(format, in: range, highlightARGB: highlightARGB)
        }
    }

    // MARK: - Apply Format

    func applyFormat(_ format: RichTextFormat, in range: NSRange, highlightARGB: UInt32 = HighlightColors.defaultHighlightColor) {
        switch format {
        case .bold:
            applyStyle(.bold, in: range)
        case .italic:
            applyStyle(.italic, in: range)
        case .underline:
            applyCharacterAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, in: range)
        case .strikethrough:
            applyCharacterAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, in: range)
        case .highlight:
            applyHighlight(lightARGB: highlightARGB, in: range)
        case .bulletList:
            applyParagraphFormat(.bulletList, in: range)
        case .blockquote:
            applyParagraphFormat(.blockquote, in: range)
        case .link:
            break // 链接通过 applyLink(_:in:) 单独处理
        }
    }

    // MARK: - Remove Format

    func removeFormat(_ format: RichTextFormat, in range: NSRange, highlightARGB: UInt32 = HighlightColors.defaultHighlightColor) {
        switch format {
        case .bold:
            removeStyle(.bold, in: range)
        case .italic:
            removeStyle(.italic, in: range)
        case .underline:
            removeCharacterAttribute(.underlineStyle, in: range)
        case .strikethrough:
            removeCharacterAttribute(.strikethroughStyle, in: range)
        case .highlight:
            removeHighlight(in: range)
        case .bulletList:
            removeParagraphFormat(.bulletList, in: range)
        case .blockquote:
            removeParagraphFormat(.blockquote, in: range)
        case .link:
            removeLink(in: range)
        }
    }

    // MARK: - Contains Format

    func containsFormat(_ format: RichTextFormat, in range: NSRange) -> Bool {
        switch format {
        case .bold:
            return containsStyle(.bold, in: range)
        case .italic:
            return containsStyle(.italic, in: range)
        case .underline:
            return containsCharacterAttribute(.underlineStyle, in: range)
        case .strikethrough:
            return containsCharacterAttribute(.strikethroughStyle, in: range)
        case .highlight:
            return containsCharacterAttribute(.backgroundColor, in: range)
        case .bulletList:
            return containsParagraphFormat(.bulletList, in: range)
        case .blockquote:
            return containsParagraphFormat(.blockquote, in: range)
        case .link:
            return containsCharacterAttribute(.link, in: range)
        }
    }

    // MARK: - 清除所有格式

    func clearFormats(in range: NSRange) {
        guard range.length > 0 else { return }
        let plainText = textStorage.attributedSubstring(from: range).string
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 16)]
        mutateTextStorage {
            textStorage.replaceCharacters(in: range, with: NSAttributedString(string: plainText, attributes: attrs))
        }
    }

    // MARK: - 缩进

    /// 在光标位置插入两个全角空格，对标 Android KnifeText.indent()
    func indent() {
        let pos = selectedRange.location
        let indentStr = "\u{3000}\u{3000}"
        let attrs: [NSAttributedString.Key: Any] = typingAttributes
        mutateTextStorage {
            textStorage.replaceCharacters(in: NSRange(location: pos, length: 0), with: NSAttributedString(string: indentStr, attributes: attrs))
        }
        selectedRange = NSRange(location: pos + 2, length: 0)
    }

    // MARK: - 链接

    func applyLink(_ url: String, in range: NSRange) {
        guard range.length > 0, let linkURL = URL(string: url) else { return }
        mutateTextStorage {
            textStorage.removeAttribute(.link, range: range)
            textStorage.addAttribute(.link, value: linkURL, range: range)
        }
    }

    private func removeLink(in range: NSRange) {
        guard range.length > 0 else { return }
        mutateTextStorage {
            textStorage.removeAttribute(.link, range: range)
        }
    }
}

// MARK: - StyleSpan（粗体/斜体）

/// 对标 KnifeText.styleValid / styleInvalid / containStyle
private extension RichTextEditorView {

    /// 字体 trait 类型
    enum FontStyle {
        case bold, italic

        var trait: UIFontDescriptor.SymbolicTraits {
            switch self {
            case .bold: return .traitBold
            case .italic: return .traitItalic
            }
        }
    }

    func applyStyle(_ style: FontStyle, in range: NSRange) {
        guard range.length > 0 else { return }
        mutateTextStorage {
            textStorage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                guard let currentFont = value as? UIFont else { return }
                var traits = currentFont.fontDescriptor.symbolicTraits
                traits.insert(style.trait)

                let hasOblique = textStorage.attribute(.obliqueItalic, at: subRange.location, effectiveRange: nil) != nil

                if let descriptor = currentFont.fontDescriptor.withSymbolicTraits(traits) {
                    let newFont = UIFont(descriptor: descriptor, size: currentFont.pointSize)

                    // 验证 trait 是否真正生效（PingFang 等 CJK 字体会返回非 nil 但 trait 未变）
                    if newFont.fontDescriptor.symbolicTraits.contains(style.trait) {
                        if hasOblique {
                            // .obliqueItalic 标记存在 → 在新字体上重新应用倾斜矩阵
                            let restoredDesc = newFont.fontDescriptor.addingAttributes([.matrix: Self.obliqueTransform])
                            textStorage.addAttribute(.font, value: UIFont(descriptor: restoredDesc, size: currentFont.pointSize), range: subRange)
                        } else {
                            textStorage.addAttribute(.font, value: newFont, range: subRange)
                        }
                    } else if style == .italic {
                        applyCJKOblique(to: currentFont, in: subRange)
                    }
                } else if style == .italic {
                    applyCJKOblique(to: currentFont, in: subRange)
                } else if style == .bold {
                    // withSymbolicTraits 返回 nil（oblique 字体上），强制 bold 系统字体
                    let boldFont = UIFont.boldSystemFont(ofSize: currentFont.pointSize)
                    var finalDesc = boldFont.fontDescriptor
                    if hasOblique {
                        finalDesc = finalDesc.addingAttributes([.matrix: Self.obliqueTransform])
                    }
                    textStorage.addAttribute(.font, value: UIFont(descriptor: finalDesc, size: currentFont.pointSize), range: subRange)
                }
            }
        }
    }

    /// CJK oblique 回退：12° 倾斜矩阵模拟斜体
    private func applyCJKOblique(to font: UIFont, in range: NSRange) {
        let obliqueDesc = font.fontDescriptor.addingAttributes([
            .matrix: Self.obliqueTransform
        ])
        let obliqueFont = UIFont(descriptor: obliqueDesc, size: font.pointSize)
        textStorage.addAttribute(.font, value: obliqueFont, range: range)
        textStorage.addAttribute(.obliqueItalic, value: true, range: range)
    }

    /// 对标 KnifeText.styleInvalid — KnifePart 分割逻辑
    func removeStyle(_ style: FontStyle, in range: NSRange) {
        guard range.length > 0 else { return }
        mutateTextStorage {
            textStorage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                guard let currentFont = value as? UIFont else { return }
                if style == .italic,
                   textStorage.attribute(.obliqueItalic, at: subRange.location, effectiveRange: nil) != nil {
                    // 清除 oblique：用 identity matrix 还原
                    let cleanDesc = currentFont.fontDescriptor.addingAttributes([
                        .matrix: CGAffineTransform.identity
                    ])
                    let cleanFont = UIFont(descriptor: cleanDesc, size: currentFont.pointSize)
                    textStorage.addAttribute(.font, value: cleanFont, range: subRange)
                    textStorage.removeAttribute(.obliqueItalic, range: subRange)
                } else {
                    var traits = currentFont.fontDescriptor.symbolicTraits
                    traits.remove(style.trait)
                    if let descriptor = currentFont.fontDescriptor.withSymbolicTraits(traits) {
                        let newFont = UIFont(descriptor: descriptor, size: currentFont.pointSize)
                        textStorage.addAttribute(.font, value: newFont, range: subRange)
                    }
                }
            }
        }
    }

    /// 对标 KnifeText.containStyle
    func containsStyle(_ style: FontStyle, in range: NSRange) -> Bool {
        let storage = textStorage
        let length = storage.length

        // 光标位置（无选区）：检查前后字符
        if range.length == 0 {
            let pos = range.location
            guard pos - 1 >= 0, pos + 1 <= length else { return false }
            return characterHasStyle(style, at: pos - 1) && characterHasStyle(style, at: pos)
        }

        // 有选区：逐字符检查，全部包含才返回 true
        var allContain = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, stop in
            guard let font = value as? UIFont else {
                allContain = false; stop.pointee = true; return
            }
            if font.fontDescriptor.symbolicTraits.contains(style.trait) { return }
            if style == .italic,
               storage.attribute(.obliqueItalic, at: subRange.location, effectiveRange: nil) != nil { return }
            allContain = false; stop.pointee = true
        }
        return allContain
    }

    private func characterHasStyle(_ style: FontStyle, at index: Int) -> Bool {
        guard let font = textStorage.attribute(.font, at: index, effectiveRange: nil) as? UIFont else { return false }
        if font.fontDescriptor.symbolicTraits.contains(style.trait) { return true }
        if style == .italic, textStorage.attribute(.obliqueItalic, at: index, effectiveRange: nil) != nil { return true }
        return false
    }
}

// MARK: - 字符级属性（下划线/删除线/高亮/链接）

/// 对标 KnifeText 的 underline/strikethrough/highlight 系列方法
private extension RichTextEditorView {

    func applyCharacterAttribute(_ key: NSAttributedString.Key, value: Any, in range: NSRange) {
        guard range.length > 0 else { return }
        mutateTextStorage {
            textStorage.addAttribute(key, value: value, range: range)
        }
    }

    /// 对标 KnifePart 分割逻辑：移除选区内属性，保留选区外部分
    func removeCharacterAttribute(_ key: NSAttributedString.Key, in range: NSRange) {
        guard range.length > 0 else { return }
        mutateTextStorage {
            textStorage.removeAttribute(key, range: range)
        }
    }

    /// 对标 containUnderline / containStrikethrough / containHighlight
    func containsCharacterAttribute(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        let storage = textStorage
        let length = storage.length

        if range.length == 0 {
            let pos = range.location
            guard pos - 1 >= 0, pos + 1 <= length else { return false }
            let before = storage.attribute(key, at: pos - 1, effectiveRange: nil)
            let after = storage.attribute(key, at: pos, effectiveRange: nil)
            return before != nil && after != nil
        }

        var allContain = true
        storage.enumerateAttribute(key, in: range, options: []) { value, _, stop in
            if value == nil {
                allContain = false
                stop.pointee = true
            }
        }
        return allContain
    }

    // MARK: - 高亮特殊处理

    func applyHighlight(lightARGB: UInt32, in range: NSRange) {
        guard range.length > 0 else { return }
        let displayColor = HighlightColors.adaptedColor(lightARGB: lightARGB, for: traitCollection)
        mutateTextStorage {
            textStorage.addAttribute(.backgroundColor, value: displayColor, range: range)
            textStorage.addAttribute(.highlightColor, value: lightARGB, range: range)
        }
    }

    func removeHighlight(in range: NSRange) {
        guard range.length > 0 else { return }
        mutateTextStorage {
            textStorage.removeAttribute(.backgroundColor, range: range)
            textStorage.removeAttribute(.highlightColor, range: range)
        }
    }
}

// MARK: - 段落级格式（Bullet / Blockquote）

/// 对标 KnifeText.bulletValid / bulletInvalid / containBullet 系列
private extension RichTextEditorView {

    /// 获取选区覆盖的行范围列表
    func lineRanges(for range: NSRange) -> [NSRange] {
        let text = textStorage.string as NSString
        var ranges: [NSRange] = []
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        var searchStart = 0

        while searchStart <= text.length {
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: searchStart, length: 0))
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)

            // 行与选区有交集
            if NSIntersectionRange(lineRange, range).length > 0 || NSLocationInRange(range.location, lineRange) {
                ranges.append(lineRange)
            }

            if lineEnd == searchStart { break } // 防止死循环
            searchStart = lineEnd
            if searchStart > NSMaxRange(range) && !ranges.isEmpty { break }
        }

        return ranges
    }

    func paragraphIndent() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = (bulletRadius * 2) + bulletGapWidth + Self.defaultIndentPadding
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    func applyParagraphFormat(_ key: NSAttributedString.Key, in range: NSRange) {
        mutateTextStorage {
            for lineRange in lineRanges(for: range) {
                guard lineRange.length > 0 else { continue }
                if textStorage.attribute(key, at: lineRange.location, effectiveRange: nil) != nil { continue }
                textStorage.addAttribute(key, value: true, range: lineRange)
                textStorage.addAttribute(.paragraphStyle, value: paragraphIndent(), range: lineRange)
            }
        }
    }

    func removeParagraphFormat(_ key: NSAttributedString.Key, in range: NSRange) {
        mutateTextStorage {
            for lineRange in lineRanges(for: range) {
                guard lineRange.length > 0 else { continue }
                if textStorage.attribute(key, at: lineRange.location, effectiveRange: nil) == nil { continue }
                textStorage.removeAttribute(key, range: lineRange)
                let otherKey: NSAttributedString.Key = (key == .bulletList) ? .blockquote : .bulletList
                if textStorage.attribute(otherKey, at: lineRange.location, effectiveRange: nil) == nil {
                    textStorage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: lineRange)
                }
            }
        }
    }

    func containsParagraphFormat(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        let lines = lineRanges(for: range)
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { lineRange in
            guard lineRange.length > 0 else { return false }
            return textStorage.attribute(key, at: lineRange.location, effectiveRange: nil) != nil
        }
    }
}
