/**
 * [INPUT]: 依赖 Foundation XMLParser 读取 Android Knife HTML 片段
 * [OUTPUT]: 对外提供 RichTextPlainTextExtractor，生成详情页预览所需的纯文本
 * [POS]: RichTextEditor 功能模块内部轻量解析器，被书籍详情 ViewModel 用于后台预处理富文本预览
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 富文本纯文本提取器，服务列表和详情预览，不参与富文本编辑器的样式还原。
nonisolated final class RichTextPlainTextExtractor: NSObject {
    private var result = ""
    private var currentText = ""

    /// 将 Android Knife HTML 片段转换为可展示纯文本。
    static func plainText(from html: String) -> String {
        let normalized = normalizedHTMLFragment(html)
        guard !normalized.isEmpty else { return "" }
        let extractor = RichTextPlainTextExtractor()
        return extractor.parseHTML(normalized)
    }

    /// 使用 XMLParser 读取合法 Knife HTML，解析失败时退回标签剥离路径以避免预览空白。
    private func parseHTML(_ html: String) -> String {
        let xml = "<root>\(preprocessEntities(html))</root>"
        guard let data = xml.data(using: .utf8) else {
            return Self.fallbackPlainText(from: html)
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else {
            return Self.fallbackPlainText(from: html)
        }
        flushText()
        return result
    }

    /// 归一化 Android 前缀与换行标签，保留后续 XML 解析需要的标签结构。
    private static func normalizedHTMLFragment(_ html: String) -> String {
        var cleaned = html
        if cleaned.hasPrefix("&zwj;") {
            cleaned = String(cleaned.dropFirst(5))
        }
        return cleaned.replacingOccurrences(
            of: #"(?i)<br\s*/?>"#,
            with: "\n",
            options: .regularExpression
        )
    }

    /// 预处理 XMLParser 不直接识别的常用 HTML 实体，保持与现有 HTMLParser 可见文本口径一致。
    private func preprocessEntities(_ html: String) -> String {
        html.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
    }

    /// 解析不合法 HTML 时用正则剥离标签，保证详情预览仍展示可读文本。
    private static func fallbackPlainText(from html: String) -> String {
        var cleaned = normalizedHTMLFragment(html)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)</li>\s*<li[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)</li>"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return decodeEntities(cleaned)
    }

    /// 解码预览中最常见的 HTML 实体，避免回退路径残留转义符号。
    private static func decodeEntities(_ value: String) -> String {
        var decoded = decodeNumericEntities(value)
        decoded = decoded.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
        decoded = decoded.replacingOccurrences(of: "&lt;", with: "<")
        decoded = decoded.replacingOccurrences(of: "&gt;", with: ">")
        decoded = decoded.replacingOccurrences(of: "&quot;", with: "\"")
        decoded = decoded.replacingOccurrences(of: "&apos;", with: "'")
        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")
        return decoded
    }

    /// 解码十进制与十六进制数字实体，兼容外部导入内容中的 Unicode 文本。
    private static func decodeNumericEntities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) else {
            return value
        }
        var output = value
        let nsValue = value as NSString
        let matches = regex.matches(
            in: value,
            range: NSRange(location: 0, length: nsValue.length)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: output) else {
                continue
            }
            let token = nsValue.substring(with: match.range(at: 1))
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(String(token.dropFirst()), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            output.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return output
    }

    /// 将 XMLParser 分段回调累积的文本写入最终结果。
    private func flushText() {
        guard !currentText.isEmpty else { return }
        result += currentText
        currentText = ""
    }

    /// 在列表项之间补一个换行，但避免制造重复空行。
    private func appendNewlineIfNeeded() {
        guard !result.isEmpty, result.last != "\n" else { return }
        result += "\n"
    }
}

nonisolated extension RichTextPlainTextExtractor: XMLParserDelegate {
    /// 在列表项边界补齐换行，保持与富文本解析后的可见字符串一致。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        flushText()
        if elementName.lowercased() == "li" {
            appendNewlineIfNeeded()
        }
    }

    /// 在列表项结束时补齐换行，避免多个条目在详情预览中粘连。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        flushText()
        if elementName.lowercased() == "li" {
            appendNewlineIfNeeded()
        }
    }

    /// 累积文本节点内容，标签样式由纯文本预览忽略。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
}
