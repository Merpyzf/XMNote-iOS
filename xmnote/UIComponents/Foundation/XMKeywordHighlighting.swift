/**
 * [INPUT]: 依赖 SwiftUI AttributedString、Font、Color 与项目关键字高亮语义色
 * [OUTPUT]: 对外提供 XMKeywordHighlighting，统一构建搜索关键字高亮文本与富文本
 * [POS]: UIComponents/Foundation 跨模块文本高亮工具，被书籍搜索卡片、选书弹层与书架列表消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 搜索关键字高亮工具，保证各书籍搜索入口使用一致的匹配与渲染语义。
enum XMKeywordHighlighting {
    /// 生成 SwiftUI 文本，适合直接嵌入 `Text` 渲染路径。
    static func text(
        _ text: String,
        keyword: String,
        baseFont: Font,
        highlightFont: Font? = nil,
        baseColor: Color,
        highlightColor: Color = .keywordHighlight
    ) -> Text {
        Text(
            attributedString(
                text,
                keyword: keyword,
                baseFont: baseFont,
                highlightFont: highlightFont,
                baseColor: baseColor,
                highlightColor: highlightColor
            )
        )
    }

    /// 生成高亮富文本；空关键字或未命中时返回完整基础样式文本。
    static func attributedString(
        _ text: String,
        keyword: String,
        baseFont: Font,
        highlightFont: Font? = nil,
        baseColor: Color,
        highlightColor: Color = .keywordHighlight
    ) -> AttributedString {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttributedString() }
        guard !trimmedKeyword.isEmpty else {
            return styledSegment(text, font: baseFont, color: baseColor)
        }

        var result = AttributedString()
        var searchStart = text.startIndex
        var didMatch = false

        while searchStart < text.endIndex,
              let range = text.range(
                of: trimmedKeyword,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex,
                locale: .current
              ) {
            if searchStart < range.lowerBound {
                result.append(
                    styledSegment(
                        String(text[searchStart..<range.lowerBound]),
                        font: baseFont,
                        color: baseColor
                    )
                )
            }

            result.append(
                styledSegment(
                    String(text[range]),
                    font: highlightFont ?? baseFont,
                    color: highlightColor
                )
            )
            didMatch = true
            searchStart = range.upperBound
        }

        if searchStart < text.endIndex {
            result.append(
                styledSegment(
                    String(text[searchStart..<text.endIndex]),
                    font: baseFont,
                    color: baseColor
                )
            )
        }

        return didMatch ? result : styledSegment(text, font: baseFont, color: baseColor)
    }

    /// 判断文本是否按统一高亮规则命中关键字，便于列表决定是否展示命中上下文。
    static func contains(_ text: String, keyword: String) -> Bool {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !trimmedKeyword.isEmpty else { return false }
        return text.range(
            of: trimmedKeyword,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: text.startIndex..<text.endIndex,
            locale: .current
        ) != nil
    }

    private static func styledSegment(_ text: String, font: Font, color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = font
        attributed.foregroundColor = color
        return attributed
    }
}
