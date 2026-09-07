/**
 * [INPUT]: 依赖 Foundation Data 与 App 注入的外部服务、导入导出和对象存储能力端口
 * [OUTPUT]: 提供 AI、在线书籍、封面代理、导入导出及图片上传的跨平台契约，并区分书摘与书籍信息导出请求
 * [POS]: XMNoteWeb 外部与文件类业务边界；不公开 Hummingbird、URLSession、数据库或 App 类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 表达透明代理的缓冲或流式字节，SSE 不因跨模块边界退化为整包响应。
public enum DesktopWebRawHTTPBody: Sendable {
    case data(Data)
    case stream(AsyncThrowingStream<Data, any Error>)
}

/// 表达透明代理或二进制端点的完整 HTTP 结果，避免公开服务器框架类型。
public struct DesktopWebRawHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: DesktopWebRawHTTPBody

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = .data(body)
    }

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        stream: AsyncThrowingStream<Data, any Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = .stream(stream)
    }
}

/// 承载已从 multipart 中安全提取的单个上传文件。
public struct DesktopWebUploadedFile: Sendable, Equatable {
    public let fileName: String
    public let contentType: String?
    public let data: Data

    public init(fileName: String, contentType: String?, data: Data) {
        self.fileName = fileName
        self.contentType = contentType
        self.data = data
    }
}

/// 隔离 AI 设置持久化与上游网络代理。
public protocol DesktopWebAIPort: Sendable {
    func aiConfig() async throws -> DesktopWebJSONValue
    func updateAIConfig(_ patch: DesktopWebJSONValue) async throws
    func chatCompletions(body: Data) async throws -> DesktopWebRawHTTPResponse
}

/// Android Wenqu 搜索结果的稳定 Web 表达。
public struct DesktopWebOnlineBook: Codable, Sendable, Equatable {
    public let title: String
    public let author: String
    public let publisher: String
    public let pubDate: String
    public let cover: String
    public let isbn: String
    public let summary: String
    public let authorIntro: String
    public let catalog: String

    public init(
        title: String,
        author: String,
        publisher: String,
        pubDate: String,
        cover: String,
        isbn: String,
        summary: String,
        authorIntro: String,
        catalog: String
    ) {
        self.title = title
        self.author = author
        self.publisher = publisher
        self.pubDate = pubDate
        self.cover = cover
        self.isbn = isbn
        self.summary = summary
        self.authorIntro = authorIntro
        self.catalog = catalog
    }
}

public protocol DesktopWebOnlineBookPort: Sendable {
    func searchOnlineBooks(keyword: String) async throws -> [DesktopWebOnlineBook]
}

public protocol DesktopWebBookCoverPort: Sendable {
    func proxiedBookCover(bookID: Int64, expires: Int64?, signature: String?) async throws -> DesktopWebRawHTTPResponse
}

public struct DesktopWebExportPlatformOption: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DesktopWebExportContentSelection: Codable, Sendable, Equatable {
    public let note: Bool
    public let relevant: Bool
    public let review: Bool

    public init(note: Bool = true, relevant: Bool = true, review: Bool = true) {
        self.note = note
        self.relevant = relevant
        self.review = review
    }
}

public struct DesktopWebNoteExportRequest: Codable, Sendable, Equatable {
    public let bookIds: [Int64]
    public let target: String
    public let content: DesktopWebExportContentSelection

    public init(
        bookIds: [Int64] = [],
        target: String = "",
        content: DesktopWebExportContentSelection = .init()
    ) {
        self.bookIds = bookIds
        self.target = target
        self.content = content
    }
}

/// 书籍信息导出请求只携带稳定书籍顺序与 CSV/Notion 目标，不复用书摘内容开关。
public struct DesktopWebBookExportRequest: Codable, Sendable, Equatable {
    public let bookIds: [Int64]
    public let target: String

    public init(bookIds: [Int64] = [], target: String = "") {
        self.bookIds = bookIds
        self.target = target
    }
}

public struct DesktopWebExportFile: Sendable, Equatable {
    public let fileName: String
    public let mediaType: String
    public let data: Data

    public init(fileName: String, mediaType: String, data: Data) {
        self.fileName = fileName
        self.mediaType = mediaType
        self.data = data
    }
}

public struct DesktopWebRemoteExportFailedItem: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let bookName: String
    public let reason: String

    public init(bookId: Int64, bookName: String, reason: String) {
        self.bookId = bookId
        self.bookName = bookName
        self.reason = reason
    }
}

public struct DesktopWebRemoteExportResult: Codable, Sendable, Equatable {
    public let total: Int
    public let successCount: Int
    public let failCount: Int
    public let failedItems: [DesktopWebRemoteExportFailedItem]

    public init(total: Int, successCount: Int, failCount: Int, failedItems: [DesktopWebRemoteExportFailedItem]) {
        self.total = total
        self.successCount = successCount
        self.failCount = failCount
        self.failedItems = failedItems
    }
}

public protocol DesktopWebExportPort: Sendable {
    func siYuanNotebooks() async throws -> [DesktopWebExportPlatformOption]
    func obsidianDirectories() async throws -> [DesktopWebExportPlatformOption]
    func exportNotesLocally(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebExportFile
    func exportNotesRemotely(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebRemoteExportResult
    func exportBooksLocally(_ request: DesktopWebBookExportRequest) async throws -> DesktopWebExportFile
    func exportBooksRemotely(_ request: DesktopWebBookExportRequest) async throws -> DesktopWebRemoteExportResult
}

public extension DesktopWebExportPort {
    /// 兼容尚未升级的宿主实现；生产 XMNote Adapter 已覆盖该方法，其他宿主会收到明确未实现错误。
    func exportBooksLocally(_ request: DesktopWebBookExportRequest) async throws -> DesktopWebExportFile {
        throw DesktopWebAPIError(code: 50_001, message: "当前宿主尚未提供书籍信息本地导出")
    }

    /// 兼容尚未升级的宿主实现；生产 XMNote Adapter 已覆盖该方法，其他宿主会收到明确未实现错误。
    func exportBooksRemotely(_ request: DesktopWebBookExportRequest) async throws -> DesktopWebRemoteExportResult {
        throw DesktopWebAPIError(code: 50_001, message: "当前宿主尚未提供书籍信息远端导出")
    }
}

public struct DesktopWebImportTaskCreateResponse: Codable, Sendable, Equatable {
    public let taskId: String
    public let status: String
    public let message: String?

    public init(taskId: String, status: String, message: String? = nil) {
        self.taskId = taskId
        self.status = status
        self.message = message
    }
}

public struct DesktopWebImportTaskCommitBook: Codable, Sendable, Equatable {
    public let index: Int
    public let noteIndexes: [Int]
    public let targetBookId: Int64?
    public let clearTargetBook: Bool

    public init(index: Int, noteIndexes: [Int], targetBookId: Int64? = nil, clearTargetBook: Bool = false) {
        self.index = index
        self.noteIndexes = noteIndexes
        self.targetBookId = targetBookId
        self.clearTargetBook = clearTargetBook
    }
}

public struct DesktopWebImportTaskCommitRequest: Codable, Sendable, Equatable {
    public let books: [DesktopWebImportTaskCommitBook]

    public init(books: [DesktopWebImportTaskCommitBook]) {
        self.books = books
    }
}

public struct DesktopWebImportTaskCommitResponse: Codable, Sendable, Equatable {
    public let importedBookCount: Int
    public let importedNoteCount: Int

    public init(importedBookCount: Int, importedNoteCount: Int) {
        self.importedBookCount = importedBookCount
        self.importedNoteCount = importedNoteCount
    }
}

public protocol DesktopWebImportPort: Sendable {
    func createImportTask(file: DesktopWebUploadedFile) async throws -> DesktopWebImportTaskCreateResponse
    func importTask(id: String) async throws -> DesktopWebJSONValue
    func commitImportTask(id: String, request: DesktopWebImportTaskCommitRequest) async throws -> DesktopWebImportTaskCommitResponse
    func deleteImportTask(id: String) async throws
}

public struct DesktopWebUploadTicketReserveRequest: Codable, Sendable, Equatable {
    public let count: Int

    public init(count: Int = 1) {
        self.count = count
    }
}

public struct DesktopWebUploadTicketReleaseRequest: Codable, Sendable, Equatable {
    public let ticketIds: [String]

    public init(ticketIds: [String] = []) {
        self.ticketIds = ticketIds
    }
}

public struct DesktopWebUploadTicket: Codable, Sendable, Equatable {
    public let ticketId: String
    public let expiresAt: Int64

    public init(ticketId: String, expiresAt: Int64) {
        self.ticketId = ticketId
        self.expiresAt = expiresAt
    }
}

public struct DesktopWebUploadTicketReserveResult: Codable, Sendable, Equatable {
    public let tickets: [DesktopWebUploadTicket]
    public let remaining: Int?

    public init(tickets: [DesktopWebUploadTicket], remaining: Int? = nil) {
        self.tickets = tickets
        self.remaining = remaining
    }
}

public struct DesktopWebNoteImageUploadResult: Codable, Sendable, Equatable {
    public let url: String
    public let ticketId: String
    public let expiresAt: Int64

    public init(url: String, ticketId: String, expiresAt: Int64) {
        self.url = url
        self.ticketId = ticketId
        self.expiresAt = expiresAt
    }
}

public struct DesktopWebBookCoverUploadResult: Codable, Sendable, Equatable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

public protocol DesktopWebUploadPort: Sendable {
    func reserveNoteImageTickets(count: Int) async throws -> DesktopWebUploadTicketReserveResult
    func uploadNoteImage(ticketID: String, file: DesktopWebUploadedFile) async throws -> DesktopWebNoteImageUploadResult
    func releaseNoteImageTickets(_ ticketIDs: [String]) async throws
    func uploadBookCover(file: DesktopWebUploadedFile) async throws -> DesktopWebBookCoverUploadResult
}
