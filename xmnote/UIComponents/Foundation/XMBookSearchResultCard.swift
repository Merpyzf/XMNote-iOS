/**
 * [INPUT]: 依赖 Domain/Models/BookSearchModels 的书籍搜索结果模型，依赖 XMBookCover 与设计令牌渲染统一的搜索结果卡片
 * [OUTPUT]: 对外提供 XMBookSearchResultCard，统一封装在线书籍搜索条目的标题高亮、结构字段与番茄摘要行渲染
 * [POS]: UIComponents/Foundation 跨模块复用组件，服务功能页与测试页的书籍搜索结果展示一致性
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在线书籍搜索结果卡片，统一承接封面、标题高亮与结构化字段展示。
struct XMBookSearchResultCard: View {
    static let coverWidth: CGFloat = 72

    let result: BookSearchResult
    let keyword: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                Self.coverWidth,
                urlString: result.coverURL,
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .medium,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                highlightedText(
                    result.title,
                    keyword: keyword,
                    baseFont: SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .headline),
                        relativeTo: .headline,
                        weight: .semibold
                    ),
                    highlightFont: SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .headline),
                        relativeTo: .headline,
                        weight: .bold
                    ),
                    baseColor: Color.textPrimary,
                    highlightColor: Color.brand
                )
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

                if result.isLightweightDoubanSearchCard {
                    if !result.subtitle.isEmpty {
                        highlightedText(
                            result.subtitle,
                            keyword: keyword,
                            baseFont: SemanticTypography.font(
                                baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                relativeTo: .subheadline
                            ),
                            highlightFont: SemanticTypography.font(
                                baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                relativeTo: .subheadline,
                                weight: .semibold
                            ),
                            baseColor: Color.textSecondary,
                            highlightColor: Color.brand
                        )
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(result.metadataLines) { line in
                            highlightedText(
                                "\(line.label)\(line.value)",
                                keyword: keyword,
                                baseFont: SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                                    relativeTo: .footnote
                                ),
                                highlightFont: SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                                    relativeTo: .footnote,
                                    weight: .semibold
                                ),
                                baseColor: Color.textSecondary,
                                highlightColor: Color.brand
                            )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if result.shouldShowStructuredSummaryLine {
                            highlightedText(
                                result.subtitle,
                                keyword: keyword,
                                baseFont: SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                                    relativeTo: .footnote
                                ),
                                highlightFont: SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                                    relativeTo: .footnote,
                                    weight: .semibold
                                ),
                                baseColor: Color.textSecondary,
                                highlightColor: Color.brand
                            )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.base)
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 聚合标题与结构字段，供外层容器拼接无障碍描述。
    var accessibilitySummary: String {
        if result.isLightweightDoubanSearchCard {
            return [result.title, result.subtitle]
                .filter { !$0.isEmpty }
                .joined(separator: "，")
        }

        let metadata = result.metadataLines.map { "\($0.label)\($0.value)" }
        let summaryLine = result.shouldShowStructuredSummaryLine ? [result.subtitle] : []
        return ([result.title] + metadata + summaryLine)
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    /// 生成与当前文本层级同步的高亮文本，保证未命中和空关键字时仍保留既有语义字体。
    private func highlightedText(
        _ text: String,
        keyword: String,
        baseFont: Font,
        highlightFont: Font,
        baseColor: Color,
        highlightColor: Color
    ) -> Text {
        Text(
            highlightedAttributedString(
                text,
                keyword: keyword,
                baseFont: baseFont,
                highlightFont: highlightFont,
                baseColor: baseColor,
                highlightColor: highlightColor
            )
        )
    }

    private func highlightedAttributedString(
        _ text: String,
        keyword: String,
        baseFont: Font,
        highlightFont: Font,
        baseColor: Color,
        highlightColor: Color
    ) -> AttributedString {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttributedString() }

        guard !trimmedKeyword.isEmpty else {
            return styledSegment(
                String(text[text.startIndex..<text.endIndex]),
                font: baseFont,
                color: baseColor
            )
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
                    font: highlightFont,
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

        if didMatch {
            return result
        }

        return styledSegment(
            String(text[text.startIndex..<text.endIndex]),
            font: baseFont,
            color: baseColor
        )
    }

    private func styledSegment(_ text: String, font: Font, color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = font
        attributed.foregroundColor = color
        return attributed
    }
}

private struct SearchResultMetadataLine: Identifiable {
    let id: String
    let label: String
    let value: String
}

private extension BookSearchResult {
    var isLightweightDoubanSearchCard: Bool {
        source == .douban &&
            seed == nil &&
            author.isEmpty &&
            translator.isEmpty &&
            press.isEmpty &&
            pubDate.isEmpty
    }

    var metadataLines: [SearchResultMetadataLine] {
        [
            SearchResultMetadataLine(id: "author", label: "作者：", value: author),
            SearchResultMetadataLine(id: "translator", label: "译者：", value: translator),
            SearchResultMetadataLine(id: "press", label: "出版社：", value: press),
            SearchResultMetadataLine(id: "pubDate", label: "出版日期：", value: pubDate)
        ]
        .filter { !$0.value.isEmpty }
    }

    var shouldShowStructuredSummaryLine: Bool {
        source == .fanqie && !subtitle.isEmpty
    }
}
