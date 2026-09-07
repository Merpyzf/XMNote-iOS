/**
 * [INPUT]: 依赖 Foundation 提供标识、时间戳与 URL 等跨层基础类型
 * [OUTPUT]: 对外提供 ContentViewerSourceContext、ContentViewerItemID/ListItem/Detail、编辑模式、相关书籍草稿及含图片额度票据的内容编辑草稿
 * [POS]: Domain/Models 的通用内容查看领域模型，供 Repository、ViewModel 与 Viewer/Editor 页面共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 时间线内容查看过滤器，只承接可进入通用查看器的三类内容。
nonisolated enum TimelineContentFilter: Hashable, Sendable, Codable {
    case allContent
    case note
    case review
    case relevant
}

/// 通用内容查看器的数据来源上下文。
nonisolated enum ContentViewerSourceContext: Hashable, Sendable, Codable {
    case timeline(startTimestamp: Int64, endTimestamp: Int64, filter: TimelineContentFilter)
    case bookNotes(bookId: Int64)
    case noteReview(noteIDs: [Int64])
    case noteReviewDirectory(NoteReviewDirectoryReference)
    case noteExcerpts(
        scope: NoteExcerptScope,
        query: String,
        sort: NoteExcerptSortRule,
        randomSeed: Int64
    )
    case chapterNotes(
        bookID: Int64,
        chapterID: Int64,
        includeDescendants: Bool,
        query: String,
        sort: NoteExcerptSortRule,
        randomSeed: Int64
    )
    case relatedCategory(
        scope: RelatedCategoryScope,
        query: String,
        sort: RelatedContentSortRule,
        randomSeed: Int64
    )
    case allReviews(query: String, sort: BookReviewSortRule)
    case bookRelated(bookId: Int64)
    case bookReviews(bookId: Int64)
}

/// 通用查看器单项身份，保证分页选择与详情查询使用统一 ID。
nonisolated enum ContentViewerItemID: Hashable, Identifiable, Sendable, Codable {
    case note(Int64)
    case review(Int64)
    case relevant(Int64)

    var id: Self { self }
}

/// 通用查看器分页列表项，只保留分页切换与头部展示所需字段。
nonisolated struct ContentViewerListItem: Hashable, Identifiable, Sendable {
    let id: ContentViewerItemID
    let sourceBookId: Int64
    let bookTitle: String
    let timestamp: Int64
}

/// 通用查看器单页详情。
nonisolated enum ContentViewerDetail: Equatable, Identifiable, Sendable {
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
nonisolated struct NoteContentDetail: Equatable, Sendable {
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
    let weReadOriginalURL: String?
}

/// 微信读书原文深链构造器，作为书摘回顾与普通查看器共享的 Android `WeReadUrlSchema` 业务规则。
nonisolated enum WeReadOriginalURLBuilder {
    private static let chapterSourceType: Int64 = 1

    /// 仅在书籍 ID、微信读书章节来源与合法划线范围同时存在时生成 bestbookmark 深链。
    static func build(
        bookID: String,
        chapterSourceType: Int64,
        chapterUID: String,
        range: String
    ) -> String? {
        guard chapterSourceType == Self.chapterSourceType else { return nil }

        let normalizedBookID = bookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBookID.isEmpty else { return nil }

        let normalizedChapterUID = chapterUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chapterUIDValue = Int64(normalizedChapterUID), chapterUIDValue > 0 else { return nil }
        guard let rangeBounds = parseRange(range) else { return nil }

        return "weread://bestbookmark?bookId=\(normalizedBookID)"
            + "&chapterUid=\(normalizedChapterUID)"
            + "&rangeStart=\(rangeBounds.start)"
            + "&rangeEnd=\(rangeBounds.end)"
    }

    /// 解析 Android `note.weread_range` 的 `start-end`，拒绝负起点、空范围与逆序范围。
    private static func parseRange(_ range: String) -> (start: Int64, end: Int64)? {
        let parts = range.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "-")
        guard parts.count == 2 else { return nil }

        let startText = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let endText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = Int64(startText), let end = Int64(endText) else { return nil }
        guard start >= 0, end > start else { return nil }

        return (start, end)
    }
}

/// 书评详情，承载查看页完整展示字段。
nonisolated struct ReviewContentDetail: Equatable, Sendable {
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
nonisolated struct RelevantContentDetail: Equatable, Sendable {
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

/// 书评编辑入口模式；新建时由所属书籍建立业务上下文，编辑时由书评主键定位。
nonisolated enum ReviewEditorMode: Hashable, Sendable, Codable {
    case create(bookID: Int64)
    case edit(reviewID: Int64)

    var isCreating: Bool {
        if case .create = self { return true }
        return false
    }
}

/// 相关内容编辑入口模式；新建时携带书籍与分类，编辑时由内容主键定位。
nonisolated enum RelevantEditorMode: Hashable, Sendable, Codable {
    case create(bookID: Int64, categoryID: Int64)
    case edit(contentID: Int64)

    var isCreating: Bool {
        if case .create = self { return true }
        return false
    }
}

/// 内容编辑器附图上传状态，统一承接上传等待、成功与可重试失败语义。
nonisolated enum ContentEditorImageUploadState: String, Equatable, Sendable, Codable {
    case uploading
    case success
    case failed
}

/// 书评与相关内容编辑器共享的附图条目，保留稳定身份、本地预览与最终远端地址。
nonisolated struct ContentEditorImageItem: Identifiable, Equatable, Sendable, Codable {
    static let maximumCount = 9

    let id: String
    var remoteURL: String?
    var localFilePath: String?
    var uploadState: ContentEditorImageUploadState
    var origin: EditorImageOrigin

    /// 建立书评/相关编辑图片，并显式保留其是否仍属于未保存新图。
    init(
        id: String,
        remoteURL: String?,
        localFilePath: String?,
        uploadState: ContentEditorImageUploadState,
        origin: EditorImageOrigin
    ) {
        self.id = id
        self.remoteURL = remoteURL
        self.localFilePath = localFilePath
        self.uploadState = uploadState
        self.origin = origin
    }

    /// 将既有数据库图片映射为无需再次上传的成功条目。
    static func existing(id: String, remoteURL: String) -> ContentEditorImageItem {
        ContentEditorImageItem(
            id: id,
            remoteURL: remoteURL,
            localFilePath: nil,
            uploadState: .success,
            origin: .persisted
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case remoteURL
        case localFilePath
        case uploadState
        case origin
    }

    /// 解码自动草稿；旧格式仅在仍有本地缓存时判为新图，避免通过 UUID 或 URL 命名猜测来源。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
        localFilePath = try container.decodeIfPresent(String.self, forKey: .localFilePath)
        uploadState = try container.decode(ContentEditorImageUploadState.self, forKey: .uploadState)
        origin = try container.decodeIfPresent(EditorImageOrigin.self, forKey: .origin)
            ?? (localFilePath?.isEmpty == false ? .newInDraft : .persisted)
    }

    /// 编码自动草稿时持久化明确来源，使上传成功且已清理缓存的新图仍会占用当前草稿额度。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try container.encodeIfPresent(localFilePath, forKey: .localFilePath)
        try container.encode(uploadState, forKey: .uploadState)
        try container.encode(origin, forKey: .origin)
    }
}

/// 书评编辑自动保存快照，以书籍与书评主键组合隔离新建、编辑草稿。
nonisolated struct ReviewEditorAutoSaveDraft: Equatable, Sendable, Codable {
    let sourceBookId: Int64
    let reviewId: Int64
    var title: String
    var contentHTML: String
    var imageItems: [ContentEditorImageItem]
    let savedTime: Int64
    var imageQuotaReservationID: String? = nil

    /// 严格核验持久化身份，阻止 Android 兼容回退查询把新建草稿恢复到编辑场景。
    func matches(sourceBookId: Int64, reviewId: Int64) -> Bool {
        self.sourceBookId == sourceBookId && self.reviewId == reviewId
    }
}

/// 相关内容编辑自动保存快照，以书籍、分类与内容主键组合隔离所有编辑上下文。
nonisolated struct RelevantEditorAutoSaveDraft: Equatable, Sendable, Codable {
    let sourceBookId: Int64
    let categoryId: Int64
    let contentId: Int64
    var title: String
    var contentHTML: String
    var url: String
    var imageItems: [ContentEditorImageItem]
    let savedTime: Int64
    var imageQuotaReservationID: String? = nil

    /// 严格核验持久化身份，避免跨书、跨分类或新建/编辑草稿串用。
    func matches(sourceBookId: Int64, categoryId: Int64, contentId: Int64) -> Bool {
        self.sourceBookId == sourceBookId &&
            self.categoryId == categoryId &&
            self.contentId == contentId
    }
}

/// 书评编辑草稿。
nonisolated struct ReviewEditorDraft: Equatable, Sendable {
    let reviewId: Int64
    let sourceBookId: Int64
    let bookTitle: String
    var title: String
    var contentHTML: String
    var imageItems: [ContentEditorImageItem]

    /// 返回可持久化的成功图片地址，并保持当前拖拽顺序。
    var imageURLs: [String] {
        imageItems.compactMap { item in
            guard item.uploadState == .success else { return nil }
            let value = item.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }
}

/// 相关内容编辑草稿。
nonisolated struct RelevantEditorDraft: Equatable, Sendable {
    let contentId: Int64
    let sourceBookId: Int64
    let categoryId: Int64
    let bookTitle: String
    let categoryTitle: String
    var title: String
    var contentHTML: String
    var url: String
    var imageItems: [ContentEditorImageItem]

    /// 返回可持久化的成功图片地址，并保持当前拖拽顺序。
    var imageURLs: [String] {
        imageItems.compactMap { item in
            guard item.uploadState == .success else { return nil }
            let value = item.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }
}

/// 相关书籍编辑草稿，只允许更换关联目标书，分类由 Android 业务常量固定为“书籍”。
nonisolated struct RelatedBookRelationDraft: Identifiable, Hashable, Sendable {
    let id: Int64
    let sourceBookID: Int64
    var contentBook: BookPickerBook
}
