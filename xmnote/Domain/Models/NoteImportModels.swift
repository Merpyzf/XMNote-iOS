/**
 * [INPUT]: 依赖 Foundation，承接各正式书摘来源解析后的书籍、目录、书摘、书评、附件、标签与阅读时长
 * [OUTPUT]: 对外提供 NoteImportDraftBook、NoteImportParser、NoteImportParserID 与稳定错误模型
 * [POS]: Domain/Models 的统一书摘导入契约，被 Parser、Repository、ViewModel 与导入预览共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated enum NoteImportParserID: String, Codable, CaseIterable, Hashable, Sendable {
    case booxOld = "boox-old"
    case booxNew = "boox-new"
    case doubanRead = "douban-read"
    case dedao
    case dangdang
    case dimo
    case wereadOld = "weread-old"
    case wereadPre830 = "weread-pre-830"
    case weread830 = "weread-830"
    case duokan
    case ireaderSelected = "ireader-selected"
    case moonReader = "moon-reader"
    case doubanApp = "douban-app"
    case reader163 = "reader-163"
    case fanqie
    case readingo
    case kindleApp = "kindle-app"
    case koreader
    case legado
    case neatReader = "neat-reader"
    case koodo
    case reeden
    case kindle
    case jdReader = "jd-reader"
    case ireaderFile = "ireader-file"
    case ireaderEpub = "ireader-epub"
    case appleBooks = "apple-books"
    case hanwang
}

nonisolated enum NoteImportParserError: LocalizedError, Equatable, Sendable {
    case noteFormat
    case bookNotFound
    case noteNotFound
    case invalidDatabase
    case unexpected(String)

    var code: String {
        switch self {
        case .noteFormat: "note_format"
        case .bookNotFound: "book_not_found"
        case .noteNotFound: "note_not_found"
        case .invalidDatabase: "invalid_database"
        case .unexpected: "unexpected"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noteFormat: "笔记格式有误"
        case .bookNotFound: "笔记格式有误，无法解析到书籍信息"
        case .noteNotFound: "笔记格式有误，无法解析到书摘信息"
        case .invalidDatabase: "无法识别的数据库文件"
        case let .unexpected(message): message.isEmpty ? "未知解析错误" : message
        }
    }
}

/// Kindle 系统文件入口的稳定错误语义，覆盖 Android OTG 同等的大小、空间和访问失败边界。
nonisolated enum KindleImportFileError: LocalizedError, Equatable, Sendable {
    case invalidFileName
    case fileTooLarge
    case insufficientStorage
    case accessDenied
    case readFailed

    var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "请选择 Kindle 的 Documents/My Clippings.txt"
        case .fileTooLarge:
            return "My Clippings.txt 不能超过 32 MiB"
        case .insufficientStorage:
            return "设备可用空间不足，无法暂存 Kindle 书摘文件"
        case .accessDenied:
            return "无法访问所选文件，请确认 Kindle 仍已连接并重新选择"
        case .readFailed:
            return "无法完整读取 Kindle 书摘文件，请检查连接后重试"
        }
    }
}

nonisolated protocol NoteImportParser: Sendable {
    var id: NoteImportParserID { get }

    /// 解析原始文件字节；实现必须保留 Android Parser 的文本、数组顺序和错误语义。
    func parse(data: Data, fileExtension: String?) async throws -> [NoteImportDraftBook]
}

/// Android 中依赖 DocumentFile 文件名的来源通过该附加协议接收文件名；内容解析仍走同一 Parser 实例。
nonisolated protocol NoteImportFileNameAwareParser: NoteImportParser {
    func parse(data: Data, fileName: String, fileExtension: String?) async throws -> [NoteImportDraftBook]
}

nonisolated struct NoteImportDraftBook: Equatable, Sendable {
    var name = ""
    var rawName = ""
    var doubanID: Int64 = 0
    var author = ""
    var authorIntro = ""
    var translator = ""
    var press = ""
    var isbn = ""
    var summary = ""
    var pubDate = ""
    var cover = ""
    var type: Int64 = 0
    var source: Int64 = 1
    var sourceName = ""
    var positionUnit: Int64 = 2
    var currentPositionUnit: Int64 = 2
    var readPosition: Double = 0
    var bookmarkModifiedTime: Int64 = 0
    var totalPosition: Int64 = 0
    var totalPagination: Int64 = 0
    var wordCount: Int64?
    var score: Int64 = 0
    var purchaseDate: Int64 = 0
    var price: Double = 0
    var readStatusID: Int64 = 2
    var readStatusChangedDate: Int64 = 0
    var readDoneTime: Int64 = 0
    var wereadBookID = ""
    var wereadUpdateTime: Int64 = 0
    var group: NoteImportDraftGroup?
    var groups: [NoteImportDraftGroup] = []
    var tags: [NoteImportDraftTag] = []
    var notes: [NoteImportDraftNote] = []
    var chapters: [NoteImportDraftChapter] = []
    var reviews: [NoteImportDraftReview] = []
    var preciseReadingDurations: [NoteImportPreciseReadingDuration]?
    var fuzzyReadingDurations: [NoteImportFuzzyReadingDuration]?
    var wereadReadingDurations: [NoteImportFuzzyReadingDuration]?
}

nonisolated struct NoteImportDraftNote: Equatable, Sendable {
    var content = ""
    var idea = ""
    var position = ""
    var positionUnit: Int64 = 2
    var createdTime: Int64 = 0
    var isIncludeTime = true
    var wereadRange = ""
    var wereadChapterUID: Int64 = 0
    var chapter: NoteImportDraftChapter?
    var tags: [NoteImportDraftTag] = []
    var attachments: [NoteImportDraftAttachment] = []
}

nonisolated struct NoteImportDraftChapter: Equatable, Sendable {
    var title = ""
    var remark = ""
    var level: Int64 = 0
    var order: Int64 = 0
    var pathTitles: [String] = []
    var sourceType: Int64 = 0
    var sourceUID = ""
    var sourceAnchor = ""
    var sourceOrder: Int64 = 0
    var sourcePath = ""
    var children: [NoteImportDraftChapter] = []
}

nonisolated struct NoteImportDraftReview: Equatable, Sendable {
    var title = ""
    var content = ""
    var createdTime: Int64 = 0
    var images: [NoteImportDraftReviewImage] = []
}

nonisolated struct NoteImportDraftAttachment: Equatable, Sendable {
    var imageURL = ""
    var digest = ""
    var order: Int64 = 0
}

nonisolated struct NoteImportDraftReviewImage: Equatable, Sendable {
    var image = ""
    var order: Int64 = 0
}

nonisolated struct NoteImportDraftTag: Equatable, Sendable {
    var name = ""
    var color: Int64 = 0
    var order: Int64 = 0
    var type: Int64 = 0
}

nonisolated struct NoteImportDraftGroup: Equatable, Sendable {
    var name = ""
    var order: Int64 = Int64(Int32.max)
}

nonisolated struct NoteImportPreciseReadingDuration: Equatable, Sendable {
    var startTime: Int64?
    var endTime: Int64?
    var position: Double?
}

nonisolated struct NoteImportFuzzyReadingDuration: Equatable, Sendable {
    var date: Int64?
    var durationSeconds: Int64?
    var position: Double?
}

/// 统一预览确认后的单书提交载荷。targetBookID 为空时创建新书，否则增量合并到本地书。
nonisolated struct NoteImportCommitBook: Equatable, Sendable {
    var draft: NoteImportDraftBook
    var targetBookID: Int64?

    init(draft: NoteImportDraftBook, targetBookID: Int64? = nil) {
        self.draft = draft
        self.targetBookID = targetBookID
    }
}
