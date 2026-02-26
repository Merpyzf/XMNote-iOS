import Foundation
import UIKit

/// NSAttributedString → HTML，对标 KnifeParser.toHtml
/// 输出格式与 Android Knife 完全兼容
enum HTMLSerializer {

    enum ComboParagraphOrderStrategy {
        case bulletThenQuote
        case quoteThenBullet
    }

    /// 当同一段同时存在 bullet + quote 时的序列化策略。
    /// iOS 无法从 NSAttributedString 可靠恢复 Android Span 的原始插入顺序，
    /// 默认使用稳定输出，避免跨端往返时结果漂移。
    static var comboParagraphOrderStrategy: ComboParagraphOrderStrategy = .bulletThenQuote

    /// 将 NSAttributedString 序列化为 HTML 字符串
    static func serialize(_ attributedString: NSAttributedString) -> String {
        let text = attributedString
        guard text.length > 0 else { return "" }

        var out = ""
        withinHtml(&out, text)
        return tidy(out)
    }

    // MARK: - 顶层遍历（段落级 span 分割）

    /// 对标 KnifeParser.withinHtml
    private static func withinHtml(_ out: inout String, _ text: NSAttributedString) {
        let fullRange = NSRange(location: 0, length: text.length)
        let string = text.string as NSString

        // 按行处理，检测段落级格式
        var i = 0
        while i < text.length {
            // 找到当前行的范围
            let lineRange = string.lineRange(for: NSRange(location: i, length: 0))
            // 内容范围（不含换行符）
            let contentsEnd = lineRange.location + lineRange.length
            var actualEnd = contentsEnd
            while actualEnd > lineRange.location && isNewline(string.character(at: actualEnd - 1)) {
                actualEnd -= 1
            }
            let contentRange = NSRange(location: lineRange.location, length: actualEnd - lineRange.location)

            let isBullet = contentRange.length > 0 && text.attribute(.bulletList, at: contentRange.location, effectiveRange: nil) != nil
            let isQuote = contentRange.length > 0 && text.attribute(.blockquote, at: contentRange.location, effectiveRange: nil) != nil

            if isBullet && isQuote {
                // Bullet + Blockquote 组合：支持两种 Android 结构策略
                let comboEnd = collectConsecutiveCombinedLines(from: i, in: text, string: string)
                switch comboParagraphOrderStrategy {
                case .bulletThenQuote:
                    out += "<ul>"
                    writeBulletQuoteLines(&out, text, string: string, from: i, to: comboEnd)
                    out += "</ul>"
                case .quoteThenBullet:
                    out += "<blockquote><ul>"
                    writeBulletLines(&out, text, string: string, from: i, to: comboEnd)
                    out += "</ul></blockquote>"
                }
                i = comboEnd
            } else if isBullet {
                // 收集连续的 bullet 行
                let bulletEnd = collectConsecutiveLines(attribute: .bulletList, from: i, in: text, string: string)
                out += "<ul>"
                writeBulletLines(&out, text, string: string, from: i, to: bulletEnd)
                out += "</ul>"
                i = bulletEnd
            } else if isQuote {
                let quoteEnd = collectConsecutiveLines(attribute: .blockquote, from: i, in: text, string: string)
                out += "<blockquote>"
                writeContentLines(&out, text, from: i, to: quoteEnd)
                out += "</blockquote>"
                i = quoteEnd
            } else {
                // 普通内容行
                let nextLine = lineRange.location + lineRange.length
                writeContentLines(&out, text, from: i, to: nextLine)
                i = nextLine
            }
        }
    }

    /// 收集从 start 开始的连续具有指定段落属性的行
    private static func collectConsecutiveLines(attribute: NSAttributedString.Key, from start: Int, in text: NSAttributedString, string: NSString) -> Int {
        var pos = start
        while pos < text.length {
            let lineRange = string.lineRange(for: NSRange(location: pos, length: 0))
            let lineContentEnd = findContentEnd(in: lineRange, string: string)
            let contentRange = NSRange(location: lineRange.location, length: lineContentEnd - lineRange.location)

            if contentRange.length > 0 && text.attribute(attribute, at: contentRange.location, effectiveRange: nil) != nil {
                pos = lineRange.location + lineRange.length
            } else {
                break
            }
        }
        return pos
    }

    /// 写入 bullet 行：每行包裹 <li>...</li>
    private static func writeBulletLines(_ out: inout String, _ text: NSAttributedString, string: NSString, from start: Int, to end: Int) {
        var pos = start
        while pos < end {
            let lineRange = string.lineRange(for: NSRange(location: pos, length: 0))
            let lineContentEnd = findContentEnd(in: lineRange, string: string)
            let contentRange = NSRange(location: lineRange.location, length: lineContentEnd - lineRange.location)

            out += "<li>"
            if contentRange.length > 0 {
                withinParagraph(&out, text, start: contentRange.location, end: NSMaxRange(contentRange))
            }
            out += "</li>"

            pos = lineRange.location + lineRange.length
        }
    }

    /// 收集从 start 开始的连续同时具有 bulletList + blockquote 的行
    private static func collectConsecutiveCombinedLines(from start: Int, in text: NSAttributedString, string: NSString) -> Int {
        var pos = start
        while pos < text.length {
            let lineRange = string.lineRange(for: NSRange(location: pos, length: 0))
            let lineContentEnd = findContentEnd(in: lineRange, string: string)
            let contentRange = NSRange(location: lineRange.location, length: lineContentEnd - lineRange.location)

            if contentRange.length > 0
                && text.attribute(.bulletList, at: contentRange.location, effectiveRange: nil) != nil
                && text.attribute(.blockquote, at: contentRange.location, effectiveRange: nil) != nil {
                pos = lineRange.location + lineRange.length
            } else {
                break
            }
        }
        return pos
    }

    /// 写入 bullet+blockquote 组合行：<li><blockquote>...</blockquote></li>
    /// 对标 Android KnifeParser.withinBulletThenQuote
    private static func writeBulletQuoteLines(_ out: inout String, _ text: NSAttributedString, string: NSString, from start: Int, to end: Int) {
        var pos = start
        while pos < end {
            let lineRange = string.lineRange(for: NSRange(location: pos, length: 0))
            let lineContentEnd = findContentEnd(in: lineRange, string: string)
            let contentRange = NSRange(location: lineRange.location, length: lineContentEnd - lineRange.location)

            out += "<li><blockquote>"
            if contentRange.length > 0 {
                withinParagraph(&out, text, start: contentRange.location, end: NSMaxRange(contentRange))
            }
            out += "</blockquote></li>"

            pos = lineRange.location + lineRange.length
        }
    }

    /// 写入普通内容行
    private static func writeContentLines(_ out: inout String, _ text: NSAttributedString, from start: Int, to end: Int) {
        let string = text.string as NSString
        var pos = start
        while pos < end {
            let lineRange = string.lineRange(for: NSRange(location: pos, length: 0))
            let lineContentEnd = findContentEnd(in: lineRange, string: string)
            let contentRange = NSRange(location: lineRange.location, length: lineContentEnd - lineRange.location)

            if contentRange.length > 0 {
                withinParagraph(&out, text, start: contentRange.location, end: NSMaxRange(contentRange))
            }

            // 换行符 → <br>
            let nlCount = (lineRange.location + lineRange.length) - lineContentEnd
            for _ in 0..<nlCount {
                out += "<br>"
            }

            pos = lineRange.location + lineRange.length
        }
    }

    // MARK: - 字符级 span 遍历

    /// 对标 KnifeParser.withinParagraph
    private static func withinParagraph(_ out: inout String, _ text: NSAttributedString, start: Int, end: Int) {
        guard start < end else { return }
        let range = NSRange(location: start, length: end - start)

        text.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            // 开标签
            var openTags: [String] = []

            if let font = attrs[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) {
                    out += "<b>"
                    openTags.append("b")
                }
                if traits.contains(.traitItalic) || attrs[.obliqueItalic] != nil {
                    out += "<i>"
                    openTags.append("i")
                }
            }

            if attrs[.underlineStyle] != nil {
                out += "<u>"
                openTags.append("u")
            }

            if attrs[.strikethroughStyle] != nil {
                out += "<del>"
                openTags.append("del")
            }

            if attrs[.backgroundColor] != nil {
                // 序列化时使用 light mode 原始值
                let lightARGB: UInt32
                if let stored = attrs[.highlightColor] as? UInt32 {
                    lightARGB = stored
                } else if let bgColor = attrs[.backgroundColor] as? UIColor {
                    let displayARGB = HighlightColors.argb(from: bgColor)
                    lightARGB = HighlightColors.lightARGB(from: displayARGB)
                } else {
                    lightARGB = HighlightColors.defaultHighlightColor
                }
                let androidInt = HighlightColors.androidInt(from: lightARGB)
                out += "<mark style=\"background-color:\(androidInt)\">"
                openTags.append("mark")
            }

            if let link = attrs[.link] {
                let urlString: String
                if let url = link as? URL {
                    urlString = url.absoluteString
                } else if let str = link as? String {
                    urlString = str
                } else {
                    urlString = ""
                }
                out += "<a href=\"\(escapeHTML(urlString))\">"
                openTags.append("a")
            }

            // 文本内容（转义特殊字符）
            let substring = text.attributedSubstring(from: subRange).string
            withinStyle(&out, substring)

            // 闭标签（逆序）
            for tag in openTags.reversed() {
                out += "</\(tag)>"
            }
        }
    }

    // MARK: - 文本转义

    /// 对标 KnifeParser.withinStyle
    private static func withinStyle(_ out: inout String, _ text: String) {
        let chars = Array(text.utf16)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c == 0x3C { // <
                out += "&lt;"
            } else if c == 0x3E { // >
                out += "&gt;"
            } else if c == 0x26 { // &
                out += "&amp;"
            } else if c >= 0xD800 && c <= 0xDFFF {
                // Unicode 代理对
                if c < 0xDC00 && i + 1 < chars.count {
                    let d = chars[i + 1]
                    if d >= 0xDC00 && d <= 0xDFFF {
                        i += 1
                        let codepoint = 0x010000 | (Int(c) - 0xD800) << 10 | (Int(d) - 0xDC00)
                        out += "&#\(codepoint);"
                    }
                }
            } else if c > 0x7E || c < 0x20 {
                if c == 0x0A { // \n → <br> 已在上层处理
                    out += "\n"
                } else {
                    out += "&#\(c);"
                }
            } else if c == 0x20 { // 空格
                // 连续空格 → &nbsp; + 最后一个保留空格
                var spaceCount = 0
                while i + spaceCount + 1 < chars.count && chars[i + spaceCount + 1] == 0x20 {
                    spaceCount += 1
                }
                for _ in 0..<spaceCount {
                    out += "&nbsp;"
                    i += 1
                }
                out += " "
            } else {
                out += String(Unicode.Scalar(UInt32(c))!)
            }

            i += 1
        }
    }

    // MARK: - 工具方法

    /// 对标 KnifeParser.tidy
    private static func tidy(_ html: String) -> String {
        var result = html
        // </ul><br> → </ul>
        result = result.replacingOccurrences(of: "</ul><br>", with: "</ul>")
        // </blockquote><br> → </blockquote>
        result = result.replacingOccurrences(of: "</blockquote><br>", with: "</blockquote>")
        return result
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func isNewline(_ char: unichar) -> Bool {
        char == 0x0A || char == 0x0D // \n or \r
    }

    private static func findContentEnd(in lineRange: NSRange, string: NSString) -> Int {
        var end = lineRange.location + lineRange.length
        while end > lineRange.location && isNewline(string.character(at: end - 1)) {
            end -= 1
        }
        return end
    }
}
