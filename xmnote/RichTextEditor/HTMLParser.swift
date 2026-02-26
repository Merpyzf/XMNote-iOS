import Foundation
import UIKit

/// HTML → NSAttributedString，对标 KnifeParser.fromHtml + KnifeTagHandler
/// 使用 XMLParser（SAX 模式），不依赖 WebKit
final class HTMLParser: NSObject {

    // MARK: - 公开接口

    /// 将 HTML 字符串解析为 NSAttributedString
    /// - Parameters:
    ///   - html: HTML 字符串（来自 Android Knife 序列化）
    ///   - baseFont: 基础字体
    ///   - traitCollection: 用于高亮色适配
    static func parse(
        _ html: String,
        baseFont: UIFont = .systemFont(ofSize: 16),
        traitCollection: UITraitCollection = .current
    ) -> NSAttributedString {
        let parser = HTMLParser()
        parser.baseFont = baseFont
        parser.traitCollection = traitCollection
        return parser.parseHTML(html)
    }

    // MARK: - 内部状态

    private var baseFont: UIFont = .systemFont(ofSize: 16)
    private var traitCollection: UITraitCollection = .current
    private var result = NSMutableAttributedString()
    private var tagStack: [TagContext] = []
    private var currentText = ""

    /// 标签上下文：记录开始位置和属性
    private struct TagContext {
        let tag: String
        let startIndex: Int
        var attributes: [String: String]
    }

    // MARK: - 解析入口

    private func parseHTML(_ html: String) -> NSAttributedString {
        // 清理 Android Knife 的 &zwj; 前缀
        var cleaned = html
        if cleaned.hasPrefix("&zwj;") {
            cleaned = String(cleaned.dropFirst(5))
        }

        // 将 <br> 转为占位符以便 XMLParser 处理
        cleaned = cleaned.replacingOccurrences(of: "<br>", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "<br/>", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "<br />", with: "\n")

        // 包裹根元素使其成为合法 XML
        let xml = "<root>\(cleaned)</root>"

        // 预处理 HTML 实体（XMLParser 只认 &amp; &lt; &gt; &apos; &quot;）
        let preprocessed = preprocessEntities(xml)

        let data = preprocessed.data(using: .utf8) ?? Data()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()

        return NSAttributedString(attributedString: result)
    }

    /// 预处理 HTML 实体：&nbsp; → 空格，&#xxx; 保留（XMLParser 能处理 &#）
    private func preprocessEntities(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
        // &lt; &gt; &amp; &quot; &apos; 是 XML 标准实体，XMLParser 自动处理
        return result
    }

    // MARK: - 属性构建

    private func buildAttributes(for tagStack: [TagContext]) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        var traits: UIFontDescriptor.SymbolicTraits = []

        for ctx in tagStack {
            switch ctx.tag.lowercased() {
            case "b", "strong":
                traits.insert(.traitBold)
            case "i", "em":
                traits.insert(.traitItalic)
            case "u":
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "del", "s", "strike":
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "mark":
                let lightARGB = parseMarkColor(from: ctx.attributes["style"])
                let displayColor = HighlightColors.adaptedColor(lightARGB: lightARGB, for: traitCollection)
                attrs[.backgroundColor] = displayColor
                attrs[.highlightColor] = lightARGB
            case "a":
                if let href = ctx.attributes["href"], let url = URL(string: href) {
                    attrs[.link] = url
                }
            default:
                break
            }
        }

        // 构建字体
        var font = baseFont
        if !traits.isEmpty {
            if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) {
                let candidateFont = UIFont(descriptor: descriptor, size: baseFont.pointSize)
                // 验证 trait 是否真正生效（PingFang 等 CJK 字体会返回非 nil 但 trait 未变）
                if candidateFont.fontDescriptor.symbolicTraits.isSuperset(of: traits) {
                    font = candidateFont
                } else if traits.contains(.traitItalic) {
                    font = Self.buildCJKObliqueFont(base: baseFont, needsBold: traits.contains(.traitBold))
                    attrs[.obliqueItalic] = true
                }
            } else if traits.contains(.traitItalic) {
                font = Self.buildCJKObliqueFont(base: baseFont, needsBold: traits.contains(.traitBold))
                attrs[.obliqueItalic] = true
            }
        }
        attrs[.font] = font

        return attrs
    }

    /// 解析 mark 标签的 style 属性中的背景色
    /// Android 格式：`background-color:-394337`（有符号 Int32）
    private func parseMarkColor(from style: String?) -> UInt32 {
        guard let style = style else { return HighlightColors.defaultHighlightColor }

        // 匹配 background-color: 后面的数值
        guard let range = style.range(of: "background-color:") else {
            return HighlightColors.defaultHighlightColor
        }

        let valueStr = style[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // 尝试解析为 Int32（Android 有符号格式）
        if let intValue = Int32(valueStr) {
            return HighlightColors.argbFromAndroidInt(intValue)
        }
        // 尝试解析为 hex（#RRGGBB）
        if valueStr.hasPrefix("#"), valueStr.count == 7 {
            let hex = String(valueStr.dropFirst())
            if let rgb = UInt32(hex, radix: 16) {
                return 0xFF000000 | rgb // 补全 alpha
            }
        }
        return HighlightColors.defaultHighlightColor
    }
}

// MARK: - XMLParserDelegate

extension HTMLParser: XMLParserDelegate {

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        // 先 flush 当前文本
        flushText()

        let tag = elementName.lowercased()
        if tag == "root" { return }

        let ctx = TagContext(tag: tag, startIndex: result.length, attributes: attributeDict)
        tagStack.append(ctx)

        // <li> 开始前确保换行
        if tag == "li" && result.length > 0 {
            let lastChar = result.string.last
            if lastChar != "\n" {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        flushText()

        let tag = elementName.lowercased()
        if tag == "root" { return }

        guard let ctx = tagStack.last, ctx.tag == tag else { return }
        tagStack.removeLast()

        let range = NSRange(location: ctx.startIndex, length: result.length - ctx.startIndex)

        switch tag {
        case "b", "strong", "i", "em", "u", "del", "s", "strike", "mark", "a":
            // 字符级格式：对已插入的文本应用属性
            applyCharacterAttributes(tag: tag, context: ctx, range: range)

        case "li":
            // 段落级：标记为 bulletList
            if range.length > 0 {
                let indent = paragraphIndent()
                result.addAttribute(.bulletList, value: true, range: range)
                result.addAttribute(.paragraphStyle, value: indent, range: range)
            }
            // <li> 结束后确保换行
            if result.length > 0 && result.string.last != "\n" {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }

        case "blockquote":
            if range.length > 0 {
                let indent = paragraphIndent()
                result.addAttribute(.blockquote, value: true, range: range)
                result.addAttribute(.paragraphStyle, value: indent, range: range)
            }

        case "ul":
            // <ul> 本身不产生属性，<li> 已处理
            break

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    // MARK: - 内部方法

    private func flushText() {
        guard !currentText.isEmpty else { return }
        let attrs = buildAttributes(for: tagStack)
        result.append(NSAttributedString(string: currentText, attributes: attrs))
        currentText = ""
    }

    private func applyCharacterAttributes(tag: String, context: TagContext, range: NSRange) {
        guard range.length > 0 else { return }

        switch tag {
        case "b", "strong":
            applyFontTrait(.traitBold, in: range)
        case "i", "em":
            applyFontTrait(.traitItalic, in: range)
        case "u":
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case "del", "s", "strike":
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case "mark":
            let lightARGB = parseMarkColor(from: context.attributes["style"])
            let displayColor = HighlightColors.adaptedColor(lightARGB: lightARGB, for: traitCollection)
            result.addAttribute(.backgroundColor, value: displayColor, range: range)
            result.addAttribute(.highlightColor, value: lightARGB, range: range)
        case "a":
            if let href = context.attributes["href"], let url = URL(string: href) {
                result.addAttribute(.link, value: url, range: range)
            }
        default:
            break
        }
    }

    private func applyFontTrait(_ trait: UIFontDescriptor.SymbolicTraits, in range: NSRange) {
        result.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            guard let currentFont = value as? UIFont else { return }
            var traits = currentFont.fontDescriptor.symbolicTraits
            traits.insert(trait)
            if let descriptor = currentFont.fontDescriptor.withSymbolicTraits(traits) {
                let newFont = UIFont(descriptor: descriptor, size: currentFont.pointSize)
                // 验证 trait 是否真正生效（PingFang 等 CJK 字体会返回非 nil 但 trait 未变）
                if newFont.fontDescriptor.symbolicTraits.contains(trait) {
                    // withSymbolicTraits 会丢失 matrix，需从原 font 恢复
                    let existingMatrix = currentFont.fontDescriptor.object(forKey: .matrix) as? CGAffineTransform
                    if let matrix = existingMatrix, matrix != .identity {
                        let restoredDesc = newFont.fontDescriptor.addingAttributes([.matrix: matrix])
                        result.addAttribute(.font, value: UIFont(descriptor: restoredDesc, size: currentFont.pointSize), range: subRange)
                    } else {
                        result.addAttribute(.font, value: newFont, range: subRange)
                    }
                } else if trait.contains(.traitItalic) {
                    let obliqueFont = Self.buildCJKObliqueFont(base: currentFont, needsBold: false)
                    result.addAttribute(.font, value: obliqueFont, range: subRange)
                    result.addAttribute(.obliqueItalic, value: true, range: subRange)
                }
            } else if trait.contains(.traitItalic) {
                let obliqueFont = Self.buildCJKObliqueFont(base: currentFont, needsBold: false)
                result.addAttribute(.font, value: obliqueFont, range: subRange)
                result.addAttribute(.obliqueItalic, value: true, range: subRange)
            }
        }
    }

    /// CJK oblique 回退：12° 倾斜矩阵模拟斜体
    private static func buildCJKObliqueFont(base: UIFont, needsBold: Bool) -> UIFont {
        let obliqueTransform = CGAffineTransform(
            a: 1, b: 0,
            c: CGFloat(tanf(Float.pi / 180 * 12)),
            d: 1, tx: 0, ty: 0
        )
        var baseDesc = base.fontDescriptor
        if needsBold, let boldDesc = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            baseDesc = boldDesc
        }
        let obliqueDesc = baseDesc.addingAttributes([.matrix: obliqueTransform])
        return UIFont(descriptor: obliqueDesc, size: base.pointSize)
    }

    private func paragraphIndent() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = RichTextEditorView.defaultParagraphIndent
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }
}
