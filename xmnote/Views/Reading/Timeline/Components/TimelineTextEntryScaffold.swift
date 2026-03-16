/**
 * [INPUT]: 依赖 DesignTokens 设计令牌、SwiftSoup HTML 文本提取、SwiftUI openURL 环境
 * [OUTPUT]: 对外提供 TimelineCardHeaderBar、TimelineCardDivider、TimelineInlineTag、TimelineCardFooterRow 与 TimelineMeaningfulText
 * [POS]: Reading/Timeline 页面私有共享骨架，统一书摘/书评/相关内容类文本卡片的头部、分割线、尾部标签行与空字段判定
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import SwiftSoup

/// 时间线文本类卡片共享头部，统一图标、书名与时间排布节奏。
struct TimelineCardHeaderBar: View {
    let iconSystemName: String
    let timestamp: Int64
    let bookName: String
    var fallbackBookTitle: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.cozy) {
            Image(systemName: iconSystemName)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.brand)

            if let displayBookName {
                Text("《\(displayBookName)》")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.cozy)

            Text(timeString)
                .font(AppTypography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textHint)
        }
    }

    private var displayBookName: String? {
        let primaryName = TimelineMeaningfulText.trimmedText(bookName)
        if !primaryName.isEmpty {
            return primaryName
        }

        let fallbackName = TimelineMeaningfulText.trimmedText(fallbackBookTitle ?? "")
        return fallbackName.isEmpty ? nil : fallbackName
    }

    private var timeString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 时间线文本类卡片共享分割线，对齐书摘头部与正文之间的视觉节奏。
struct TimelineCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderDefault.opacity(0.55))
            .frame(height: 1)
    }
}

/// 时间线内联标签，对齐书摘标签的间距与胶囊样式。
struct TimelineInlineTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.caption2)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.tagBackground, in: Capsule())
    }
}

/// 时间线文本类卡片尾部行，左侧放分类标签，右侧保留外链入口。
struct TimelineCardFooterRow: View {
    let tagTitle: String?
    let linkURLString: String?
    var linkAccessibilityLabel: String = "打开链接"

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            if let tagText = normalizedTagTitle {
                TimelineInlineTag(text: tagText)
            }

            Spacer(minLength: 0)

            if let normalizedLinkURLString {
                Button {
                    guard let destination = TimelineMeaningfulText.url(from: normalizedLinkURLString) else {
                        return
                    }
                    openURL(destination)
                } label: {
                    Image(systemName: "link")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(linkAccessibilityLabel)
            }
        }
    }

    private var normalizedTagTitle: String? {
        let trimmed = TimelineMeaningfulText.trimmedText(tagTitle ?? "")
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedLinkURLString: String? {
        let trimmed = TimelineMeaningfulText.trimmedText(linkURLString ?? "")
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 时间线文本有效性辅助，负责 trim、HTML 去标签与 URL 字符串清洗。
enum TimelineMeaningfulText {

    /// 统一处理空白字符，避免标题、标签、URL 仅包含空格时被误判为有内容。
    static func trimmedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 纯文本是否包含可展示内容。
    static func hasMeaningfulText(_ text: String) -> Bool {
        !trimmedText(text).isEmpty
    }

    /// 将 HTML 富文本抽取为纯文本，用于与 Android 一致的空内容判定。
    static func strippedHTML(_ html: String) -> String {
        let parsedText = (try? SwiftSoup.parse(html).text()) ?? html
        return trimmedText(parsedText)
    }

    /// HTML 富文本去标签后是否仍存在可展示正文。
    static func hasMeaningfulHTML(_ html: String) -> Bool {
        !strippedHTML(html).isEmpty
    }

    /// 统一从字符串构造外链 URL，失败时返回 nil。
    static func url(from text: String) -> URL? {
        let trimmed = trimmedText(text)
        guard !trimmed.isEmpty else { return nil }
        if let directURL = URL(string: trimmed) {
            return directURL
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }
}
