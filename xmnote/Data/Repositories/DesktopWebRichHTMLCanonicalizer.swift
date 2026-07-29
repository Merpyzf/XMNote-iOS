/**
 * [INPUT]: 依赖 Foundation 字符串、正则与 Unicode 能力
 * [OUTPUT]: 对外提供 Android canonicalizeRichHtmlHighlightColors 的无 UI 等价实现
 * [POS]: Data 层网页书摘富文本兼容器；仅供 Web 写入路径复刻 Android 持久化格式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 将 Web 富文本转换为 Android Knife 使用的受限标签和 signed ARGB 高亮格式。
nonisolated enum DesktopWebRichHTMLCanonicalizer {
    private static let defaultHighlightHex = "#FDFBCA"
    private static let highlightColorPairs = [
        ("#FFE1F9", "#665A64"),
        ("#FDFBCA", "#8D8B42"),
        ("#C8F2EE", "#7C9299"),
        ("#C8EDF8", "#506062"),
        ("#B1C7E7", "#323333"),
        ("#A6CED1", "#6E8788"),
        ("#D4E8A4", "#818F66"),
        ("#F0D472", "#A89C00"),
        ("#F2A4B8", "#AD7683"),
        ("#EB88E1", "#C070B7"),
        ("#ECD8FE", "#83798D"),
        ("#DABDB9", "#A9928F"),
        ("#DFDFDF", "#626262")
    ]

    /// 规范化 `<mark>` 颜色并转义 Android 不支持的左尖括号；该纯函数无异步任务与竞态。
    static func canonicalize(_ html: String) -> String {
        let colorNormalized = html.range(of: "<mark", options: .caseInsensitive) == nil
            ? html
            : canonicalizeHighlightColors(html)
        return escapeUnsupportedTags(colorNormalized)
    }
}

private nonisolated extension DesktopWebRichHTMLCanonicalizer {
    static var lightHighlightByAnyHex: [String: String] {
        Dictionary(uniqueKeysWithValues: highlightColorPairs.flatMap { light, dark in
            [(light.uppercased(), light.uppercased()), (dark.uppercased(), light.uppercased())]
        })
    }

    static var androidColorByLightHex: [String: String] {
        Dictionary(uniqueKeysWithValues: highlightColorPairs.map { light, _ in
            (light.uppercased(), signedARGB(light.uppercased()))
        })
    }

    static func canonicalizeHighlightColors(_ html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"<mark\b([^>]*)>"#,
            options: [.caseInsensitive]
        ) else { return html }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.stringByReplacingMatches(
            in: html,
            range: fullRange,
            withTemplate: "__XMNOTE_MARK_PLACEHOLDER__"
        ).replacingMarkPlaceholders(from: html, expression: expression)
    }

    static func normalizeHighlightColor(_ value: String?) -> String {
        let token = colorToken(value) ?? defaultHighlightHex
        let lightHex = lightHighlightByAnyHex[token] ?? token
        return androidColorByLightHex[lightHex] ?? signedARGB(lightHex)
    }

    static func colorToken(_ value: String?) -> String? {
        guard var normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        normalized = normalized.replacingOccurrences(
            of: #"\s*!important\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if normalized.hasSuffix(";") { normalized.removeLast() }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.caseInsensitiveCompare("transparent") != .orderedSame else {
            return nil
        }
        if normalized.range(of: #"^-?\d+$"#, options: .regularExpression) != nil,
           let signed = Int32(normalized) {
            return hexFromARGB(bitPattern: UInt32(bitPattern: signed))
        }
        if let hex = normalizeHex(normalized) { return hex }
        return rgbToHex(normalized)
    }

    static func normalizeHex(_ value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#
        ) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let rawRange = Range(match.range(at: 1), in: value) else { return nil }
        let raw = String(value[rawRange])
        let normalized = raw.count == 3
            ? raw.map { "\($0)\($0)" }.joined()
            : String(raw.prefix(6))
        return "#\(normalized.uppercased())"
    }

    static func rgbToHex(_ value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^rgba?\((.+)\)$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let channelRange = Range(match.range(at: 1), in: value) else { return nil }
        var channels = String(value[channelRange])
        channels = channels.replacingOccurrences(
            of: #"\s*/\s*[^,]+$"#,
            with: "",
            options: .regularExpression
        )
        let components = channels
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n\r"))
            .filter { !$0.isEmpty }
        guard components.count >= 3,
              let red = parseRGBChannel(components[0]),
              let green = parseRGBChannel(components[1]),
              let blue = parseRGBChannel(components[2]) else { return nil }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func parseRGBChannel(_ value: String) -> Int? {
        if value.hasSuffix("%") {
            guard let percent = Double(value.dropLast()) else { return nil }
            return Int((min(max(percent, 0), 100) * 2.55).rounded())
        }
        guard let channel = Double(value) else { return nil }
        return Int(min(max(channel, 0), 255).rounded())
    }

    static func signedARGB(_ hex: String) -> String {
        let raw = String(hex.dropFirst())
        guard let rgb = UInt32(raw, radix: 16) else {
            return signedARGB(defaultHighlightHex)
        }
        return String(Int32(bitPattern: 0xFF00_0000 | rgb))
    }

    static func hexFromARGB(bitPattern: UInt32) -> String {
        String(
            format: "#%02X%02X%02X",
            (bitPattern >> 16) & 0xFF,
            (bitPattern >> 8) & 0xFF,
            bitPattern & 0xFF
        )
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: "\\b\(escapedName)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = expression.firstMatch(in: attributes, range: range) else { return nil }
        for index in 1...3 where index < match.numberOfRanges && match.range(at: index).location != NSNotFound {
            guard let valueRange = Range(match.range(at: index), in: attributes) else { continue }
            return String(attributes[valueRange])
        }
        return nil
    }

    static func backgroundColor(in attributes: String) -> String? {
        guard let style = attribute("style", in: attributes),
              let expression = try? NSRegularExpression(
                pattern: #"(?:^|;)\s*background-color\s*:\s*([^;]+)\s*(?:;|$)"#,
                options: [.caseInsensitive]
              ) else { return nil }
        let range = NSRange(style.startIndex..<style.endIndex, in: style)
        guard let match = expression.firstMatch(in: style, range: range),
              let colorRange = Range(match.range(at: 1), in: style) else { return nil }
        return String(style[colorRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escapeUnsupportedTags(_ html: String) -> String {
        var output = ""
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                let next = html.index(after: index)
                let suffix = String(html[next...])
                output += allowedTagStart(suffix) ? "<" : "&lt;"
            } else {
                output.append(character)
            }
            index = html.index(after: index)
        }
        return output
    }

    static func allowedTagStart(_ value: String) -> Bool {
        if value.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) { return true }
        if matches(#"(?i)^br\s*/?>"#, value) { return true }
        for tag in ["b", "mark", "u", "i", "del"] {
            if value.lowercased().hasPrefix("\(tag)>") || value.lowercased().hasPrefix("/\(tag)>") {
                return true
            }
            if tag == "mark", matches(#"(?i)^mark\s+style=\"background-color:-?\d+\">"#, value) {
                return true
            }
        }
        if ["ul>", "/ul>", "ol>", "/ol>", "li>", "/li>"].contains(where: {
            value.lowercased().hasPrefix($0)
        }) {
            return true
        }
        return matches(#"(?i)^ol(?:\s+start=(?:\"\d+\"|'\d+'|\d+))?>"#, value)
    }

    static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private nonisolated extension String {
    func replacingMarkPlaceholders(
        from original: String,
        expression: NSRegularExpression
    ) -> String {
        let placeholder = "__XMNOTE_MARK_PLACEHOLDER__"
        let fullRange = NSRange(original.startIndex..<original.endIndex, in: original)
        let replacements = expression.matches(in: original, range: fullRange).map { match -> String in
            let attributes = Range(match.range(at: 1), in: original).map { String(original[$0]) } ?? ""
            let rawColor = DesktopWebRichHTMLCanonicalizer.attribute("data-color", in: attributes)
                ?? DesktopWebRichHTMLCanonicalizer.backgroundColor(in: attributes)
            let color = DesktopWebRichHTMLCanonicalizer.normalizeHighlightColor(rawColor)
            return "<mark style=\"background-color:\(color)\">"
        }
        var output = self
        for replacement in replacements {
            guard let range = output.range(of: placeholder) else { break }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }
}
