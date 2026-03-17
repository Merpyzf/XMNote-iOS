/**
 * [INPUT]: 依赖 Foundation 提供标识、时间戳与 URL 等跨层基础类型
 * [OUTPUT]: 对外提供 ContentViewerSourceContext、ContentViewerItemID、ContentViewerListItem、ContentViewerDetail、ReviewEditorDraft、RelevantEditorDraft
 * [POS]: Domain/Models 的通用内容查看领域模型，供 Repository、ViewModel 与 Viewer/Editor 页面共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 时间线内容查看过滤器，只承接可进入通用查看器的三类内容。
enum TimelineContentFilter: Hashable {
    case allContent
    case note
    case review
    case relevant
}

/// 通用内容查看器的数据来源上下文。
enum ContentViewerSourceContext: Hashable {
    case timeline(startTimestamp: Int64, endTimestamp: Int64, filter: TimelineContentFilter)
    case bookNotes(bookId: Int64)
}

/// 通用查看器单项身份，保证分页选择与详情查询使用统一 ID。
enum ContentViewerItemID: Hashable, Identifiable {
    case note(Int64)
    case review(Int64)
    case relevant(Int64)

    var id: Self { self }
}

/// 通用查看器分页列表项，只保留分页切换与头部展示所需字段。
struct ContentViewerListItem: Hashable, Identifiable {
    let id: ContentViewerItemID
    let sourceBookId: Int64
    let bookTitle: String
    let timestamp: Int64
}

/// 通用查看器单页详情。
enum ContentViewerDetail: Equatable, Identifiable {
    case note(NoteContentDetail)
    case review(ReviewContentDetail)
    case relevant(RelevantContentDetail)

    var id: ContentViewerItemID {
        switch self {
        case .note(let detail):
            .note(detail.noteId)
        case .review(let detail):
            .review(detail.reviewId)
        case .relevant(let detail):
            .relevant(detail.contentId)
        }
    }

    var itemID: ContentViewerItemID { id }

    var sourceBookId: Int64 {
        switch self {
        case .note(let detail):
            detail.sourceBookId
        case .review(let detail):
            detail.sourceBookId
        case .relevant(let detail):
            detail.sourceBookId
        }
    }

    var bookTitle: String {
        switch self {
        case .note(let detail):
            detail.bookTitle
        case .review(let detail):
            detail.bookTitle
        case .relevant(let detail):
            detail.bookTitle
        }
    }
}

/// 书摘详情，承载查看页完整展示字段。
struct NoteContentDetail: Equatable {
    let noteId: Int64
    let sourceBookId: Int64
    let bookTitle: String
    let chapterTitle: String
    let contentHTML: String
    let ideaHTML: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64
    let imageURLs: [String]
    let tagNames: [String]
}

/// 书评详情，承载查看页完整展示字段。
struct ReviewContentDetail: Equatable {
    let reviewId: Int64
    let sourceBookId: Int64
    let bookTitle: String
    let title: String
    let contentHTML: String
    let createdDate: Int64
    let bookScore: Int64
    let imageURLs: [String]
}

/// 相关内容详情，承载查看页完整展示字段。
struct RelevantContentDetail: Equatable {
    let contentId: Int64
    let sourceBookId: Int64
    let categoryId: Int64
    let bookTitle: String
    let categoryTitle: String
    let title: String
    let contentHTML: String
    let url: String
    let createdDate: Int64
    let imageURLs: [String]
}

/// 书评编辑草稿。
struct ReviewEditorDraft: Equatable {
    let reviewId: Int64
    let sourceBookId: Int64
    let bookTitle: String
    var title: String
    var contentHTML: String
    let imageURLs: [String]
}

/// 相关内容编辑草稿。
struct RelevantEditorDraft: Equatable {
    let contentId: Int64
    let sourceBookId: Int64
    let categoryId: Int64
    let bookTitle: String
    let categoryTitle: String
    var title: String
    var contentHTML: String
    var url: String
    let imageURLs: [String]
}
