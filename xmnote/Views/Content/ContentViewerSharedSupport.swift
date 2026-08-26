/**
 * [INPUT]: 依赖 ContentViewerSourceContext 与 Foundation 提供通用查看器共享展示语义
 * [OUTPUT]: 对外提供 ContentViewerPresentationStyle 与关联应用配置提示
 * [POS]: Content 模块查看页共享 support；业务 Sheet 归属 Views/Content/Sheets
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 通用内容查看器展示风格，按入口来源决定文案与局部交互语义。
enum ContentViewerPresentationStyle {
    case general
    case noteOnly

    init(source: ContentViewerSourceContext) {
        switch source {
        case .bookNotes, .noteReview, .noteExcerpts, .chapterNotes:
            self = .noteOnly
        case .relatedCategory, .allReviews, .bookReviews, .bookRelated:
            self = .general
        case .timeline(_, _, let filter):
            self = filter == .note ? .noteOnly : .general
        }
    }

    var defaultTitle: String {
        switch self {
        case .general:
            "内容查看"
        case .noteOnly:
            "书摘"
        }
    }

    var missingItemMessage: String {
        switch self {
        case .general:
            "内容不存在或已删除"
        case .noteOnly:
            "书摘不存在或已删除"
        }
    }

    var loadingMessage: String {
        switch self {
        case .general:
            "正在加载内容…"
        case .noteOnly:
            "正在加载书摘…"
        }
    }

    var emptyIconName: String {
        switch self {
        case .general:
            "doc.text.magnifyingglass"
        case .noteOnly:
            "text.quote"
        }
    }

    var deleteDialogTitle: String {
        switch self {
        case .general:
            "删除当前内容？"
        case .noteOnly:
            "删除当前书摘？"
        }
    }

    var deleteAccessibilityLabel: String {
        switch self {
        case .general:
            "删除内容"
        case .noteOnly:
            "删除书摘"
        }
    }

    var showsListErrorBanner: Bool {
        switch self {
        case .general:
            true
        case .noteOnly:
            false
        }
    }
}

/// 通用内容查看需要先完成配置的能力枚举，统一管理入口提示文案。
enum ContentViewerPendingCapability {
    case apiConfiguration

    var title: String {
        switch self {
        case .apiConfiguration:
            "尚未配置关联应用"
        }
    }

    var message: String {
        switch self {
        case .apiConfiguration:
            "请先前往“我的 > 关联应用”，配置至少一个发送目标后再试。"
        }
    }
}

/// 通用内容查看待办提示载体，供 `XMSystemAlert` 统一承接。
struct PendingCapabilityPresentation: Identifiable {
    let capability: ContentViewerPendingCapability
    let id = UUID()

    var title: String { capability.title }
    var message: String { capability.message }
}
