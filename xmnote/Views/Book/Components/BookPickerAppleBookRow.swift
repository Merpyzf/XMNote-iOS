/**
 * [INPUT]: 依赖 XMBookCover、XMKeywordHighlighting 与 XMSelectionIndicator，接收 BookPicker 已整理的书籍展示值和选择状态
 * [OUTPUT]: 对 Apple 推荐选书列表提供无卡片表层的系统行内容与同构骨架行
 * [POS]: Book 模块页面私有列表行，仅服务仍在验证中的 Apple 推荐选书样式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// Apple 推荐选书列表的统一书籍行；本地与在线条目共享同一信息层级和尾随选择语义。
struct BookPickerAppleBookRow: View {
    let title: String
    let author: String
    let detail: String
    let coverURL: String
    let keyword: String
    let isSelected: Bool
    let showsSelectionIndicator: Bool
    let statusText: String?

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                Layout.coverWidth,
                urlString: coverURL,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                placeholderIconSize: .medium
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.half) {
                XMKeywordHighlighting.text(
                    title,
                    keyword: keyword,
                    baseFont: AppTypography.bodyMedium,
                    highlightFont: AppTypography.headlineSemibold,
                    baseColor: Color.textPrimary,
                    highlightColor: Color.textPrimary
                )
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

                if !metadataText.isEmpty {
                    XMKeywordHighlighting.text(
                        metadataText,
                        keyword: keyword,
                        baseFont: AppTypography.subheadline,
                        highlightFont: AppTypography.subheadlineSemibold,
                        baseColor: Color.textSecondary,
                        highlightColor: Color.textPrimary
                    )
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: Spacing.none)

            if let resolvedStatusText {
                Text(resolvedStatusText)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            } else if showsSelectionIndicator {
                XMSelectionIndicator(
                    style: .checkbox,
                    isSelected: isSelected,
                    font: AppTypography.body
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var accessibilitySummary: String {
        ([title] + [author, detail].filter { !$0.isEmpty })
            .joined(separator: "，")
    }

    private var metadataText: String {
        [author, detail]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var resolvedStatusText: String? {
        guard let statusText else { return nil }
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var accessibilityValue: String {
        if let resolvedStatusText {
            return resolvedStatusText
        }
        if showsSelectionIndicator {
            return isSelected ? "已选择" : "未选择"
        }
        return ""
    }
}

/// 加载态复用真实列表行几何，避免从大卡片骨架跳变为紧凑系统列表。
struct BookPickerAppleBookSkeletonRow: View {
    var body: some View {
        BookPickerAppleBookRow(
            title: "书籍标题占位文字",
            author: "作者信息",
            detail: "来源信息",
            coverURL: "",
            keyword: "",
            isSelected: false,
            showsSelectionIndicator: false,
            statusText: nil
        )
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension BookPickerAppleBookRow {
    enum Layout {
        static let coverWidth: CGFloat = 44
    }
}
