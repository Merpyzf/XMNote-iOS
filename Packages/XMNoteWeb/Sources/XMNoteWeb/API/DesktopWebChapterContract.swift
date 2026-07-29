/**
 * [INPUT]: 依赖 Foundation Codable/Sendable 与 App 注入的章节能力
 * [OUTPUT]: 提供 ChapterController 全部 17 个 API 的章节树、在线目录、导入预览、写入请求与能力端口
 * [POS]: XMNoteWeb 章节公共边界；只表达 Android Web 合同，不依赖 App 数据库、Repository 或 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebChapterFullDto，noteCount 仅代表本章节直接书摘数。
public struct DesktopWebChapterFull: Codable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let order: Int
    public let noteCount: Int
    public let children: [DesktopWebChapterFull]
    public let parentId: Int64
    public let level: Int
    public let pathTitles: [String]
    public let directNoteCount: Int
    public let descendantNoteCount: Int
    public let isStarred: Bool

    public init(
        id: Int64,
        title: String,
        order: Int,
        noteCount: Int,
        children: [DesktopWebChapterFull],
        parentId: Int64,
        level: Int,
        pathTitles: [String],
        directNoteCount: Int,
        descendantNoteCount: Int,
        isStarred: Bool
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.noteCount = noteCount
        self.children = children
        self.parentId = parentId
        self.level = level
        self.pathTitles = pathTitles
        self.directNoteCount = directNoteCount
        self.descendantNoteCount = descendantNoteCount
        self.isStarred = isStarred
    }
}

/// Android WebChapterDto，用于最近章节与星标状态更新结果。
public struct DesktopWebChapter: Codable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let parentTitle: String?
    public let parentId: Int64
    public let level: Int
    public let pathTitles: [String]
    public let isStarred: Bool

    public init(
        id: Int64,
        title: String,
        parentTitle: String?,
        parentId: Int64,
        level: Int,
        pathTitles: [String],
        isStarred: Bool
    ) {
        self.id = id
        self.title = title
        self.parentTitle = parentTitle
        self.parentId = parentId
        self.level = level
        self.pathTitles = pathTitles
        self.isStarred = isStarred
    }
}

/// Android WebBookSimpleDto 的章节星标分组投影。
public struct DesktopWebChapterBook: Codable, Sendable, Equatable {
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

/// Android WebStarredChapterDto，保留祖先 ID、路径与聚合计数。
public struct DesktopWebStarredChapter: Codable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let parentTitle: String?
    public let parentId: Int64
    public let level: Int
    public let pathTitles: [String]
    public let order: Int
    public let noteCount: Int
    public let directNoteCount: Int
    public let descendantNoteCount: Int
    public let updatedTime: Int64
    public let ancestorIds: [Int64]
    public let isStarred: Bool

    public init(
        id: Int64,
        title: String,
        parentTitle: String?,
        parentId: Int64,
        level: Int,
        pathTitles: [String],
        order: Int,
        noteCount: Int,
        directNoteCount: Int,
        descendantNoteCount: Int,
        updatedTime: Int64,
        ancestorIds: [Int64],
        isStarred: Bool
    ) {
        self.id = id
        self.title = title
        self.parentTitle = parentTitle
        self.parentId = parentId
        self.level = level
        self.pathTitles = pathTitles
        self.order = order
        self.noteCount = noteCount
        self.directNoteCount = directNoteCount
        self.descendantNoteCount = descendantNoteCount
        self.updatedTime = updatedTime
        self.ancestorIds = ancestorIds
        self.isStarred = isStarred
    }
}

/// Android WebStarredChapterGroupDto，按最近星标章节更新时间倒序返回。
public struct DesktopWebStarredChapterGroup: Codable, Sendable, Equatable {
    public let book: DesktopWebChapterBook
    public let chapters: [DesktopWebStarredChapter]
    public let chapterCount: Int
    public let noteCount: Int
    public let latestUpdatedTime: Int64

    public init(
        book: DesktopWebChapterBook,
        chapters: [DesktopWebStarredChapter],
        chapterCount: Int,
        noteCount: Int,
        latestUpdatedTime: Int64
    ) {
        self.book = book
        self.chapters = chapters
        self.chapterCount = chapterCount
        self.noteCount = noteCount
        self.latestUpdatedTime = latestUpdatedTime
    }
}

/// 创建单个章节的 Android 请求合同。
public struct DesktopWebChapterCreateRequest: Codable, Sendable, Equatable {
    public let title: String
    public let parentId: Int64?

    public init(title: String, parentId: Int64? = nil) {
        self.title = title
        self.parentId = parentId
    }
}

/// 更新章节标题的 Android 请求合同。
public struct DesktopWebChapterUpdateRequest: Codable, Sendable, Equatable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

/// 更新章节星标状态的 Android 请求合同。
public struct DesktopWebChapterStarredRequest: Codable, Sendable, Equatable {
    public let isStarred: Bool

    public init(isStarred: Bool) {
        self.isStarred = isStarred
    }
}

/// 删除或排序章节的 ID 数组合同。
public struct DesktopWebChapterIDsRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]

    public init(ids: [Int64]) {
        self.ids = ids
    }
}

/// 把章节移动到目标父章节下的 Android 请求合同。
public struct DesktopWebChapterMoveToParentRequest: Codable, Sendable, Equatable {
    public let chapterIds: [Int64]
    public let parentId: Int64

    public init(chapterIds: [Int64], parentId: Int64) {
        self.chapterIds = chapterIds
        self.parentId = parentId
    }
}

/// 把子章节移出到书籍顶层的 Android 请求合同。
public struct DesktopWebChapterMoveOutRequest: Codable, Sendable, Equatable {
    public let chapterIds: [Int64]

    public init(chapterIds: [Int64]) {
        self.chapterIds = chapterIds
    }
}

/// 批量创建同级章节的 Android 请求合同。
public struct DesktopWebChapterBatchCreateRequest: Codable, Sendable, Equatable {
    public let titles: [String]
    public let parentId: Int64?

    public init(titles: [String], parentId: Int64? = nil) {
        self.titles = titles
        self.parentId = parentId
    }
}

/// Android WebChapterResultDto 的写入结果。
public struct DesktopWebChapterResult: Codable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let parentId: Int64
    public let order: Int

    public init(id: Int64, title: String, parentId: Int64, order: Int) {
        self.id = id
        self.title = title
        self.parentId = parentId
        self.order = order
    }
}

/// Android WebChapterBatchResultDto 的批量新增结果。
public struct DesktopWebChapterBatchResult: Codable, Sendable, Equatable {
    public let created: [DesktopWebChapterResult]

    public init(created: [DesktopWebChapterResult]) {
        self.created = created
    }
}

/// Android WebOnlineChapterCandidateDto，保留文渠原始列表字段与目录可用性。
public struct DesktopWebOnlineChapterCandidate: Codable, Sendable, Equatable {
    public let title: String
    public let author: String
    public let publisher: String
    public let pubDate: String
    public let cover: String
    public let doubanId: Int
    public let hasCatalog: Bool

    public init(
        title: String,
        author: String,
        publisher: String,
        pubDate: String,
        cover: String,
        doubanId: Int,
        hasCatalog: Bool
    ) {
        self.title = title
        self.author = author
        self.publisher = publisher
        self.pubDate = pubDate
        self.cover = cover
        self.doubanId = doubanId
        self.hasCatalog = hasCatalog
    }
}

/// Android WebOnlineChapterCatalogDto，source 固定为 wenqu。
public struct DesktopWebOnlineChapterCatalog: Codable, Sendable, Equatable {
    public let doubanId: Int
    public let title: String
    public let catalog: String
    public let source: String

    public init(doubanId: Int, title: String, catalog: String, source: String = "wenqu") {
        self.doubanId = doubanId
        self.title = title
        self.catalog = catalog
        self.source = source
    }
}

/// 目录导入预览的原始文本请求。
public struct DesktopWebChapterImportPreviewRequest: Codable, Sendable, Equatable {
    public let catalog: String

    public init(catalog: String) {
        self.catalog = catalog
    }
}

/// 目录导入提交请求；selectedKeys 使用预览生成的稳定层级键。
public struct DesktopWebChapterImportCommitRequest: Codable, Sendable, Equatable {
    public let catalog: String
    public let selectedKeys: [String]

    public init(catalog: String, selectedKeys: [String]) {
        self.catalog = catalog
        self.selectedKeys = selectedKeys
    }
}

/// Android WebChapterImportNodeDto，递归表达目录导入候选树。
public struct DesktopWebChapterImportNode: Codable, Sendable, Equatable {
    public let key: String
    public let title: String
    public let depth: Int
    public let duplicate: Bool
    public let selected: Bool
    public let children: [DesktopWebChapterImportNode]

    public init(
        key: String,
        title: String,
        depth: Int,
        duplicate: Bool,
        selected: Bool,
        children: [DesktopWebChapterImportNode]
    ) {
        self.key = key
        self.title = title
        self.depth = depth
        self.duplicate = duplicate
        self.selected = selected
        self.children = children
    }
}

/// Android WebChapterImportPreviewDto，计数均基于递归扁平节点集合。
public struct DesktopWebChapterImportPreview: Codable, Sendable, Equatable {
    public let items: [DesktopWebChapterImportNode]
    public let totalCount: Int
    public let selectableCount: Int
    public let duplicateCount: Int
    public let selectedCount: Int

    public init(
        items: [DesktopWebChapterImportNode],
        totalCount: Int,
        selectableCount: Int,
        duplicateCount: Int,
        selectedCount: Int
    ) {
        self.items = items
        self.totalCount = totalCount
        self.selectableCount = selectableCount
        self.duplicateCount = duplicateCount
        self.selectedCount = selectedCount
    }
}

/// Android WebChapterImportCommitResultDto，分别统计创建、跳过和已存在节点。
public struct DesktopWebChapterImportCommitResult: Codable, Sendable, Equatable {
    public let created: Int
    public let skipped: Int
    public let duplicated: Int

    public init(created: Int, skipped: Int, duplicated: Int) {
        self.created = created
        self.skipped = skipped
        self.duplicated = duplicated
    }
}

/// 隔离章节树读写；实现由 App Repository 提供，不向 Package 泄漏 GRDB 或 App 领域模型。
public protocol DesktopWebChapterPort: Sendable {
    func chapters(bookID: Int64) async throws -> [DesktopWebChapterFull]
    func lastUsedChapter(bookID: Int64) async throws -> DesktopWebChapter?
    func starredChapterGroups() async throws -> [DesktopWebStarredChapterGroup]
    func createChapter(bookID: Int64, request: DesktopWebChapterCreateRequest) async throws -> DesktopWebChapterResult
    func updateChapter(id: Int64, request: DesktopWebChapterUpdateRequest) async throws -> DesktopWebChapterResult
    func updateChapterStarred(id: Int64, request: DesktopWebChapterStarredRequest) async throws -> DesktopWebChapter
    func deleteChapter(id: Int64) async throws
    func batchDeleteChapters(_ request: DesktopWebChapterIDsRequest) async throws
    func reorderParentChapters(bookID: Int64, request: DesktopWebChapterIDsRequest) async throws
    func reorderChildChapters(parentID: Int64, request: DesktopWebChapterIDsRequest) async throws
    func moveChaptersToParent(_ request: DesktopWebChapterMoveToParentRequest) async throws
    func moveChaptersOut(_ request: DesktopWebChapterMoveOutRequest) async throws
    func batchCreateChapters(bookID: Int64, request: DesktopWebChapterBatchCreateRequest) async throws -> DesktopWebChapterBatchResult
    func searchOnlineChapterCandidates(
        bookID: Int64,
        keyword: String
    ) async throws -> [DesktopWebOnlineChapterCandidate]
    func onlineChapterCatalog(bookID: Int64, doubanID: Int?) async throws -> DesktopWebOnlineChapterCatalog
    func previewChapterImport(
        bookID: Int64,
        request: DesktopWebChapterImportPreviewRequest
    ) async throws -> DesktopWebChapterImportPreview
    func commitChapterImport(
        bookID: Int64,
        request: DesktopWebChapterImportCommitRequest
    ) async throws -> DesktopWebChapterImportCommitResult
}
