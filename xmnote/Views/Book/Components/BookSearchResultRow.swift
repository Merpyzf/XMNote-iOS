/**
 * [INPUT]: 依赖 Domain/Models/BookSearchModels 的搜索结果模型，依赖 XMBookCover 与设计令牌渲染在线搜索条目，依赖外部回调承接进入录入页动作
 * [OUTPUT]: 对外提供 BookSearchResultRow，封装在线书籍搜索结果的标题高亮、元数据排版与豆瓣轻量卡展示规则
 * [POS]: Book 模块搜索页的页面私有子视图，服务 BookSearchView 的结果列表渲染，不承担搜索状态与导航编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在线书籍搜索结果行，负责在不改变业务模型的前提下渲染命中高亮与来源差异化信息。
struct BookSearchResultRow: View {
    let result: BookSearchResult
    let keyword: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Spacing.base) {
                XMBookCover.fixedWidth(
                    68,
                    urlString: result.coverURL,
                    cornerRadius: CornerRadius.inlayHairline,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .medium,
                    surfaceStyle: .spine
                )

                VStack(alignment: .leading, spacing: Spacing.half) {
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(result.metadataLines) { line in
                            highlightedText(
                                "\(line.label)\(line.value)",
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
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.base)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
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
}
