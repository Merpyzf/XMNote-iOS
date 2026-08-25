/**
 * [INPUT]: 依赖通用内容详情模型、RichText、XMTagLabel 与图片墙组件，依赖 DesignTokens 排版与颜色令牌
 * [OUTPUT]: 对外提供 NoteContentDetailBody、ReviewContentDetailBody、RelevantContentDetailBody，承接三类内容的全屏正文结构与选区 AI 释义入口
 * [POS]: Content 模块查看页正文组件集合，被书摘查看与通用内容查看复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘正文主体，负责元信息、正文、想法、配图与页脚信息布局。
struct NoteContentDetailBody: View {
    let detail: NoteContentDetail
    var onAISelection: ((AITextLookupInput) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            noteMeta

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                RichText(
                    html: detail.contentHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.label,
                    lineSpacing: 5,
                    selectionActionTitle: "AI 释义",
                    onSelectionAction: { selectedText in
                        onAISelection?(
                            AITextLookupInput(
                                queryText: selectedText,
                                queryContext: plainText(detail.contentHTML),
                                bookTitle: detail.bookTitle
                            )
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.ideaHTML) {
                RichText(
                    html: detail.ideaHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.xmResolved(Color.textSecondary),
                    lineSpacing: 5,
                    selectionActionTitle: "AI 释义",
                    onSelectionAction: { selectedText in
                        onAISelection?(
                            AITextLookupInput(
                                queryText: selectedText,
                                queryContext: plainText(detail.ideaHTML),
                                bookTitle: detail.bookTitle
                            )
                        )
                    }
                )
                .padding(Spacing.cozy)
                .background(
                    Color.surfaceCard,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                )
            }

            if !detail.imageURLs.isEmpty {
                ContentImageWall(
                    imageURLs: detail.imageURLs,
                    prefix: "note"
                )
            }

            if let footer = footerText, !footer.isEmpty {
                Text(footer)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(.top, Spacing.half)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension NoteContentDetailBody {
    @ViewBuilder
    var noteMeta: some View {
        if detail.includeTime || !detail.tagNames.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                if detail.includeTime, let dateText = formattedDate(detail.createdDate) {
                    Text(dateText)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                if !detail.tagNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.tight) {
                            ForEach(detail.tagNames, id: \.self) { tag in
                                XMTagLabel(tag)
                            }
                        }
                    }
                }
            }
        }
    }

    var footerText: String? {
        var parts: [String] = []

        if let positionText = NotePositionUnitFormatter.labeledFooterText(
            position: detail.position,
            unit: detail.positionUnit
        ) {
            parts.append(positionText)
        }

        if !detail.chapterTitle.isEmpty {
            parts.append("章节：\(detail.chapterTitle)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func formattedDate(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        return ContentDetailDateFormatter.full.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        )
    }

    func plainText(_ html: String) -> String {
        RichTextPlainTextExtractor.plainText(from: html)
    }
}

/// 书评正文主体按标题、正文、配图与弱元信息顺序建立阅读层级。
struct ReviewContentDetailBody: View {
    let detail: ReviewContentDetail
    var onAISelection: ((AITextLookupInput) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if !trimmed(detail.title).isEmpty {
                ContentViewerSelectablePlainText(
                    text: detail.title,
                    baseFont: AppTypography.uiSemantic(.subheadline, weight: .semibold),
                    textColor: UIColor.xmResolved(Color.textPrimary),
                    inputContext: AITextLookupInput(
                        queryText: "",
                        queryContext: detail.title,
                        bookTitle: detail.bookTitle
                    ),
                    onAISelection: onAISelection
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                RichText(
                    html: detail.contentHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.label,
                    lineSpacing: 5,
                    selectionActionTitle: "AI 释义",
                    onSelectionAction: { selectedText in
                        onAISelection?(
                            AITextLookupInput(
                                queryText: selectedText,
                                queryContext: RichTextPlainTextExtractor.plainText(from: detail.contentHTML),
                                bookTitle: detail.bookTitle
                            )
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !detail.imageURLs.isEmpty {
                ContentImageWall(
                    imageURLs: detail.imageURLs,
                    prefix: "review"
                )
                .padding(.top, Spacing.half)
            }

            reviewMetadata
                .padding(.top, Spacing.half)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ReviewContentDetailBody {
    var reviewMetadata: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: detail.bookScore > 0 ? "star.fill" : "star")
                .font(AppTypography.caption)
                .foregroundStyle(detail.bookScore > 0 ? Color.ratingActive : Color.textHint)

            Text(ratingText)

            Text("·")
                .accessibilityHidden(true)

            Text("\(wordCount.formatted()) 字")

            if let dateText = formattedDate(detail.createdDate) {
                Text("·")
                    .accessibilityHidden(true)
                Text(dateText)
            }
        }
        .font(NoteExcerptTypography.footer)
        .foregroundStyle(Color.textSecondary)
        .accessibilityElement(children: .combine)
    }

    var ratingText: String {
        guard detail.bookScore > 0 else { return "未评分" }
        return (Double(detail.bookScore) / 10.0).formatted(
            .number.precision(.fractionLength(1))
        )
    }

    var wordCount: Int {
        RichTextPlainTextExtractor.plainText(from: detail.contentHTML).count
    }

    func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func formattedDate(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        return ContentDetailDateFormatter.full.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        )
    }
}

/// 相关内容正文主体，负责时间、标题、正文、链接与配图布局。
struct RelevantContentDetailBody: View {
    let detail: RelevantContentDetail
    var onAISelection: ((AITextLookupInput) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let dateText = formattedDate(detail.createdDate) {
                Text(dateText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            if !trimmed(detail.title).isEmpty {
                ContentViewerSelectablePlainText(
                    text: detail.title,
                    baseFont: AppTypography.uiSemantic(.subheadline, weight: .semibold),
                    textColor: UIColor.xmResolved(Color.textPrimary),
                    inputContext: AITextLookupInput(
                        queryText: "",
                        queryContext: detail.title,
                        bookTitle: detail.bookTitle
                    ),
                    onAISelection: onAISelection
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                RichText(
                    html: detail.contentHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.label,
                    lineSpacing: 5,
                    selectionActionTitle: "AI 释义",
                    onSelectionAction: { selectedText in
                        onAISelection?(
                            AITextLookupInput(
                                queryText: selectedText,
                                queryContext: RichTextPlainTextExtractor.plainText(from: detail.contentHTML),
                                bookTitle: detail.bookTitle
                            )
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let normalizedURL = normalizedURL(detail.url) {
                Link(destination: normalizedURL) {
                    Text(normalizedURL.absoluteString)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.brandDeep)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !detail.imageURLs.isEmpty {
                ContentImageWall(
                    imageURLs: detail.imageURLs,
                    prefix: "relevant"
                )
                .padding(.top, Spacing.half)
            }

            if let normalizedURL = normalizedURL(detail.url),
               TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                Link(destination: normalizedURL) {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "link")
                        Text(normalizedURL.absoluteString)
                            .lineLimit(1)
                    }
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.brandDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 标题选区桥接复用 RichText 的系统编辑菜单能力，并用转义保证纯文本不被解释为 HTML。
private struct ContentViewerSelectablePlainText: View {
    let text: String
    let baseFont: UIFont
    let textColor: UIColor
    let inputContext: AITextLookupInput
    let onAISelection: ((AITextLookupInput) -> Void)?

    var body: some View {
        RichText(
            html: escapedHTML,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: Spacing.none,
            selectionActionTitle: "AI 释义",
            onSelectionAction: { selectedText in
                onAISelection?(
                    AITextLookupInput(
                        queryText: selectedText,
                        queryContext: inputContext.queryContext,
                        bookTitle: inputContext.bookTitle
                    )
                )
            }
        )
    }

    private var escapedHTML: String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension RelevantContentDetailBody {
    func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func formattedDate(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        return ContentDetailDateFormatter.full.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        )
    }

    func normalizedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let directURL = URL(string: trimmed), directURL.scheme != nil {
            return directURL
        }

        if let directURL = URL(string: "https://\(trimmed)") {
            return directURL
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }
}
