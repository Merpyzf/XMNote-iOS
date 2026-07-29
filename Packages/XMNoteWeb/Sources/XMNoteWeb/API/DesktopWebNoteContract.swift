/**
 * [INPUT]: 依赖 Foundation Codable/Sendable、共享分页模型与章节 DTO
 * [OUTPUT]: 提供 NoteController 15 个 API 的列表、筛选、CRUD、批量操作、合并请求与能力端口
 * [POS]: XMNoteWeb 书摘公共边界；只表达 Android Web 合同，不依赖 App 数据库、Repository 或 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebTagDto 的书摘轻量投影。
public struct DesktopWebNoteTag: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// Android WebAttachImageDto；写接口响应中的 ID 可能是从零开始的临时下标。
public struct DesktopWebNoteImage: Codable, Sendable, Equatable {
    public let id: Int64
    public let url: String

    public init(id: Int64, url: String) {
        self.id = id
        self.url = url
    }
}

/// Android WebBookSimpleDto 的全局书摘投影。
public struct DesktopWebNoteBook: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let cover: String
    public let author: String
    public let press: String

    public init(id: Int64, name: String, cover: String, author: String, press: String) {
        self.id = id
        self.name = name
        self.cover = cover
        self.author = author
        self.press = press
    }
}

/// Android WebBookNoteDto，用于书内列表与单条详情。
public struct DesktopWebBookNote: Codable, Sendable, Equatable {
    public let id: Int64
    public let content: String
    public let idea: String?
    public let position: String?
    public let positionUnit: Int
    public let isIncludeTime: Bool
    public let createdTime: Int64
    public let updatedTime: Int64
    public let chapter: DesktopWebChapter?
    public let tags: [DesktopWebNoteTag]
    public let images: [DesktopWebNoteImage]

    public init(
        id: Int64,
        content: String,
        idea: String?,
        position: String?,
        positionUnit: Int,
        isIncludeTime: Bool,
        createdTime: Int64,
        updatedTime: Int64,
        chapter: DesktopWebChapter?,
        tags: [DesktopWebNoteTag],
        images: [DesktopWebNoteImage]
    ) {
        self.id = id
        self.content = content
        self.idea = idea
        self.position = position
        self.positionUnit = positionUnit
        self.isIncludeTime = isIncludeTime
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.chapter = chapter
        self.tags = tags
        self.images = images
    }
}

/// 书内筛选后的章节书摘数量。
public struct DesktopWebBookNoteChapterCount: Codable, Sendable, Equatable {
    public let chapterId: Int64
    public let noteCount: Int

    public init(chapterId: Int64, noteCount: Int) {
        self.chapterId = chapterId
        self.noteCount = noteCount
    }
}

/// Android WebBookNotesPageDto。
public struct DesktopWebBookNotesPage: Codable, Sendable, Equatable {
    public let items: [DesktopWebBookNote]
    public let pagination: DesktopWebPagination
    public let chapterNoteCounts: [DesktopWebBookNoteChapterCount]

    public init(
        items: [DesktopWebBookNote],
        pagination: DesktopWebPagination,
        chapterNoteCounts: [DesktopWebBookNoteChapterCount]
    ) {
        self.items = items
        self.pagination = pagination
        self.chapterNoteCounts = chapterNoteCounts
    }
}

/// Android WebGlobalNoteDto。
public struct DesktopWebGlobalNote: Codable, Sendable, Equatable {
    public let id: Int64
    public let content: String
    public let idea: String?
    public let position: String?
    public let positionUnit: Int
    public let createdTime: Int64
    public let updatedTime: Int64
    public let isIncludeTime: Bool
    public let chapter: DesktopWebChapter?
    public let tags: [DesktopWebNoteTag]
    public let images: [DesktopWebNoteImage]
    public let book: DesktopWebNoteBook

    public init(
        id: Int64,
        content: String,
        idea: String?,
        position: String?,
        positionUnit: Int,
        createdTime: Int64,
        updatedTime: Int64,
        isIncludeTime: Bool,
        chapter: DesktopWebChapter?,
        tags: [DesktopWebNoteTag],
        images: [DesktopWebNoteImage],
        book: DesktopWebNoteBook
    ) {
        self.id = id
        self.content = content
        self.idea = idea
        self.position = position
        self.positionUnit = positionUnit
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.isIncludeTime = isIncludeTime
        self.chapter = chapter
        self.tags = tags
        self.images = images
        self.book = book
    }
}

/// 默认与自定义书摘标签筛选项。
public struct DesktopWebNoteTagFilter: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let noteCount: Int
    public let section: String

    public init(id: Int64, name: String, noteCount: Int, section: String) {
        self.id = id
        self.name = name
        self.noteCount = noteCount
        self.section = section
    }
}

/// 书摘排序设置。
public struct DesktopWebNoteSortRule: Codable, Sendable, Equatable {
    public let sortBy: String
    public let sortOrder: String

    public init(sortBy: String, sortOrder: String) {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

/// 更新书摘排序设置的 Android 请求。
public struct DesktopWebNoteSortRuleUpdateRequest: Codable, Sendable, Equatable {
    public let sortBy: String
    public let sortOrder: String

    public init(sortBy: String = "create_time", sortOrder: String = "desc") {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

/// 书内列表筛选；路由已应用 Android 参数默认值、去重和正数过滤。
public struct DesktopWebBookNoteFilter: Sendable, Equatable {
    public let chapterID: Int64
    public let tagID: Int64
    public let tagIDs: [Int64]
    public let tagMode: String
    public let sortBy: String
    public let sortOrder: String

    public init(
        chapterID: Int64,
        tagID: Int64,
        tagIDs: [Int64],
        tagMode: String,
        sortBy: String,
        sortOrder: String
    ) {
        self.chapterID = chapterID
        self.tagID = tagID
        self.tagIDs = tagIDs
        self.tagMode = tagMode
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

/// 全局书摘筛选；Repository 负责 Android 的二次正数过滤与随机排除语义。
public struct DesktopWebGlobalNoteFilter: Sendable, Equatable {
    public let keyword: String
    public let bookID: Int64
    public let bookIDs: [Int64]
    public let tagID: Int64
    public let tagIDs: [Int64]
    public let tagMode: String
    public let sortBy: String
    public let sortOrder: String
    public let sortMode: String
    public let excludeIDs: [Int64]

    public init(
        keyword: String,
        bookID: Int64,
        bookIDs: [Int64],
        tagID: Int64,
        tagIDs: [Int64],
        tagMode: String,
        sortBy: String,
        sortOrder: String,
        sortMode: String,
        excludeIDs: [Int64]
    ) {
        self.keyword = keyword
        self.bookID = bookID
        self.bookIDs = bookIDs
        self.tagID = tagID
        self.tagIDs = tagIDs
        self.tagMode = tagMode
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.sortMode = sortMode
        self.excludeIDs = excludeIDs
    }
}

/// 创建书摘请求；nil 与空数组按 Android 各字段规则分别解释。
public struct DesktopWebNoteCreateRequest: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let chapterId: Int64?
    public let content: String?
    public let idea: String?
    public let position: String?
    public let tagIds: [Int64]?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let createdTime: Int64?

    public init(
        bookId: Int64,
        chapterId: Int64? = nil,
        content: String? = nil,
        idea: String? = nil,
        position: String? = nil,
        tagIds: [Int64]? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        createdTime: Int64? = nil
    ) {
        self.bookId = bookId
        self.chapterId = chapterId
        self.content = content
        self.idea = idea
        self.position = position
        self.tagIds = tagIds
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.createdTime = createdTime
    }
}

/// 局部更新书摘请求；nil 表示保留现值，空数组表示清空关系。
public struct DesktopWebNoteUpdateRequest: Codable, Sendable, Equatable {
    public let bookId: Int64?
    public let chapterId: Int64?
    public let content: String?
    public let idea: String?
    public let position: String?
    public let tagIds: [Int64]?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let createdTime: Int64?

    public init(
        bookId: Int64? = nil,
        chapterId: Int64? = nil,
        content: String? = nil,
        idea: String? = nil,
        position: String? = nil,
        tagIds: [Int64]? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        createdTime: Int64? = nil
    ) {
        self.bookId = bookId
        self.chapterId = chapterId
        self.content = content
        self.idea = idea
        self.position = position
        self.tagIds = tagIds
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.createdTime = createdTime
    }
}

/// 仅包含书摘 ID 数组的批量请求。
public struct DesktopWebNoteIDsRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]

    public init(ids: [Int64]) {
        self.ids = ids
    }
}

/// 批量移动到章节；chapterId=0 表示未分类。
public struct DesktopWebNoteBatchMoveChapterRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let chapterId: Int64

    public init(ids: [Int64], chapterId: Int64) {
        self.ids = ids
        self.chapterId = chapterId
    }
}

/// 批量追加或替换标签。
public struct DesktopWebNoteBatchSetTagsRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let tagIds: [Int64]
    public let mode: String

    public init(ids: [Int64], tagIds: [Int64], mode: String = "append") {
        self.ids = ids
        self.tagIds = tagIds
        self.mode = mode
    }
}

/// 批量移动到目标书籍。
public struct DesktopWebNoteBatchMoveBookRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let targetBookId: Int64

    public init(ids: [Int64], targetBookId: Int64) {
        self.ids = ids
        self.targetBookId = targetBookId
    }
}

/// 合并结果的可选前端草稿。
public struct DesktopWebNoteMergeDraftRequest: Codable, Sendable, Equatable {
    public let content: String?
    public let idea: String?
    public let position: String?
    public let positionUnit: Int?
    public let chapterId: Int64?
    public let tagIds: [Int64]?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let createdTime: Int64?

    public init(
        content: String? = nil,
        idea: String? = nil,
        position: String? = nil,
        positionUnit: Int? = nil,
        chapterId: Int64? = nil,
        tagIds: [Int64]? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        createdTime: Int64? = nil
    ) {
        self.content = content
        self.idea = idea
        self.position = position
        self.positionUnit = positionUnit
        self.chapterId = chapterId
        self.tagIds = tagIds
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.createdTime = createdTime
    }
}

/// Android NoteBatchMergeRequest，分别控制正文和想法顺序及连接规则。
public struct DesktopWebNoteBatchMergeRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let contentOrderedIds: [Int64]?
    public let ideaOrderedIds: [Int64]?
    public let orderedIds: [Int64]?
    public let contentMergeRule: String?
    public let ideaMergeRule: String?
    public let merged: DesktopWebNoteMergeDraftRequest?

    public init(
        ids: [Int64],
        contentOrderedIds: [Int64]? = nil,
        ideaOrderedIds: [Int64]? = nil,
        orderedIds: [Int64]? = nil,
        contentMergeRule: String? = "new_one_line",
        ideaMergeRule: String? = "new_one_line",
        merged: DesktopWebNoteMergeDraftRequest? = nil
    ) {
        self.ids = ids
        self.contentOrderedIds = contentOrderedIds
        self.ideaOrderedIds = ideaOrderedIds
        self.orderedIds = orderedIds
        self.contentMergeRule = contentMergeRule
        self.ideaMergeRule = ideaMergeRule
        self.merged = merged
    }
}

/// Android WebNoteResultDto；图片 ID 保留 Android 写响应的临时下标语义。
public struct DesktopWebNoteResult: Codable, Sendable, Equatable {
    public let id: Int64
    public let bookId: Int64
    public let chapterId: Int64
    public let content: String
    public let idea: String?
    public let position: String?
    public let positionUnit: Int
    public let createdTime: Int64
    public let updatedTime: Int64
    public let tags: [DesktopWebNoteTag]
    public let images: [DesktopWebNoteImage]

    public init(
        id: Int64,
        bookId: Int64,
        chapterId: Int64,
        content: String,
        idea: String?,
        position: String?,
        positionUnit: Int,
        createdTime: Int64,
        updatedTime: Int64,
        tags: [DesktopWebNoteTag],
        images: [DesktopWebNoteImage]
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterId = chapterId
        self.content = content
        self.idea = idea
        self.position = position
        self.positionUnit = positionUnit
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.tags = tags
        self.images = images
    }
}

/// 隔离书摘查询、CRUD 与批量业务；路由只负责 HTTP 参数和 Android 包络。
public protocol DesktopWebNotePort: Sendable {
    func bookNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookNoteFilter
    ) async throws -> DesktopWebBookNotesPage

    func bookNoteTagFilters(bookID: Int64) async throws -> [DesktopWebNoteTagFilter]
    func bookNoteSortRule(bookID: Int64) async throws -> DesktopWebNoteSortRule
    func updateBookNoteSortRule(
        bookID: Int64,
        request: DesktopWebNoteSortRuleUpdateRequest
    ) async throws -> DesktopWebNoteSortRule

    func globalNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalNote>

    func globalNoteTagFilters() async throws -> [DesktopWebNoteTagFilter]
    func note(id: Int64) async throws -> DesktopWebBookNote
    func createNote(_ request: DesktopWebNoteCreateRequest) async throws -> DesktopWebNoteResult
    func updateNote(id: Int64, request: DesktopWebNoteUpdateRequest) async throws -> DesktopWebNoteResult
    func deleteNote(id: Int64) async throws
    func batchDeleteNotes(_ request: DesktopWebNoteIDsRequest) async throws
    func batchMoveNotesToChapter(_ request: DesktopWebNoteBatchMoveChapterRequest) async throws
    func batchSetNoteTags(_ request: DesktopWebNoteBatchSetTagsRequest) async throws
    func batchMoveNotesToBook(_ request: DesktopWebNoteBatchMoveBookRequest) async throws
    func batchMergeNotes(_ request: DesktopWebNoteBatchMergeRequest) async throws -> DesktopWebNoteResult
}
