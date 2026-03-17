/**
 * [INPUT]: 依赖 SwiftUI 与 XMJXImageWall 提供内容详情公共展示能力
 * [OUTPUT]: 对外提供 ContentImageWall 与 ContentDetailDateFormatter 等查看页支撑组件
 * [POS]: Content 模块查看页共享支撑视图，供书摘/书评/相关详情页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftUI

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

enum ContentDetailDateFormatter {
    static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
