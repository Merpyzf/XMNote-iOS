/**
 * [INPUT]: 依赖 Foundation，承接微信读书授权、远端书籍、目录、书摘、书评、阅读时长与导入选择状态
 * [OUTPUT]: 对外提供 WereadImportPreferences、WereadImportBook、WereadImportBatch 等导入领域模型
 * [POS]: Domain/Models 的微信读书扫码授权导入模型，被 Repository、ViewModel 与页面共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct WereadImportPreferences: Equatable, Sendable {
    var recentBookCount: Int
    var importsReadingTime: Bool
    var onlyBooksWithNotes: Bool
    var showsUsageTips: Bool

    static let `default` = WereadImportPreferences(
        recentBookCount: -1,
        importsReadingTime: false,
        onlyBooksWithNotes: false,
        showsUsageTips: true
    )
}

nonisolated struct WereadAuthorization: Equatable, Sendable {
    let cookieHeader: String
    let userID: String
}

nonisolated enum WereadQRCodePhase: Equatable, Sendable {
    case loading
    case available
    case expired
    case failed(message: String)
    case authorized
}

nonisolated struct WereadImportNote: Identifiable, Hashable, Sendable {
    let id: UUID
    var content: String
    var idea: String
    var range: String
    var chapterUID: Int64
    var chapterID: Int64
    var createdAt: Int64
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        content: String,
        idea: String = "",
        range: String = "",
        chapterUID: Int64 = 0,
        chapterID: Int64 = 0,
        createdAt: Int64,
        isSelected: Bool = false
    ) {
        self.id = id
        self.content = content
        self.idea = idea
        self.range = range
        self.chapterUID = chapterUID
        self.chapterID = chapterID
        self.createdAt = createdAt
        self.isSelected = isSelected
    }
}

nonisolated struct WereadImportReview: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var createdAt: Int64

    init(id: UUID = UUID(), title: String = "", content: String, createdAt: Int64) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
    }
}

nonisolated struct WereadImportReadingDay: Hashable, Sendable {
    let date: Int64
    let seconds: Int64
}

nonisolated struct WereadImportChapter: Identifiable, Hashable, Sendable {
    let id: UUID
    var uid: Int64
    var title: String
    var order: Int64
    var level: Int64
    var sourceAnchor: String
    var sourcePath: String
    var children: [WereadImportChapter]

    init(
        id: UUID = UUID(),
        uid: Int64,
        title: String,
        order: Int64,
        level: Int64,
        sourceAnchor: String = "",
        sourcePath: String = "",
        children: [WereadImportChapter] = []
    ) {
        self.id = id
        self.uid = uid
        self.title = title
        self.order = order
        self.level = level
        self.sourceAnchor = sourceAnchor
        self.sourcePath = sourcePath
        self.children = children
    }
}

nonisolated struct WereadImportBook: Identifiable, Hashable, Sendable {
    let id: UUID
    var wereadBookID: String
    var title: String
    var rawTitle: String
    var author: String
    var coverURL: String
    var summary: String
    var translator: String
    var isbn: String
    var press: String
    var publicationDate: String
    var wordCount: Int64?
    var wereadUpdatedAt: Int64
    var readStatusID: Int64
    var readStatusChangedAt: Int64
    var chapters: [WereadImportChapter]
    var notes: [WereadImportNote]
    var reviews: [WereadImportReview]
    var readingDays: [WereadImportReadingDay]
    var isSelected: Bool
    var targetBookID: Int64?
    var targetBookTitle: String?

    init(
        id: UUID = UUID(),
        wereadBookID: String,
        title: String,
        rawTitle: String,
        author: String,
        coverURL: String,
        summary: String = "",
        translator: String = "",
        isbn: String = "",
        press: String = "",
        publicationDate: String = "",
        wordCount: Int64? = nil,
        wereadUpdatedAt: Int64,
        readStatusID: Int64,
        readStatusChangedAt: Int64 = 0,
        chapters: [WereadImportChapter] = [],
        notes: [WereadImportNote] = [],
        reviews: [WereadImportReview] = [],
        readingDays: [WereadImportReadingDay] = [],
        isSelected: Bool = false,
        targetBookID: Int64? = nil,
        targetBookTitle: String? = nil
    ) {
        self.id = id
        self.wereadBookID = wereadBookID
        self.title = title
        self.rawTitle = rawTitle
        self.author = author
        self.coverURL = coverURL
        self.summary = summary
        self.translator = translator
        self.isbn = isbn
        self.press = press
        self.publicationDate = publicationDate
        self.wordCount = wordCount
        self.wereadUpdatedAt = wereadUpdatedAt
        self.readStatusID = readStatusID
        self.readStatusChangedAt = readStatusChangedAt
        self.chapters = chapters
        self.notes = notes
        self.reviews = reviews
        self.readingDays = readingDays
        self.isSelected = isSelected
        self.targetBookID = targetBookID
        self.targetBookTitle = targetBookTitle
    }

    var hasBrowsableContent: Bool { !notes.isEmpty || !reviews.isEmpty }
    var selectedNoteCount: Int { notes.lazy.filter(\.isSelected).count }
}

nonisolated enum WereadImportBatchStatus: Equatable, Sendable {
    case notStarted
    case loading(percent: Int)
    case failed
    case success
}

nonisolated struct WereadImportBatch: Identifiable, Equatable, Sendable {
    let id: UUID
    let number: Int
    let start: Int
    let end: Int
    let bookIDs: [String]
    var status: WereadImportBatchStatus
    var books: [WereadImportBook]

    init(
        id: UUID = UUID(),
        number: Int,
        start: Int,
        end: Int,
        bookIDs: [String],
        status: WereadImportBatchStatus = .notStarted,
        books: [WereadImportBook] = []
    ) {
        self.id = id
        self.number = number
        self.start = start
        self.end = end
        self.bookIDs = bookIDs
        self.status = status
        self.books = books
    }
}

nonisolated struct WereadBackfillPrompt: Equatable, Sendable {
    let pendingCount: Int
    let candidateKeys: Set<String>
}

nonisolated struct WereadBackfillProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparing
        case syncingRemoteBooks
        case matchingBooks
        case processingBooks
    }

    let stage: Stage
    let current: Int
    let total: Int
    let bookName: String
}

nonisolated struct WereadBackfillResult: Equatable, Sendable {
    let bookIDMatchedCount: Int
    let chapterUIDUpdatedCount: Int
    let skippedCount: Int
    let partialFailureCount: Int
    let handledCandidateKeys: Set<String>
}

nonisolated enum WereadImportError: LocalizedError, Sendable {
    case authorizationExpired
    case invalidResponse
    case remote(code: Int, message: String)
    case emptyImport
    case photoPermissionDenied
    case message(String)

    var errorDescription: String? {
        switch self {
        case .authorizationExpired:
            return "微信读书登录已失效，请重新扫码授权"
        case .invalidResponse:
            return "微信读书返回的数据格式异常"
        case .remote(_, let message):
            return message.isEmpty ? "微信读书请求失败" : message
        case .emptyImport:
            return "没有获取到可导入的内容"
        case .photoPermissionDenied:
            return "无法保存二维码，请在系统设置中允许纸间添加照片"
        case .message(let message):
            return message
        }
    }
}
