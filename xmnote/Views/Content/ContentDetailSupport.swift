/**
 * [INPUT]: 依赖 SwiftUI 与 XMJXImageWall 提供内容详情公共展示能力
 * [OUTPUT]: 对外提供 ContentImageWall、ContentViewerNavigationTitle 与 ContentDetailDateFormatter 等查看页支撑组件
 * [POS]: Content 模块查看页共享支撑视图，供书摘/书评/相关详情页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftUI

/// 内容查看器页码进度模型，拆分当前页与总数，便于数字转场只作用于真实数值。
struct ContentViewerPageProgress: Equatable {
    let current: Int
    let total: Int
}

/// 内容查看器导航标题，统一承接书名与页码进度，避免把分页信息悬浮到材质按钮上。
struct ContentViewerNavigationTitle<TitleContent: View>: View {
    let pageProgress: ContentViewerPageProgress?
    let titleContent: TitleContent

    init(
        pageProgress: ContentViewerPageProgress?,
        @ViewBuilder titleContent: () -> TitleContent
    ) {
        self.pageProgress = pageProgress
        self.titleContent = titleContent()
    }

    var body: some View {
        VStack(spacing: Spacing.tiny) {
            titleContent

            if let pageProgress {
                ContentViewerPageProgressLabel(pageProgress: pageProgress)
            }
        }
        .frame(maxWidth: 220)
        .multilineTextAlignment(.center)
    }
}

/// 内容查看器页码副行，按整段 `N/N` 文本驱动 numericText 转场。
private struct ContentViewerPageProgressLabel: View {
    let pageProgress: ContentViewerPageProgress

    var body: some View {
        Text("\(pageProgress.current)/\(pageProgress.total)")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: pageProgress)
    }
}

/// 内容查看器标题文本样式，统一书名在导航栏中的字号、截断与前景色。
func contentViewerTitleLabel(_ title: String) -> some View {
    Text(title)
        .font(AppTypography.subheadlineSemibold)
        .lineLimit(1)
        .foregroundStyle(Color.textPrimary)
}

/// 内容详情图片墙，共用单图一列、多图三列的展示策略。
struct ContentImageWall: View {
    let imageURLs: [String]
    let prefix: String

    var body: some View {
        XMJXImageWall(
            items: imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(
                    id: "\(prefix)-img-\(index)",
                    thumbnailURL: url,
                    originalURL: url
                )
            },
            columnCount: imageURLs.count == 1 ? 1 : 3
        )
    }
}

/// 统一判断富文本 HTML 是否存在可展示正文，避免空标签误判为有效内容。
enum TimelineMeaningfulPreview {
    /// 封装hasMeaningfulHTML对应的业务步骤，确保调用方可以稳定复用该能力。
    static func hasMeaningfulHTML(_ html: String) -> Bool {
        !RichTextBridge.htmlToAttributed(html).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

/// 通用 viewer 使用的日期格式器，保持跨内容详情页展示一致。
enum ContentViewerDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()
}

/// 内容查看页统一错误提示卡片，避免各页重复定义相同的错误样式。
func viewerMessageCard(text: String) -> some View {
    CardContainer {
        Text(text)
            .font(AppTypography.footnote)
            .foregroundStyle(Color.feedbackError)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
    }
}

/// ContentDetailDateFormatter 负责当前场景的enum定义，明确职责边界并组织相关能力。
enum ContentDetailDateFormatter {
    static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
