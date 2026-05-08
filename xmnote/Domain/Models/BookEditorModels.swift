/**
 * [INPUT]: 依赖 Foundation 的值类型语义，承接书籍录入页的编辑状态、偏好和下拉选项
 * [OUTPUT]: 对外提供 BookEntryBookType、BookEntryProgressUnit、BookEntryReadingStatus、BookEditorMode、BookEditorDraft、BookEditorOptions、BookEntryPreference 等录入域模型
 * [POS]: Domain/Models 的书籍录入模型定义，被录入仓储、录入页 ViewModel 与保存事务共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书籍类型，对齐 Android `BookType`。
enum BookEntryBookType: Int64, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case paper = 0
    case ebook = 1

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .paper:
            return "纸质书"
        case .ebook:
            return "电子书"
        }
    }

    var defaultProgressUnit: BookEntryProgressUnit {
        switch self {
        case .paper:
            return .pagination
        case .ebook:
            return .position
        }
    }
}

/// 阅读进度单位，对齐 Android `BookPositionUnit`。
enum BookEntryProgressUnit: Int64, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case progress = 0
    case position = 1
    case pagination = 2

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .progress:
            return "进度"
        case .position:
            return "位置"
        case .pagination:
            return "页数"
        }
    }
}

/// 阅读状态，对齐 Android `BookReadingStatus`。
enum BookEntryReadingStatus: Int64, CaseIterable, Identifiable, Hashable, Sendable {
    case wantRead = 1
    case reading = 2
    case finished = 3
    case abandoned = 4
    case onHold = 5

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .wantRead:
            return "想读"
        case .reading:
            return "在读"
        case .finished:
            return "读完"
        case .abandoned:
            return "弃读"
        case .onHold:
            return "搁置"
        }
    }
}

/// 书籍录入页模式，区分搜索/手动新增与既有书籍编辑两条保存路径。
enum BookEditorMode: Hashable, Sendable {
    case create(seed: BookEditorSeed?)
    case edit(bookId: Int64)
}

/// 录入页可复用的命名选项，统一表示来源/分组/标签。
nonisolated struct BookEditorNamedOption: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
}

/// 录入偏好，只持久化 Android 端已存在的四项默认值。
struct BookEntryPreference: Hashable, Sendable {
    var bookType: BookEntryBookType
    var sourceName: String
    var progressUnit: BookEntryProgressUnit
    var readingStatus: BookEntryReadingStatus

    static let `default` = BookEntryPreference(
        bookType: .paper,
        sourceName: "未知",
        progressUnit: .pagination,
        readingStatus: .reading
    )
}

/// 录入页选项集合，承接来源、分组、标签和当前偏好。
struct BookEditorOptions: Hashable, Sendable {
    let sources: [BookEditorNamedOption]
    let groups: [BookEditorNamedOption]
    let tags: [BookEditorNamedOption]
    let preference: BookEntryPreference
}

/// 录入页草稿，覆盖 Android 完整录入页的核心字段与本地选择状态。
struct BookEditorDraft: Equatable, Sendable {
    var title: String
    var rawTitle: String
    var author: String
    var authorIntro: String
    var translator: String
    var press: String
    var isbn: String
    var pubDate: String
    var summary: String
    var catalog: String
    var coverURL: String
    var doubanId: Int?
    var totalPagesText: String
    var totalPositionText: String
    var currentProgressText: String
    var wordCount: Int?
    var sourceName: String
    var groupName: String
    var tagNames: [String]
    var purchaseDate: Date?
    var priceText: String
    var readStatusChangedDate: Date
    var bookType: BookEntryBookType
    var progressUnit: BookEntryProgressUnit
    var readingStatus: BookEntryReadingStatus
    var searchSource: BookSearchSource?

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedTagNames: [String] {
        Array(
            Set(
                tagNames
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }
}

/// 保存阶段的业务错误，避免界面层自行推断判重或数据不合法。
enum BookEditorError: LocalizedError {
    case emptyTitle
    case duplicateBook
    case bookNotFound

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "书名不能为空"
        case .duplicateBook:
            return "该书已存在"
        case .bookNotFound:
            return "书籍不存在或已删除"
        }
    }
}
