/**
 * [INPUT]: 依赖 DesignTokens、XMTagLabel、SwiftSoup HTML 文本提取与 SwiftUI openURL 环境
 * [OUTPUT]: 对外提供 TimelineCardPresentationStyle、TimelineCardHeaderBar、TimelineBookSourceFooter、TimelineCardDivider、TimelineInlineTag、TimelineCardFooterRow 与 TimelineMeaningfulText
 * [POS]: Reading/Timeline 页面私有共享骨架，统一文本卡片的首页头部、每日详情来源尾注、分割线、标签行与空字段判定
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import SwiftSoup

/// 文本卡片上下文展示方式；首页保留完整头部，每日详情将来源书名置于内容之后。
enum TimelineCardPresentationStyle: Equatable {
    case standard
    case contentFirst
    case hidden
}

/// 首页时间线文本卡片共享头部，保持事件类型、来源书籍和时间的既有排布。
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
                bookTitle(displayBookName, color: .textHint)
            }

            Spacer(minLength: Spacing.cozy)

            Text(timeString)
                .font(AppTypography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textHint)
        }
        .accessibilityElement(children: .combine)
    }

    /// 书名统一使用中文书名号，不附加作者、封面或跳转暗示。
    private func bookTitle(_ title: String, color: Color) -> some View {
        Text("《\(title)》")
            .font(AppTypography.caption)
            .foregroundStyle(color)
            .lineLimit(1)
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

/// 每日阅读详情的书籍来源尾注；只保留书名号语义，并确保辅助功能读取完整来源。
struct TimelineBookSourceFooter: View {
    let bookName: String
    var fallbackBookTitle: String? = nil

    var body: some View {
        Text("《\(displayBookName)》")
            .font(NoteExcerptTypography.footer)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("来源书籍，《\(displayBookName)》")
    }

    private var displayBookName: String {
        let primaryName = TimelineMeaningfulText.trimmedText(bookName)
        if !primaryName.isEmpty {
            return primaryName
        }

        let fallbackName = TimelineMeaningfulText.trimmedText(fallbackBookTitle ?? "")
        return fallbackName.isEmpty ? "未命名书籍" : fallbackName
    }
}

/// 时间线文本类卡片共享分割线，对齐书摘头部与正文之间的视觉节奏。
struct TimelineCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderDefault.opacity(0.55))
            .frame(height: 1)
    }
}

/// 时间线内联标签，以系统中性填充承接分类语义，避免品牌色或带色背景制造脏感。
struct TimelineInlineTag: View {
    let text: String

    var body: some View {
        XMTagLabel(text)
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
nonisolated enum TimelineMeaningfulText {

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
