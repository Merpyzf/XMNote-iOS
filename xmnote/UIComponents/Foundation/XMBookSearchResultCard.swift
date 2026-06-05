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
                XMKeywordHighlighting.text(
                    result.title,
                    keyword: keyword,
                    baseFont: AppTypography.semantic(.headline, weight: .semibold),
                    highlightFont: AppTypography.semantic(.headline, weight: .bold),
                    baseColor: Color.textPrimary
                )
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

                if result.isLightweightDoubanSearchCard {
                    if !result.subtitle.isEmpty {
                        XMKeywordHighlighting.text(
                            result.subtitle,
                            keyword: keyword,
                            baseFont: AppTypography.subheadline,
                            highlightFont: AppTypography.subheadlineSemibold,
                            baseColor: Color.textSecondary
                        )
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(result.metadataLines) { line in
                            XMKeywordHighlighting.text(
                                "\(line.label)\(line.value)",
                                keyword: keyword,
                                baseFont: AppTypography.footnote,
                                highlightFont: AppTypography.footnoteSemibold,
                                baseColor: Color.textSecondary
                            )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if result.shouldShowStructuredSummaryLine {
                            XMKeywordHighlighting.text(
                                result.subtitle,
                                keyword: keyword,
                                baseFont: AppTypography.footnote,
                                highlightFont: AppTypography.footnoteSemibold,
                                baseColor: Color.textSecondary
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
